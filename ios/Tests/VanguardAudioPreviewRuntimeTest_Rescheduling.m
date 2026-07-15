// VanguardAudioPreviewRuntimeTest_Rescheduling.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (Rescheduling) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (Rescheduling)


// ─────────────────────────────────────────────────────────────────────────────
// S-22: testSeekWhilePausedDoesNotStartPlayer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSeekWhilePausedDoesNotStartPlayer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 3.0, .generation = 1, .isPlaying = NO, .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandSeek];
  [self waitFor:0.3];

  XCTAssertEqual(_player.playCount, 0,
                 @"seek while paused must not start player");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-23: testSeekWhilePlayingStopsAndReschedules
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSeekWhilePlayingStopsAndReschedules {
  double sr = 44100.0, fileDur = 10.0, seekPTS = 4.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = seekPTS,
                                               .playStartPTS = seekPTS,
                                               .playStartHostTime = 0.0,
                                               .generation = 3,
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
  [rt commandSeek];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_player.stopCount, 0, @"seek must stop player");
  XCTAssertGreaterThan(_player.scheduleCount, 0,
                       @"seek while playing must reschedule");
  XCTAssertGreaterThan(_player.playCount, 0,
                       @"seek while playing must restart player");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-24: testNegativeSeekUsesClampedZeroSnapshot
// ─────────────────────────────────────────────────────────────────────────────

- (void)testNegativeSeekUsesClampedZeroSnapshot {
  // Snapshot has negative PTS — the runtime must clamp to MAX(0.0, PTS).
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = -1.5, .generation = 1, .isPlaying = NO, .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandSeek];
  [self waitFor:0.3];
  // Should not crash; player must be stopped.
  XCTAssertGreaterThan(_player.stopCount, 0,
                       @"negative PTS seek must not crash");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-25: testRapidSeeksOnlyLatestCommandMaySchedule
// ─────────────────────────────────────────────────────────────────────────────

- (void)testRapidSeeksOnlyLatestCommandMaySchedule {
  double sr = 44100.0, fileDur = 10.0, finalPTS = 5.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = finalPTS,
                                               .playStartPTS = finalPTS,
                                               .playStartHostTime = 0.0,
                                               .generation = 5,
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

  // Fire multiple seeks rapidly.
  for (NSInteger i = 0; i < 5; i++) {
    [rt commandSeek];
  }
  [self waitFor:0.5];

  // Each seek cancels the timer and stops the player. The last seek may
  // schedule.
  XCTAssertGreaterThan(_timer.cancelCount, 0, @"rapid seeks must cancel timer");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-26: testTimelineGenerationMismatchRejectsTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTimelineGenerationMismatchRejectsTimer {
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

  // Change generation on snapshot → stales token.
  _stubbedSnapshot.generation = 99;
  // Fire the timer — callback should detect generation mismatch.
  [_timer fireForcefully];
  [self waitFor:0.2];

  XCTAssertEqual(_player.playCount, 0,
                 @"generation mismatch must reject timer");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-27: testCommandSerialMismatchRejectsCompletion
// ─────────────────────────────────────────────────────────────────────────────

- (void)testCommandSerialMismatchRejectsCompletion {
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

  NSInteger playsBefore = _player.playCount;
  // Issue commandSeek — increments commandSerial, cancels timer.
  _stubbedSnapshot.generation = 2;
  [rt commandSeek];
  [self waitFor:0.2];

  // Fire the stale timer (pendingBlock is nil after cancel).
  [_timer fireForcefully];
  [self waitFor:0.2];

  XCTAssertEqual(_player.playCount, playsBefore,
                 @"stale timer with cancelled block must not call play");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-28: testLifecycleEpochMismatchRejectsOldRuntimeCallback
// ─────────────────────────────────────────────────────────────────────────────

- (void)testLifecycleEpochMismatchRejectsOldRuntimeCallback {
  // Two runtimes with different epochs. Old runtime commands must not affect
  // new.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .generation = 1, .isPlaying = YES, .isValid = YES};

  VanguardAudioPreviewRuntime *rt1 = [self makeRuntimeWithEpoch:1];
  VanguardAudioPreviewRuntime *rt2 = [self makeRuntimeWithEpoch:2];

  [rt1 prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt2 prepareWithSidecarPlan:nil timelineDuration:10.0];

  // Invalidate rt1.
  XCTestExpectation *inv1 = [self expectationWithDescription:@"inv1"];
  [rt1 invalidateAsync:^{
    [inv1 fulfill];
  }];
  [self waitForExpectations:@[ inv1 ] timeout:5.0];

  // rt2 should still be fully functional.
  NSInteger prevStop = _player.stopCount;
  [rt2 commandPause];
  [self waitFor:0.3];
  XCTAssertGreaterThan(_player.stopCount, prevStop,
                       @"rt2 must still accept commands after rt1 invalidated");

  [self invalidateAndWait:rt2];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-29: testInvalidSnapshotStopsActiveAudio
// ─────────────────────────────────────────────────────────────────────────────

- (void)testInvalidSnapshotStopsActiveAudio {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 3.0, .generation = 1, .isPlaying = NO, .isValid = NO};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandPause]; // triggers snapshot read; invalid snapshot => stops player
  [self waitFor:0.3];
  XCTAssertGreaterThan(_player.stopCount, 0,
                       @"invalid snapshot must stop player");
  [self invalidateAndWait:rt];
}


- (void)testD_T7_commandPauseStopsPlayerAndCancelsTimer {
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
  XCTAssertGreaterThan(_timer.cancelCount, 0);
  XCTAssertGreaterThan(_player.stopCount, 0);
  [self invalidateAndWait:rt];
}


- (void)testD_T8_commandSeekCancelsTimerAndStopsPlayer {
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
  XCTAssertGreaterThan(_timer.cancelCount, 0);
  XCTAssertGreaterThan(_player.stopCount, 0);
  [self invalidateAndWait:rt];
}


- (void)testD_T9_staleTokenBoundaryTimerCallbackIsDiscarded {
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 0.0,
                                               .playStartPTS = 0.0,
                                               .playStartHostTime = 0.0,
                                               .generation = 1,
                                               .isPlaying = YES,
                                               .isValid = YES};
  _clock.currentTime = 0.0;

  double sr = 44100.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(10.0 * sr), sr);
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
  NSDictionary *d = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(2.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[ d ]
                                                        volumeKeyframes:nil
                                                          waveformCache:nil
                                                   timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.2];
  XCTAssertGreaterThan(_timer.armCount, 0);

  _stubbedSnapshot.generation = 2;
  [rt commandSeek];
  [self waitFor:0.2];

  NSInteger playBefore = _player.playCount;
  [_timer fireForcefully];
  [self waitFor:0.2];

  XCTAssertEqual(_player.playCount, playBefore,
                 @"stale timer must not call play");
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


- (void)testD_T10_invalidateAsyncIsIdempotent {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *e1 = [self expectationWithDescription:@"inv1"];
  XCTestExpectation *e2 = [self expectationWithDescription:@"inv2"];
  [rt invalidateAsync:^{
    [e1 fulfill];
  }];
  [rt invalidateAsync:^{
    [e2 fulfill];
  }];
  [self waitForExpectations:@[ e1, e2 ] timeout:5.0];
}


- (void)testD_T11_commandPlayAfterInvalidateIsNoOp {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [self invalidateAndWait:rt];

  [rt commandPlay];
  [self waitFor:0.3];
  XCTAssertEqual(_player.playCount, 0,
                 @"commandPlay after invalidation is no-op");
}




// G-T6: seek while playing a voiceover track stops and reschedules correctly
- (void)testG_T6_seekWhilePlayingVoiceoverReschedules {
  double sr = 44100.0, fileDur = 10.0, seekPTS = 2.5;
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = seekPTS,
                                               .playStartPTS = seekPTS,
                                               .playStartHostTime = 0.0,
                                               .generation = 4,
                                               .isPlaying = YES,
                                               .isValid = YES};
  _clock.currentTime = 0.0;

  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open WAV");
    return;
  }

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *trackDict = @{
    @"trackId" : @"vo-g6",
    @"role" : @"voiceover",
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
  [rt commandSeek];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_player.stopCount, 0, @"seek must stop voiceover player");
  XCTAssertGreaterThan(_player.scheduleCount, 0,
                       @"seek on voiceover track must reschedule");
  XCTAssertGreaterThan(_player.playCount, 0,
                       @"seek on voiceover track must restart player");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
