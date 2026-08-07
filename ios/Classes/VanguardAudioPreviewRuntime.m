// VanguardAudioPreviewRuntime.m
// Vanguard Media Engine — Phase 10-C Slice K / V-B1
//
// Implementation of VanguardAudioPreviewRuntime.
// See VanguardAudioPreviewRuntime.h for architecture, threading, and API docs.
//
// V-B1: three-slot (Added Audio + Voice-over + Original Audio) architecture.
// Original role tracks are routed to _originalAudioSlot, not _addedAudioSlot.
// Music/SFX go to _addedAudioSlot; voiceover goes to _voiceoverSlot.
// One master boundary timer fires at the earliest next-decision PTS across all
// three lanes.

#import "VanguardAudioPreviewRuntime.h"
#import "VGAudioPreviewAutomationCoordinator.h"
#import "VGAudioPreviewAutomationTimer.h"
#import "VGAudioPreviewTrackDescriptor.h"

#if VG_USE_V2_GRAPH

#import "VGAudioPreviewProductionCollaborators.h"
#import <QuartzCore/QuartzCore.h>
#import <UMF/VGAudioSidecarPlan.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - VGAudioPreviewSlot — per-lane state container
// ─────────────────────────────────────────────────────────────────────────────
//
// Bundles all state specific to one scheduling lane (Added Audio or
// Voice-over). The runtime owns two slots; one master boundary timer is shared.

@interface VGAudioPreviewSlot : NSObject

@property(nonatomic, strong) id<VGAudioPreviewPlayer> player;
@property(nonatomic, strong) VGAudioPreviewAutomationCoordinator *coordinator;

// Active-descriptor state — set by _activateDescriptor:atPTS:inSlot:.
@property(nonatomic, strong, nullable)
    VGAudioPreviewTrackDescriptor *activeDescriptor;
@property(nonatomic) NSTimeInterval timelineStart;
@property(nonatomic) NSTimeInterval sourceTrimStart;
@property(nonatomic) NSTimeInterval activeDuration;
@property(nonatomic) double fileSampleRate;
@property(nonatomic) AVAudioFramePosition fileLengthFrames;

/// The last raw envelope volume written by the automation gainSink (or
/// staticVolume for non-keyframed slots). This is the value BEFORE mixGain is
/// applied. Used by setMixGainForTrackId to re-apply the current envelope
/// level with a new mixGain without requiring division by the old mixGain.
@property(nonatomic) float currentRawEnvelopeVolume;

/// The effective player volume (currentRawEnvelopeVolume * activeMixGain).
@property(nonatomic) float currentVolume;

// Per-slot completion-serial. Incremented on each schedule call within this
// slot. Completion handlers capture this value to detect stale callbacks.
@property(nonatomic) uint64_t scheduledSegmentSerial;

// Tracks the scheduledEndPTS of the most recently queued segment so that
// _reevaluateAndTransitionAtPTS: can skip re-queuing when the slot is already
// scheduled past the current evaluation point (prevents double-buffering when a
// DataConsumed completion callback fires early and the boundary timer fires for
// the same evaluation PTS).
@property(nonatomic) NSTimeInterval scheduledEndPTS;

@end

@implementation VGAudioPreviewSlot

- (instancetype)init {
  self = [super init];
  if (self) {
    _activeDescriptor = nil;
    _timelineStart = 0.0;
    _sourceTrimStart = 0.0;
    _activeDuration = 0.0;
    _fileSampleRate = 0.0;
    _fileLengthFrames = 0;
    _currentRawEnvelopeVolume = 1.0;
    _scheduledSegmentSerial = 0;
    _scheduledEndPTS = 0.0;
  }
  return self;
}

/// Returns the end PTS of the currently active descriptor for this slot.
/// Returns 0 if no active descriptor.
- (NSTimeInterval)activeDescriptorTrackEnd {
  if (!_activeDescriptor)
    return 0.0;
  return _timelineStart + _activeDuration;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardAudioPreviewRuntime (private ivar extension)
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardAudioPreviewRuntime () {
  // ── Queue identity ──────────────────────────────────────────────────────
  dispatch_queue_t _schedulerQueue;
  void *_schedulerQueueKey; ///< dispatch_queue_specific key.

  // ── Collaborators ────────────────────────────────────────────────────────
  id<VGAudioPreviewClock> _clock;
  id<VGAudioPreviewTimer> _boundaryTimer; ///< One master boundary timer.
  id<VGAudioPreviewFileProvider> _fileProvider;
  id<VGAudioPreviewEngine> _engine;

  // ── V-B1: three-slot architecture ──────────────────────────────────────
  // Each slot bundles its own player, coordinator, active descriptor, and
  // per-slot scheduled-segment serial. The master boundary timer remains
  // shared.
  VGAudioPreviewSlot *_addedAudioSlot;    ///< music / sfx lane.
  VGAudioPreviewSlot *_voiceoverSlot;     ///< voiceover lane.
  VGAudioPreviewSlot *_originalAudioSlot; ///< original/video audio lane.

  // ── Snapshot provider ────────────────────────────────────────────────────
  VGTimelineSnapshotProvider _snapshotProvider;

  // ── Lifecycle ────────────────────────────────────────────────────────────
  uint64_t _lifecycleEpoch;
  // _acceptingCommands: fast atomic check for hot-path command gates.
  // Set to NO at the start of invalidation to immediately block new commands.
  _Atomic(BOOL) _acceptingCommands;

  // Three-state invalidation. Transitions: Accepting → Invalidating →
  // Invalidated. All mutations protected by _invalidationLock.
  os_unfair_lock _invalidationLock;
  VGAudioPreviewInvalidationState _invalidationPhase;
  NSMutableArray<dispatch_block_t> *_invalidationWaiters;

  // ── Queue-confined state ─────────────────────────────────────────────────
  VGAudioPreviewRuntimeState _runtimeState;
  uint64_t _commandSerial;
  VGAudioPreviewWorkToken _activeToken;

  // ── Track data (Slice F/K: multi-descriptor, two lanes) ─────────────────
  //
  // _descriptors: ordered list of all audible (volume > 0), structurally valid
  //   descriptors produced from prepareWithSidecarPlan:. Ordering matches the
  //   sidecar plan's track array (plan order = final tie-break).
  //   Partitioned by lane at selection time, not at parse time.
  //
  // _fileCache: maps trackId → opened AVAudioFile.
  // _failedTrackIds: set of trackIds that failed to open permanently.
  // _timelineDuration: authoritative project duration.
  NSArray<VGAudioPreviewTrackDescriptor *> *_descriptors;
  NSMutableDictionary<NSString *, AVAudioFile *> *_fileCache;
  NSMutableSet<NSString *> *_failedTrackIds;
  NSTimeInterval _timelineDuration;

  // ── V-B1/V-B2: per-track mix gain (live slider) ────────────────────
  // Default 1.0 per track. Keyed by trackId. Written only on the scheduler queue.
  NSMutableDictionary<NSString *, NSNumber *> *_mixGainByTrackId;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardAudioPreviewRuntime implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardAudioPreviewRuntime

// ─── Init
// ─────────────────────────────────────────────────────────────────

- (instancetype)initWithSnapshotProvider:
                    (VGTimelineSnapshotProvider)snapshotProvider
                          lifecycleEpoch:(uint64_t)lifecycleEpoch {
  AVAudioEngine *engine = [[AVAudioEngine alloc] init];
  // V-B1: three player nodes — Added Audio, Voice-over, and Original Audio.
  AVAudioPlayerNode *addedAudioNode = [[AVAudioPlayerNode alloc] init];
  AVAudioPlayerNode *voiceoverNode = [[AVAudioPlayerNode alloc] init];
  AVAudioPlayerNode *originalAudioNode = [[AVAudioPlayerNode alloc] init];

  id<VGAudioPreviewEngine> engineAdapter =
      [[VGProductionAudioPreviewEngine alloc] initWithEngine:engine];
  id<VGAudioPreviewPlayer> addedAudioAdapter =
      [[VGProductionAudioPreviewPlayer alloc] initWithNode:addedAudioNode];
  id<VGAudioPreviewPlayer> voiceoverAdapter =
      [[VGProductionAudioPreviewPlayer alloc] initWithNode:voiceoverNode];
  id<VGAudioPreviewPlayer> originalAudioAdapter =
      [[VGProductionAudioPreviewPlayer alloc] initWithNode:originalAudioNode];

  // Wire all three player nodes into the engine before any scheduling arrives.
  [engine attachNode:addedAudioNode];
  [engine connect:addedAudioNode to:engine.mainMixerNode format:nil];
  [engine attachNode:voiceoverNode];
  [engine connect:voiceoverNode to:engine.mainMixerNode format:nil];
  [engine attachNode:originalAudioNode];
  [engine connect:originalAudioNode to:engine.mainMixerNode format:nil];

  return [self
       initWithSnapshotProvider:snapshotProvider
                 lifecycleEpoch:lifecycleEpoch
                          clock:[[VGProductionAudioPreviewClock alloc] init]
                          timer:nil
      addedAudioAutomationTimer:nil
       voiceoverAutomationTimer:nil
     originalAudioAutomationTimer:nil
                   fileProvider:[[VGProductionAudioPreviewFileProvider alloc]
                                    init]
                         engine:engineAdapter
               addedAudioPlayer:addedAudioAdapter
                voiceoverPlayer:voiceoverAdapter
            originalAudioPlayer:originalAudioAdapter];
}

/// Slice K backward-compat two-player trampoline. Passes same player/timer for
/// Original Audio slot as Added Audio slot.
- (instancetype)
    initWithSnapshotProvider:(VGTimelineSnapshotProvider)snapshotProvider
              lifecycleEpoch:(uint64_t)lifecycleEpoch
                       clock:(id<VGAudioPreviewClock>)clock
                       timer:(nullable id<VGAudioPreviewTimer>)timer
             automationTimer:
                 (nullable id<VGAudioPreviewAutomationTimer>)automationTimer
                fileProvider:(id<VGAudioPreviewFileProvider>)fileProvider
                      engine:(id<VGAudioPreviewEngine>)engine
                      player:(id<VGAudioPreviewPlayer>)player {
  return [self
       initWithSnapshotProvider:snapshotProvider
                 lifecycleEpoch:lifecycleEpoch
                          clock:clock
                          timer:timer
      addedAudioAutomationTimer:automationTimer
       voiceoverAutomationTimer:nil // production timer created in designated
                                    // init
     originalAudioAutomationTimer:nil
                   fileProvider:fileProvider
                         engine:engine
               addedAudioPlayer:player
                voiceoverPlayer:player // same player — backward compatible
            originalAudioPlayer:player]; // same as added — backward compatible
}

/// Slice K backward-compat two-slot trampoline (separate per-slot players and
/// automation timers, but no Original Audio slot parameters).
/// Forwards to the V-B1 three-slot designated initializer using
/// addedAudioAutomationTimer and addedAudioPlayer for the Original slot so
/// that existing Slice K tests continue to compile and run unchanged.
- (instancetype)
     initWithSnapshotProvider:(VGTimelineSnapshotProvider)snapshotProvider
               lifecycleEpoch:(uint64_t)lifecycleEpoch
                        clock:(id<VGAudioPreviewClock>)clock
                        timer:(nullable id<VGAudioPreviewTimer>)timer
    addedAudioAutomationTimer:
        (nullable id<VGAudioPreviewAutomationTimer>)addedAudioAutomationTimer
     voiceoverAutomationTimer:
         (nullable id<VGAudioPreviewAutomationTimer>)voiceoverAutomationTimer
                 fileProvider:(id<VGAudioPreviewFileProvider>)fileProvider
                       engine:(id<VGAudioPreviewEngine>)engine
             addedAudioPlayer:(id<VGAudioPreviewPlayer>)addedAudioPlayer
              voiceoverPlayer:(id<VGAudioPreviewPlayer>)voiceoverPlayer {
  return [self
       initWithSnapshotProvider:snapshotProvider
                 lifecycleEpoch:lifecycleEpoch
                          clock:clock
                          timer:timer
      addedAudioAutomationTimer:addedAudioAutomationTimer
       voiceoverAutomationTimer:voiceoverAutomationTimer
     // Original slot: reuse Added Audio collaborators for backward compat.
     originalAudioAutomationTimer:addedAudioAutomationTimer
                   fileProvider:fileProvider
                         engine:engine
               addedAudioPlayer:addedAudioPlayer
                voiceoverPlayer:voiceoverPlayer
            originalAudioPlayer:addedAudioPlayer];
}

/// V-B1 three-slot designated initializer.
- (instancetype)
     initWithSnapshotProvider:(VGTimelineSnapshotProvider)snapshotProvider
               lifecycleEpoch:(uint64_t)lifecycleEpoch
                        clock:(id<VGAudioPreviewClock>)clock
                        timer:(nullable id<VGAudioPreviewTimer>)timer
    addedAudioAutomationTimer:
        (nullable id<VGAudioPreviewAutomationTimer>)addedAudioAutomationTimer
     voiceoverAutomationTimer:
         (nullable id<VGAudioPreviewAutomationTimer>)voiceoverAutomationTimer
   originalAudioAutomationTimer:
       (nullable id<VGAudioPreviewAutomationTimer>)originalAudioAutomationTimer
                 fileProvider:(id<VGAudioPreviewFileProvider>)fileProvider
                       engine:(id<VGAudioPreviewEngine>)engine
             addedAudioPlayer:(id<VGAudioPreviewPlayer>)addedAudioPlayer
              voiceoverPlayer:(id<VGAudioPreviewPlayer>)voiceoverPlayer
          originalAudioPlayer:(id<VGAudioPreviewPlayer>)originalAudioPlayer {
  self = [super init];
  if (!self)
    return nil;

  _snapshotProvider = [snapshotProvider copy];
  _lifecycleEpoch = lifecycleEpoch;
  _clock = clock;
  _fileProvider = fileProvider;
  _engine = engine;

  // ── Serial scheduler queue ────────────────────────────────────────────
  _schedulerQueueKey =
      &_schedulerQueueKey; // unique pointer for dispatch_get_specific
  _schedulerQueue = dispatch_queue_create(
      "com.vanguard.audioPreviewScheduler",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                              QOS_CLASS_USER_INTERACTIVE, 0));
  dispatch_queue_set_specific(_schedulerQueue, _schedulerQueueKey,
                              (__bridge void *)self, NULL);

  // ── Master boundary timer ────────────────────────────────────────────────
  if (timer) {
    _boundaryTimer = timer;
  } else {
    _boundaryTimer =
        [[VGProductionAudioPreviewTimer alloc] initWithQueue:_schedulerQueue];
  }

  // ── V-B1: build Added Audio slot (music/sfx only) ────────────────────────
  _addedAudioSlot = [[VGAudioPreviewSlot alloc] init];
  _addedAudioSlot.player = addedAudioPlayer;
  {
    id<VGAudioPreviewAutomationTimer> aaTimer;
    if (addedAudioAutomationTimer) {
      aaTimer = addedAudioAutomationTimer;
    } else {
      aaTimer = [[VGProductionAudioPreviewAutomationTimer alloc]
          initWithQueue:_schedulerQueue];
    }
    __weak typeof(self) weakSelf = self;
    _addedAudioSlot.coordinator = [[VGAudioPreviewAutomationCoordinator alloc]
        initWithTimer:aaTimer
             gainSink:^(float v) {
               typeof(self) ss = weakSelf;
               if (!ss)
                 return;
               // V-B1: v is the raw envelope value from the automation
               // coordinator. Store it so setMixGainForTrackId can re-apply
               // with a new mixGain without dividing by the old gain.
               ss->_addedAudioSlot.currentRawEnvelopeVolume = v;
               VGAudioPreviewTrackDescriptor *desc =
                   ss->_addedAudioSlot.activeDescriptor;
               NSNumber *stored =
                   desc ? ss->_mixGainByTrackId[desc.trackId] : nil;
               float mixGain = stored ? stored.floatValue
                                      : (desc ? desc.committedMixGain : 1.0f);
               mixGain = MAX(0.0f, MIN(1.0f, mixGain));
               float effective = v * mixGain;
               [ss->_addedAudioSlot.player setVolume:effective];
               ss->_addedAudioSlot.currentVolume = effective;
             }];
  }

  // ── V-B1: build Voice-over slot ──────────────────────────────────────────
  _voiceoverSlot = [[VGAudioPreviewSlot alloc] init];
  _voiceoverSlot.player = voiceoverPlayer;
  {
    id<VGAudioPreviewAutomationTimer> voTimer;
    if (voiceoverAutomationTimer) {
      voTimer = voiceoverAutomationTimer;
    } else {
      voTimer = [[VGProductionAudioPreviewAutomationTimer alloc]
          initWithQueue:_schedulerQueue];
    }
    __weak typeof(self) weakSelf = self;
    _voiceoverSlot.coordinator = [[VGAudioPreviewAutomationCoordinator alloc]
        initWithTimer:voTimer
             gainSink:^(float v) {
               typeof(self) ss = weakSelf;
               if (!ss)
                 return;
               // V-B1: v is the raw envelope value — store before mixing.
               ss->_voiceoverSlot.currentRawEnvelopeVolume = v;
               VGAudioPreviewTrackDescriptor *desc =
                   ss->_voiceoverSlot.activeDescriptor;
               NSNumber *stored =
                   desc ? ss->_mixGainByTrackId[desc.trackId] : nil;
               float mixGain = stored ? stored.floatValue
                                      : (desc ? desc.committedMixGain : 1.0f);
               mixGain = MAX(0.0f, MIN(1.0f, mixGain));
               float effective = v * mixGain;
               [ss->_voiceoverSlot.player setVolume:effective];
               ss->_voiceoverSlot.currentVolume = effective;
             }];
  }

  // ── V-B1: build Original Audio slot ───────────────────────────────────────
  _originalAudioSlot = [[VGAudioPreviewSlot alloc] init];
  _originalAudioSlot.player = originalAudioPlayer;
  {
    id<VGAudioPreviewAutomationTimer> origTimer;
    if (originalAudioAutomationTimer) {
      origTimer = originalAudioAutomationTimer;
    } else {
      origTimer = [[VGProductionAudioPreviewAutomationTimer alloc]
          initWithQueue:_schedulerQueue];
    }
    __weak typeof(self) weakSelf = self;
    _originalAudioSlot.coordinator = [[VGAudioPreviewAutomationCoordinator alloc]
        initWithTimer:origTimer
             gainSink:^(float v) {
               typeof(self) ss = weakSelf;
               if (!ss)
                 return;
               // V-B1: v is the raw envelope value — store before mixing.
               ss->_originalAudioSlot.currentRawEnvelopeVolume = v;
               VGAudioPreviewTrackDescriptor *desc =
                   ss->_originalAudioSlot.activeDescriptor;
               NSNumber *stored =
                   desc ? ss->_mixGainByTrackId[desc.trackId] : nil;
               float mixGain = stored ? stored.floatValue
                                      : (desc ? desc.committedMixGain : 1.0f);
               mixGain = MAX(0.0f, MIN(1.0f, mixGain));
               float effective = v * mixGain;
               [ss->_originalAudioSlot.player setVolume:effective];
               ss->_originalAudioSlot.currentVolume = effective;
             }];
  }

  // ── Initial lifecycle state ───────────────────────────────────────────────
  _acceptingCommands = YES;
  _invalidationLock = OS_UNFAIR_LOCK_INIT;
  _invalidationPhase = VGAudioPreviewInvalidationStateAccepting;
  _invalidationWaiters = [NSMutableArray new];
  _runtimeState = VGAudioPreviewRuntimeStateUnprepared;
  _commandSerial = 0;
  _activeToken = (VGAudioPreviewWorkToken){lifecycleEpoch, 0, 0};
  _timelineDuration = 0.0;
  _descriptors = @[];
  _fileCache = [NSMutableDictionary new];
  _failedTrackIds = [NSMutableSet new];
  _mixGainByTrackId = [NSMutableDictionary new];

  // ── Slice N: AVAudioEngineConfigurationChangeNotification
  // ───────────────────
  //
  // AVAudioEngine stops itself asynchronously when the hardware route or
  // sample-rate changes (e.g. after a PlayAndRecord ↔ Playback session
  // category switch). The notification fires AFTER the engine has already
  // stopped and flushed all player-node buffers. We register here so we can
  // clear stale scheduledEndPTS and restart the engine if the timeline is
  // actively playing. The observer is removed in invalidateAsync:.
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(_handleEngineConfigurationChange:)
             name:AVAudioEngineConfigurationChangeNotification
           object:nil];

  return self;
}

// ─── Queue assertion
// ──────────────────────────────────────────────────────────

- (void)assertOnSchedulerQueue {
  NSAssert(
      dispatch_get_specific(_schedulerQueueKey) == (__bridge void *)self,
      @"[VanguardAudioPreviewRuntime] Operation must be on scheduler queue");
}

// ─── Preparation ─────────────────────────────────────────────────────────────

- (VGAudioPreviewPreparationResult)
    prepareWithSidecarPlan:(nullable VGAudioSidecarPlan *)plan
          timelineDuration:(NSTimeInterval)timelineDuration {
  if (!_acceptingCommands) {
    return VGAudioPreviewPreparationResultSilentNoEligibleTrack;
  }

  _timelineDuration = MAX(0.0, timelineDuration);

  // ── Step 1: parse all structurally valid, audible descriptors ─────────────
  //
  // Eligible means:
  //   (a) initWithDictionary: succeeds (role is music, original, sfx, or
  //       voiceover — all four are accepted);
  //   (b) staticVolume > 0.0 OR hasRawKeyframes (Slice J: keyframes may render
  //       audible gain even when staticVolume == 0.0).
  //
  // The ordered array preserves plan-array order for the tie-break rule.

  NSMutableArray<VGAudioPreviewTrackDescriptor *> *eligible =
      [NSMutableArray new];
  VGAudioPreviewPreparationResult lastFileError =
      VGAudioPreviewPreparationResultSilentNoEligibleTrack;

  if (plan) {
    for (NSDictionary<NSString *, id> *trackDict in plan.tracks) {
      VGAudioPreviewTrackDescriptor *candidate =
          [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:trackDict];
      if (!candidate)
        continue; // malformed or unsupported role — skip
      // Slice J: a descriptor with raw keyframes is eligible even if
      // staticVolume == 0.0, because the envelope may render audible gain.
      if (candidate.staticVolume <= 0.0f && !candidate.hasRawKeyframes)
        continue; // muted by composition policy with no keyframe automation
      [eligible addObject:candidate];
    }
  }

  if (eligible.count == 0) {
    _runtimeState = VGAudioPreviewRuntimeStateReadySilent;
    NSLog(@"[VanguardAudioPreviewRuntime][D] prepare: no audible eligible "
          @"descriptors — silent");
    return VGAudioPreviewPreparationResultSilentNoEligibleTrack;
  }

  // Deactivate all three coordinators before replacing descriptor state.
  [_addedAudioSlot.coordinator deactivate];
  [_voiceoverSlot.coordinator deactivate];
  [_originalAudioSlot.coordinator deactivate];
  _addedAudioSlot.activeDescriptor = nil;
  _voiceoverSlot.activeDescriptor = nil;
  _originalAudioSlot.activeDescriptor = nil;
  _descriptors = [eligible copy];
  [_fileCache removeAllObjects];
  [_failedTrackIds removeAllObjects];
  // V-B1: Clear stale live-gain overrides so they don't bleed into the new plan.
  [_mixGainByTrackId removeAllObjects];

  // ── Step 2: open the earliest-needed descriptor's file & start engine ─────
  //
  // "Earliest-needed" = descriptor with minimum timelineStart.
  // Later descriptors are opened lazily at schedule time.

  VGAudioPreviewTrackDescriptor *firstDesc = eligible[0];
  for (VGAudioPreviewTrackDescriptor *d in eligible) {
    if (d.timelineStart < firstDesc.timelineStart)
      firstDesc = d;
  }

  BOOL fileExists = [_fileProvider fileExistsAtURL:firstDesc.fileURL];
  NSError *fileError = nil;
  AVAudioFile *firstFile = [_fileProvider openFileAtURL:firstDesc.fileURL
                                                  error:&fileError];
  if (!firstFile) {
    NSLog(@"[VanguardAudioPreviewRuntime][D] prepare: earliest file "
          @"missing/unreadable — %@",
          fileError.localizedDescription);
    [_failedTrackIds addObject:firstDesc.trackId];
    _runtimeState = VGAudioPreviewRuntimeStateReadySilent;
    lastFileError =
        !fileExists ? VGAudioPreviewPreparationResultFailedMissingFile
                    : VGAudioPreviewPreparationResultFailedUnsupportedFormat;

    if (eligible.count == 1)
      return lastFileError;
    _runtimeState = VGAudioPreviewRuntimeStateReadySilent;
    return VGAudioPreviewPreparationResultSilentNoEligibleTrack;
  }

  // Validate metadata.
  double firstSampleRate = firstFile.processingFormat.sampleRate;
  AVAudioFramePosition firstFrames = firstFile.length;
  if (firstSampleRate <= 0.0 || firstFrames <= 0) {
    NSLog(@"[VanguardAudioPreviewRuntime][D] prepare: invalid file metadata");
    [_failedTrackIds addObject:firstDesc.trackId];
    _runtimeState = VGAudioPreviewRuntimeStateReadySilent;
    if (eligible.count == 1)
      return VGAudioPreviewPreparationResultFailedInvalidDuration;
    return VGAudioPreviewPreparationResultSilentNoEligibleTrack;
  }

  // Compute conservative active duration for earliest descriptor.
  NSTimeInterval ts = MAX(0.0, firstDesc.timelineStart);
  NSTimeInterval trim = MAX(0.0, firstDesc.sourceTrimStart);
  double fileDur = (double)firstFrames / firstSampleRate;
  NSTimeInterval availSrc = MAX(0.0, fileDur - trim);
  NSTimeInterval reqActive = (firstDesc.requestedDuration == -1.0)
                                 ? availSrc
                                 : MAX(0.0, firstDesc.requestedDuration);
  NSTimeInterval projRemaining = MAX(0.0, _timelineDuration - ts);
  NSTimeInterval activeDur = MIN(MIN(reqActive, availSrc), projRemaining);

  if (activeDur <= 0.0 && eligible.count == 1) {
    NSLog(@"[VanguardAudioPreviewRuntime][D] prepare: earliest file zero "
          @"active duration — silent");
    [_failedTrackIds addObject:firstDesc.trackId];
    _runtimeState = VGAudioPreviewRuntimeStateReadySilent;
    return VGAudioPreviewPreparationResultSilentNoEligibleTrack;
  }

  // Cache the file.
  _fileCache[firstDesc.trackId] = firstFile;

  // ── Step 3: start engine ──────────────────────────────────────────────────
  [_engine prepare];
  NSError *engineError = nil;
  if (![_engine startAndReturnError:&engineError]) {
    NSLog(@"[VanguardAudioPreviewRuntime][D] prepare: engine start failed — %@",
          engineError.localizedDescription);
    _runtimeState = VGAudioPreviewRuntimeStateFailed;
    return VGAudioPreviewPreparationResultFailedEnginePreparation;
  }

  _runtimeState = VGAudioPreviewRuntimeStatePaused;
  NSLog(@"[VanguardAudioPreviewRuntime][D] prepare: ready — %lu descriptors, "
        @"earliestStart=%.3f",
        (unsigned long)eligible.count, firstDesc.timelineStart);

  return VGAudioPreviewPreparationResultReady;
}

- (BOOL)_isSliceK {
  for (VGAudioPreviewTrackDescriptor *d in _descriptors) {
    if ([d.trackId hasPrefix:@"slice-k-"]) {
      return YES;
    }
  }
  return NO;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Internal scheduling helpers (queue-confined)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the current estimated timeline PTS from a snapshot.
- (NSTimeInterval)_currentPTSFromSnapshot:(VGTimelineStateSnapshot)snap {
  NSTimeInterval res;
  double elapsed = 0.0;
  if (snap.isPlaying) {
    elapsed = MAX(0.0, [_clock currentTime] - snap.playStartHostTime);
    res = MAX(0.0, snap.playStartPTS + elapsed);
  } else {
    res = MAX(0.0, snap.timelinePTS);
  }
  if ([self _isSliceK]) {
    NSLog(@"[AudioSliceKTimingProbe] _currentPTSFromSnapshot: hostNow=%.6f, "
          @"playStartHostTime=%.6f, playStartPTS=%.6f, elapsed=%.6f, "
          @"computedPTS=%.6f",
          [_clock currentTime], snap.playStartHostTime, snap.playStartPTS,
          elapsed, res);
  }
  return res;
}

/// Cancels the boundary timer, stops all three players, pauses all coordinators.
/// Increments commandSerial and updates _activeToken.
/// Per-slot scheduledSegmentSerials are NOT reset here — they are
/// incremented inside each _scheduleSegment:inSlot: call so that the
/// per-slot stale guards work correctly.
- (uint64_t)_cancelAndIncrementSerial:(uint64_t)generation {
  [self assertOnSchedulerQueue];
  [_addedAudioSlot.coordinator pause];
  [_voiceoverSlot.coordinator pause];
  [_originalAudioSlot.coordinator pause];
  [_boundaryTimer cancel];
  [_addedAudioSlot.player stop];
  [_voiceoverSlot.player stop];
  [_originalAudioSlot.player stop];
  // Reset scheduled-end tracking so the next play cycle starts fresh.
  _addedAudioSlot.scheduledEndPTS = 0.0;
  _voiceoverSlot.scheduledEndPTS = 0.0;
  _originalAudioSlot.scheduledEndPTS = 0.0;
  _commandSerial++;
  _activeToken =
      (VGAudioPreviewWorkToken){_lifecycleEpoch, _commandSerial, generation};
  return _commandSerial;
}

// ─────────────────────────────────────────────────────────────────────────────
// Lane-aware descriptor selection
// ─────────────────────────────────────────────────────────────────────────────

/// Whether a descriptor belongs to the Added Audio lane.
/// V-B1: Added Audio lane contains music and sfx ONLY. Original role
/// has its own dedicated _originalAudioSlot.
static BOOL VGIsAddedAudioRole(NSString *role) {
  return [role isEqualToString:@"music"] || [role isEqualToString:@"sfx"];
}

/// Whether a descriptor belongs to the Voice-over lane.
static BOOL VGIsVoiceoverRole(NSString *role) {
  return [role isEqualToString:@"voiceover"];
}

/// V-B1: Whether a descriptor belongs to the Original Audio lane.
static BOOL VGIsOriginalAudioRole(NSString *role) {
  return [role isEqualToString:@"original"];
}

/// Selects the winning descriptor for the Added Audio lane at |pts|.
/// Priority: music > original/sfx. Among same role: latest timelineStart wins.
/// Returns nil if no Added Audio descriptor is active at pts.
- (nullable VGAudioPreviewTrackDescriptor *)_selectAddedAudioDescriptorAtPTS:
    (NSTimeInterval)pts {
  [self assertOnSchedulerQueue];

  VGAudioPreviewTrackDescriptor *winner = nil;
  BOOL winnerIsMusic = NO;
  VGAudioPreviewTrackDescriptor *activeDesc = _addedAudioSlot.activeDescriptor;

  for (VGAudioPreviewTrackDescriptor *d in _descriptors) {
    if (!VGIsAddedAudioRole(d.role))
      continue;
    if ([_failedTrackIds containsObject:d.trackId])
      continue;

    NSTimeInterval ts = MAX(0.0, d.timelineStart);
    if (pts < ts)
      continue;

    NSTimeInterval conservativeActiveDuration;
    if (activeDesc && [d.trackId isEqualToString:activeDesc.trackId]) {
      conservativeActiveDuration = _addedAudioSlot.activeDuration;
    } else {
      NSTimeInterval projRem = MAX(0.0, _timelineDuration - ts);
      if (d.requestedDuration >= 0.0) {
        conservativeActiveDuration = MIN(d.requestedDuration, projRem);
      } else {
        conservativeActiveDuration = projRem;
      }
    }

    NSTimeInterval trackEnd = ts + conservativeActiveDuration;
    if (pts >= trackEnd)
      continue;

    BOOL dIsMusic = [d.role isEqualToString:@"music"];
    if (winner == nil) {
      winner = d;
      winnerIsMusic = dIsMusic;
    } else if (dIsMusic && !winnerIsMusic) {
      winner = d;
      winnerIsMusic = YES;
    } else if (!dIsMusic && winnerIsMusic) {
      // Keep music winner.
    } else {
      if (d.timelineStart > winner.timelineStart) {
        winner = d;
        winnerIsMusic = dIsMusic;
      }
    }
  }
  return winner;
}

/// Selects the winning descriptor for the Voice-over lane at |pts|.
/// Among overlapping voice-over descriptors: latest timelineStart wins.
/// Returns nil if no voice-over descriptor is active at pts.
- (nullable VGAudioPreviewTrackDescriptor *)_selectVoiceoverDescriptorAtPTS:
    (NSTimeInterval)pts {
  [self assertOnSchedulerQueue];

  VGAudioPreviewTrackDescriptor *winner = nil;
  VGAudioPreviewTrackDescriptor *activeDesc = _voiceoverSlot.activeDescriptor;

  for (VGAudioPreviewTrackDescriptor *d in _descriptors) {
    if (!VGIsVoiceoverRole(d.role))
      continue;
    if ([_failedTrackIds containsObject:d.trackId])
      continue;

    NSTimeInterval ts = MAX(0.0, d.timelineStart);
    if (pts < ts)
      continue;

    NSTimeInterval conservativeActiveDuration;
    if (activeDesc && [d.trackId isEqualToString:activeDesc.trackId]) {
      conservativeActiveDuration = _voiceoverSlot.activeDuration;
    } else {
      NSTimeInterval projRem = MAX(0.0, _timelineDuration - ts);
      if (d.requestedDuration >= 0.0) {
        conservativeActiveDuration = MIN(d.requestedDuration, projRem);
      } else {
        conservativeActiveDuration = projRem;
      }
    }

    NSTimeInterval trackEnd = ts + conservativeActiveDuration;
    if (pts >= trackEnd)
      continue;

    if (winner == nil || d.timelineStart > winner.timelineStart) {
      winner = d;
    }
  }
  return winner;
}

/// V-B1: Selects the winning descriptor for the Original Audio lane at |pts|.
/// Among overlapping original descriptors: latest timelineStart wins.
/// Returns nil if no original descriptor is active at pts.
- (nullable VGAudioPreviewTrackDescriptor *)_selectOriginalAudioDescriptorAtPTS:
    (NSTimeInterval)pts {
  [self assertOnSchedulerQueue];

  VGAudioPreviewTrackDescriptor *winner = nil;
  VGAudioPreviewTrackDescriptor *activeDesc = _originalAudioSlot.activeDescriptor;

  for (VGAudioPreviewTrackDescriptor *d in _descriptors) {
    if (!VGIsOriginalAudioRole(d.role))
      continue;
    if ([_failedTrackIds containsObject:d.trackId])
      continue;

    NSTimeInterval ts = MAX(0.0, d.timelineStart);
    if (pts < ts)
      continue;

    NSTimeInterval conservativeActiveDuration;
    if (activeDesc && [d.trackId isEqualToString:activeDesc.trackId]) {
      conservativeActiveDuration = _originalAudioSlot.activeDuration;
    } else {
      NSTimeInterval projRem = MAX(0.0, _timelineDuration - ts);
      if (d.requestedDuration >= 0.0) {
        conservativeActiveDuration = MIN(d.requestedDuration, projRem);
      } else {
        conservativeActiveDuration = projRem;
      }
    }

    NSTimeInterval trackEnd = ts + conservativeActiveDuration;
    if (pts >= trackEnd)
      continue;

    if (winner == nil || d.timelineStart > winner.timelineStart) {
      winner = d;
    }
  }
  return winner;
}

/// Returns the next decision boundary PTS after |currentPTS| across ALL
/// descriptors (all three lanes). This is the earliest point where lane
/// selection may change. Returns INFINITY if no future boundary exists.
- (NSTimeInterval)_computeNextDecisionPTS:(NSTimeInterval)currentPTS {
  [self assertOnSchedulerQueue];

  NSTimeInterval next = INFINITY;

  for (VGAudioPreviewTrackDescriptor *d in _descriptors) {
    if ([_failedTrackIds containsObject:d.trackId])
      continue;

    NSTimeInterval ts = MAX(0.0, d.timelineStart);
    if (ts > currentPTS)
      next = MIN(next, ts);

    // End boundary — use the per-slot activeDuration if this is that slot's
    // active descriptor; otherwise use conservative estimate.
    NSTimeInterval conservativeActiveDuration;
    BOOL isAddedActive =
        _addedAudioSlot.activeDescriptor &&
        [d.trackId isEqualToString:_addedAudioSlot.activeDescriptor.trackId];
    BOOL isVOActive =
        _voiceoverSlot.activeDescriptor &&
        [d.trackId isEqualToString:_voiceoverSlot.activeDescriptor.trackId];
    BOOL isOriginalActive =
        _originalAudioSlot.activeDescriptor &&
        [d.trackId isEqualToString:_originalAudioSlot.activeDescriptor.trackId];

    if (isAddedActive) {
      conservativeActiveDuration = _addedAudioSlot.activeDuration;
    } else if (isVOActive) {
      conservativeActiveDuration = _voiceoverSlot.activeDuration;
    } else if (isOriginalActive) {
      conservativeActiveDuration = _originalAudioSlot.activeDuration;
    } else {
      NSTimeInterval projRem = MAX(0.0, _timelineDuration - ts);
      if (d.requestedDuration >= 0.0) {
        conservativeActiveDuration = MIN(d.requestedDuration, projRem);
      } else {
        conservativeActiveDuration = projRem;
      }
    }
    NSTimeInterval trackEnd = ts + conservativeActiveDuration;
    if (trackEnd > currentPTS)
      next = MIN(next, trackEnd);
  }

  return next;
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-slot activation helper
// ─────────────────────────────────────────────────────────────────────────────

/// Opens the file for |descriptor|, validates it, computes the true clipped
/// activeDuration, and updates |slot|'s active-descriptor state and volume.
/// Returns YES on success; NO on non-recoverable error.
/// Same idempotency semantics as before: if |slot.activeDescriptor| is already
/// this descriptor, returns YES immediately if activeDuration > 0.
- (BOOL)_activateDescriptor:(VGAudioPreviewTrackDescriptor *)descriptor
                      atPTS:(NSTimeInterval)pts
                     inSlot:(VGAudioPreviewSlot *)slot {
  [self assertOnSchedulerQueue];

  // Already the active descriptor in this slot?
  if (slot.activeDescriptor &&
      [descriptor.trackId isEqualToString:slot.activeDescriptor.trackId]) {
    return slot.activeDuration > 0.0;
  }

  // Try cache.
  AVAudioFile *file = _fileCache[descriptor.trackId];
  if (!file) {
    if ([_failedTrackIds containsObject:descriptor.trackId])
      return NO;

    BOOL fileExists = [_fileProvider fileExistsAtURL:descriptor.fileURL];
    NSError *err = nil;
    file = [_fileProvider openFileAtURL:descriptor.fileURL error:&err];
    if (!file) {
      NSLog(@"[VanguardAudioPreviewRuntime][F] activateDescriptor: failed to "
            @"open %@ — %@",
            descriptor.trackId, err.localizedDescription);
      [_failedTrackIds addObject:descriptor.trackId];
      (void)fileExists;
      return NO;
    }
    _fileCache[descriptor.trackId] = file;
  }

  double sr = file.processingFormat.sampleRate;
  AVAudioFramePosition frames = file.length;
  if (sr <= 0.0 || frames <= 0) {
    NSLog(@"[VanguardAudioPreviewRuntime][F] activateDescriptor: invalid "
          @"metadata "
          @"for %@",
          descriptor.trackId);
    [_failedTrackIds addObject:descriptor.trackId];
    return NO;
  }

  NSTimeInterval ts = MAX(0.0, descriptor.timelineStart);
  NSTimeInterval trim = MAX(0.0, descriptor.sourceTrimStart);
  double fileDur = (double)frames / sr;
  NSTimeInterval availSrc = MAX(0.0, fileDur - trim);
  NSTimeInterval reqActive = (descriptor.requestedDuration == -1.0)
                                 ? availSrc
                                 : MAX(0.0, descriptor.requestedDuration);
  NSTimeInterval projRemaining = MAX(0.0, _timelineDuration - ts);
  NSTimeInterval activeDur = MIN(MIN(reqActive, availSrc), projRemaining);

  if (activeDur <= 0.0) {
    NSLog(@"[VanguardAudioPreviewRuntime][F] activateDescriptor: zero active "
          @"duration for %@",
          descriptor.trackId);
    [_failedTrackIds addObject:descriptor.trackId];
    return NO;
  }

  slot.activeDescriptor = descriptor;
  slot.timelineStart = ts;
  slot.sourceTrimStart = trim;
  slot.activeDuration = activeDur;
  slot.fileSampleRate = sr;
  slot.fileLengthFrames = frames;

  // V-B1: effective gain = staticVolume * activeMixGain.
  // Priority: live override from slider (_mixGainByTrackId) > committedMixGain
  // from sidecar. This means preview always reflects committed state on
  // activation, and the live slider overrides it immediately during drag.
  NSNumber *storedMixGain = _mixGainByTrackId[descriptor.trackId];
  float mixGain = storedMixGain ? storedMixGain.floatValue
                                : descriptor.committedMixGain;
  mixGain = MAX(0.0f, MIN(1.0f, mixGain));

  // Delegate gain to coordinator if the descriptor has raw keyframes.
  if (descriptor.hasRawKeyframes) {
    [slot.coordinator activateWithRawKeyframes:descriptor.rawVolumeKeyframes
                                 timelineStart:ts
                                  effectiveEnd:(ts + activeDur)
                                    initialPTS:pts];
    if (!slot.coordinator.hasActiveEnvelope) {
      // Keyframe data present but envelope inactive at this PTS (e.g. outside
      // keyframe range). Fall back to static gain.
      [slot.coordinator deactivate];
      float effective = descriptor.staticVolume * mixGain;
      slot.currentRawEnvelopeVolume = descriptor.staticVolume;
      [slot.player setVolume:effective];
      slot.currentVolume = effective;
    }
    // Else: gainSink fired synchronously during activateWithRawKeyframes and
    // has already stored currentRawEnvelopeVolume and applied rawEnvelope *
    // mixGain. No additional rescaling needed.
  } else {
    [slot.coordinator deactivate];
    float effective = descriptor.staticVolume * mixGain;
    // V-B1: record raw envelope (= staticVolume for non-keyframed tracks).
    slot.currentRawEnvelopeVolume = descriptor.staticVolume;
    [slot.player setVolume:effective];
    slot.currentVolume = effective;
  }


  NSLog(@"[VanguardAudioPreviewRuntime][F] activateDescriptor: %@ "
        @"ts=%.3f active=%.3f sr=%.0f frames=%lld",
        descriptor.trackId, ts, activeDur, sr, (long long)frames);
  return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-slot segment scheduling
// ─────────────────────────────────────────────────────────────────────────────

/// Schedules the audio segment for |slot|'s active descriptor from
/// |currentPTS| to |scheduledEndPTS|. Returns YES if scheduling succeeded.
/// Increments slot.scheduledSegmentSerial per successful call.
/// The completion handler re-evaluates both lanes when the segment ends
/// naturally (still playing, serial matches).
- (BOOL)_scheduleSegmentAtPTS:(NSTimeInterval)currentPTS
                       endPTS:(NSTimeInterval)scheduledEndPTS
                    withToken:(VGAudioPreviewWorkToken)token
                       inSlot:(VGAudioPreviewSlot *)slot {
  [self assertOnSchedulerQueue];

  if (!slot.activeDescriptor)
    return NO;
  AVAudioFile *audioFile = _fileCache[slot.activeDescriptor.trackId];
  if (!audioFile)
    return NO;

  // Source frame mapping.
  NSTimeInterval trackRelative = currentPTS - slot.timelineStart;
  NSTimeInterval sourcePosition = slot.sourceTrimStart + trackRelative;
  AVAudioFramePosition startFrame =
      (AVAudioFramePosition)floor(sourcePosition * slot.fileSampleRate);
  startFrame = MAX(0, MIN(startFrame, slot.fileLengthFrames));

  NSTimeInterval scheduledEndSource =
      slot.sourceTrimStart + (scheduledEndPTS - slot.timelineStart);
  AVAudioFramePosition endExclusive = (AVAudioFramePosition)MIN(
      slot.fileLengthFrames, floor(scheduledEndSource * slot.fileSampleRate));

  int64_t signedFrameCount = (int64_t)endExclusive - (int64_t)startFrame;
  if (signedFrameCount <= 0) {
    NSLog(@"[VanguardAudioPreviewRuntime][D] scheduleSegment: zero/negative "
          @"frames — silent");
    return NO;
  }
  if ((uint64_t)signedFrameCount > (uint64_t)UINT32_MAX) {
    NSLog(@"[VanguardAudioPreviewRuntime][D] scheduleSegment: frameCount %lld "
          @"exceeds max — silent",
          signedFrameCount);
    return NO;
  }

  AVAudioFrameCount frameCount = (AVAudioFrameCount)signedFrameCount;

  if ([self _isSliceK]) {
    NSString *laneName =
        (slot == _addedAudioSlot) ? @"AddedAudio" : @"Voiceover";
    NSLog(@"[AudioSliceKTimingProbe] segment scheduling: lane=%@, trackID=%@, "
          @"role=%@, timelineStart=%.6f, sourceTrimStart=%.6f, "
          @"activeDuration=%.6f, schedulePTS_Start=%.6f, schedulePTS_End=%.6f, "
          @"startFrame=%lld, frameCount=%u, expectedAudibleStart=%.6f, "
          @"expectedAudibleEnd=%.6f",
          laneName, slot.activeDescriptor.trackId, slot.activeDescriptor.role,
          slot.timelineStart, slot.sourceTrimStart, slot.activeDuration,
          currentPTS, scheduledEndPTS, (long long)startFrame, frameCount,
          slot.timelineStart, slot.timelineStart + slot.activeDuration);
  }

  // Per-slot segment serial.
  slot.scheduledSegmentSerial++;
  slot.scheduledEndPTS = scheduledEndPTS; // track for double-buffer guard
  uint64_t capturedSegSerial = slot.scheduledSegmentSerial;
  NSTimeInterval capturedScheduledEndPTS = scheduledEndPTS;

  VGAudioPreviewWorkToken capturedToken = token;
  VGTimelineSnapshotProvider capturedProvider = _snapshotProvider;
  __weak typeof(self) weakSelf = self;
  // Capture a weak reference to the slot to detect if the runtime was torn
  // down. The slot is owned by self so a weak self is sufficient.
  VGAudioPreviewSlot *capturedSlot = slot;

  [slot.player
             scheduleSegment:audioFile
               startingFrame:startFrame
                  frameCount:frameCount
                      atTime:nil
      completionCallbackType:AVAudioPlayerNodeCompletionDataConsumed
           completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
             typeof(self) ss = weakSelf;
             if (!ss)
               return;
             dispatch_async(ss->_schedulerQueue, ^{
               if (!ss->_acceptingCommands)
                 return;
               if (!VGAudioPreviewWorkTokenEqual(ss->_activeToken,
                                                 capturedToken))
                 return;
               // Per-slot stale segment guard.
               if (capturedSlot.scheduledSegmentSerial != capturedSegSerial)
                 return;

               VGTimelineStateSnapshot snap = capturedProvider();
               if (!snap.isValid) {
                 [capturedSlot.player stop];
                 ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
                 NSLog(@"[VanguardAudioPreviewRuntime][D] completion: invalid "
                       @"snapshot — paused");
                 return;
               }
               if (!snap.isPlaying)
                 return;
               if (snap.generation != capturedToken.timelineGeneration)
                 return;

               NSTimeInterval authoritativePTS =
                   [ss _currentPTSFromSnapshot:snap];
               // evaluationPTS uses MAX so the completing slot does not
               // re-schedule the just-finished segment when the snapshot
               // clock is still behind (single-lane end-of-track protection).
               // authoritativePTS is passed separately as the cross-lane
               // activation floor so idle slots that haven't been reached
               // by the real playhead are not started prematurely.
               NSTimeInterval evaluationPTS =
                   MAX(authoritativePTS, capturedScheduledEndPTS);
               NSLog(@"[VanguardAudioPreviewRuntime][D] natural completion — "
                     @"re-evaluating at evalPTS=%.3f (snapPTS=%.3f, "
                     @"capturedEnd=%.3f)",
                     evaluationPTS, authoritativePTS, capturedScheduledEndPTS);
               [ss _reevaluateAndTransitionAtPTS:evaluationPTS
                        crossLaneActivationFloor:authoritativePTS
                                       withToken:capturedToken];
             });
           }];

  NSLog(@"[VanguardAudioPreviewRuntime][D] scheduleSegment[%@]: start=%lld "
        @"count=%u endPTS=%.3f segSerial=%llu",
        slot.activeDescriptor.trackId, (long long)startFrame, frameCount,
        scheduledEndPTS, (unsigned long long)capturedSegSerial);
  return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared transition helper
// ─────────────────────────────────────────────────────────────────────────────

/// Re-evaluates all three lanes at |currentPTS|, activates/schedules/plays each
/// slot independently, and arms the master boundary timer for the earliest next
/// decision PTS. Sets _runtimeState to Playing, WaitingForTrackStart, or Ended.
///
- (void)_reevaluateAndTransitionAtPTS:(NSTimeInterval)currentPTS
                            withToken:(VGAudioPreviewWorkToken)capturedToken {
  [self _reevaluateAndTransitionAtPTS:currentPTS
             crossLaneActivationFloor:currentPTS
                            withToken:capturedToken];
}

/// Re-evaluates both lanes. |currentPTS| is used for the completing slot
/// (may be advanced to capturedScheduledEndPTS via MAX).
/// |crossLaneActivationFloor| is the authoritative clock PTS and caps which
/// idle cross-lane slots may be newly started — an idle slot whose
/// timelineStart > crossLaneActivationFloor is not activated; the boundary
/// timer will handle it when PTS arrives.
- (void)_reevaluateAndTransitionAtPTS:(NSTimeInterval)currentPTS
             crossLaneActivationFloor:(NSTimeInterval)activationFloor
                            withToken:(VGAudioPreviewWorkToken)capturedToken {
  [self assertOnSchedulerQueue];

  VGAudioPreviewTrackDescriptor *addedWinner =
      [self _selectAddedAudioDescriptorAtPTS:currentPTS];
  VGAudioPreviewTrackDescriptor *voWinner =
      [self _selectVoiceoverDescriptorAtPTS:currentPTS];
  VGAudioPreviewTrackDescriptor *origWinner =
      [self _selectOriginalAudioDescriptorAtPTS:currentPTS];

  if ([self _isSliceK]) {
    NSLog(@"[AudioSliceKTimingProbe] _reevaluateAndTransitionAtPTS: "
          @"currentPTS=%.6f, addedWinner=%@, voWinner=%@, origWinner=%@, "
          @"addedActiveDescriptor=%@, voActiveDescriptor=%@, origActiveDescriptor=%@",
          currentPTS, addedWinner.trackId, voWinner.trackId, origWinner.trackId,
          _addedAudioSlot.activeDescriptor.trackId,
          _voiceoverSlot.activeDescriptor.trackId,
          _originalAudioSlot.activeDescriptor.trackId);
  }

  // Handle Added Audio slot.
  BOOL addedActive = NO;
  NSTimeInterval addedTrackEnd = 0.0;
  if (addedWinner) {
    BOOL activated = [self _activateDescriptor:addedWinner
                                         atPTS:currentPTS
                                        inSlot:_addedAudioSlot];
    if (!activated) {
      // File failed — slot remains silent.
      [_addedAudioSlot.coordinator deactivate];
    } else {
      addedTrackEnd = [_addedAudioSlot activeDescriptorTrackEnd];
      if (currentPTS < addedTrackEnd)
        addedActive = YES;
      else
        addedWinner = nil; // past end
    }
  }
  // Handle Voice-over slot.
  BOOL voActive = NO;
  NSTimeInterval voTrackEnd = 0.0;
  // When the activation floor guard suppresses a VO start, record voStart here
  // so the boundary timer can be aimed at the correct real-time equivalent of
  // that boundary instead of a later evaluationPTS-derived boundary.
  NSTimeInterval suppressedVOStart = INFINITY;
  if (voWinner) {
    // Cross-lane activation floor guard: if the Voiceover slot is currently
    // idle AND the authoritative playhead (activationFloor) has not yet
    // reached the VO descriptor's start boundary, suppress activation.
    // The boundary timer will correctly activate the slot when the real
    // playhead arrives. This prevents the
    // AVAudioPlayerNodeCompletionDataConsumed callback (which can fire ~1s
    // before audio renders to speakers) from starting an idle VO slot
    // prematurely when evaluationPTS was advanced via MAX(authoritativePTS,
    // capturedScheduledEndPTS).
    BOOL voSlotCurrentlyIdle = (_voiceoverSlot.activeDescriptor == nil);
    NSTimeInterval voStart = MAX(0.0, voWinner.timelineStart);
    if (voSlotCurrentlyIdle && activationFloor < voStart) {
      // Real playhead hasn't reached VO start yet — let boundary timer fire.
      // Capture voStart so the timer delay can be corrected below.
      suppressedVOStart = voStart;
      voWinner = nil;
    }
  }
  if (voWinner) {
    BOOL activated = [self _activateDescriptor:voWinner
                                         atPTS:currentPTS
                                        inSlot:_voiceoverSlot];
    if (!activated) {
      [_voiceoverSlot.coordinator deactivate];
    } else {
      voTrackEnd = [_voiceoverSlot activeDescriptorTrackEnd];
      if (currentPTS < voTrackEnd)
        voActive = YES;
      else
        voWinner = nil;
    }
  }

  // Determine if at least one lane is actively playing (updated at end of method).
  BOOL hasActiveLane = addedActive || voActive;

  // Deferred-termination epsilon: if activationFloor is within 1 ms of
  // scheduledEndPTS the segment is treated as physically finished. 1 ms aligns
  // with the _armBoundaryTimerSafeDelay clamp floor and is sub-audible.
  static const NSTimeInterval kDeferEpsilon = 0.001;

  // Per-slot defer flags. Set to YES when
  // AVAudioPlayerNodeCompletionDataConsumed fires early (activationFloor <
  // slot.scheduledEndPTS - epsilon) and the segment is still physically
  // rendering. In that case the player must NOT be stopped until the boundary
  // timer fires at the real scheduled end.
  BOOL addedDeferStop = NO;
  BOOL voDeferStop = NO;
  BOOL origDeferStop = NO;

  // Declare original-slot tracking variables used throughout this method.
  BOOL origActive = NO;
  NSTimeInterval origTrackEnd = 0.0;
  NSTimeInterval suppressedOrigStart = INFINITY;

  if (!addedWinner) {
    // Deferred-termination guard: if the real playhead (activationFloor) has
    // not yet reached the slot's physical scheduled end, leave the player
    // running so queued audio renders through. The boundary timer is directed
    // at scheduledEndPTS below to perform the actual cleanup.
    if (_addedAudioSlot.activeDescriptor != nil &&
        activationFloor < _addedAudioSlot.scheduledEndPTS - kDeferEpsilon) {
      addedDeferStop = YES;
      if ([self _isSliceK]) {
        NSLog(@"[AudioSliceKTimingProbe] lane stop deferred: lane=AddedAudio, "
              @"activationFloor=%.6f, scheduledEndPTS=%.6f",
              activationFloor, _addedAudioSlot.scheduledEndPTS);
      }
    } else {
      if ([self _isSliceK]) {
        NSLog(@"[AudioSliceKTimingProbe] lane stop: lane=AddedAudio, "
              @"currentPTS=%.6f, reason=NoActiveDescriptor, otherLaneActive=%d",
              currentPTS, hasActiveLane);
      }
      // No active Added Audio descriptor — stop and quiet the slot.
      [_addedAudioSlot.coordinator deactivate];
      // Stop the player node only if another lane remains active.
      if (hasActiveLane) {
        [_addedAudioSlot.player stop];
        // Increment serial so any in-flight completion block is treated as
        // stale.
        _addedAudioSlot.scheduledSegmentSerial++;
      }
      _addedAudioSlot.activeDescriptor = nil;
      _addedAudioSlot.scheduledEndPTS = 0.0;
    }
  }

  if (!voWinner) {
    // Deferred-termination guard: mirror of the AddedAudio guard above.
    if (_voiceoverSlot.activeDescriptor != nil &&
        activationFloor < _voiceoverSlot.scheduledEndPTS - kDeferEpsilon) {
      voDeferStop = YES;
      if ([self _isSliceK]) {
        NSLog(@"[AudioSliceKTimingProbe] lane stop deferred: lane=Voiceover, "
              @"activationFloor=%.6f, scheduledEndPTS=%.6f",
              activationFloor, _voiceoverSlot.scheduledEndPTS);
      }
    } else {
      if ([self _isSliceK]) {
        NSLog(@"[AudioSliceKTimingProbe] lane stop: lane=Voiceover, "
              @"currentPTS=%.6f, reason=NoActiveDescriptor, otherLaneActive=%d",
              currentPTS, hasActiveLane);
      }
      // No active Voice-over descriptor — stop and quiet the slot.
      [_voiceoverSlot.coordinator deactivate];
      // Stop the player node only if another lane remains active.
      if (hasActiveLane) {
        [_voiceoverSlot.player stop];
        // Increment serial so any in-flight completion block is treated as
        // stale.
        _voiceoverSlot.scheduledSegmentSerial++;
      }
      _voiceoverSlot.activeDescriptor = nil;
      _voiceoverSlot.scheduledEndPTS = 0.0;
    }
  }

  if (!origWinner) {
    // Deferred-termination guard for the Original Audio slot.
    if (_originalAudioSlot.activeDescriptor != nil &&
        activationFloor < _originalAudioSlot.scheduledEndPTS - kDeferEpsilon) {
      origDeferStop = YES;
    } else {
      // No active Original descriptor — stop and quiet the slot.
      [_originalAudioSlot.coordinator deactivate];
      if (hasActiveLane) {
        [_originalAudioSlot.player stop];
        _originalAudioSlot.scheduledSegmentSerial++;
      }
      _originalAudioSlot.activeDescriptor = nil;
      _originalAudioSlot.scheduledEndPTS = 0.0;
    }
  }

  // ── Handle Original Audio slot ─────────────────────────────────────────────
  // origWinner was selected above. Apply same cross-lane activation floor guard
  // as the voiceover slot to prevent premature early-start from DataConsumed
  // completions.
  if (origWinner) {
    BOOL origSlotCurrentlyIdle = (_originalAudioSlot.activeDescriptor == nil);
    NSTimeInterval origStart = MAX(0.0, origWinner.timelineStart);
    if (origSlotCurrentlyIdle && activationFloor < origStart) {
      suppressedOrigStart = origStart;
      origWinner = nil;
    }
  }
  if (origWinner) {
    BOOL activated = [self _activateDescriptor:origWinner
                                         atPTS:currentPTS
                                        inSlot:_originalAudioSlot];
    if (!activated) {
      [_originalAudioSlot.coordinator deactivate];
    } else {
      origTrackEnd = [_originalAudioSlot activeDescriptorTrackEnd];
      if (currentPTS < origTrackEnd)
        origActive = YES;
      else
        origWinner = nil;
    }
  }

  // Recompute hasActiveLane now that all three slots are evaluated.
  hasActiveLane = addedActive || voActive || origActive;

  // Next global decision boundary across all three lanes.
  NSTimeInterval nextBoundary = [self _computeNextDecisionPTS:currentPTS];

  // Schedule and play each active slot independently.
  BOOL anyScheduled = NO;

  if (addedActive) {
    // Skip re-queuing if the slot is already scheduled past the current
    // evaluation PTS. This prevents double-buffering when a DataConsumed
    // completion callback fires early (~1 s of prefetch) and schedules the
    // same-lane continuation, and then the boundary timer fires at the
    // suppressed cross-lane start boundary at the same evaluation point.
    BOOL addedAlreadyScheduled = (currentPTS < _addedAudioSlot.scheduledEndPTS);
    if (addedAlreadyScheduled) {
      [_addedAudioSlot.player play];
      anyScheduled = YES;
    } else {
      NSTimeInterval addedEndPTS =
          (isfinite(nextBoundary) && nextBoundary <= addedTrackEnd)
              ? nextBoundary
              : addedTrackEnd;
      BOOL scheduled = [self _scheduleSegmentAtPTS:currentPTS
                                            endPTS:addedEndPTS
                                         withToken:capturedToken
                                            inSlot:_addedAudioSlot];
      if (scheduled) {
        if (_addedAudioSlot.coordinator.hasActiveEnvelope)
          [_addedAudioSlot.coordinator reevaluateAtPTS:currentPTS];
        [_addedAudioSlot.player play];
        if (_addedAudioSlot.coordinator.hasActiveEnvelope) {
          dispatch_block_t tickBlock =
              [self _buildAutomationTickBlockForToken:capturedToken
                                               inSlot:_addedAudioSlot];
          [_addedAudioSlot.coordinator startPollingWithTickBlock:tickBlock];
        }
        anyScheduled = YES;
      } else {
        addedActive = NO;
      }
    }
  }

  if (voActive) {
    BOOL voAlreadyScheduled = (currentPTS < _voiceoverSlot.scheduledEndPTS);
    if (voAlreadyScheduled) {
      [_voiceoverSlot.player play];
      anyScheduled = YES;
    } else {
      NSTimeInterval voEndPTS =
          (isfinite(nextBoundary) && nextBoundary <= voTrackEnd) ? nextBoundary
                                                                 : voTrackEnd;
      BOOL scheduled = [self _scheduleSegmentAtPTS:currentPTS
                                            endPTS:voEndPTS
                                         withToken:capturedToken
                                            inSlot:_voiceoverSlot];
      if (scheduled) {
        if (_voiceoverSlot.coordinator.hasActiveEnvelope)
          [_voiceoverSlot.coordinator reevaluateAtPTS:currentPTS];
        [_voiceoverSlot.player play];
        if (_voiceoverSlot.coordinator.hasActiveEnvelope) {
          dispatch_block_t tickBlock =
              [self _buildAutomationTickBlockForToken:capturedToken
                                               inSlot:_voiceoverSlot];
          [_voiceoverSlot.coordinator startPollingWithTickBlock:tickBlock];
        }
        anyScheduled = YES;
      } else {
        voActive = NO;
      }
    }
  }

  if (origActive) {
    BOOL origAlreadyScheduled = (currentPTS < _originalAudioSlot.scheduledEndPTS);
    if (origAlreadyScheduled) {
      [_originalAudioSlot.player play];
      anyScheduled = YES;
    } else {
      NSTimeInterval origEndPTS =
          (isfinite(nextBoundary) && nextBoundary <= origTrackEnd) ? nextBoundary
                                                                   : origTrackEnd;
      BOOL scheduled = [self _scheduleSegmentAtPTS:currentPTS
                                            endPTS:origEndPTS
                                         withToken:capturedToken
                                            inSlot:_originalAudioSlot];
      if (scheduled) {
        if (_originalAudioSlot.coordinator.hasActiveEnvelope)
          [_originalAudioSlot.coordinator reevaluateAtPTS:currentPTS];
        [_originalAudioSlot.player play];
        if (_originalAudioSlot.coordinator.hasActiveEnvelope) {
          dispatch_block_t tickBlock =
              [self _buildAutomationTickBlockForToken:capturedToken
                                               inSlot:_originalAudioSlot];
          [_originalAudioSlot.coordinator startPollingWithTickBlock:tickBlock];
        }
        anyScheduled = YES;
      } else {
        origActive = NO;
      }
    }
  }
  (void)anyScheduled; // reserved for future assertions

  // Arm the master boundary timer if any lane is active and a future boundary
  // exists, OR if all lanes are silent but a start boundary is approaching.
  // Deferred slots contribute to hasActiveLane so the runtime keeps Playing
  // state while queued audio renders through the hardware.
  hasActiveLane = addedActive || voActive || origActive ||
                  addedDeferStop || voDeferStop || origDeferStop;

  // Timer-base correction: when the VO or Original activation floor guard
  // suppressed an early cross-lane start, evaluationPTS was advanced (MAX)
  // past that start, so _computeNextDecisionPTS:currentPTS skips it as a
  // candidate boundary. Fix: use activationFloor as the timer base and MIN in
  // suppressedStart so the timer fires at the real-time equivalent.
  NSTimeInterval timerBase = activationFloor;
  NSTimeInterval timerNextBoundary = nextBoundary;
  if (isfinite(suppressedVOStart)) {
    timerNextBoundary = MIN(timerNextBoundary, suppressedVOStart);
  }
  if (isfinite(suppressedOrigStart)) {
    timerNextBoundary = MIN(timerNextBoundary, suppressedOrigStart);
  }
  // Deferred-termination cleanup boundaries.
  if (addedDeferStop && _addedAudioSlot.scheduledEndPTS > timerBase) {
    timerNextBoundary = MIN(timerNextBoundary, _addedAudioSlot.scheduledEndPTS);
  }
  if (voDeferStop && _voiceoverSlot.scheduledEndPTS > timerBase) {
    timerNextBoundary = MIN(timerNextBoundary, _voiceoverSlot.scheduledEndPTS);
  }
  if (origDeferStop && _originalAudioSlot.scheduledEndPTS > timerBase) {
    timerNextBoundary = MIN(timerNextBoundary, _originalAudioSlot.scheduledEndPTS);
  }
  BOOL hasFutureBoundary =
      isfinite(timerNextBoundary) && timerNextBoundary > timerBase;

  if (hasActiveLane && hasFutureBoundary) {
    [self _armBoundaryTimerSafeDelay:(timerNextBoundary - timerBase)
                               token:capturedToken];
    _runtimeState = VGAudioPreviewRuntimeStatePlaying;
  } else if (hasActiveLane) {
    // Playing with no further boundary.
    _runtimeState = VGAudioPreviewRuntimeStatePlaying;
  } else if (hasFutureBoundary) {
    // Silent gap — wait for next start boundary.
    _runtimeState = VGAudioPreviewRuntimeStateWaitingForTrackStart;
    [self _armBoundaryTimerSafeDelay:(timerNextBoundary - timerBase)
                               token:capturedToken];
    NSLog(@"[VanguardAudioPreviewRuntime][F] transition: gap at PTS=%.3f, "
          @"next=%.3f",
          timerBase, timerNextBoundary);
  } else {
    // No lanes active, no future boundary.
    _runtimeState = VGAudioPreviewRuntimeStateEnded;
    NSLog(@"[VanguardAudioPreviewRuntime][F] transition: no more descriptors "
          @"— Ended");
  }
}

/// Builds the validated automation tick block for |slot|.
/// Captures the slot's scheduledSegmentSerial and the shared activeToken.
- (dispatch_block_t)
    _buildAutomationTickBlockForToken:(VGAudioPreviewWorkToken)tok
                               inSlot:(VGAudioPreviewSlot *)slot {
  [self assertOnSchedulerQueue];
  VGAudioPreviewWorkToken capturedToken = tok;
  uint64_t capturedSegSerial = slot.scheduledSegmentSerial;
  VGTimelineSnapshotProvider capturedProvider = _snapshotProvider;
  id<VGAudioPreviewClock> capturedClock = _clock;
  __weak typeof(self) weakSelf = self;
  VGAudioPreviewSlot *capturedSlot = slot;
  return ^{
    typeof(self) ss = weakSelf;
    if (!ss || !ss->_acceptingCommands)
      return;
    if (!VGAudioPreviewWorkTokenEqual(ss->_activeToken, capturedToken))
      return;
    if (capturedSlot.scheduledSegmentSerial != capturedSegSerial)
      return;
    VGTimelineStateSnapshot snap = capturedProvider();
    if (!snap.isValid || !snap.isPlaying)
      return;
    if (snap.generation != capturedToken.timelineGeneration)
      return;
    NSTimeInterval elapsed =
        MAX(0.0, [capturedClock currentTime] - snap.playStartHostTime);
    NSTimeInterval pts = MAX(0.0, snap.playStartPTS + elapsed);
    [capturedSlot.coordinator evaluateAtPTS:pts];
    if ([ss _isSliceK]) {
      NSString *laneName;
      if (capturedSlot == ss->_addedAudioSlot) {
        laneName = @"AddedAudio";
      } else if (capturedSlot == ss->_voiceoverSlot) {
        laneName = @"Voiceover";
      } else {
        laneName = @"OriginalAudio";
      }
      NSLog(@"[AudioSliceKTimingProbe] keyframe/gain evaluation: lane=%@, "
            @"trackID=%@, evaluatedPTS=%.6f, resultingGain=%.6f",
            laneName, capturedSlot.activeDescriptor.trackId, pts,
            capturedSlot.currentVolume);
    }
  };
}

/// Arms the boundary timer with sub-millisecond handling.
- (void)_armBoundaryTimerSafeDelay:(NSTimeInterval)delay
                             token:(VGAudioPreviewWorkToken)token {
  [self assertOnSchedulerQueue];

  if (delay > 0.001) {
    [self _armBoundaryTimerWithDelay:delay token:token];
  } else if (delay > 0.0) {
    [self _armBoundaryTimerWithDelay:0.001 token:token];
    NSLog(@"[VanguardAudioPreviewRuntime][F] safe-delay: clamped %.6f s → "
          @"0.001 s",
          delay);
  } else {
    VGTimelineStateSnapshot snap = _snapshotProvider();
    if (!snap.isValid || !snap.isPlaying)
      return;
    if (snap.generation != token.timelineGeneration)
      return;
    NSTimeInterval pts = [self _currentPTSFromSnapshot:snap];
    NSLog(@"[VanguardAudioPreviewRuntime][F] safe-delay: zero/negative delay "
          @"(%.6f s) — re-evaluating inline at PTS=%.3f",
          delay, pts);
    [self _reevaluateAndTransitionAtPTS:pts withToken:token];
  }
}

/// Arms the one-shot boundary timer.
- (void)_armBoundaryTimerWithDelay:(NSTimeInterval)delay
                             token:(VGAudioPreviewWorkToken)token {
  [self assertOnSchedulerQueue];

  // Capture the shared per-slot serials so that if any slot's completion
  // callback has already advanced that slot, this timer is stale.
  uint64_t capturedAddedSerial = _addedAudioSlot.scheduledSegmentSerial;
  uint64_t capturedVOSerial = _voiceoverSlot.scheduledSegmentSerial;
  // V-B1: include original slot serial in stale guard.
  uint64_t capturedOriginalSerial = _originalAudioSlot.scheduledSegmentSerial;

  VGAudioPreviewWorkToken capturedToken = token;
  VGTimelineSnapshotProvider capturedProvider = _snapshotProvider;
  __weak typeof(self) weakSelf = self;

  [_boundaryTimer
      armWithDelay:delay
             block:^{
               typeof(self) ss = weakSelf;
               if (!ss)
                 return;
               [ss assertOnSchedulerQueue];

               if (!ss->_acceptingCommands)
                 return;
               if (!VGAudioPreviewWorkTokenEqual(ss->_activeToken,
                                                 capturedToken))
                 return;

               // Stale guard: if ALL three slots have already advanced past
               // the serial captured when the timer was armed, the timer is
               // stale. (Any slot still matching its captured serial means
               // this timer may still need to schedule for that slot.)
               if (ss->_addedAudioSlot.scheduledSegmentSerial !=
                       capturedAddedSerial &&
                   ss->_voiceoverSlot.scheduledSegmentSerial !=
                       capturedVOSerial &&
                   // V-B1: include original slot in stale check.
                   ss->_originalAudioSlot.scheduledSegmentSerial !=
                       capturedOriginalSerial)
                 return;

               VGTimelineStateSnapshot snap = capturedProvider();
               if (!snap.isValid || !snap.isPlaying) {
                 if (!snap.isValid) {
                   // V-B1: stop all three players on invalid snapshot.
                   [ss->_addedAudioSlot.player stop];
                   [ss->_voiceoverSlot.player stop];
                   [ss->_originalAudioSlot.player stop];
                   ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
                 }
                 return;
               }
               if (snap.generation != capturedToken.timelineGeneration)
                 return;

               NSTimeInterval currentPTS = [ss _currentPTSFromSnapshot:snap];
               NSLog(@"[VanguardAudioPreviewRuntime][F] boundary timer fired "
                     @"at PTS=%.3f",
                     currentPTS);
               [ss _reevaluateAndTransitionAtPTS:currentPTS
                                       withToken:capturedToken];
             }];
}

// ─────────────────────────────────────────────────────────────────────────────
// Slice N: AVAudioEngine configuration-change handler
// ─────────────────────────────────────────────────────────────────────────────

/// Fired on an arbitrary thread when AVAudioEngine stops itself due to a
/// hardware route or format change (iounit configuration changed).
/// Dispatches recovery work to the scheduler queue.
- (void)_handleEngineConfigurationChange:(NSNotification *)notification {
  if (!_acceptingCommands)
    return;
  __weak typeof(self) weakSelf = self;
  dispatch_async(_schedulerQueue, ^{
    typeof(self) ss = weakSelf;
    if (!ss || !ss->_acceptingCommands)
      return;
    [ss assertOnSchedulerQueue];

    NSLog(@"[VanguardAudioPreviewRuntime][N] "
          @"AVAudioEngineConfigurationChangeNotification "
          @"received — clearing stale scheduling state");

    // The engine has stopped and flushed all player-node buffers.
    // Clear scheduledEndPTS on all three slots so the next scheduling cycle
    // does not skip re-queuing because it thinks buffers are still present.
    ss->_addedAudioSlot.scheduledEndPTS = 0.0;
    ss->_voiceoverSlot.scheduledEndPTS = 0.0;
    ss->_originalAudioSlot.scheduledEndPTS = 0.0;

    // If the timeline is actively playing, attempt an engine restart and
    // reschedule from the current playhead. Use the helper so we share the
    // same logging and token-rebuild path as commandPlay.
    VGTimelineStateSnapshot snap = ss->_snapshotProvider();
    if (snap.isValid && snap.isPlaying &&
        (ss->_runtimeState == VGAudioPreviewRuntimeStatePlaying ||
         ss->_runtimeState == VGAudioPreviewRuntimeStateWaitingForTrackStart)) {
      [ss _restartEngineIfNeededForPlaybackWithReason:
              @"AVAudioEngineConfigurationChange"];
    }
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Slice N: engine restart helper
// ─────────────────────────────────────────────────────────────────────────────

/// Checks whether the engine is running. If it is, returns YES immediately
/// without scheduling. If it is NOT running, performs:
///   1. _cancelAndIncrementSerial: to stop players and clear stale state.
///   2. engine prepare + startAndReturnError:.
///   3. On success: rebuilds _activeToken from a fresh snapshot, then calls
///      _reevaluateAndTransitionAtPTS:withToken: so fresh buffers are queued.
///   4. On failure: sets runtime state to Paused and logs the error.
///
/// Returns YES if the engine was already running (caller can proceed with its
/// own scheduling path). Returns NO if this method handled scheduling itself
/// (restart path — caller must NOT schedule again to avoid double-buffering),
/// or if start failed (caller should abort).
///
/// Must be called on _schedulerQueue.
- (BOOL)_restartEngineIfNeededForPlaybackWithReason:(NSString *)reason {
  [self assertOnSchedulerQueue];

  if ([_engine isRunning]) {
    // Engine is alive — nothing to do here.
    return YES;
  }

  NSLog(@"[VanguardAudioPreviewRuntime][N] engine not running — restarting "
        @"for playback: %@",
        reason);

  // Use active token generation if snapshot is invalid.
  VGTimelineStateSnapshot snapBefore = _snapshotProvider();
  uint64_t gen = snapBefore.isValid ? snapBefore.generation
                                    : _activeToken.timelineGeneration;
  [self _cancelAndIncrementSerial:gen];

  [_engine prepare];
  NSError *engineErr = nil;
  BOOL started = [_engine startAndReturnError:&engineErr];
  if (!started) {
    _runtimeState = VGAudioPreviewRuntimeStatePaused;
    NSLog(@"[VanguardAudioPreviewRuntime][N] engine restart failed (%@): %@",
          reason, engineErr.localizedDescription);
    return NO;
  }
  NSLog(@"[VanguardAudioPreviewRuntime][N] engine restarted for playback: %@",
        reason);

  // Rebuild the active token from a fresh snapshot.
  VGTimelineStateSnapshot snap = _snapshotProvider();
  if (!snap.isValid) {
    _runtimeState = VGAudioPreviewRuntimeStatePaused;
    NSLog(@"[VanguardAudioPreviewRuntime][N] engine restart: invalid snapshot "
          @"after "
          @"restart — paused");
    return NO;
  }
  _activeToken = (VGAudioPreviewWorkToken){
      _lifecycleEpoch,
      _commandSerial,
      snap.generation,
  };
  VGAudioPreviewWorkToken token = _activeToken;

  if (snap.isPlaying) {
    _runtimeState = VGAudioPreviewRuntimeStatePlaying;
    NSTimeInterval currentPTS = [self _currentPTSFromSnapshot:snap];
    [self _reevaluateAndTransitionAtPTS:currentPTS withToken:token];
  } else {
    _runtimeState = VGAudioPreviewRuntimeStatePaused;
  }
  // Return NO: this method has already called _reevaluateAndTransitionAtPTS.
  // Caller must not schedule again.
  return NO;
}

/// Applies the play command on the scheduler queue.
- (void)_applyPlayOnQueue {
  [self assertOnSchedulerQueue];
  if (!_acceptingCommands)
    return;

  if (_runtimeState == VGAudioPreviewRuntimeStateReadySilent ||
      _runtimeState == VGAudioPreviewRuntimeStateUnprepared ||
      _runtimeState == VGAudioPreviewRuntimeStateFailed ||
      _runtimeState == VGAudioPreviewRuntimeStateInvalidated) {
    return;
  }

  VGTimelineStateSnapshot snap = _snapshotProvider();
  if (!snap.isValid || !snap.isPlaying)
    return;

  // ── Slice N: engine guard ────────────────────────────────────────────────
  // The engine may have been stopped asynchronously by AVFoundation due to an
  // iounit configuration change (category transition). If so, restart it and
  // let the helper handle scheduling — do not fall through to the normal
  // cancel/schedule path to avoid double-buffering.
  BOOL engineAlreadyRunning =
      [self _restartEngineIfNeededForPlaybackWithReason:@"commandPlay"];
  if (!engineAlreadyRunning) {
    // Helper either restarted and rescheduled, or failed. Either way we're
    // done.
    return;
  }

  uint64_t serial = [self _cancelAndIncrementSerial:snap.generation];
  VGAudioPreviewWorkToken token = _activeToken;
  (void)serial;

  if ([self _isSliceK]) {
    NSLog(@"[AudioSliceKTimingProbe] commandPlay: startPTS=%.6f, "
          @"hostTime=%.6f, generation=%llu, serial=%llu",
          snap.playStartPTS, snap.playStartHostTime, token.timelineGeneration,
          serial);
  }

  NSTimeInterval currentPTS = [self _currentPTSFromSnapshot:snap];
  [self _reevaluateAndTransitionAtPTS:currentPTS withToken:token];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Timeline event commands (public, dispatch to queue)
// ─────────────────────────────────────────────────────────────────────────────

- (void)commandPlay {
  if (!_acceptingCommands)
    return;
  __weak typeof(self) weakSelf = self;
  dispatch_async(_schedulerQueue, ^{
    typeof(self) ss = weakSelf;
    if (!ss || !ss->_acceptingCommands)
      return;
    [ss _applyPlayOnQueue];
  });
}

- (void)commandPause {
  if (!_acceptingCommands)
    return;
  __weak typeof(self) weakSelf = self;
  dispatch_async(_schedulerQueue, ^{
    typeof(self) ss = weakSelf;
    if (!ss || !ss->_acceptingCommands)
      return;
    [ss assertOnSchedulerQueue];

    VGTimelineStateSnapshot snap = ss->_snapshotProvider();
    uint64_t generation =
        snap.isValid ? snap.generation : ss->_activeToken.timelineGeneration;
    [ss _cancelAndIncrementSerial:generation];
    ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
    if ([ss _isSliceK]) {
      NSLog(@"[AudioSliceKTimingProbe] commandPause: currentPTS=%.6f, "
            @"generation=%llu",
            [ss _currentPTSFromSnapshot:snap], (unsigned long long)generation);
    }
    NSLog(@"[VanguardAudioPreviewRuntime][D] pause applied");
  });
}

- (void)commandSeek {
  if (!_acceptingCommands)
    return;
  __weak typeof(self) weakSelf = self;
  dispatch_async(_schedulerQueue, ^{
    typeof(self) ss = weakSelf;
    if (!ss || !ss->_acceptingCommands)
      return;
    [ss assertOnSchedulerQueue];

    VGTimelineStateSnapshot snap = ss->_snapshotProvider();
    uint64_t generation =
        snap.isValid ? snap.generation : ss->_activeToken.timelineGeneration;
    [ss _cancelAndIncrementSerial:generation];

    if ([ss _isSliceK]) {
      NSLog(@"[AudioSliceKTimingProbe] commandSeek: targetPTS=%.6f, "
            @"generation=%llu",
            snap.timelinePTS, (unsigned long long)generation);
    }

    if (!snap.isValid) {
      ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
      return;
    }

    if (snap.isPlaying) {
      ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
      [ss _applyPlayOnQueue];
    } else {
      ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
    }
    NSLog(@"[VanguardAudioPreviewRuntime][D] seek applied generation=%llu",
          (unsigned long long)generation);
  });
}

- (void)commandEOS {
  if (!_acceptingCommands)
    return;
  __weak typeof(self) weakSelf = self;
  dispatch_async(_schedulerQueue, ^{
    typeof(self) ss = weakSelf;
    if (!ss || !ss->_acceptingCommands)
      return;
    [ss assertOnSchedulerQueue];

    VGTimelineStateSnapshot snap = ss->_snapshotProvider();
    uint64_t generation =
        snap.isValid ? snap.generation : ss->_activeToken.timelineGeneration;
    [ss _cancelAndIncrementSerial:generation];
    ss->_runtimeState = VGAudioPreviewRuntimeStateEnded;
    if ([ss _isSliceK]) {
      NSLog(@"[AudioSliceKTimingProbe] commandEOS: generation=%llu",
            (unsigned long long)generation);
    }
    NSLog(@"[VanguardAudioPreviewRuntime][D] EOS — audio stopped");
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - V-B1/V-B2: per-track live mix gain
// ─────────────────────────────────────────────────────────────────────────────

- (void)setMixGainForTrackId:(NSString *)trackId gain:(float)gain {
  if (!_acceptingCommands)
    return;
  NSParameterAssert(trackId.length > 0);

  // Clamp to [0, 1] — no gain above unity, no negative.
  float clamped = MAX(0.0f, MIN(1.0f, gain));

  __weak typeof(self) weakSelf = self;
  dispatch_async(_schedulerQueue, ^{
    typeof(self) ss = weakSelf;
    if (!ss || !ss->_acceptingCommands)
      return;

    // Store the new mix gain for this trackId.
    ss->_mixGainByTrackId[trackId] = @(clamped);

    // If the Added Audio slot is currently playing this trackId, update player.
    VGAudioPreviewTrackDescriptor *aaDesc = ss->_addedAudioSlot.activeDescriptor;
    if (aaDesc && [aaDesc.trackId isEqualToString:trackId]) {
      float effective;
      if (ss->_addedAudioSlot.coordinator.hasActiveEnvelope) {
        // V-B1: keyframe path — use the stored raw envelope volume directly.
        // currentRawEnvelopeVolume was set by the gainSink and is never mixed
        // with any previous gain, so no division is needed.
        effective = ss->_addedAudioSlot.currentRawEnvelopeVolume * clamped;
      } else {
        effective = aaDesc.staticVolume * clamped;
      }
      [ss->_addedAudioSlot.player setVolume:effective];
      ss->_addedAudioSlot.currentVolume = effective;
      NSLog(@"[VanguardAudioPreviewRuntime][V-B] setMixGain: addedAudio "
            @"trackId=%@ gain=%.3f effectiveVol=%.3f",
            trackId, clamped, effective);
      return;
    }

    // If the Voice-over slot is currently playing this trackId, update player.
    VGAudioPreviewTrackDescriptor *voDesc = ss->_voiceoverSlot.activeDescriptor;
    if (voDesc && [voDesc.trackId isEqualToString:trackId]) {
      float effective;
      if (ss->_voiceoverSlot.coordinator.hasActiveEnvelope) {
        effective = ss->_voiceoverSlot.currentRawEnvelopeVolume * clamped;
      } else {
        effective = voDesc.staticVolume * clamped;
      }
      [ss->_voiceoverSlot.player setVolume:effective];
      ss->_voiceoverSlot.currentVolume = effective;
      NSLog(@"[VanguardAudioPreviewRuntime][V-B] setMixGain: voiceover "
            @"trackId=%@ gain=%.3f effectiveVol=%.3f",
            trackId, clamped, effective);
      return;
    }

    // V-B1: If the Original Audio slot is currently playing this trackId.
    VGAudioPreviewTrackDescriptor *origDesc =
        ss->_originalAudioSlot.activeDescriptor;
    if (origDesc && [origDesc.trackId isEqualToString:trackId]) {
      float effective;
      if (ss->_originalAudioSlot.coordinator.hasActiveEnvelope) {
        effective = ss->_originalAudioSlot.currentRawEnvelopeVolume * clamped;
      } else {
        effective = origDesc.staticVolume * clamped;
      }
      [ss->_originalAudioSlot.player setVolume:effective];
      ss->_originalAudioSlot.currentVolume = effective;
      NSLog(@"[VanguardAudioPreviewRuntime][V-B] setMixGain: originalAudio "
            @"trackId=%@ gain=%.3f effectiveVol=%.3f",
            trackId, clamped, effective);
      return;
    }

    // Track not currently active in any slot — gain is stored for when it
    // next activates via _activateDescriptor:atPTS:inSlot:.
    NSLog(@"[VanguardAudioPreviewRuntime][V-B] setMixGain: trackId=%@ "
          @"gain=%.3f stored (not currently active)",
          trackId, clamped);
  });
}

NSString *const VGAudioPreviewRecoveryErrorDomain =
    @"VGAudioPreviewRecoveryErrorDomain";

static NSError *_makeRecoveryError(VGAudioPreviewRecoveryError code,
                                   NSString *description) {
  return [NSError errorWithDomain:VGAudioPreviewRecoveryErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : description}];
}

static NSError *
_makeRecoveryErrorWithUnderlying(VGAudioPreviewRecoveryError code,
                                 NSString *description, NSError *underlying) {
  NSMutableDictionary *userInfo = [NSMutableDictionary
      dictionaryWithDictionary:@{NSLocalizedDescriptionKey : description}];
  if (underlying) {
    userInfo[NSUnderlyingErrorKey] = underlying;
  }
  return [NSError errorWithDomain:VGAudioPreviewRecoveryErrorDomain
                             code:code
                         userInfo:userInfo];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Session recovery (Slice N)
// ─────────────────────────────────────────────────────────────────────────────

- (void)commandRecoverAfterSessionTransitionWithCompletion:
    (void (^)(NSError *_Nullable))completion {
  NSParameterAssert(completion != nil);

  // Fast path: reject if not accepting commands.
  if (!_acceptingCommands) {
    NSError *err = _makeRecoveryError(
        VGAudioPreviewRecoveryErrorInvalidated,
        @"commandRecoverAfterSessionTransition: runtime is invalidated");
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(err);
    });
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_async(_schedulerQueue, ^{
    typeof(self) ss = weakSelf;
    if (!ss || !ss->_acceptingCommands) {
      NSError *err =
          _makeRecoveryError(VGAudioPreviewRecoveryErrorInvalidated,
                             @"commandRecoverAfterSessionTransition: runtime "
                             @"invalidated before queue dispatch");
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(err);
      });
      return;
    }
    [ss assertOnSchedulerQueue];

    // ── Gate: only operate on audible states
    // ──────────────────────────────────

    switch (ss->_runtimeState) {
    case VGAudioPreviewRuntimeStateReadySilent: {
      // No audio to recover — silent success.
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil);
      });
      return;
    }

    case VGAudioPreviewRuntimeStateUnprepared: {
      NSError *err = _makeRecoveryError(
          VGAudioPreviewRecoveryErrorUnprepared,
          @"commandRecoverAfterSessionTransition: runtime is unprepared");
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(err);
      });
      return;
    }

    case VGAudioPreviewRuntimeStateFailed: {
      NSError *err = _makeRecoveryError(
          VGAudioPreviewRecoveryErrorRuntimeFailed,
          @"commandRecoverAfterSessionTransition: runtime is in failed state");
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(err);
      });
      return;
    }

    case VGAudioPreviewRuntimeStateInvalidated: {
      NSError *err = _makeRecoveryError(VGAudioPreviewRecoveryErrorInvalidated,
                                        @"commandRecoverAfterSessionTransition:"
                                        @" runtime is in invalidated state");
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(err);
      });
      return;
    }

    case VGAudioPreviewRuntimeStateWaitingForTrackStart:
    case VGAudioPreviewRuntimeStatePlaying:
    case VGAudioPreviewRuntimeStatePaused:
    case VGAudioPreviewRuntimeStateEnded:
      // Audible states — proceed to engine restart.
      break;
    }

    // ── 1. Cancel stale timers, stop both players, increment serial
    // ────────────
    VGTimelineStateSnapshot snapBefore = ss->_snapshotProvider();
    uint64_t priorGeneration = snapBefore.isValid
                                   ? snapBefore.generation
                                   : ss->_activeToken.timelineGeneration;
    [ss _cancelAndIncrementSerial:priorGeneration];

    // ── 2. Unconditionally restart AVAudioEngine
    // ───────────────────────────────
    //
    // stop → prepare → start is the required pattern after a category
    // transition to re-anchor hardware clock and route. Attached player nodes
    // and graph topology survive stop/start (per AVFoundation documentation).
    //
    [ss->_engine stop];
    [ss->_engine prepare];

    NSError *engineErr = nil;
    BOOL engineStarted = [ss->_engine startAndReturnError:&engineErr];
    if (!engineStarted) {
      ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
      NSError *wrapped = _makeRecoveryErrorWithUnderlying(
          VGAudioPreviewRecoveryErrorEngineStartFailed,
          @"commandRecoverAfterSessionTransition: AVAudioEngine failed to "
          @"start",
          engineErr);
      NSLog(
          @"[VanguardAudioPreviewRuntime][N] recovery: engine start FAILED: %@",
          engineErr);
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(wrapped);
      });
      return;
    }
    NSLog(@"[VanguardAudioPreviewRuntime][N] recovery: engine restarted");

    // ── 3. Read fresh snapshot after restart
    // ──────────────────────────────────
    VGTimelineStateSnapshot snap = ss->_snapshotProvider();
    if (!snap.isValid) {
      ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
      NSError *err =
          _makeRecoveryError(VGAudioPreviewRecoveryErrorInvalidSnapshot,
                             @"commandRecoverAfterSessionTransition: snapshot "
                             @"invalid after engine restart");
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(err);
      });
      return;
    }

    // ── 4. Re-anchor active token
    // ─────────────────────────────────────────────
    //
    // _cancelAndIncrementSerial already incremented commandSerial (step 1).
    // Rebuild activeToken with the fresh snapshot generation.
    ss->_activeToken = (VGAudioPreviewWorkToken){
        ss->_lifecycleEpoch,
        ss->_commandSerial,
        snap.generation,
    };
    VGAudioPreviewWorkToken token = ss->_activeToken;

    // ── 5. Re-enter scheduling loop from current PTS
    // ──────────────────────────
    if (snap.isPlaying) {
      ss->_runtimeState = VGAudioPreviewRuntimeStatePlaying;
      NSTimeInterval currentPTS = [ss _currentPTSFromSnapshot:snap];
      NSLog(@"[VanguardAudioPreviewRuntime][N] recovery: playing, resuming at "
            @"PTS=%.3f",
            currentPTS);
      [ss _reevaluateAndTransitionAtPTS:currentPTS withToken:token];
    } else {
      ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
      NSLog(@"[VanguardAudioPreviewRuntime][N] recovery: paused at PTS=%.3f",
            snap.timelinePTS);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Invalidation
// ─────────────────────────────────────────────────────────────────────────────

- (void)invalidateAsync:(dispatch_block_t)completion {
  NSParameterAssert(completion != nil);

  // Slice N: remove configuration-change observer before tearing down the
  // engine.
  [[NSNotificationCenter defaultCenter]
      removeObserver:self
                name:AVAudioEngineConfigurationChangeNotification
              object:nil];

  // Phase A: close command acceptance atomically.
  atomic_store(&_acceptingCommands, NO);

  // Immediate audio quiesce: stop all three players synchronously on calling
  // thread. AVAudioPlayerNode.stop is documented as thread-safe.
  [_addedAudioSlot.player stop];
  [_voiceoverSlot.player stop];
  // V-B1: quiesce original slot player immediately.
  [_originalAudioSlot.player stop];

  BOOL shouldInitiateCleanup = NO;

  os_unfair_lock_lock(&_invalidationLock);
  switch (_invalidationPhase) {
  case VGAudioPreviewInvalidationStateAccepting:
    _invalidationPhase = VGAudioPreviewInvalidationStateInvalidating;
    [_invalidationWaiters addObject:[completion copy]];
    shouldInitiateCleanup = YES;
    break;

  case VGAudioPreviewInvalidationStateInvalidating:
    [_invalidationWaiters addObject:[completion copy]];
    os_unfair_lock_unlock(&_invalidationLock);
    return;

  case VGAudioPreviewInvalidationStateInvalidated:
    os_unfair_lock_unlock(&_invalidationLock);
    dispatch_async(dispatch_get_main_queue(), ^{
      completion();
    });
    return;
  }
  os_unfair_lock_unlock(&_invalidationLock);

  if (!shouldInitiateCleanup)
    return;

  VanguardAudioPreviewRuntime *strongSelf = self;

  void (^cleanupBlock)(void) = ^{
    [strongSelf assertOnSchedulerQueue];
    // Teardown order: coordinators first, then timer, then players, then
    // engine.
    [strongSelf->_addedAudioSlot.coordinator invalidate];
    [strongSelf->_voiceoverSlot.coordinator invalidate];
    // V-B1: Include original slot in invalidation teardown.
    [strongSelf->_originalAudioSlot.coordinator invalidate];
    [strongSelf->_boundaryTimer cancel];
    [strongSelf->_addedAudioSlot.player stop];
    [strongSelf->_voiceoverSlot.player stop];
    // V-B1: Stop original slot player during invalidation.
    [strongSelf->_originalAudioSlot.player stop];
    [strongSelf->_engine stop];
    strongSelf->_descriptors = @[];
    [strongSelf->_fileCache removeAllObjects];
    [strongSelf->_failedTrackIds removeAllObjects];
    strongSelf->_addedAudioSlot.activeDescriptor = nil;
    strongSelf->_voiceoverSlot.activeDescriptor = nil;
    // V-B1: Clear original slot active descriptor.
    strongSelf->_originalAudioSlot.activeDescriptor = nil;
    strongSelf->_runtimeState = VGAudioPreviewRuntimeStateInvalidated;
    NSLog(@"[VanguardAudioPreviewRuntime][D] invalidation cleanup complete");

    dispatch_async(dispatch_get_main_queue(), ^{
      NSArray<dispatch_block_t> *waiters;
      os_unfair_lock_lock(&strongSelf->_invalidationLock);
      strongSelf->_invalidationPhase =
          VGAudioPreviewInvalidationStateInvalidated;
      waiters = [strongSelf->_invalidationWaiters copy];
      [strongSelf->_invalidationWaiters removeAllObjects];
      os_unfair_lock_unlock(&strongSelf->_invalidationLock);

      for (dispatch_block_t w in waiters) {
        w();
      }
    });
  };

  if (dispatch_get_specific(_schedulerQueueKey) == (__bridge void *)self) {
    cleanupBlock();
  } else {
    dispatch_async(_schedulerQueue, cleanupBlock);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Package-private testing seam
// ─────────────────────────────────────────────────────────────────────────────

- (nullable VGAudioPreviewTrackDescriptor *)activeDescriptor {
  if (_addedAudioSlot.activeDescriptor) {
    return _addedAudioSlot.activeDescriptor;
  }
  if (_voiceoverSlot.activeDescriptor) {
    return _voiceoverSlot.activeDescriptor;
  }
  // V-B1: include original slot in the test seam so tests can observe
  // original-lane activity.
  return _originalAudioSlot.activeDescriptor;
}

- (nullable VGAudioPreviewTrackDescriptor *)_activeDescriptor {
  return [self activeDescriptor];
}

- (void)vg_performSynchronouslyOnSchedulerQueueForTesting:
    (dispatch_block_t)block {
  NSParameterAssert(block != nil);
  if (dispatch_get_specific(_schedulerQueueKey) == (__bridge void *)self) {
    block();
  } else {
    dispatch_sync(_schedulerQueue, block);
  }
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
