// VanguardAudioPreviewRuntime.m
// Vanguard Media Engine — Phase 10-C Slice D
//
// Implementation of VanguardAudioPreviewRuntime.
// See VanguardAudioPreviewRuntime.h for architecture, threading, and API docs.

#import "VanguardAudioPreviewRuntime.h"

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
#pragma mark - VGAudioPreviewTrackDescriptor
// ─────────────────────────────────────────────────────────────────────────────

// Private extension — keeps role internal to .m (Slice F Mandatory Correction 3).
@interface VGAudioPreviewTrackDescriptor () {
  NSString *_role; ///< Either @"music" or @"original". Never nil.
}
/// The track role accepted by the scheduler: @"music" or @"original".
/// Private to .m — never exposed in public_header_files.
@property(nonatomic, readonly, copy) NSString *role;
@end

@implementation VGAudioPreviewTrackDescriptor

- (NSString *)role { return _role; }


- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dict {
  // 1. Role must be "music" or "original"; all others (incl. voiceover) rejected.
  id roleRaw = dict[@"role"];
  if (![roleRaw isKindOfClass:[NSString class]])
    return nil;
  NSString *role = (NSString *)roleRaw;
  BOOL isMusicRole = [role isEqualToString:@"music"];
  BOOL isOriginalRole = [role isEqualToString:@"original"];
  if (!isMusicRole && !isOriginalRole)
    return nil;

  // 2. trackId non-empty string.
  id trackIdRaw = dict[@"trackId"];
  if (![trackIdRaw isKindOfClass:[NSString class]])
    return nil;
  NSString *trackId = (NSString *)trackIdRaw;
  if (trackId.length == 0)
    return nil;

  // 3. url non-empty string → local file NSURL.
  id urlRaw = dict[@"url"];
  if (![urlRaw isKindOfClass:[NSString class]])
    return nil;
  NSString *urlStr = (NSString *)urlRaw;
  if (urlStr.length == 0)
    return nil;
  NSURL *fileURL = [NSURL fileURLWithPath:urlStr];
  if (!fileURL)
    return nil;

  // 4. Numeric fields — finite bounds.
  id startTimeRaw = dict[@"startTime"];
  id trimStartRaw = dict[@"sourceTrimStart"];
  id volumeRaw = dict[@"volume"];
  id durationRaw = dict[@"duration"];

  if (![startTimeRaw isKindOfClass:[NSNumber class]])
    return nil;

  // sourceTrimStart defaults to 0.0 if nil.
  double trimStart = 0.0;
  if (trimStartRaw != nil) {
    if (![trimStartRaw isKindOfClass:[NSNumber class]])
      return nil;
    trimStart = [trimStartRaw doubleValue];
  }

  // volume defaults to 1.0 if nil.
  double volume = 1.0;
  if (volumeRaw != nil) {
    if (![volumeRaw isKindOfClass:[NSNumber class]])
      return nil;
    volume = [volumeRaw doubleValue];
  }
  if (![durationRaw isKindOfClass:[NSNumber class]])
    return nil;

  double startTime = [startTimeRaw doubleValue];
  double duration = [durationRaw doubleValue];

  // Finite checks.
  if (!isfinite(startTime))
    return nil;
  if (!isfinite(trimStart))
    return nil;
  if (!isfinite(volume))
    return nil;
  if (!isfinite(duration) && duration != -1.0)
    return nil;

  // Bound checks.
  if (startTime < 0.0)
    return nil;
  if (trimStart < 0.0)
    return nil;
  if (volume < 0.0 || volume > 1.0)
    return nil;
  if (duration != -1.0 && duration < 0.0)
    return nil;

  self = [super init];
  if (!self)
    return nil;
  _trackId = [trackId copy];
  _fileURL = fileURL;
  _timelineStart = startTime;
  _sourceTrimStart = trimStart;
  _requestedDuration = duration;
  _staticVolume = (float)volume;
  _role = [role copy];
  return self;
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
  id<VGAudioPreviewTimer> _boundaryTimer;
  id<VGAudioPreviewFileProvider> _fileProvider;
  id<VGAudioPreviewEngine> _engine;
  id<VGAudioPreviewPlayer> _player;

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
  // Per-scheduled-segment serial. Incremented each time a player segment is
  // scheduled. Captured inside the completion handler. A completion block is
  // considered stale if the runtime has already scheduled a newer segment
  // (i.e. _scheduledSegmentSerial != captured value). This prevents the
  // previous-descriptor's natural-completion callback from cancelling the
  // boundary timer of the descriptor that was scheduled by a transition.
  uint64_t _scheduledSegmentSerial;

  // ── Track data (Slice F: multi-descriptor) ──────────────────────────────
  //
  // _descriptors: ordered list of all audible (volume > 0), structurally valid
  //   descriptors produced from prepareWithSidecarPlan:.  Ordering matches the
  //   sidecar plan's track array (plan order = final tie-break).
  //
  // _fileCache: maps trackId → opened AVAudioFile.  Files are opened lazily
  //   on first scheduling attempt.  Stale entries are released during
  //   invalidation cleanup.
  //
  // _failedTrackIds: set of trackIds that failed to open.  Prevents continuous
  //   retry on every scheduler decision (Mandatory Correction 1).
  //
  // _timelineDuration: authoritative project duration from prepareWithSidecarPlan:.
  //
  // Active-descriptor state (computed when a descriptor is activated):
  //   _activeDescriptor  — the descriptor currently being scheduled (or nil).
  //   _timelineStart     — MAX(0, _activeDescriptor.timelineStart).
  //   _sourceTrimStart   — MAX(0, _activeDescriptor.sourceTrimStart).
  //   _activeDuration    — clipped effective duration (see _activateDescriptor:).
  //   _fileSampleRate    — opened file's sample rate.
  //   _fileLengthFrames  — opened file's frame count.
  NSArray<VGAudioPreviewTrackDescriptor *> *_descriptors;
  NSMutableDictionary<NSString *, AVAudioFile *> *_fileCache;
  NSMutableSet<NSString *> *_failedTrackIds;
  NSTimeInterval _timelineDuration;

  VGAudioPreviewTrackDescriptor *_Nullable _activeDescriptor;
  NSTimeInterval _timelineStart;
  NSTimeInterval _sourceTrimStart;
  NSTimeInterval _activeDuration;
  double _fileSampleRate;
  AVAudioFramePosition _fileLengthFrames;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VanguardAudioPreviewRuntime implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardAudioPreviewRuntime

// ─── Init
// ─────────────────────────────────────────────────────────────────────

- (instancetype)initWithSnapshotProvider:
                    (VGTimelineSnapshotProvider)snapshotProvider
                          lifecycleEpoch:(uint64_t)lifecycleEpoch {
  AVAudioEngine *engine = [[AVAudioEngine alloc] init];
  AVAudioPlayerNode *playerNode = [[AVAudioPlayerNode alloc] init];

  id<VGAudioPreviewEngine> engineAdapter =
      [[VGProductionAudioPreviewEngine alloc] initWithEngine:engine];
  id<VGAudioPreviewPlayer> playerAdapter =
      [[VGProductionAudioPreviewPlayer alloc] initWithNode:playerNode];

  // Wire the player node into the engine BEFORE creating the timer, so the
  // engine graph is stable before any scheduling could arrive.
  [engine attachNode:playerNode];
  [engine connect:playerNode to:engine.mainMixerNode format:nil];

  return [self
      initWithSnapshotProvider:snapshotProvider
                lifecycleEpoch:lifecycleEpoch
                         clock:[[VGProductionAudioPreviewClock alloc] init]
                         timer:nil // replaced below after queue creation
                  fileProvider:[[VGProductionAudioPreviewFileProvider alloc]
                                   init]
                        engine:engineAdapter
                        player:playerAdapter];
}

- (instancetype)
    initWithSnapshotProvider:(VGTimelineSnapshotProvider)snapshotProvider
              lifecycleEpoch:(uint64_t)lifecycleEpoch
                       clock:(id<VGAudioPreviewClock>)clock
                       timer:(nullable id<VGAudioPreviewTimer>)timer
                fileProvider:(id<VGAudioPreviewFileProvider>)fileProvider
                      engine:(id<VGAudioPreviewEngine>)engine
                      player:(id<VGAudioPreviewPlayer>)player {
  self = [super init];
  if (!self)
    return nil;

  _snapshotProvider = [snapshotProvider copy];
  _lifecycleEpoch = lifecycleEpoch;
  _clock = clock;
  _fileProvider = fileProvider;
  _engine = engine;
  _player = player;

  // ── Serial scheduler queue ────────────────────────────────────────────────
  _schedulerQueueKey =
      &_schedulerQueueKey; // unique pointer for dispatch_get_specific
  _schedulerQueue = dispatch_queue_create(
      "com.vanguard.audioPreviewScheduler",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                              QOS_CLASS_USER_INTERACTIVE, 0));
  dispatch_queue_set_specific(_schedulerQueue, _schedulerQueueKey,
                              (__bridge void *)self, NULL);

  // ── Boundary timer ────────────────────────────────────────────────────────
  // If the caller supplied a mock timer, use it; otherwise create production.
  if (timer) {
    _boundaryTimer = timer;
  } else {
    _boundaryTimer =
        [[VGProductionAudioPreviewTimer alloc] initWithQueue:_schedulerQueue];
  }

  // ── Initial lifecycle state ───────────────────────────────────────────────
  _acceptingCommands = YES;
  _invalidationLock = OS_UNFAIR_LOCK_INIT;
  _invalidationPhase = VGAudioPreviewInvalidationStateAccepting;
  _invalidationWaiters = [NSMutableArray new];
  _runtimeState = VGAudioPreviewRuntimeStateUnprepared;
  _commandSerial = 0;
  _activeToken = (VGAudioPreviewWorkToken){lifecycleEpoch, 0, 0};
  _scheduledSegmentSerial = 0;
  _timelineDuration = 0.0;
  _descriptors = @[];
  _fileCache = [NSMutableDictionary new];
  _failedTrackIds = [NSMutableSet new];
  _activeDescriptor = nil;
  _timelineStart = 0.0;
  _sourceTrimStart = 0.0;
  _activeDuration = 0.0;
  _fileSampleRate = 0.0;
  _fileLengthFrames = 0;

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
  //   (a) initWithDictionary: succeeds (role is music or original, well-formed);
  //   (b) staticVolume > 0.0 (muted tracks are ignored at policy level).
  //
  // Voiceover: rejected by initWithDictionary: (role not in supported set).
  // Music:     volume==0 is muted by composition policy; still excluded here.
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
      if (candidate.staticVolume <= 0.0f)
        continue; // muted by composition policy — skip
      [eligible addObject:candidate];
    }
  }

  if (eligible.count == 0) {
    _runtimeState = VGAudioPreviewRuntimeStateReadySilent;
    NSLog(@"[VanguardAudioPreviewRuntime][D] prepare: no audible eligible "
          @"descriptors — silent");
    return VGAudioPreviewPreparationResultSilentNoEligibleTrack;
  }

  _descriptors = [eligible copy];
  [_fileCache removeAllObjects];
  [_failedTrackIds removeAllObjects];

  // ── Step 2: open the earliest-needed descriptor's file & start engine ─────
  //
  // To preserve existing test expectations (engine.startCount == 1 after
  // prepare when an eligible track exists), we immediately open the file for
  // the descriptor with the lowest timelineStart and start the engine.
  // Later descriptors are opened lazily at schedule time.
  //
  // "Earliest-needed" = descriptor with minimum timelineStart, which is the
  // first one the scheduler will need.

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
    // Mark it failed so scheduler won't retry.
    [_failedTrackIds addObject:firstDesc.trackId];
    _runtimeState = VGAudioPreviewRuntimeStateReadySilent;
    lastFileError = !fileExists
                        ? VGAudioPreviewPreparationResultFailedMissingFile
                        : VGAudioPreviewPreparationResultFailedUnsupportedFormat;

    // If there are other descriptors that might succeed, return Ready so the
    // scheduler can try them.  If this was the only descriptor, return the
    // failure code.
    if (eligible.count == 1)
      return lastFileError;
    // Multiple descriptors — treat as Ready (other files may open fine).
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

  // Compute conservative active duration for earliest descriptor (clipped
  // without source-file clipping since we'll refine at schedule time).
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


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Internal scheduling helpers (queue-confined)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the current estimated timeline PTS from a snapshot.
- (NSTimeInterval)_currentPTSFromSnapshot:(VGTimelineStateSnapshot)snap {
  if (snap.isPlaying) {
    double elapsed = MAX(0.0, [_clock currentTime] - snap.playStartHostTime);
    return MAX(0.0, snap.playStartPTS + elapsed);
  } else {
    return MAX(0.0, snap.timelinePTS);
  }
}

/// Cancels the boundary timer, stops the player, clears scheduled work.
/// Increments commandSerial and updates _activeToken.
- (uint64_t)_cancelAndIncrementSerial:(uint64_t)generation {
  [self assertOnSchedulerQueue];
  [_boundaryTimer cancel];
  [_player stop];
  _commandSerial++;
  _activeToken =
      (VGAudioPreviewWorkToken){_lifecycleEpoch, _commandSerial, generation};
  return _commandSerial;
}

/// Schedules the audio segment for the currently active descriptor from
/// |currentPTS| to |scheduledEndPTS|.  Requires _activeDescriptor,
/// _fileSampleRate, _fileLengthFrames, _timelineStart, and _sourceTrimStart
/// to be set.  Returns YES if scheduling succeeded; NO if no frames to
/// schedule.
///
/// |scheduledEndPTS| must equal min(trackEnd, nextDecisionPTS) so that the
/// scheduled segment never extends beyond the next ownership-decision boundary.
///
/// Every successful call increments _scheduledSegmentSerial. The completion
/// handler captures the serial at call time; if it no longer matches
/// _scheduledSegmentSerial when the callback runs, the segment is stale
/// (a newer descriptor has been scheduled) and the callback does nothing.
/// When the serial does match the handler re-evaluates the timeline at
/// MAX(authoritativeSnapshotPTS, capturedScheduledEndPTS) so that a behind-
/// clock snapshot does not cause the completed descriptor to be rescheduled.
- (BOOL)_scheduleSegmentAtPTS:(NSTimeInterval)currentPTS
                       endPTS:(NSTimeInterval)scheduledEndPTS
                    withToken:(VGAudioPreviewWorkToken)token {
  [self assertOnSchedulerQueue];

  if (!_activeDescriptor)
    return NO;
  AVAudioFile *audioFile = _fileCache[_activeDescriptor.trackId];
  if (!audioFile)
    return NO;

  // Source frame mapping — use signed 64-bit arithmetic to detect overflow
  // before narrowing to AVAudioFrameCount (uint32_t).
  NSTimeInterval trackRelative = currentPTS - _timelineStart;
  NSTimeInterval sourcePosition = _sourceTrimStart + trackRelative;
  AVAudioFramePosition startFrame =
      (AVAudioFramePosition)floor(sourcePosition * _fileSampleRate);
  startFrame = MAX(0, MIN(startFrame, _fileLengthFrames));

  // Compute the end frame from the scheduledEndPTS boundary.
  // scheduledEndSource = sourceTrimStart + (scheduledEndPTS - timelineStart)
  NSTimeInterval scheduledEndSource =
      _sourceTrimStart + (scheduledEndPTS - _timelineStart);
  AVAudioFramePosition endExclusive = (AVAudioFramePosition)MIN(
      _fileLengthFrames, floor(scheduledEndSource * _fileSampleRate));

  // Signed 64-bit frame difference — safe before any narrowing cast.
  int64_t signedFrameCount = (int64_t)endExclusive - (int64_t)startFrame;

  // Reject non-positive or overflow values before casting to uint32_t.
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

  // Assign and capture a per-segment identity serial.
  _scheduledSegmentSerial++;
  uint64_t capturedSegSerial = _scheduledSegmentSerial;

  // Capture the exact scheduled end PTS for use inside the completion block.
  // The completion block uses MAX(authoritativeSnapshotPTS, capturedEndPTS)
  // so that a snapshot clock that is momentarily behind the segment end does
  // not cause the completed descriptor to be rescheduled from before its end.
  NSTimeInterval capturedScheduledEndPTS = scheduledEndPTS;

  VGAudioPreviewWorkToken capturedToken = token;
  VGTimelineSnapshotProvider capturedProvider = _snapshotProvider;
  __weak typeof(self) weakSelf = self;

  [_player scheduleSegment:audioFile
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
               // Stale command context — a play/seek/pause was issued.
               if (!VGAudioPreviewWorkTokenEqual(ss->_activeToken,
                                                 capturedToken))
                 return;
               // Stale segment — a newer descriptor has been scheduled under
               // the same command token (automatic boundary transition). The
               // new segment's boundary timer must not be cancelled.
               if (ss->_scheduledSegmentSerial != capturedSegSerial)
                 return;

               // This is a natural completion of the currently-active segment.
               // Rather than unconditionally setting Ended (which would tear
               // down any timer armed for the next descriptor), re-read the
               // authoritative snapshot and re-evaluate the timeline.
               VGTimelineStateSnapshot snap = capturedProvider();
               if (!snap.isValid) {
                 // Snapshot became invalid — stop cleanly.
                 [ss->_player stop];
                 ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
                 NSLog(@"[VanguardAudioPreviewRuntime][D] completion: invalid "
                       @"snapshot — paused");
                 return;
               }
               if (!snap.isPlaying) {
                 // Timeline was paused before completion arrived.
                 return;
               }
               if (snap.generation != capturedToken.timelineGeneration) {
                 return;
               }

               // Timeline is still playing. Use MAX(authoritativeSnapshotPTS,
               // capturedScheduledEndPTS) as the evaluation PTS so that a
               // behind-clock snapshot does not re-schedule an already-
               // completed segment from before the end boundary.
               NSTimeInterval authoritativeSnapshotPTS =
                   [ss _currentPTSFromSnapshot:snap];
               NSTimeInterval evaluationPTS =
                   MAX(authoritativeSnapshotPTS, capturedScheduledEndPTS);
               NSLog(@"[VanguardAudioPreviewRuntime][D] natural completion — "
                     @"re-evaluating at evalPTS=%.3f (snapPTS=%.3f, "
                     @"capturedEnd=%.3f)",
                     evaluationPTS, authoritativeSnapshotPTS,
                     capturedScheduledEndPTS);
               [ss _reevaluateAndTransitionAtPTS:evaluationPTS
                                       withToken:capturedToken];
             });
           }];

  NSLog(
      @"[VanguardAudioPreviewRuntime][D] scheduleSegment: start=%lld count=%u "
      @"endPTS=%.3f segSerial=%llu",
      (long long)startFrame, frameCount, scheduledEndPTS,
      (unsigned long long)capturedSegSerial);
  return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
// Slice F multi-descriptor helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Selects the winning descriptor for a given PTS according to:
///   1. A descriptor is active at PTS T when:
///        T >= d.timelineStart  &&  T < d.timelineStart + d._conservativeEnd
///      where conservativeEnd = MAX(0, MIN(d.requestedDuration or INF,
///                                         timelineDuration - d.timelineStart)).
///      Files not yet opened use requestedDuration as the conservative bound.
///   2. Among all active candidates: music beats original.
///   3. Same-role ties: latest timelineStart wins.
///   4. Remaining ties: earliest plan-array index wins (preserved by _descriptors).
///   5. Failed track IDs are excluded.
/// Returns nil if no descriptor is active at PTS.
- (nullable VGAudioPreviewTrackDescriptor *)_selectActiveDescriptorAtPTS:
    (NSTimeInterval)pts {
  [self assertOnSchedulerQueue];

  VGAudioPreviewTrackDescriptor *winner = nil;
  BOOL winnerIsMusic = NO;

  for (VGAudioPreviewTrackDescriptor *d in _descriptors) {
    // Skip permanently-failed descriptors.
    if ([_failedTrackIds containsObject:d.trackId])
      continue;

    NSTimeInterval ts = MAX(0.0, d.timelineStart);
    if (pts < ts)
      continue; // not yet started

    // Compute conservative end using resolved activeDuration if this is the
    // active descriptor, otherwise use requestedDuration or project remaining.
    NSTimeInterval conservativeActiveDuration;
    if (_activeDescriptor && [d.trackId isEqualToString:_activeDescriptor.trackId]) {
      conservativeActiveDuration = _activeDuration;
    } else {
      // Conservative: use requestedDuration if set, else project remaining.
      NSTimeInterval projRem = MAX(0.0, _timelineDuration - ts);
      if (d.requestedDuration >= 0.0) {
        conservativeActiveDuration = MIN(d.requestedDuration, projRem);
      } else {
        conservativeActiveDuration = projRem; // -1 means full file
      }
    }

    NSTimeInterval trackEnd = ts + conservativeActiveDuration;
    if (pts >= trackEnd)
      continue; // past this descriptor's range

    // Candidate is active at pts. Apply priority rules.
    BOOL dIsMusic = [d.role isEqualToString:@"music"];
    if (winner == nil) {
      winner = d;
      winnerIsMusic = dIsMusic;
    } else if (dIsMusic && !winnerIsMusic) {
      // Music beats original.
      winner = d;
      winnerIsMusic = YES;
    } else if (!dIsMusic && winnerIsMusic) {
      // Current winner is music, candidate is original — skip.
    } else {
      // Same role: latest timelineStart wins (plan order as tiebreak, since
      // we iterate in plan order and use strict >).
      if (d.timelineStart > winner.timelineStart) {
        winner = d;
        winnerIsMusic = dIsMusic;
      }
    }
  }

  return winner;
}

/// Returns the next decision boundary PTS after |currentPTS|.
/// A boundary is any descriptor's timelineStart or its conservative end.
/// Returns INFINITY if no future boundary exists.
- (NSTimeInterval)_computeNextDecisionPTS:(NSTimeInterval)currentPTS {
  [self assertOnSchedulerQueue];

  NSTimeInterval next = INFINITY;

  for (VGAudioPreviewTrackDescriptor *d in _descriptors) {
    if ([_failedTrackIds containsObject:d.trackId])
      continue;

    NSTimeInterval ts = MAX(0.0, d.timelineStart);
    if (ts > currentPTS)
      next = MIN(next, ts);

    // End boundary.
    NSTimeInterval conservativeActiveDuration;
    if (_activeDescriptor && [d.trackId isEqualToString:_activeDescriptor.trackId]) {
      conservativeActiveDuration = _activeDuration;
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

/// Opens the file for |descriptor| (from cache or lazily from provider),
/// validates it, computes the true clipped activeDuration, updates the active-
/// descriptor state, and sets the player volume.
/// Returns YES on success; NO if the file cannot be opened or yields zero
/// active duration.  Marks the descriptor failed on non-recoverable error.
- (BOOL)_activateDescriptor:(VGAudioPreviewTrackDescriptor *)descriptor
                      atPTS:(NSTimeInterval)pts {
  [self assertOnSchedulerQueue];

  // Already the active descriptor with valid state?
  if (_activeDescriptor &&
      [descriptor.trackId isEqualToString:_activeDescriptor.trackId]) {
    // Already activated — state is current.
    return _activeDuration > 0.0;
  }

  // Try cache.
  AVAudioFile *file = _fileCache[descriptor.trackId];
  if (!file) {
    // Check if permanently failed.
    if ([_failedTrackIds containsObject:descriptor.trackId])
      return NO;

    // Lazy open.
    BOOL fileExists = [_fileProvider fileExistsAtURL:descriptor.fileURL];
    NSError *err = nil;
    file = [_fileProvider openFileAtURL:descriptor.fileURL error:&err];
    if (!file) {
      NSLog(@"[VanguardAudioPreviewRuntime][F] activateDescriptor: failed to "
            @"open %@ — %@",
            descriptor.trackId, err.localizedDescription);
      [_failedTrackIds addObject:descriptor.trackId];
      (void)fileExists; // used for logging context
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

  _activeDescriptor = descriptor;
  _timelineStart = ts;
  _sourceTrimStart = trim;
  _activeDuration = activeDur;
  _fileSampleRate = sr;
  _fileLengthFrames = frames;

  [_player setVolume:descriptor.staticVolume];

  NSLog(@"[VanguardAudioPreviewRuntime][F] activateDescriptor: %@ "
        @"ts=%.3f active=%.3f sr=%.0f frames=%lld",
        descriptor.trackId, ts, activeDur, sr, (long long)frames);
  return YES;
}

/// Returns the end PTS of the currently active descriptor's range.
/// Returns 0 if no active descriptor.
- (NSTimeInterval)_activeDescriptorTrackEnd {
  if (!_activeDescriptor)
    return 0.0;
  return _timelineStart + _activeDuration;
}



// ─────────────────────────────────────────────────────────────────────────────
// Shared transition helper — used by both the boundary timer callback and the
// natural-completion callback so that both paths make identical decisions.
// ─────────────────────────────────────────────────────────────────────────────

/// Selects the winning descriptor at |currentPTS|, activates it, schedules the
/// segment, starts playback, and arms the next boundary timer. Sets _runtimeState
/// to Playing, WaitingForTrackStart, or Ended as appropriate.
///
/// Must be called on the scheduler queue with an already-validated snapshot
/// (snapshot is still playing, generation matches capturedToken).
- (void)_reevaluateAndTransitionAtPTS:(NSTimeInterval)currentPTS
                            withToken:(VGAudioPreviewWorkToken)capturedToken {
  [self assertOnSchedulerQueue];

  VGAudioPreviewTrackDescriptor *winner =
      [self _selectActiveDescriptorAtPTS:currentPTS];

  if (!winner) {
    // No descriptor active at this PTS — silent gap.
    NSTimeInterval nextBoundary = [self _computeNextDecisionPTS:currentPTS];
    if (isfinite(nextBoundary) && nextBoundary > currentPTS) {
      _runtimeState = VGAudioPreviewRuntimeStateWaitingForTrackStart;
      [self _armBoundaryTimerSafeDelay:(nextBoundary - currentPTS)
                                 token:capturedToken];
      NSLog(@"[VanguardAudioPreviewRuntime][F] transition: gap at PTS=%.3f, "
            @"next=%.3f",
            currentPTS, nextBoundary);
    } else {
      _runtimeState = VGAudioPreviewRuntimeStateEnded;
      NSLog(@"[VanguardAudioPreviewRuntime][F] transition: no more descriptors "
            @"— Ended");
    }
    return;
  }

  // Activate the winner (lazy file open + true activeDuration).
  BOOL activated = [self _activateDescriptor:winner atPTS:currentPTS];
  if (!activated) {
    // File failed — re-evaluate at next boundary.
    NSTimeInterval nextBoundary = [self _computeNextDecisionPTS:currentPTS];
    if (isfinite(nextBoundary) && nextBoundary > currentPTS) {
      _runtimeState = VGAudioPreviewRuntimeStateWaitingForTrackStart;
      [self _armBoundaryTimerSafeDelay:(nextBoundary - currentPTS)
                                 token:capturedToken];
    } else {
      _runtimeState = VGAudioPreviewRuntimeStateEnded;
    }
    return;
  }

  NSTimeInterval trackEnd = [self _activeDescriptorTrackEnd];

  if (currentPTS >= trackEnd) {
    // We are at or past this descriptor's end — move to the next boundary.
    NSTimeInterval nextBoundary = [self _computeNextDecisionPTS:currentPTS];
    if (isfinite(nextBoundary) && nextBoundary > currentPTS) {
      _runtimeState = VGAudioPreviewRuntimeStateWaitingForTrackStart;
      [self _armBoundaryTimerSafeDelay:(nextBoundary - currentPTS)
                                 token:capturedToken];
    } else {
      _runtimeState = VGAudioPreviewRuntimeStateEnded;
    }
    return;
  }

  // Inside the active range — schedule and play.
  // Compute nextBoundary first so the segment end can be clipped to it.
  NSTimeInterval nextBoundaryReeval = [self _computeNextDecisionPTS:currentPTS];
  NSTimeInterval scheduledEndPTS;
  if (isfinite(nextBoundaryReeval) && nextBoundaryReeval <= trackEnd) {
    scheduledEndPTS = nextBoundaryReeval;
  } else {
    scheduledEndPTS = trackEnd;
  }

  BOOL scheduled = [self _scheduleSegmentAtPTS:currentPTS
                                        endPTS:scheduledEndPTS
                                     withToken:capturedToken];
  if (scheduled) {
    [_player play];
    _runtimeState = VGAudioPreviewRuntimeStatePlaying;

    // Arm for the next descriptor boundary at or before this segment ends.
    // Using <= so that an exact-end transition (nextBoundary == trackEnd)
    // also schedules re-evaluation. Safe-delay helper handles sub-1ms cases.
    if (isfinite(nextBoundaryReeval) && nextBoundaryReeval <= trackEnd) {
      [self _armBoundaryTimerSafeDelay:(nextBoundaryReeval - currentPTS)
                                 token:capturedToken];
    }
    NSLog(@"[VanguardAudioPreviewRuntime][F] transition: playing %@ at PTS=%.3f "
          @"endPTS=%.3f",
          winner.trackId, currentPTS, scheduledEndPTS);
  } else {
    _runtimeState = VGAudioPreviewRuntimeStateEnded;
  }
}

/// Arms the boundary timer, handling three delay ranges:
///   delay > 0.001 s  — arm normally;
///   0 < delay ≤ 0.001 s — clamp to exactly 0.001 s (avoids silent drop);
///   delay ≤ 0       — re-evaluate at the current PTS immediately (inline,
///                      safe because we are already on the serial scheduler
///                      queue; the snapshot will be re-read inside).
///
/// This is the single call-site for sub-millisecond boundary handling. All
/// scheduling paths must use this helper instead of calling
/// _armBoundaryTimerWithDelay:token: with an unchecked delay.
- (void)_armBoundaryTimerSafeDelay:(NSTimeInterval)delay
                             token:(VGAudioPreviewWorkToken)token {
  [self assertOnSchedulerQueue];

  if (delay > 0.001) {
    // Normal case — arm the timer with the computed delay.
    [self _armBoundaryTimerWithDelay:delay token:token];
  } else if (delay > 0.0) {
    // Sub-1ms positive delay: clamp to 1 ms to avoid the silent-drop the
    // old `bDelay > 0.001` guard produced. The timer will fire 0.5–1 ms
    // late at most, well within acceptable audio scheduling tolerance.
    [self _armBoundaryTimerWithDelay:0.001 token:token];
    NSLog(@"[VanguardAudioPreviewRuntime][F] safe-delay: clamped %.6f s → "
          @"0.001 s", delay);
  } else {
    // Zero or negative delay — the boundary is already past or at the current
    // PTS. Re-evaluate immediately using the fresh snapshot. This avoids
    // arming a zero-delay timer that could cause a loop. Since we are already
    // on the serial scheduler queue the call is safe.
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

/// Arms the one-shot boundary timer. The timer will re-evaluate descriptor
/// selection when it fires.
///
/// Callers that have a potentially-small delay must use
/// _armBoundaryTimerSafeDelay:token: instead.
- (void)_armBoundaryTimerWithDelay:(NSTimeInterval)delay
                             token:(VGAudioPreviewWorkToken)token {
  [self assertOnSchedulerQueue];

  // Capture the current per-segment serial at the moment the timer is armed.
  // When the timer fires, a mismatch means the completion callback already
  // transitioned to the next segment, so the timer must be a no-op.
  uint64_t capturedSegmentSerial = _scheduledSegmentSerial;

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

               // Guard: if the completion callback already scheduled a newer
               // segment (incrementing _scheduledSegmentSerial) before this
               // timer fired, discard this stale timer to prevent duplicate
               // transitions.
               if (ss->_scheduledSegmentSerial != capturedSegmentSerial)
                 return;

               VGTimelineStateSnapshot snap = capturedProvider();
               if (!snap.isValid || !snap.isPlaying) {
                 if (!snap.isValid) {
                   [ss->_player stop];
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
/// Implements the Slice F multi-descriptor selection:
///   1. Determine the winning descriptor at currentPTS via _selectActiveDescriptorAtPTS:
///   2. If a winner is found, activate it (lazy file open + true active duration).
///   3. If PTS is before the winner's start, arm a boundary timer.
///   4. If PTS is inside the winner's range, schedule and play.
///   5. After scheduling, also arm a timer for the next inter-descriptor boundary
///      if one falls before the scheduled segment's natural end.
///   6. If no winner, look for the next boundary and arm a timer (silent gap).
- (void)_applyPlayOnQueue {
  [self assertOnSchedulerQueue];
  if (!_acceptingCommands)
    return;

  // Only proceed if we have valid prepared state.
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

  NSTimeInterval currentPTS = [self _currentPTSFromSnapshot:snap];

  // ── Slice F: multi-descriptor selection ─────────────────────────────────────
  VGAudioPreviewTrackDescriptor *winner =
      [self _selectActiveDescriptorAtPTS:currentPTS];

  if (!winner) {
    // No descriptor is active at currentPTS. Either we are in a gap before
    // any descriptor starts, or all descriptors have ended.
    NSTimeInterval nextBoundary = [self _computeNextDecisionPTS:currentPTS];
    if (isfinite(nextBoundary) && nextBoundary > currentPTS) {
      // Arm a timer for the next start boundary.
      _runtimeState = VGAudioPreviewRuntimeStateWaitingForTrackStart;
      NSTimeInterval delay = nextBoundary - currentPTS;
      [self _armBoundaryTimerWithDelay:delay token:token];
      NSLog(@"[VanguardAudioPreviewRuntime][F] play: gap — arming timer for "
            @"next boundary at PTS=%.3f (delay=%.3f)",
            nextBoundary, delay);
    } else {
      _runtimeState = VGAudioPreviewRuntimeStateEnded;
      NSLog(@"[VanguardAudioPreviewRuntime][F] play: PTS=%.3f past all "
            @"descriptors — Ended",
            currentPTS);
    }
    return;
  }

  // Activate the winning descriptor (lazy file open + true activeDuration).
  BOOL activated = [self _activateDescriptor:winner atPTS:currentPTS];
  if (!activated) {
    // File failed. Re-evaluate at next boundary.
    NSTimeInterval nextBoundary = [self _computeNextDecisionPTS:currentPTS];
    if (isfinite(nextBoundary) && nextBoundary > currentPTS) {
      _runtimeState = VGAudioPreviewRuntimeStateWaitingForTrackStart;
      [self _armBoundaryTimerWithDelay:(nextBoundary - currentPTS) token:token];
    } else {
      _runtimeState = VGAudioPreviewRuntimeStateEnded;
    }
    return;
  }

  NSTimeInterval trackEnd = [self _activeDescriptorTrackEnd];

  if (currentPTS < _timelineStart) {
    // PTS is before the winner's start — arm timer for the winner's start.
    _runtimeState = VGAudioPreviewRuntimeStateWaitingForTrackStart;
    NSTimeInterval delay = _timelineStart - currentPTS;
    [self _armBoundaryTimerWithDelay:delay token:token];
    NSLog(@"[VanguardAudioPreviewRuntime][F] play: arming boundary timer "
          @"delay=%.3f for %@",
          delay, winner.trackId);
  } else if (currentPTS < trackEnd) {
    // Inside the active range — schedule and play.
    // Compute nextBoundary first so the segment end can be clipped to it.
    NSTimeInterval nextBoundaryPlay = [self _computeNextDecisionPTS:currentPTS];
    NSTimeInterval scheduledEndPTSPlay;
    if (isfinite(nextBoundaryPlay) && nextBoundaryPlay <= trackEnd) {
      scheduledEndPTSPlay = nextBoundaryPlay;
    } else {
      scheduledEndPTSPlay = trackEnd;
    }

    BOOL scheduled = [self _scheduleSegmentAtPTS:currentPTS
                                          endPTS:scheduledEndPTSPlay
                                       withToken:token];
    if (scheduled) {
      [_player play];
      _runtimeState = VGAudioPreviewRuntimeStatePlaying;

      // Check if there is a descriptor boundary at or before this segment
      // ends. Using <= so that an exact-end transition (nextBoundary ==
      // trackEnd) also schedules re-evaluation. Safe-delay helper handles
      // sub-1ms cases that the old bDelay > 0.001 guard would have dropped.
      if (isfinite(nextBoundaryPlay) && nextBoundaryPlay <= trackEnd) {
        [self _armBoundaryTimerSafeDelay:(nextBoundaryPlay - currentPTS)
                                   token:token];
      }

      NSLog(@"[VanguardAudioPreviewRuntime][F] play: scheduling %@ at PTS=%.3f "
            @"endPTS=%.3f",
            winner.trackId, currentPTS, scheduledEndPTSPlay);
    } else {
      _runtimeState = VGAudioPreviewRuntimeStateEnded;
    }
  } else {
    // Past the end of all descriptors — remain silent.
    _runtimeState = VGAudioPreviewRuntimeStateEnded;
    NSLog(@"[VanguardAudioPreviewRuntime][F] play: PTS=%.3f past track end — "
          @"silent",
          currentPTS);
  }
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

    if (!snap.isValid) {
      ss->_runtimeState = VGAudioPreviewRuntimeStatePaused;
      return;
    }

    if (snap.isPlaying) {
      // Resume from new position.
      ss->_runtimeState =
          VGAudioPreviewRuntimeStatePaused; // _applyPlayOnQueue will update
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
    NSLog(@"[VanguardAudioPreviewRuntime][D] EOS — audio stopped");
  });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Invalidation
// ─────────────────────────────────────────────────────────────────────────────

- (void)invalidateAsync:(dispatch_block_t)completion {
  NSParameterAssert(completion != nil);

  // Phase A: close command acceptance atomically. This immediately gates all
  // hot-path command checks before we acquire the lock.
  atomic_store(&_acceptingCommands, NO);

  // ── Immediate audio quiesce (Phase 10-C Slice D teardown fix) ─────────────
  //
  // Stop the player node synchronously on the calling thread (main in
  // production). AVAudioPlayerNode.stop is documented as thread-safe and
  // may be called from any thread. This silences audible output immediately.
  //
  // The cleanupBlock on _schedulerQueue will call [_player stop] again as
  // part of full teardown — that second call is a no-op on an already-stopped
  // node. The engine is NOT stopped here because engine.stop() is heavier
  // (detaches nodes, releases audio session) and is not required for silence.
  [_player stop];

  // Phase B: inspect and transition the three-state lifecycle under the lock.
  // We must determine whether we are the first caller (Accepting →
  // Invalidating), a joining caller (Invalidating, append waiter), or late
  // (Invalidated, fire immediately).
  BOOL shouldInitiateCleanup = NO;

  os_unfair_lock_lock(&_invalidationLock);
  switch (_invalidationPhase) {
  case VGAudioPreviewInvalidationStateAccepting:
    // First caller — we own cleanup.
    _invalidationPhase = VGAudioPreviewInvalidationStateInvalidating;
    [_invalidationWaiters addObject:[completion copy]];
    shouldInitiateCleanup = YES;
    break;

  case VGAudioPreviewInvalidationStateInvalidating:
    // Cleanup already in progress — join the waiter list.
    [_invalidationWaiters addObject:[completion copy]];
    os_unfair_lock_unlock(&_invalidationLock);
    return; // early return — cleanup owner will drain waiters

  case VGAudioPreviewInvalidationStateInvalidated:
    // Already fully invalidated — fire immediately on main.
    os_unfair_lock_unlock(&_invalidationLock);
    dispatch_async(dispatch_get_main_queue(), ^{
      completion();
    });
    return;
  }
  os_unfair_lock_unlock(&_invalidationLock);

  if (!shouldInitiateCleanup)
    return;

  // Phase C: dispatch cleanup to the scheduler queue.
  // Strongly retain self so the runtime survives until all cleanup is done
  // and all waiters have been fired. This ensures timer cancel, player stop,
  // engine stop, and descriptor/file clear all complete before deallocation.
  VanguardAudioPreviewRuntime *strongSelf = self;

  void (^cleanupBlock)(void) = ^{
    // Runs on the scheduler queue. strongSelf keeps self alive.
    [strongSelf assertOnSchedulerQueue];
    [strongSelf->_boundaryTimer cancel];
    [strongSelf->_player stop];
    [strongSelf->_engine stop];
    strongSelf->_descriptors = @[];
    [strongSelf->_fileCache removeAllObjects];
    [strongSelf->_failedTrackIds removeAllObjects];
    strongSelf->_activeDescriptor = nil;
    strongSelf->_runtimeState = VGAudioPreviewRuntimeStateInvalidated;
    NSLog(@"[VanguardAudioPreviewRuntime][D] invalidation cleanup complete");

    // Phase D: transition to Invalidated and drain waiters on main.
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

  // If already on the scheduler queue, run cleanup inline to avoid deadlock.
  if (dispatch_get_specific(_schedulerQueueKey) == (__bridge void *)self) {
    cleanupBlock();
  } else {
    dispatch_async(_schedulerQueue, cleanupBlock);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Package-private testing seam
// ─────────────────────────────────────────────────────────────────────────────

/// Executes |block| synchronously on the private scheduler queue.
/// If the caller is already on the scheduler queue the block runs inline
/// (avoids deadlock). This method is package-internal and must only be called
/// from unit tests; it must never appear in public_header_files.
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
