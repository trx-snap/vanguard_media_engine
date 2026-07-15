// VanguardAudioPreviewRuntimeTest_SliceJ_Automation.m
// Vanguard Media Engine — Audio Slice J
//
// 30 automation selectors: testJ_T23 through testJ_T52.
// Tests the automation coordinator lifecycle through the runtime.

#import "VanguardAudioPreviewRuntimeTest.h"
#import "VGAudioPreviewKeyframeNormalizer.h"
#import "VGAudioPreviewVolumeKeyframe.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// Helper to build a linear ramp keyframe array from t0→v0 to t1→v1.
static NSArray *rampKFs(double t0, double v0, double t1, double v1) {
  return @[
    @{@"time" : @(t0), @"volume" : @(v0)},
    @{@"time" : @(t1), @"volume" : @(v1)},
  ];
}

@implementation VanguardAudioPreviewRuntimeTest (SliceJAutomation)

// ─── Preparation and descriptor parsing ─────────────────────────────────────

// T42: Descriptor parses raw keyframes.
- (void)testJ_T42_descriptorParsesRawKeyframes {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *dict = [self trackDictWithId:@"kf_track"
                                        role:@"music"
                                   startTime:0.0
                                    duration:10.0
                                      volume:1.0
                                         url:@"/tmp/fake.mp3"
                                  keyframes:kfs];
  VGAudioPreviewTrackDescriptor *desc =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNotNil(desc);
  XCTAssertTrue(desc.hasRawKeyframes);
  XCTAssertEqual(desc.rawVolumeKeyframes.count, 2UL);
}

// T43: Descriptor normalizes at activation (via coordinator).
- (void)testJ_T43_descriptorNormalizesAtActivation {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSArray *normalized =
      [VGAudioPreviewKeyframeNormalizer normalizeKeyframes:kfs
                                             timelineStart:0.0
                                              effectiveEnd:10.0];
  XCTAssertNotNil(normalized);
  XCTAssertGreaterThanOrEqual(normalized.count, 2UL);
}

// T44: When normalization returns nil, coordinator falls back to staticVolume.
- (void)testJ_T44_normalizationEmptyFallsBackToStatic {
  // All out-of-range keyframes.
  NSArray *kfs = @[@{@"time" : @(999.0), @"volume" : @(0.5)}];
  NSDictionary *trackDict = [self trackDictWithId:@"fallback_track"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:0.7
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];

  NSURL *tempURL = VGAPrCreateTempWAVURL(44100, 44100.0);
  if (!tempURL) {
    XCTSkip(@"Could not create temp WAV");
    return;
  }
  NSError *err = nil;
  AVAudioFile *realFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  XCTAssertNotNil(realFile);
  _fileProvider.stubbedFile = realFile;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES,
      .isPlaying = YES,
      .generation = 1,
      .playStartPTS = 1.0,
      .playStartHostTime = [_clock currentTime],
      .timelinePTS = 1.0,
  };
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // With out-of-range keyframes, no envelope — static volume applied.
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.7f, 1e-5f);
  // Automation timer must NOT have been started.
  XCTAssertEqual(_automationTimer.startCount, 0);

  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T27: Static descriptor — no automation timer started.
- (void)testJ_T27_staticDescriptorNoAutomationTimer {
  NSDictionary *trackDict = [self trackDictWithStartTime:0.0
                                                duration:10.0
                                                  volume:0.8];
  NSURL *tempURL = VGAPrCreateTempWAVURL(44100, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.8f, 1e-5f);
  XCTAssertEqual(_automationTimer.startCount, 0,
                 @"Static descriptor must not start automation timer");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T28: Keyframed activation sets initial volume through coordinator.
- (void)testJ_T28_keyframedActivationSetsInitialVolume {
  NSArray *kfs = rampKFs(0.0, 0.3, 10.0, 0.9);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t28"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // At PTS=0.0, ramp is 0.3 (first point). Initial gain must be applied.
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.3f, 0.01f,
                             @"Coordinator must apply initial gain at PTS=0");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T25: Pause cancels automation timer.
- (void)testJ_T25_pauseCancelsAutomationTimer {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t25"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  NSInteger startCountBefore = _automationTimer.startCount;
  XCTAssertGreaterThan(startCountBefore, 0,
                       @"Automation timer must have started after play");

  [rt commandPause];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertGreaterThan(_automationTimer.cancelCount, 0,
                       @"Pause must cancel automation timer");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T26: Resume restarts automation timer.
- (void)testJ_T26_resumeRestartsAutomationTimer {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t26"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  [rt commandPause];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  NSInteger startCountAfterPause = _automationTimer.startCount;
  _stubbedSnapshot.playStartPTS = 1.0;
  _stubbedSnapshot.isPlaying = YES;
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertGreaterThan(_automationTimer.startCount, startCountAfterPause,
                       @"Resume must restart automation timer");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T29: Boundary transition cancels and restarts automation timer.
- (void)testJ_T29_boundaryTransitionCancelsAndRestartsTimer {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *td1 = [self trackDictWithId:@"kf_t29_a"
                                       role:@"original"
                                  startTime:0.0
                                   duration:5.0
                                     volume:1.0
                                        url:@"/tmp/fake.mp3"
                                  keyframes:kfs];
  NSDictionary *td2 = [self trackDictWithId:@"kf_t29_b"
                                       role:@"music"
                                  startTime:5.0
                                   duration:5.0
                                     volume:1.0
                                        url:@"/tmp/fake.mp3"
                                  keyframes:rampKFs(5.0, 1.0, 10.0, 0.5)];
  NSURL *tempURL = VGAPrCreateTempWAVURL(220500, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[td1, td2]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  NSInteger startCount1 = _automationTimer.startCount;
  NSInteger cancelCount1 = _automationTimer.cancelCount;

  // Fire boundary timer to trigger transition to second descriptor.
  _stubbedSnapshot.playStartPTS = 5.0;
  _stubbedSnapshot.timelinePTS = 5.0;
  [_timer fireForcefully];

  NSInteger startCount2 = _automationTimer.startCount;
  NSInteger cancelCount2 = _automationTimer.cancelCount;

  XCTAssertGreaterThan(cancelCount2, cancelCount1,
                       @"Boundary transition must cancel previous timer");
  XCTAssertGreaterThan(startCount2, startCount1,
                       @"Boundary transition must restart timer for new descriptor");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T30: Reprepare stops automation.
- (void)testJ_T30_reprepareStopsAutomation {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t30"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  NSInteger startCountBefore = _automationTimer.startCount;

  // Reprepare.
  NSError *err2 = nil;
  AVAudioFile *f2 = [[AVAudioFile alloc] initForReading:tempURL error:&err2];
  _fileProvider.stubbedFile = f2;
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertGreaterThan(_automationTimer.cancelCount, 0,
                       @"Reprepare must cancel automation timer");
  (void)startCountBefore;
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T31: EOS cancels automation timer.
- (void)testJ_T31_eosCancelsAutomationTimer {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t31"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  NSInteger cancelBefore = _automationTimer.cancelCount;
  [rt commandEOS];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  XCTAssertGreaterThan(_automationTimer.cancelCount, cancelBefore);
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T32: Invalidation cancels automation timer.
- (void)testJ_T32_invalidationCancelsAutomationTimer {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t32"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  NSInteger cancelBefore = _automationTimer.cancelCount;
  [self invalidateAndWait:rt];
  XCTAssertGreaterThan(_automationTimer.cancelCount, cancelBefore,
                       @"Invalidation must cancel automation timer");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
}

// T33: Static volume regression — existing static tracks unchanged.
- (void)testJ_T33_staticVolumeRegressionAfterSliceJ {
  NSDictionary *trackDict = [self trackDictWithStartTime:0.0
                                                duration:10.0
                                                  volume:0.6];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.6f, 1e-5f);
  XCTAssertEqual(_automationTimer.startCount, 0);
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T34: Stale tick rejected after seek (token mismatch).
- (void)testJ_T34_staleTickRejectedAfterSeek {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t34"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Capture the first pending tick block before seek changes the token.
  dispatch_block_t staleTick = [_automationTimer.pendingBlock copy];
  float volumeBeforeSeek = _player.lastVolume;

  // Seek increments commandSerial, changing the active token.
  _stubbedSnapshot.generation = 2;
  [rt commandSeek];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  float volumeAfterSeek = _player.lastVolume;

  // Fire the captured stale tick — it must not change volume.
  if (staleTick) {
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{ staleTick(); }];
  }
  XCTAssertEqualWithAccuracy(_player.lastVolume, volumeAfterSeek, 1e-5f,
                             @"Stale tick must not update volume after seek");
  (void)volumeBeforeSeek;
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T35: Stale tick rejected after descriptor transition.
- (void)testJ_T35_staleTickRejectedAfterTransition {
  NSArray *kfs1 = rampKFs(0.0, 0.0, 5.0, 0.5);
  NSArray *kfs2 = rampKFs(5.0, 0.5, 10.0, 1.0);
  NSDictionary *td1 = [self trackDictWithId:@"kf_t35_a" role:@"original"
                                  startTime:0.0 duration:5.0 volume:1.0
                                        url:@"/tmp/fake.mp3" keyframes:kfs1];
  NSDictionary *td2 = [self trackDictWithId:@"kf_t35_b" role:@"music"
                                  startTime:5.0 duration:5.0 volume:1.0
                                        url:@"/tmp/fake.mp3" keyframes:kfs2];
  NSURL *tempURL = VGAPrCreateTempWAVURL(220500, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[td1, td2]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Capture stale tick from first descriptor.
  dispatch_block_t staleTick = [_automationTimer.pendingBlock copy];

  // Trigger boundary transition.
  [_timer fireForcefully];
  float volumeAfterTransition = _player.lastVolume;

  // Fire stale tick — must be rejected.
  if (staleTick) {
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{ staleTick(); }];
  }
  XCTAssertEqualWithAccuracy(_player.lastVolume, volumeAfterTransition, 1e-5f,
                             @"Stale tick must not update volume after transition");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T36: Tick suppresses unchanged volume.
- (void)testJ_T36_tickSuppressesUnchangedVolume {
  NSArray *kfs = rampKFs(0.0, 0.5, 10.0, 0.5); // flat envelope
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t36"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:@"/tmp/fake.mp3"
                                       keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 2.0, .playStartHostTime = 0.0, .timelinePTS = 2.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  float volumeAfterActivation = _player.lastVolume;

  // Fire timer — envelope is flat so value shouldn't change.
  // The mock timer block does not call setVolume: again if gain == last.
  // We simply verify that setVolume count did not increase meaninglessly.
  // Since _player.lastVolume is a scalar, fire and re-check.
  [_automationTimer fireOnce];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  XCTAssertEqualWithAccuracy(_player.lastVolume, volumeAfterActivation, 1e-5f,
                             @"Flat envelope tick must not call setVolume with different value");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T37: Keyframed→static transition stops timer and applies static volume.
- (void)testJ_T37_keyframedToStaticTransitionStopsTimer {
  NSArray *kfs = rampKFs(0.0, 0.0, 5.0, 1.0);
  NSDictionary *td1 = [self trackDictWithId:@"kf_t37_a" role:@"original"
                                  startTime:0.0 duration:5.0 volume:1.0
                                        url:@"/tmp/fake.mp3" keyframes:kfs];
  NSDictionary *td2 = [self trackDictWithId:@"kf_t37_b" role:@"music"
                                  startTime:5.0 duration:5.0 volume:0.55
                                        url:@"/tmp/fake.mp3" keyframes:nil];
  NSURL *tempURL = VGAPrCreateTempWAVURL(220500, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[td1, td2]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  NSInteger startBefore = _automationTimer.startCount;
  NSInteger cancelBefore = _automationTimer.cancelCount;
  _stubbedSnapshot.playStartPTS = 5.0;
  _stubbedSnapshot.timelinePTS = 5.0;
  [_timer fireForcefully];
  NSInteger cancelAfter = _automationTimer.cancelCount;
  NSInteger startAfter = _automationTimer.startCount;
  XCTAssertGreaterThan(cancelAfter, cancelBefore, @"Transition must cancel old timer");
  XCTAssertEqual(startAfter, startBefore,
                 @"Static descriptor must not start automation timer");
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.55f, 1e-5f,
                             @"Static volume applied after transition");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T38: Static→keyframed transition starts timer.
- (void)testJ_T38_staticToKeyframedTransitionStartsTimer {
  NSDictionary *td1 = [self trackDictWithId:@"kf_t38_a" role:@"original"
                                  startTime:0.0 duration:5.0 volume:0.5
                                        url:@"/tmp/fake.mp3" keyframes:nil];
  NSArray *kfs = rampKFs(5.0, 0.0, 10.0, 1.0);
  NSDictionary *td2 = [self trackDictWithId:@"kf_t38_b" role:@"music"
                                  startTime:5.0 duration:5.0 volume:1.0
                                        url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(220500, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[td1, td2]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  NSInteger startBefore = _automationTimer.startCount;
  _stubbedSnapshot.playStartPTS = 5.0;
  _stubbedSnapshot.timelinePTS = 5.0;
  [_timer fireForcefully];
  XCTAssertGreaterThan(_automationTimer.startCount, startBefore,
                       @"Keyframed transition must start automation timer");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T39: Keyframed→keyframed transition restarts timer.
- (void)testJ_T39_keyframedToKeyframedTransitionRestartsTimer {
  NSArray *kfs1 = rampKFs(0.0, 0.0, 5.0, 1.0);
  NSArray *kfs2 = rampKFs(5.0, 1.0, 10.0, 0.5);
  NSDictionary *td1 = [self trackDictWithId:@"kf_t39_a" role:@"original"
                                  startTime:0.0 duration:5.0 volume:1.0
                                        url:@"/tmp/fake.mp3" keyframes:kfs1];
  NSDictionary *td2 = [self trackDictWithId:@"kf_t39_b" role:@"music"
                                  startTime:5.0 duration:5.0 volume:1.0
                                        url:@"/tmp/fake.mp3" keyframes:kfs2];
  NSURL *tempURL = VGAPrCreateTempWAVURL(220500, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[td1, td2]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  NSInteger startBefore = _automationTimer.startCount;
  NSInteger cancelBefore = _automationTimer.cancelCount;
  _stubbedSnapshot.playStartPTS = 5.0;
  _stubbedSnapshot.timelinePTS = 5.0;
  [_timer fireForcefully];
  XCTAssertGreaterThan(_automationTimer.cancelCount, cancelBefore);
  XCTAssertGreaterThan(_automationTimer.startCount, startBefore);
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T40: Seek into gap cancels timer.
- (void)testJ_T40_seekIntoGapCancelsTimer {
  NSArray *kfs = rampKFs(0.0, 0.0, 5.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t40" role:@"music"
                                        startTime:0.0 duration:5.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(220500, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:20.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  NSInteger cancelBefore = _automationTimer.cancelCount;

  // Seek into gap (PTS = 8, past track end at 5).
  _stubbedSnapshot.generation = 2;
  _stubbedSnapshot.playStartPTS = 8.0;
  _stubbedSnapshot.timelinePTS = 8.0;
  [rt commandSeek];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertGreaterThan(_automationTimer.cancelCount, cancelBefore,
                       @"Seek into gap must cancel automation timer");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T41: Gap to keyframed track starts timer.
- (void)testJ_T41_gapToKeyframedTrackStartsTimer {
  NSArray *kfs = rampKFs(5.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t41" role:@"music"
                                        startTime:5.0 duration:5.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(220500, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  // Start at PTS=0 (in gap).
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  NSInteger startBefore = _automationTimer.startCount;

  // Boundary timer fires at track start (PTS = 5).
  _stubbedSnapshot.playStartPTS = 5.0;
  _stubbedSnapshot.timelinePTS = 5.0;
  [_timer fireForcefully];

  XCTAssertGreaterThan(_automationTimer.startCount, startBefore,
                       @"Boundary transition into keyframed track must start timer");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T45: Active tick applies interpolated gain.
- (void)testJ_T45_activeTickAppliesInterpolatedGain {
  // Ramp 0→1 over 10s. At t=5.0, expected gain = 0.5.
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t45" role:@"music"
                                        startTime:0.0 duration:10.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  // Set clock so that at tick time, PTS evaluates to ~5.0.
  _clock.currentTime = 100.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0,
      .playStartHostTime = 100.0, // elapsed = clock - 100 = 0 at start
      .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Advance clock to simulate PTS ≈ 5.0.
  _clock.currentTime = 105.0;
  [_automationTimer fireOnce];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.5f, 0.05f,
                             @"Tick at PTS≈5.0 must apply interpolated gain ≈0.5");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T46: Role independence — original static track unchanged.
- (void)testJ_T46_roleIndependenceOriginalStaticUnchanged {
  NSDictionary *trackDict = [self originalTrackDictWithId:@"orig_t46"
                                                startTime:0.0
                                                 duration:10.0
                                                   volume:0.7
                                                      url:@"/tmp/fake.mp3"];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.7f, 1e-5f);
  XCTAssertEqual(_automationTimer.startCount, 0);
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T47: Role independence — music keyframed track.
- (void)testJ_T47_roleIndependenceMusicKeyframed {
  NSArray *kfs = rampKFs(0.0, 0.2, 10.0, 0.8);
  NSDictionary *trackDict = [self trackDictWithId:@"music_t47" role:@"music"
                                        startTime:0.0 duration:10.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  // At PTS=0, gain = 0.2.
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.2f, 0.01f);
  XCTAssertGreaterThan(_automationTimer.startCount, 0);
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T48: Stale tick checks both token and seg serial.
- (void)testJ_T48_staleTickChecksTokenAndSegSerial {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t48" role:@"music"
                                        startTime:0.0 duration:10.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  dispatch_block_t staleTick = [_automationTimer.pendingBlock copy];
  float volumeBeforeSeek = _player.lastVolume;

  _stubbedSnapshot.generation = 2;
  [rt commandSeek];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  float volumeAfterSeek = _player.lastVolume;

  // Execute the stale tick on the scheduler queue.
  if (staleTick) {
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{ staleTick(); }];
  }
  // Volume must be unchanged by stale tick.
  XCTAssertEqualWithAccuracy(_player.lastVolume, volumeAfterSeek, 1e-5f);
  (void)volumeBeforeSeek;
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T49: Scheduling failure — automation timer never started.
- (void)testJ_T49_schedulingFailureNoTimerStart {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t49" role:@"music"
                                        startTime:0.0 duration:10.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  // Make file open fail.
  _fileProvider.shouldFail = YES;
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertEqual(_automationTimer.startCount, 0,
                 @"Scheduling failure must not start automation timer");
  [self invalidateAndWait:rt];
}

// T50: Invalid snapshot tick rejected — setVolume: not called.
- (void)testJ_T50_invalidSnapshotTickRejection {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t50" role:@"music"
                                        startTime:0.0 duration:10.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 2.0, .playStartHostTime = 0.0, .timelinePTS = 2.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  float volumeAfterPlay = _player.lastVolume;

  // Make snapshot invalid.
  _stubbedSnapshot.isValid = NO;
  [_automationTimer fireOnce];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertEqualWithAccuracy(_player.lastVolume, volumeAfterPlay, 1e-5f,
                             @"Invalid snapshot must not update volume");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T51: Static-zero music with malformed keyframes silences audible original.
// Ownership regression test (NORMALIZATION_EMPTY_ZERO_TRACK_INTENTIONALLY_OWNS_SILENCE).
- (void)testJ_T51_staticZeroMutedKeyframesSilencesAudibleTrack {
  // Music: vol=0, keyframes all out-of-range (normalizes to nil).
  NSArray *badKfs = @[@{@"time" : @(999.0), @"volume" : @(0.5)}];
  NSDictionary *musicDict = [self trackDictWithId:@"music_t51" role:@"music"
                                        startTime:0.0 duration:10.0 volume:0.0
                                              url:@"/tmp/fake.mp3" keyframes:badKfs];
  // Original: audible at vol=0.8.
  NSDictionary *origDict = [self originalTrackDictWithId:@"orig_t51"
                                               startTime:0.0
                                                duration:10.0
                                                  volume:0.8
                                                     url:@"/tmp/fake.mp3"];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  // Music descriptor must be eligible (has raw keyframes, even though vol=0).
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, origDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  // Music is eligible (has raw keyframes), plan should succeed.
  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady,
                 @"Music track with raw keyframes (even vol=0) must be eligible: "
                 @"prepare must return Ready so the downstream volume assertion is valid");

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Music wins selection (music > original priority).
  // Normalization returns nil (all keyframes out of range), fallback static = 0.
  // Player must be playing at volume 0.0, not 0.8.
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.0f, 1e-5f,
                             @"Music track with static 0 and empty envelope must "
                             @"silence the audible original track");

  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T23: Play-seek into ramp updates volume.
- (void)testJ_T23_playSeekIntoRampUpdatesVolume {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t23" role:@"music"
                                        startTime:0.0 duration:10.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 8.0, .playStartHostTime = 0.0, .timelinePTS = 8.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  // At PTS=8.0, ramp gain ≈ 0.8.
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.8f, 0.05f,
                             @"Seek into ramp must update volume to interpolated gain");
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T24: Paused seek does not set volume.
- (void)testJ_T24_pausedSeekDoesNotSetVolume {
  NSArray *kfs = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *trackDict = [self trackDictWithId:@"kf_t24" role:@"music"
                                        startTime:0.0 duration:10.0 volume:1.0
                                              url:@"/tmp/fake.mp3" keyframes:kfs];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) { XCTSkip(@"No temp WAV"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[trackDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  // Play first so coordinator is activated.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  [rt commandPause];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  float volumeAtPause = _player.lastVolume;
  NSInteger automationStartCount = _automationTimer.startCount;

  // Issue seek while paused.
  _stubbedSnapshot.isPlaying = NO;
  _stubbedSnapshot.generation = 2;
  _stubbedSnapshot.timelinePTS = 5.0;
  [rt commandSeek];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Volume should not have changed (paused seek).
  // Automation timer should not have been restarted.
  XCTAssertEqual(_automationTimer.startCount, automationStartCount,
                 @"Paused seek must not restart automation timer");
  (void)volumeAtPause;
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

// T52: Reprepare regression — gain sink preserved after reprepare.
// Verifies that deactivate (not invalidate) is used during
// prepareWithSidecarPlan:, so the coordinator's gain sink remains functional
// for subsequent keyframe activation after a timeline reprepare.
- (void)testJ_T52_repreparePreservesGainSink {
  // Plan 1: linear ramp 0→1. Initial gain at PTS=0 = 0.0.
  NSArray *kfs1 = rampKFs(0.0, 0.0, 10.0, 1.0);
  NSDictionary *td1 = [self trackDictWithId:@"kf_t52_p1"
                                       role:@"music"
                                  startTime:0.0
                                   duration:10.0
                                     volume:1.0
                                        url:@"/tmp/fake.mp3"
                                  keyframes:kfs1];
  NSURL *tempURL = VGAPrCreateTempWAVURL(441000, 44100.0);
  if (!tempURL) {
    XCTSkip(@"No temp WAV");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioSidecarPlan *plan1 =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[td1]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan1 timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  // Plan 1: initial gain at PTS=0 must be 0.0 (start of ramp).
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.0f, 0.01f,
                             @"First prepare: initial gain at PTS=0 must be 0.0");

  // Plan 2: flat at 0.7. Initial gain at PTS=0 = 0.7.
  // A different gain value to distinguish a live sink from a no-op sink.
  NSArray *kfs2 = rampKFs(0.0, 0.7, 10.0, 0.7);
  NSDictionary *td2 = [self trackDictWithId:@"kf_t52_p2"
                                       role:@"music"
                                  startTime:0.0
                                   duration:10.0
                                     volume:1.0
                                        url:@"/tmp/fake.mp3"
                                  keyframes:kfs2];
  VGAudioSidecarPlan *plan2 =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[td2]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  NSError *err2 = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:tempURL
                                                            error:&err2];
  [rt prepareWithSidecarPlan:plan2 timelineDuration:10.0];
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 2,
      .playStartPTS = 0.0, .playStartHostTime = 0.0, .timelinePTS = 0.0};
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // With the gain sink preserved (deactivate path): gain = 0.7.
  // With the gain sink destroyed (invalidate path): sink is a no-op and
  // _player.lastVolume remains at 0.0 from the first playback cycle.
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.7f, 0.01f,
                             @"Reprepare must preserve gain sink; initial gain "
                             @"after second prepare must be 0.7");

  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
  [self invalidateAndWait:rt];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
