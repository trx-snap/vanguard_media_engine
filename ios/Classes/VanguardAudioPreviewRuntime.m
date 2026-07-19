// VanguardAudioPreviewRuntime.m
// Vanguard Media Engine — Phase 10-C Slice K
//
// Implementation of VanguardAudioPreviewRuntime.
// See VanguardAudioPreviewRuntime.h for architecture, threading, and API docs.
//
// Slice K: two-slot (Added Audio + Voice-over) architecture.
// Each slot owns a player, automation coordinator, and per-slot segment serial.
// One master boundary timer fires at the earliest next-decision PTS across both
// lanes. Backward-compatible with all pre-Slice-K tests via single-player init.

#import "VanguardAudioPreviewRuntime.h"
#import "VGAudioPreviewTrackDescriptor.h"
#import "VGAudioPreviewAutomationCoordinator.h"
#import "VGAudioPreviewAutomationTimer.h"

#if VG_USE_V2_GRAPH

#import <QuartzCore/QuartzCore.h>
#import <UMF/VGAudioSidecarPlan.h>

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Production collaborators
// ─────────────────────────────────────────────────────────────────────────────

// Production clock — wraps CACurrentMediaTime().
@interface VGProductionAudioPreviewClock : NSObject <VGAudioPreviewClock>
@end
@implementation VGProductionAudioPreviewClock
- (NSTimeInterval)currentTime {
  return CACurrentMediaTime();
}
@end

// Production timer — wraps a one-shot dispatch_source_t.
@interface VGProductionAudioPreviewTimer : NSObject <VGAudioPreviewTimer> {
  dispatch_queue_t _targetQueue;
  dispatch_source_t _Nullable _source;
}
- (instancetype)initWithQueue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation VGProductionAudioPreviewTimer

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
  self = [super init];
  if (self) {
    _targetQueue = queue;
    _source = nil;
  }
  return self;
}

- (void)armWithDelay:(NSTimeInterval)delay block:(dispatch_block_t)block {
  // Cancel any previous source before creating a new one.
  [self cancel];
  dispatch_source_t src =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _targetQueue);
  uint64_t ns = (uint64_t)(delay * NSEC_PER_SEC);
  dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns),
                            DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
  dispatch_block_t capturedBlock = [block copy];
  dispatch_source_set_event_handler(src, capturedBlock);
  _source = src;
  dispatch_resume(src);
}

- (void)cancel {
  if (_source) {
    dispatch_source_cancel(_source);
    _source = nil;
  }
}

@end

// Production file provider — wraps AVAudioFile and NSFileManager.
@interface VGProductionAudioPreviewFileProvider
    : NSObject <VGAudioPreviewFileProvider>
@end
@implementation VGProductionAudioPreviewFileProvider
- (nullable AVAudioFile *)openFileAtURL:(NSURL *)url
                                  error:(NSError *_Nullable *_Nullable)error {
  return [[AVAudioFile alloc] initForReading:url error:error];
}
- (BOOL)fileExistsAtURL:(NSURL *)url {
  return [[NSFileManager defaultManager] fileExistsAtPath:url.path];
}
@end

// Production engine — wraps AVAudioEngine.
@interface VGProductionAudioPreviewEngine : NSObject <VGAudioPreviewEngine> {
  AVAudioEngine *_engine;
}
- (instancetype)initWithEngine:(AVAudioEngine *)engine
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation VGProductionAudioPreviewEngine

- (instancetype)initWithEngine:(AVAudioEngine *)engine {
  self = [super init];
  if (self) {
    _engine = engine;
  }
  return self;
}

- (void)attachNode:(AVAudioNode *)node {
  [_engine attachNode:node];
}

- (void)connect:(AVAudioNode *)node1
             to:(AVAudioNode *)node2
         format:(nullable AVAudioFormat *)format {
  [_engine connect:node1 to:node2 format:format];
}

- (void)prepare {
  [_engine prepare];
}

- (BOOL)startAndReturnError:(NSError *_Nullable *_Nullable)error {
  return [_engine startAndReturnError:error];
}

- (void)stop {
  [_engine stop];
}

- (AVAudioMixerNode *)mainMixerNode {
  return _engine.mainMixerNode;
}

@end

// Production player — wraps AVAudioPlayerNode.
@interface VGProductionAudioPreviewPlayer : NSObject <VGAudioPreviewPlayer> {
  AVAudioPlayerNode *_node;
}
- (instancetype)initWithNode:(AVAudioPlayerNode *)node
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation VGProductionAudioPreviewPlayer

- (instancetype)initWithNode:(AVAudioPlayerNode *)node {
  self = [super init];
  if (self) {
    _node = node;
  }
  return self;
}

- (void)scheduleSegment:(AVAudioFile *)file
             startingFrame:(AVAudioFramePosition)startFrame
                frameCount:(AVAudioFrameCount)frameCount
                    atTime:(nullable AVAudioTime *)when
    completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType
         completionHandler:
             (nullable AVAudioPlayerNodeCompletionHandler)completionHandler {
  [_node scheduleSegment:file
               startingFrame:startFrame
                  frameCount:frameCount
                      atTime:when
      completionCallbackType:callbackType
           completionHandler:completionHandler];
}

- (void)play {
  [_node play];
}
- (void)stop {
  [_node stop];
}
- (void)setVolume:(float)v {
  _node.volume = v;
}

@end


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGAudioPreviewSlot — per-lane state container
// ─────────────────────────────────────────────────────────────────────────────
//
// Bundles all state specific to one scheduling lane (Added Audio or Voice-over).
// The runtime owns two slots; one master boundary timer is shared.

@interface VGAudioPreviewSlot : NSObject

@property(nonatomic, strong) id<VGAudioPreviewPlayer> player;
@property(nonatomic, strong) VGAudioPreviewAutomationCoordinator *coordinator;

// Active-descriptor state — set by _activateDescriptor:atPTS:inSlot:.
@property(nonatomic, strong, nullable) VGAudioPreviewTrackDescriptor *activeDescriptor;
@property(nonatomic) NSTimeInterval timelineStart;
@property(nonatomic) NSTimeInterval sourceTrimStart;
@property(nonatomic) NSTimeInterval activeDuration;
@property(nonatomic) double fileSampleRate;
@property(nonatomic) AVAudioFramePosition fileLengthFrames;
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
  id<VGAudioPreviewTimer> _boundaryTimer;   ///< One master boundary timer.
  id<VGAudioPreviewFileProvider> _fileProvider;
  id<VGAudioPreviewEngine> _engine;

  // ── Slice K: two-slot architecture ──────────────────────────────────────
  // Each slot bundles its own player, coordinator, active descriptor, and
  // per-slot scheduled-segment serial. The master boundary timer remains shared.
  VGAudioPreviewSlot *_addedAudioSlot;   ///< music / sfx / original lane.
  VGAudioPreviewSlot *_voiceoverSlot;    ///< voiceover lane.

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
  // Slice K: two player nodes — Added Audio and Voice-over.
  AVAudioPlayerNode *addedAudioNode = [[AVAudioPlayerNode alloc] init];
  AVAudioPlayerNode *voiceoverNode  = [[AVAudioPlayerNode alloc] init];

  id<VGAudioPreviewEngine> engineAdapter =
      [[VGProductionAudioPreviewEngine alloc] initWithEngine:engine];
  id<VGAudioPreviewPlayer> addedAudioAdapter =
      [[VGProductionAudioPreviewPlayer alloc] initWithNode:addedAudioNode];
  id<VGAudioPreviewPlayer> voiceoverAdapter =
      [[VGProductionAudioPreviewPlayer alloc] initWithNode:voiceoverNode];

  // Wire both player nodes into the engine before any scheduling arrives.
  [engine attachNode:addedAudioNode];
  [engine connect:addedAudioNode to:engine.mainMixerNode format:nil];
  [engine attachNode:voiceoverNode];
  [engine connect:voiceoverNode to:engine.mainMixerNode format:nil];

  return [self
      initWithSnapshotProvider:snapshotProvider
                lifecycleEpoch:lifecycleEpoch
                         clock:[[VGProductionAudioPreviewClock alloc] init]
                         timer:nil
       addedAudioAutomationTimer:nil
       voiceoverAutomationTimer:nil
                  fileProvider:[[VGProductionAudioPreviewFileProvider alloc]
                                   init]
                        engine:engineAdapter
              addedAudioPlayer:addedAudioAdapter
               voiceoverPlayer:voiceoverAdapter];
}

/// Backward-compatible single-player test initialiser.
/// Routes |player| and |automationTimer| to the Added Audio slot.
/// The Voice-over slot gets the same player and a new production automation
/// timer — sufficient for all pre-Slice-K tests, which never assert on
/// per-slot voice-over behavior.
- (instancetype)
    initWithSnapshotProvider:(VGTimelineSnapshotProvider)snapshotProvider
              lifecycleEpoch:(uint64_t)lifecycleEpoch
                       clock:(id<VGAudioPreviewClock>)clock
                       timer:(nullable id<VGAudioPreviewTimer>)timer
             automationTimer:(nullable id<VGAudioPreviewAutomationTimer>)automationTimer
                fileProvider:(id<VGAudioPreviewFileProvider>)fileProvider
                      engine:(id<VGAudioPreviewEngine>)engine
                      player:(id<VGAudioPreviewPlayer>)player {
  return [self
      initWithSnapshotProvider:snapshotProvider
                lifecycleEpoch:lifecycleEpoch
                         clock:clock
                         timer:timer
       addedAudioAutomationTimer:automationTimer
       voiceoverAutomationTimer:nil   // production timer created in designated init
                  fileProvider:fileProvider
                        engine:engine
              addedAudioPlayer:player
               voiceoverPlayer:player]; // same player — backward compatible
}

/// Designated multi-slot test/production initializer.
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
  self = [super init];
  if (!self)
    return nil;

  _snapshotProvider = [snapshotProvider copy];
  _lifecycleEpoch = lifecycleEpoch;
  _clock = clock;
  _fileProvider = fileProvider;
  _engine = engine;

  // ── Serial scheduler queue ────────────────────────────────────────────────
  _schedulerQueueKey =
      &_schedulerQueueKey; // unique pointer for dispatch_get_specific
  _schedulerQueue = dispatch_queue_create(
      "com.vanguard.audioPreviewScheduler",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                              QOS_CLASS_USER_INTERACTIVE, 0));
  dispatch_queue_set_specific(_schedulerQueue, _schedulerQueueKey,
                              (__bridge void *)self, NULL);

  // ── Master boundary timer ─────────────────────────────────────────────────
  if (timer) {
    _boundaryTimer = timer;
  } else {
    _boundaryTimer =
        [[VGProductionAudioPreviewTimer alloc] initWithQueue:_schedulerQueue];
  }

  // ── Slice K: build Added Audio slot ──────────────────────────────────────
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
               if (!ss) return;
               [ss->_addedAudioSlot.player setVolume:v];
               ss->_addedAudioSlot.currentVolume = v;
             }];
  }

  // ── Slice K: build Voice-over slot ───────────────────────────────────────
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
               if (!ss) return;
               [ss->_voiceoverSlot.player setVolume:v];
               ss->_voiceoverSlot.currentVolume = v;
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

  // Deactivate both coordinators before replacing descriptor state.
  [_addedAudioSlot.coordinator deactivate];
  [_voiceoverSlot.coordinator deactivate];
  _addedAudioSlot.activeDescriptor = nil;
  _voiceoverSlot.activeDescriptor = nil;
  _descriptors = [eligible copy];
  [_fileCache removeAllObjects];
  [_failedTrackIds removeAllObjects];

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
    lastFileError = !fileExists
                        ? VGAudioPreviewPreparationResultFailedMissingFile
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
    NSLog(@"[AudioSliceKTimingProbe] _currentPTSFromSnapshot: hostNow=%.6f, playStartHostTime=%.6f, playStartPTS=%.6f, elapsed=%.6f, computedPTS=%.6f", [_clock currentTime], snap.playStartHostTime, snap.playStartPTS, elapsed, res);
  }
  return res;
}

/// Cancels the boundary timer, stops both players, pauses both coordinators.
/// Increments commandSerial and updates _activeToken.
/// Per-slot scheduledSegmentSerials are NOT reset here — they are
/// incremented inside each _scheduleSegment:inSlot: call so that the
/// per-slot stale guards work correctly.
- (uint64_t)_cancelAndIncrementSerial:(uint64_t)generation {
  [self assertOnSchedulerQueue];
  [_addedAudioSlot.coordinator pause];
  [_voiceoverSlot.coordinator pause];
  [_boundaryTimer cancel];
  [_addedAudioSlot.player stop];
  [_voiceoverSlot.player stop];
  // Reset scheduled-end tracking so the next play cycle starts fresh.
  _addedAudioSlot.scheduledEndPTS = 0.0;
  _voiceoverSlot.scheduledEndPTS = 0.0;
  _commandSerial++;
  _activeToken =
      (VGAudioPreviewWorkToken){_lifecycleEpoch, _commandSerial, generation};
  return _commandSerial;
}

// ─────────────────────────────────────────────────────────────────────────────
// Lane-aware descriptor selection
// ─────────────────────────────────────────────────────────────────────────────

/// Whether a descriptor belongs to the Added Audio lane.
/// Added Audio lane: music, sfx, original (legacy — avoids VO routing to
/// wrong slot while preserving Slice F Original behavior).
static BOOL VGIsAddedAudioRole(NSString *role) {
  return [role isEqualToString:@"music"]
      || [role isEqualToString:@"sfx"]
      || [role isEqualToString:@"original"];
}

/// Whether a descriptor belongs to the Voice-over lane.
static BOOL VGIsVoiceoverRole(NSString *role) {
  return [role isEqualToString:@"voiceover"];
}

/// Selects the winning descriptor for the Added Audio lane at |pts|.
/// Priority: music > original/sfx. Among same role: latest timelineStart wins.
/// Returns nil if no Added Audio descriptor is active at pts.
- (nullable VGAudioPreviewTrackDescriptor *)
    _selectAddedAudioDescriptorAtPTS:(NSTimeInterval)pts {
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
- (nullable VGAudioPreviewTrackDescriptor *)
    _selectVoiceoverDescriptorAtPTS:(NSTimeInterval)pts {
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

/// Returns the next decision boundary PTS after |currentPTS| across ALL
/// descriptors (both lanes). This is the earliest point where lane selection
/// may change. Returns INFINITY if no future boundary exists.
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
    BOOL isAddedActive = _addedAudioSlot.activeDescriptor &&
        [d.trackId isEqualToString:_addedAudioSlot.activeDescriptor.trackId];
    BOOL isVOActive = _voiceoverSlot.activeDescriptor &&
        [d.trackId isEqualToString:_voiceoverSlot.activeDescriptor.trackId];

    if (isAddedActive) {
      conservativeActiveDuration = _addedAudioSlot.activeDuration;
    } else if (isVOActive) {
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
    NSLog(@"[VanguardAudioPreviewRuntime][F] activateDescriptor: invalid metadata "
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

  // Delegate gain to coordinator if the descriptor has raw keyframes.
  if (descriptor.hasRawKeyframes) {
    [slot.coordinator activateWithRawKeyframes:descriptor.rawVolumeKeyframes
                                 timelineStart:ts
                                  effectiveEnd:(ts + activeDur)
                                    initialPTS:pts];
    if (!slot.coordinator.hasActiveEnvelope) {
      [slot.coordinator deactivate];
      [slot.player setVolume:descriptor.staticVolume];
      slot.currentVolume = descriptor.staticVolume;
    }
    // Else: coordinator applied initial gain through gainSink.
  } else {
    [slot.coordinator deactivate];
    [slot.player setVolume:descriptor.staticVolume];
    slot.currentVolume = descriptor.staticVolume;
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
      slot.fileLengthFrames,
      floor(scheduledEndSource * slot.fileSampleRate));

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
    NSString *laneName = (slot == _addedAudioSlot) ? @"AddedAudio" : @"Voiceover";
    NSLog(@"[AudioSliceKTimingProbe] segment scheduling: lane=%@, trackID=%@, role=%@, timelineStart=%.6f, sourceTrimStart=%.6f, activeDuration=%.6f, schedulePTS_Start=%.6f, schedulePTS_End=%.6f, startFrame=%lld, frameCount=%u, expectedAudibleStart=%.6f, expectedAudibleEnd=%.6f",
          laneName,
          slot.activeDescriptor.trackId,
          slot.activeDescriptor.role,
          slot.timelineStart,
          slot.sourceTrimStart,
          slot.activeDuration,
          currentPTS,
          scheduledEndPTS,
          (long long)startFrame,
          frameCount,
          slot.timelineStart,
          slot.timelineStart + slot.activeDuration);
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

  [slot.player scheduleSegment:audioFile
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
               if (!VGAudioPreviewWorkTokenEqual(ss->_activeToken, capturedToken))
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

/// Re-evaluates both lanes at |currentPTS|, activates/schedules/plays each slot
/// independently, and arms the master boundary timer for the earliest next
/// decision PTS. Sets _runtimeState to Playing, WaitingForTrackStart, or Ended.
///
/// Must be called on the scheduler queue with an already-validated snapshot.
/// Calls _reevaluateAndTransitionAtPTS:crossLaneActivationFloor:withToken:
/// with crossLaneActivationFloor == currentPTS (all callers except the
/// completion handler use authoritative PTS for both evaluation and activation).
- (void)_reevaluateAndTransitionAtPTS:(NSTimeInterval)currentPTS
                            withToken:(VGAudioPreviewWorkToken)capturedToken {
  [self _reevaluateAndTransitionAtPTS:currentPTS
             crossLaneActivationFloor:currentPTS
                            withToken:capturedToken];
}

/// Re-evaluates both lanes. |currentPTS| is used for the completing slot
/// (may be advanced to capturedScheduledEndPTS via MAX). |crossLaneActivationFloor|
/// is the authoritative clock PTS and caps which idle cross-lane slots may be
/// newly started — an idle slot whose timelineStart > crossLaneActivationFloor
/// is not activated; the boundary timer will handle it when PTS arrives.
- (void)_reevaluateAndTransitionAtPTS:(NSTimeInterval)currentPTS
             crossLaneActivationFloor:(NSTimeInterval)activationFloor
                            withToken:(VGAudioPreviewWorkToken)capturedToken {
  [self assertOnSchedulerQueue];

  VGAudioPreviewTrackDescriptor *addedWinner =
      [self _selectAddedAudioDescriptorAtPTS:currentPTS];
  VGAudioPreviewTrackDescriptor *voWinner =
      [self _selectVoiceoverDescriptorAtPTS:currentPTS];

  if ([self _isSliceK]) {
    NSLog(@"[AudioSliceKTimingProbe] _reevaluateAndTransitionAtPTS: currentPTS=%.6f, addedWinner=%@, voWinner=%@, addedActiveDescriptor=%@, voActiveDescriptor=%@",
          currentPTS,
          addedWinner.trackId,
          voWinner.trackId,
          _addedAudioSlot.activeDescriptor.trackId,
          _voiceoverSlot.activeDescriptor.trackId);
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
    // playhead arrives. This prevents the AVAudioPlayerNodeCompletionDataConsumed
    // callback (which can fire ~1s before audio renders to speakers) from
    // starting an idle VO slot prematurely when evaluationPTS was advanced
    // via MAX(authoritativePTS, capturedScheduledEndPTS).
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


  // Determine if at least one lane is actively playing.
  BOOL hasActiveLane = addedActive || voActive;

  // Deferred-termination epsilon: if activationFloor is within 1 ms of
  // scheduledEndPTS the segment is treated as physically finished. 1 ms aligns
  // with the _armBoundaryTimerSafeDelay clamp floor and is sub-audible.
  static const NSTimeInterval kDeferEpsilon = 0.001;

  // Per-slot defer flags. Set to YES when AVAudioPlayerNodeCompletionDataConsumed
  // fires early (activationFloor < slot.scheduledEndPTS - epsilon) and the
  // segment is still physically rendering. In that case the player must NOT be
  // stopped until the boundary timer fires at the real scheduled end.
  BOOL addedDeferStop = NO;
  BOOL voDeferStop    = NO;

  if (!addedWinner) {
    // Deferred-termination guard: if the real playhead (activationFloor) has not
    // yet reached the slot's physical scheduled end, leave the player running so
    // queued audio renders through. The boundary timer is directed at
    // scheduledEndPTS below to perform the actual cleanup.
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
        NSLog(@"[AudioSliceKTimingProbe] lane stop: lane=AddedAudio, currentPTS=%.6f, reason=NoActiveDescriptor, otherLaneActive=%d", currentPTS, hasActiveLane);
      }
      // No active Added Audio descriptor — stop and quiet the slot.
      [_addedAudioSlot.coordinator deactivate];
      // Stop the player node only if another lane remains active.
      if (hasActiveLane) {
        [_addedAudioSlot.player stop];
        // Increment serial so any in-flight completion block is treated as stale.
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
        NSLog(@"[AudioSliceKTimingProbe] lane stop: lane=Voiceover, currentPTS=%.6f, reason=NoActiveDescriptor, otherLaneActive=%d", currentPTS, hasActiveLane);
      }
      // No active Voice-over descriptor — stop and quiet the slot.
      [_voiceoverSlot.coordinator deactivate];
      // Stop the player node only if another lane remains active.
      if (hasActiveLane) {
        [_voiceoverSlot.player stop];
        // Increment serial so any in-flight completion block is treated as stale.
        _voiceoverSlot.scheduledSegmentSerial++;
      }
      _voiceoverSlot.activeDescriptor = nil;
      _voiceoverSlot.scheduledEndPTS = 0.0;
    }
  }

  // Next global decision boundary across both lanes.
  NSTimeInterval nextBoundary = [self _computeNextDecisionPTS:currentPTS];

  // Schedule and play each active slot independently.
  BOOL anyScheduled = NO;

  if (addedActive) {
    // Skip re-queuing if the slot is already scheduled past the current
    // evaluation PTS. This prevents double-buffering when a DataConsumed
    // completion callback fires early (~1 s of prefetch) and schedules the
    // same-lane continuation, and then the boundary timer fires at the
    // suppressed VO-start boundary at the same evaluation point.
    BOOL addedAlreadyScheduled = (currentPTS < _addedAudioSlot.scheduledEndPTS);
    if (addedAlreadyScheduled) {
      // Slot is already playing the correct segment — just ensure it runs.
      [_addedAudioSlot.player play];
      anyScheduled = YES;
    } else {
      NSTimeInterval addedEndPTS =
          (isfinite(nextBoundary) && nextBoundary <= addedTrackEnd)
              ? nextBoundary : addedTrackEnd;
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
    // Skip re-queuing if the slot is already scheduled past the current
    // evaluation PTS. Symmetric with the AddedAudio guard above — prevents
    // double-buffering when a DataConsumed completion callback fires early
    // and the boundary timer fires at the same evaluation PTS.
    BOOL voAlreadyScheduled = (currentPTS < _voiceoverSlot.scheduledEndPTS);
    if (voAlreadyScheduled) {
      // Slot is already playing the correct segment — just ensure it runs.
      [_voiceoverSlot.player play];
      anyScheduled = YES;
    } else {
      NSTimeInterval voEndPTS =
          (isfinite(nextBoundary) && nextBoundary <= voTrackEnd)
              ? nextBoundary : voTrackEnd;
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

  // Arm the master boundary timer if any lane is active and a future boundary
  // exists, OR if both lanes are silent but a start boundary is approaching.
  // Deferred slots contribute to hasActiveLane so the runtime keeps Playing
  // state while queued audio renders through the hardware.
  hasActiveLane = addedActive || voActive || addedDeferStop || voDeferStop;

  // Timer-base correction: when the VO activation floor guard suppressed an
  // early cross-lane start, evaluationPTS was advanced (MAX) past voStart, so
  // _computeNextDecisionPTS:currentPTS skips voStart as a candidate boundary.
  // Fix: use activationFloor as the timer base and MIN in suppressedVOStart so
  // the timer fires at the real-time equivalent of voStart, not beyond it.
  // In all non-completion paths activationFloor == currentPTS and
  // suppressedVOStart == INFINITY, so the computation is identical to before.
  NSTimeInterval timerBase = activationFloor;
  NSTimeInterval timerNextBoundary = nextBoundary;
  if (isfinite(suppressedVOStart)) {
    timerNextBoundary = MIN(timerNextBoundary, suppressedVOStart);
  }
  // Deferred-termination cleanup boundaries: _computeNextDecisionPTS does NOT
  // include a slot's trackEnd when trackEnd <= currentPTS (the slot appears
  // done from the descriptor selector's perspective). Inject the deferred
  // slot's scheduledEndPTS explicitly so the boundary timer fires at the real
  // physical end and performs the actual stop/deactivate/clear.
  if (addedDeferStop && _addedAudioSlot.scheduledEndPTS > timerBase) {
    timerNextBoundary = MIN(timerNextBoundary, _addedAudioSlot.scheduledEndPTS);
  }
  if (voDeferStop && _voiceoverSlot.scheduledEndPTS > timerBase) {
    timerNextBoundary = MIN(timerNextBoundary, _voiceoverSlot.scheduledEndPTS);
  }
  BOOL hasFutureBoundary = isfinite(timerNextBoundary) && timerNextBoundary > timerBase;

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
          @"next=%.3f", timerBase, timerNextBoundary);
  } else {
    // No lanes active, no future boundary.
    _runtimeState = VGAudioPreviewRuntimeStateEnded;
    NSLog(@"[VanguardAudioPreviewRuntime][F] transition: no more descriptors "
          @"— Ended");
  }
}

/// Builds the validated automation tick block for |slot|.
/// Captures the slot's scheduledSegmentSerial and the shared activeToken.
- (dispatch_block_t)_buildAutomationTickBlockForToken:
                        (VGAudioPreviewWorkToken)tok
                                               inSlot:
                        (VGAudioPreviewSlot *)slot {
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
      NSString *laneName = (capturedSlot == ss->_addedAudioSlot) ? @"AddedAudio" : @"Voiceover";
      NSLog(@"[AudioSliceKTimingProbe] keyframe/gain evaluation: lane=%@, trackID=%@, evaluatedPTS=%.6f, resultingGain=%.6f",
            laneName,
            capturedSlot.activeDescriptor.trackId,
            pts,
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
          @"0.001 s", delay);
  } else {
    VGTimelineStateSnapshot snap = _snapshotProvider();
    if (!snap.isValid || !snap.isPlaying)
      return;
    if (snap.generation != token.timelineGeneration)
      return;
    NSTimeInterval pts = [self _currentPTSFromSnapshot:snap];
    NSLog(@"[VanguardAudioPreviewRuntime][F] safe-delay: zero/negative delay "
          @"(%.6f s) — re-evaluating inline at PTS=%.3f", delay, pts);
    [self _reevaluateAndTransitionAtPTS:pts withToken:token];
  }
}

/// Arms the one-shot boundary timer.
- (void)_armBoundaryTimerWithDelay:(NSTimeInterval)delay
                             token:(VGAudioPreviewWorkToken)token {
  [self assertOnSchedulerQueue];

  // Capture the shared per-slot serials so that if either slot's completion
  // callback has already advanced that slot, this timer is stale.
  uint64_t capturedAddedSerial = _addedAudioSlot.scheduledSegmentSerial;
  uint64_t capturedVOSerial    = _voiceoverSlot.scheduledSegmentSerial;

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
               if (!VGAudioPreviewWorkTokenEqual(ss->_activeToken, capturedToken))
                 return;

               // Stale guard: if both slots have already advanced past the
               // serial captured when the timer was armed, the timer is stale.
               // (Either slot advancing is enough to invalidate this timer's
               // intent — the slot that advanced already re-evaluated.)
               if (ss->_addedAudioSlot.scheduledSegmentSerial != capturedAddedSerial &&
                   ss->_voiceoverSlot.scheduledSegmentSerial != capturedVOSerial)
                 return;

               VGTimelineStateSnapshot snap = capturedProvider();
               if (!snap.isValid || !snap.isPlaying) {
                 if (!snap.isValid) {
                   [ss->_addedAudioSlot.player stop];
                   [ss->_voiceoverSlot.player stop];
                   ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
                 }
                 return;
               }
               if (snap.generation != capturedToken.timelineGeneration)
                 return;

               NSTimeInterval currentPTS = [ss _currentPTSFromSnapshot:snap];
               NSLog(@"[VanguardAudioPreviewRuntime][F] boundary timer fired "
                     @"at PTS=%.3f", currentPTS);
               [ss _reevaluateAndTransitionAtPTS:currentPTS
                                       withToken:capturedToken];
             }];
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

  uint64_t serial = [self _cancelAndIncrementSerial:snap.generation];
  VGAudioPreviewWorkToken token = _activeToken;
  (void)serial;

  if ([self _isSliceK]) {
    NSLog(@"[AudioSliceKTimingProbe] commandPlay: startPTS=%.6f, hostTime=%.6f, generation=%llu, serial=%llu", snap.playStartPTS, snap.playStartHostTime, token.timelineGeneration, serial);
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
      NSLog(@"[AudioSliceKTimingProbe] commandPause: currentPTS=%.6f, generation=%llu", [ss _currentPTSFromSnapshot:snap], (unsigned long long)generation);
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
      NSLog(@"[AudioSliceKTimingProbe] commandSeek: targetPTS=%.6f, generation=%llu", snap.timelinePTS, (unsigned long long)generation);
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
      NSLog(@"[AudioSliceKTimingProbe] commandEOS: generation=%llu", (unsigned long long)generation);
    }
    NSLog(@"[VanguardAudioPreviewRuntime][D] EOS — audio stopped");
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Invalidation
// ─────────────────────────────────────────────────────────────────────────────

- (void)invalidateAsync:(dispatch_block_t)completion {
  NSParameterAssert(completion != nil);

  // Phase A: close command acceptance atomically.
  atomic_store(&_acceptingCommands, NO);

  // Immediate audio quiesce: stop both players synchronously on calling thread.
  // AVAudioPlayerNode.stop is documented as thread-safe.
  [_addedAudioSlot.player stop];
  [_voiceoverSlot.player stop];

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
    // Teardown order: coordinators first, then timer, then players, then engine.
    [strongSelf->_addedAudioSlot.coordinator invalidate];
    [strongSelf->_voiceoverSlot.coordinator invalidate];
    [strongSelf->_boundaryTimer cancel];
    [strongSelf->_addedAudioSlot.player stop];
    [strongSelf->_voiceoverSlot.player stop];
    [strongSelf->_engine stop];
    strongSelf->_descriptors = @[];
    [strongSelf->_fileCache removeAllObjects];
    [strongSelf->_failedTrackIds removeAllObjects];
    strongSelf->_addedAudioSlot.activeDescriptor = nil;
    strongSelf->_voiceoverSlot.activeDescriptor = nil;
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
  return _voiceoverSlot.activeDescriptor;
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
