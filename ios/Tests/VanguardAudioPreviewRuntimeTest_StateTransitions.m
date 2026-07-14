// VanguardAudioPreviewRuntimeTest_StateTransitions.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (StateTransitions) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (StateTransitions)


// ─────────────────────────────────────────────────────────────────────────────
// S-6: testPlayBeforeTrackStartArmsOneShotBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPlayBeforeTrackStartArmsOneShotBoundaryTimer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 0.5,
                                               .playStartPTS = 0.5,
                                               .playStartHostTime = 0.0,
                                               .generation = 1,
                                               .isPlaying = YES,
                                               .isValid = YES};
  _clock.currentTime = 0.0;

  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV needed");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open temp WAV");
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
  XCTAssertEqual([rt prepareWithSidecarPlan:plan timelineDuration:10.0],
                 VGAudioPreviewPreparationResultReady);

  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.armCount, 0, @"boundary timer must be armed");
  XCTAssertEqual(_player.playCount, 0, @"player must not play before boundary");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 1.5, 0.1,
                             @"delay ≈ trackStart - currentPTS = 1.5s");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-7: testBoundaryTimerRereadsSnapshotBeforeStarting
// ─────────────────────────────────────────────────────────────────────────────

- (void)testBoundaryTimerRereadsSnapshotBeforeStarting {
  // Timeline at PTS=0 (before track start 2.0). Snapshot is not playing.
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 0.0,
                                               .playStartPTS = 0.0,
                                               .playStartHostTime = 0.0,
                                               .generation = 1,
                                               .isPlaying = YES,
                                               .isValid = YES};
  _clock.currentTime = 0.0;

  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV needed");
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

  // Pause before firing the timer — snapshot becomes not-playing.
  _stubbedSnapshot.isPlaying = NO;

  // Fire the timer. The callback should reread snapshot, find !isPlaying, and
  // NOT play.
  [_timer fireForcefully];
  [self waitFor:0.2];

  XCTAssertEqual(
      _player.playCount, 0,
      @"player must not play if snapshot is not-playing at fire time");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-8: testBoundaryTimerRearmsAfterEarlyFire
// ─────────────────────────────────────────────────────────────────────────────

- (void)testBoundaryTimerRearmsAfterEarlyFire {
  // PTS=0, trackStart=2.0.
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 0.0,
                                               .playStartPTS = 0.0,
                                               .playStartHostTime = 0.0,
                                               .generation = 1,
                                               .isPlaying = YES,
                                               .isValid = YES};
  _clock.currentTime = 0.0;

  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV needed");
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

  NSInteger armCountBefore = _timer.armCount;
  // Fire early: snapshot still at PTS=0.0 < trackStart=2.0 → should rearm.
  [_timer fireForcefully];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.armCount, armCountBefore,
                       @"timer must rearm on early fire");
  XCTAssertEqual(_player.playCount, 0, @"player must not play on early fire");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-20: testPauseStopsAudioAndInvalidatesCompletion
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPauseStopsAudioAndInvalidatesCompletion {
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 1.0,
                                               .playStartPTS = 1.0,
                                               .playStartHostTime = 0.0,
                                               .generation = 1,
                                               .isPlaying = NO,
                                               .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandPause];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"timer must be cancelled on pause");
  XCTAssertGreaterThan(_player.stopCount, 0,
                       @"player must be stopped on pause");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-21: testResumeReschedulesFromFreshSnapshot
// ─────────────────────────────────────────────────────────────────────────────

- (void)testResumeReschedulesFromFreshSnapshot {
  double sr = 44100.0, fileDur = 10.0, pts = 3.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = pts,
                                               .playStartPTS = pts,
                                               .playStartHostTime = 0.0,
                                               .generation = 2,
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

  // Pause first, then play (resume).
  [rt commandPause];
  [self waitFor:0.2];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 1, @"resume must reschedule once");
  XCTAssertGreaterThan(_player.playCount, 0, @"player must start on resume");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-36: testAudioSessionIsNotModified
// ─────────────────────────────────────────────────────────────────────────────

- (void)testAudioSessionIsNotModified {
  // Verify the runtime does not mutate AVAudioSession category or mode.
  // We use a fresh runtime and verify the session category is unchanged.
  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSString *categoryBefore = session.category;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.2];
  [self invalidateAndWait:rt];

  XCTAssertEqualObjects(session.category, categoryBefore,
                        @"runtime must not modify AVAudioSession category");
}


// ─── No AVAudioSession mutation
// ───────────────────────────────────────────────

- (void)testNoAVAudioSessionMutation {
  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSString *categoryBefore = session.category;
  NSString *modeBefore = session.mode;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.2];
  [self invalidateAndWait:rt];

  XCTAssertEqualObjects(session.category, categoryBefore,
                        @"AVAudioSession category must not be modified");
  XCTAssertEqualObjects(session.mode, modeBefore,
                        @"AVAudioSession mode must not be modified");
}


// ─────────────────────────────────────────────────────────────────────────────
// S-37: testSliceCSnapshotContractRemainsUnchanged
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSliceCSnapshotContractRemainsUnchanged {
  // Verify VGTimelineStateSnapshot fields expected by Slice C are intact.
  VGTimelineStateSnapshot snap = {0};
  snap.isValid = YES;
  snap.isPlaying = YES;
  snap.timelinePTS = 1.5;
  snap.playStartPTS = 1.0;
  snap.playStartHostTime = 100.0;
  snap.generation = 42;

  XCTAssertTrue(snap.isValid, @"isValid field must exist");
  XCTAssertTrue(snap.isPlaying, @"isPlaying field must exist");
  XCTAssertEqualWithAccuracy(snap.timelinePTS, 1.5, 0.001);
  XCTAssertEqualWithAccuracy(snap.playStartPTS, 1.0, 0.001);
  XCTAssertEqualWithAccuracy(snap.playStartHostTime, 100.0, 0.001);
  XCTAssertEqual(snap.generation, 42ULL, @"generation field must exist");
}


- (void)testD_T6_commandPlayArmesBoundaryTimerWhenPTSBeforeTrackStart {
  [self testPlayBeforeTrackStartArmsOneShotBoundaryTimer];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
