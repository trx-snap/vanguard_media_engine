// VanguardAudioPreviewRuntimeTest_Teardown.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (Lifecycle) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (Lifecycle)


// ─────────────────────────────────────────────────────────────────────────────
// S-9: testPauseCancelsBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPauseCancelsBoundaryTimer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 1.0,
                                               .playStartPTS = 1.0,
                                               .playStartHostTime = 0.0,
                                               .generation = 1,
                                               .isPlaying = YES,
                                               .isValid = YES};
  _clock.currentTime = 0.0;

  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open WAV");
    return;
  }

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *trackDict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(2.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.2];

  [rt commandPause];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"timer must be cancelled on pause");
  XCTAssertGreaterThan(_player.stopCount, 0,
                       @"player must be stopped on pause");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-10: testSeekCancelsBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSeekCancelsBoundaryTimer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 3.0,
                                               .playStartPTS = 3.0,
                                               .playStartHostTime = 0.0,
                                               .generation = 2,
                                               .isPlaying = NO,
                                               .isValid = YES};

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandSeek];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"timer must be cancelled on seek");
  XCTAssertGreaterThan(_player.stopCount, 0, @"player must be stopped on seek");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-11: testEOSCancelsBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testEOSCancelsBoundaryTimer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 5.0, .generation = 1, .isPlaying = YES, .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandEOS];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.cancelCount, 0, @"EOS must cancel timer");
  XCTAssertGreaterThan(_player.stopCount, 0, @"EOS must stop player");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-12: testInvalidationCancelsBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testInvalidationCancelsBoundaryTimer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .isPlaying = YES, .isValid = YES, .generation = 1};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *invExp = [self expectationWithDescription:@"inv"];
  [rt invalidateAsync:^{
    [invExp fulfill];
  }];
  [self waitForExpectations:@[ invExp ] timeout:5.0];

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"invalidation must cancel timer");
  XCTAssertGreaterThan(_player.stopCount, 0, @"invalidation must stop player");
  XCTAssertGreaterThan(_engine.stopCount, 0, @"invalidation must stop engine");
}


// ─────────────────────────────────────────────────────────────────────────────
// S-30: testFileCompletionDoesNotLoop
// ─────────────────────────────────────────────────────────────────────────────

- (void)testFileCompletionDoesNotLoop {
  double sr = 44100.0, fileDur = 1.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 0.0,
                                               .playStartPTS = 0.0,
                                               .playStartHostTime = 0.0,
                                               .generation = 1,
                                               .isPlaying = YES,
                                               .isValid = YES};
  _clock.currentTime = 0.0;

  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open WAV");
    return;
  }

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *trackDict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(fileDur),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:fileDur];
  [rt commandPlay];
  [self waitFor:0.3];

  NSInteger schedBefore = _player.scheduleCount;
  // Manually trigger the completion handler to simulate file end.
  if (_player.lastCompletionHandler) {
    _player.lastCompletionHandler(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, schedBefore,
                 @"file completion must not trigger re-schedule (no loop)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-31: testTimelineEOSStopsAudio
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTimelineEOSStopsAudio {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 5.0, .generation = 1, .isPlaying = YES, .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandEOS];
  [self waitFor:0.3];
  XCTAssertGreaterThan(_player.stopCount, 0, @"EOS must stop audio");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-32: testRuntimeReplacementWaitsForOldRuntimeInvalidation
// ─────────────────────────────────────────────────────────────────────────────

- (void)testRuntimeReplacementWaitsForOldRuntimeInvalidation {
  // Verify that invalidateAsync: calls back only after cleanup.
  VanguardAudioPreviewRuntime *rt1 = [self makeRuntimeWithEpoch:1];
  [rt1 prepareWithSidecarPlan:nil timelineDuration:10.0];

  __block BOOL rt1Done = NO;
  XCTestExpectation *inv1 = [self expectationWithDescription:@"inv1Done"];
  [rt1 invalidateAsync:^{
    rt1Done = YES;
    [inv1 fulfill];
  }];

  VanguardAudioPreviewRuntime *rt2 = [self makeRuntimeWithEpoch:2];
  [rt2 prepareWithSidecarPlan:nil timelineDuration:10.0];

  [self waitForExpectations:@[ inv1 ] timeout:5.0];
  XCTAssertTrue(rt1Done, @"old runtime invalidation must complete");

  [self invalidateAndWait:rt2];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-33: testInvalidateAsyncCompletesAfterQueueCleanup
// ─────────────────────────────────────────────────────────────────────────────

- (void)testInvalidateAsyncCompletesAfterQueueCleanup {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *exp = [self expectationWithDescription:@"cleanup"];
  [rt invalidateAsync:^{
    // By the time this fires, engine/player must already be stopped.
    [exp fulfill];
  }];
  [self waitForExpectations:@[ exp ] timeout:5.0];

  // After completion, engine and player must have been stopped.
  XCTAssertGreaterThan(_engine.stopCount, 0,
                       @"engine must stop before completion fires");
  XCTAssertGreaterThan(_player.stopCount, 0,
                       @"player must stop before completion fires");
}


// ─────────────────────────────────────────────────────────────────────────────
// S-34: testNoCommandAcceptedAfterInvalidationBegins
// ─────────────────────────────────────────────────────────────────────────────

- (void)testNoCommandAcceptedAfterInvalidationBegins {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *inv = [self expectationWithDescription:@"inv"];
  [rt invalidateAsync:^{
    [inv fulfill];
  }];
  [self waitForExpectations:@[ inv ] timeout:5.0];

  NSInteger playBefore = _player.playCount;
  [rt commandPlay];
  [self waitFor:0.3];
  XCTAssertEqual(_player.playCount, playBefore,
                 @"commandPlay after invalidation is a no-op");
}


// ─────────────────────────────────────────────────────────────────────────────
// S-35: testEngineAndPlayerMutationRemainOnSchedulerQueue
// ─────────────────────────────────────────────────────────────────────────────

- (void)testEngineAndPlayerMutationRemainOnSchedulerQueue {
  // Verify: assertOnSchedulerQueue does not fire (no crash) during normal
  // operations.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 1.0, .generation = 1, .isPlaying = YES, .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandPlay];
  [rt commandPause];
  [rt commandSeek];
  [self waitFor:0.3];
  // No assertion failures = queue confinement is intact.
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-38: testVanguardGraphRuntimeLifecycleRegressions
// ─────────────────────────────────────────────────────────────────────────────

- (void)testVanguardGraphRuntimeLifecycleRegressions {
  // Regression: multiple invalidateAsync: calls must be safe.
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *exp1 = [self expectationWithDescription:@"inv1"];
  XCTestExpectation *exp2 = [self expectationWithDescription:@"inv2"];
  XCTestExpectation *exp3 = [self expectationWithDescription:@"inv3"];

  [rt invalidateAsync:^{
    [exp1 fulfill];
  }];
  [rt invalidateAsync:^{
    [exp2 fulfill];
  }];
  [rt invalidateAsync:^{
    [exp3 fulfill];
  }];

  [self waitForExpectations:@[ exp1, exp2, exp3 ] timeout:8.0];
  // All three completions must fire. No crash.
}

// ─────────────────────────────────────────────────────────────────────────────

// ─── Joined invalidation waiters ─────────────────────────────────────────────

- (void)testJoinedInvalidationWaitersAllFire {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *w1 = [self expectationWithDescription:@"w1"];
  XCTestExpectation *w2 = [self expectationWithDescription:@"w2"];
  XCTestExpectation *w3 = [self expectationWithDescription:@"w3"];

  // All three calls while in Accepting or Invalidating state must get
  // callbacks.
  [rt invalidateAsync:^{
    [w1 fulfill];
  }];
  [rt invalidateAsync:^{
    [w2 fulfill];
  }];
  [rt invalidateAsync:^{
    [w3 fulfill];
  }];

  [self waitForExpectations:@[ w1, w2, w3 ] timeout:8.0];
}


// ─── Completion after cleanup
// ─────────────────────────────────────────────────

- (void)testInvalidationCompletionFiresAfterCleanup {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  __block NSInteger stopCountAtCompletion = -1;
  XCTestExpectation *exp = [self expectationWithDescription:@"cleanup"];

  [rt invalidateAsync:^{
    // Capture engine stop count at completion time.
    stopCountAtCompletion = self->_engine.stopCount;
    [exp fulfill];
  }];

  [self waitForExpectations:@[ exp ] timeout:5.0];
  XCTAssertGreaterThan(stopCountAtCompletion, 0,
                       @"engine must be stopped before completion fires");
}


// ─── Strong runtime retention through cleanup
// ─────────────────────────────────

- (void)testRuntimeIsStronglyRetainedThroughCleanup {
  // Weak reference to verify runtime survives until completion fires.
  __weak VanguardAudioPreviewRuntime *weakRt = nil;

  XCTestExpectation *exp = [self expectationWithDescription:@"cleanup"];

  @autoreleasepool {
    VanguardAudioPreviewRuntime *rt = [self makeRuntime];
    weakRt = rt;
    [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
    [rt invalidateAsync:^{
      // weakRt must still be non-nil here (strong retention during cleanup).
      XCTAssertNotNil(
          weakRt, @"runtime must be strongly retained until cleanup completes");
      [exp fulfill];
    }];
    // rt goes out of scope here — only the strong capture inside cleanup keeps
    // it alive.
  }

  [self waitForExpectations:@[ exp ] timeout:5.0];
}


// ─── Latest-request-wins generation ─────────────────────────────────────────

- (void)testDuplicateInvalidateAsyncIsIdempotent {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *exp1 = [self expectationWithDescription:@"inv1"];
  XCTestExpectation *exp2 = [self expectationWithDescription:@"inv2"];
  [rt invalidateAsync:^{
    [exp1 fulfill];
  }];
  [rt invalidateAsync:^{
    [exp2 fulfill];
  }];
  [self waitForExpectations:@[ exp1, exp2 ] timeout:5.0];

  // Engine must only be stopped once.
  XCTAssertEqual(
      _engine.stopCount, 1,
      @"engine must stop exactly once despite multiple invalidate calls");
}


// ─── Lifecycle shutdown rejecting installation
// ────────────────────────────────

- (void)testCommandsRejectedAfterInvalidationStarts {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *exp = [self expectationWithDescription:@"done"];
  [rt invalidateAsync:^{
    [exp fulfill];
  }];
  [self waitForExpectations:@[ exp ] timeout:5.0];

  NSInteger prevPlay = _player.playCount;
  NSInteger prevSchedule = _player.scheduleCount;
  [rt commandPlay];
  [rt commandPause];
  [rt commandSeek];
  [rt commandEOS];
  [self waitFor:0.3];

  XCTAssertEqual(_player.playCount, prevPlay,
                 @"play must be rejected after invalidation");
  XCTAssertEqual(_player.scheduleCount, prevSchedule,
                 @"schedule must be rejected after invalidation");
}


// ─── Timer cancellation
// ───────────────────────────────────────────────────────

- (void)testTimerIsCancelledOnInvalidation {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .generation = 1, .isPlaying = YES, .isValid = YES};
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open WAV");
    return;
  }

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *trackDict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(2.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];
  XCTAssertGreaterThan(_timer.armCount, 0, @"timer must be armed");

  XCTestExpectation *exp = [self expectationWithDescription:@"inv"];
  [rt invalidateAsync:^{
    [exp fulfill];
  }];
  [self waitForExpectations:@[ exp ] timeout:5.0];

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"timer must be cancelled during invalidation");
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─── Frame-count overflow before narrowing
// ────────────────────────────────────

- (void)testFrameCountOverflowProducesSilence {
  // With a tiny file of only a few frames and PTS past end, signed frame
  // difference is <= 0.
  double sr = 44100.0, fileDur = 0.001; // ~44 frames
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 5.0,
                                               .playStartPTS = 5.0,
                                               .playStartHostTime = 0.0,
                                               .generation = 1,
                                               .isPlaying = YES,
                                               .isValid = YES};
  _clock.currentTime = 0.0;

  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open WAV");
    return;
  }

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *trackDict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(fileDur),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 0,
                 @"zero/negative frame count must not schedule");
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
  [self invalidateAndWait:rt];
}


// ─── Deterministic file classification ───────────────────────────────────────

- (void)testMissingFileClassifiedCorrectly {
  _fileProvider.fileDoesNotExist = YES;
  _fileProvider.shouldFailWithNoError = YES;

  NSDictionary *d = [self trackDictWithStartTime:0.0 duration:5.0 volume:1.0];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[ d ]
                                                        volumeKeyframes:nil
                                                          waveformCache:nil
                                                   timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedMissingFile);
  [self invalidateAndWait:rt];
}


- (void)testExistingButUnopenableFileClassifiedCorrectly {
  _fileProvider.fileDoesNotExist = NO;
  _fileProvider.shouldFail = YES;

  NSDictionary *d = [self trackDictWithStartTime:0.0 duration:5.0 volume:1.0];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[ d ]
                                                        volumeKeyframes:nil
                                                          waveformCache:nil
                                                   timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedUnsupportedFormat);
  [self invalidateAndWait:rt];
}


- (void)testInvalidFileMetadataClassifiedCorrectly {
  // testPrepareWithEngineFailureYieldsFailed — re-verified here explicitly.
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open WAV");
    return;
  }

  _engine.shouldFailStart = YES;
  NSDictionary *d = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[ d ]
                                                        volumeKeyframes:nil
                                                          waveformCache:nil
                                                   timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedEnginePreparation);
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// ─────────────────────────────────────────────────────────────────────────────

/// APR-TC1: [_player stop] is called immediately on the calling thread
///          when invalidateAsync: is invoked, BEFORE the scheduler-queue
///          cleanupBlock runs.
///
/// Verifies the immediate-quiesce path of the Slice D teardown fix.
/// The mock player's stopCount must be ≥ 1 before any async cleanup fires.
- (void)testImmediatePlayerStopOnInvalidateAsync {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];

  // Arm the runtime so the player is in a "would-be-playing" state.
  _stubbedSnapshot.isValid = YES;
  _stubbedSnapshot.isPlaying = YES;
  _stubbedSnapshot.timelinePTS = 0.0;

  // Install a real temp WAV so prepare succeeds and a segment is scheduled.
  NSURL *tempURL = VGAPrCreateTempWAVURL(44100, 44100.0);
  if (!tempURL) {
    XCTSkip(@"Cannot create temp WAV — skipping APR-TC1");
    return;
  }
  NSError *err = nil;
  AVAudioFile *file = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  if (!file) {
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    XCTSkip(@"Cannot open temp WAV — skipping APR-TC1");
    return;
  }
  _fileProvider.stubbedFile = file;

  NSDictionary *trackDict = @{
    @"trackId" : @"tc1-track",
    @"role" : @"music",
    @"url" : tempURL.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(1.0),
    @"volume" : @(1.0),
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:2.0];

  // Record stopCount BEFORE invalidateAsync: fires any async work.
  NSInteger stopCountBefore = _player.stopCount;

  // Call invalidateAsync: — the immediate stop must occur synchronously
  // on the calling thread before this method returns.
  XCTestExpectation *exp =
      [self expectationWithDescription:@"APR-TC1 invalidate"];
  [rt invalidateAsync:^{
    [exp fulfill];
  }];

  // stopCount must have incremented synchronously — before any
  // scheduler-queue work can execute.
  XCTAssertGreaterThan(_player.stopCount, stopCountBefore,
                       @"[_player stop] must be called synchronously in "
                       @"invalidateAsync: before dispatch to _schedulerQueue");

  [self waitForExpectations:@[ exp ] timeout:2.0];
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
}


/// APR-TC2: Concurrent invalidateAsync: callers both receive their completion.
///
/// Two callers invoke invalidateAsync: before cleanup completes. Both
/// completions must fire exactly once each.
- (void)testConcurrentInvalidateAsyncBothCompletionsFireExactlyOnce {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];

  XCTestExpectation *exp1 =
      [self expectationWithDescription:@"APR-TC2 completion-1"];
  XCTestExpectation *exp2 =
      [self expectationWithDescription:@"APR-TC2 completion-2"];

  exp1.assertForOverFulfill = YES;
  exp2.assertForOverFulfill = YES;

  [rt invalidateAsync:^{
    [exp1 fulfill];
  }];
  [rt invalidateAsync:^{
    [exp2 fulfill];
  }];

  [self waitForExpectations:@[ exp1, exp2 ] timeout:2.0];
}


/// APR-TC3: commandPlay dispatched after invalidateAsync: cannot restart audio.
///
/// Once _acceptingCommands is NO, commandPlay must not schedule a segment
/// or call [_player play]. The player's scheduleCount and playCount must
/// remain at zero.
- (void)testCommandPlayAfterInvalidateCannotRestartAudio {
  _stubbedSnapshot.isValid = YES;
  _stubbedSnapshot.isPlaying = YES;
  _stubbedSnapshot.timelinePTS = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];

  XCTestExpectation *invalidExp =
      [self expectationWithDescription:@"APR-TC3 invalidate"];
  [rt invalidateAsync:^{
    [invalidExp fulfill];
  }];
  [self waitForExpectations:@[ invalidExp ] timeout:2.0];

  // Record counts after full invalidation.
  NSInteger scheduleBefore = _player.scheduleCount;
  NSInteger playBefore = _player.playCount;

  // Attempt to issue play — must be a no-op.
  [rt commandPlay];

  // Give the scheduler queue a moment to process any work (should be none).
  XCTestExpectation *drainExp =
      [self expectationWithDescription:@"APR-TC3 drain"];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    [drainExp fulfill];
  }];
  [self waitForExpectations:@[ drainExp ] timeout:2.0];

  XCTAssertEqual(_player.scheduleCount, scheduleBefore,
                 @"scheduleSegment must not be called after invalidation");
  XCTAssertEqual(_player.playCount, playBefore,
                 @"[_player play] must not be called after invalidation");
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
