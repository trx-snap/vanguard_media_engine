// VanguardAudioPreviewRuntimeTest_SliceE.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (SliceEContract) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (SliceEContract)


// ─────────────────────────────────────────────────────────────────────────────
// SE-T1: Combined non-zero sourceTrimStart and non-zero timelineStart contract.
//
// Proves that source-position and frame-count arithmetic are correct when both
// values are non-zero in the same descriptor (the Slice E evidence gap).
//
// Descriptor: startTime=5, sourceTrimStart=2, duration=4, sr=48000, fileDur=20.
// Project timeline duration = 12. trackEnd = 9. scheduledEndPTS = 9 (no other
// descriptor ⇒ nextDecisionPTS = ∞ ⇒ scheduledEndPTS = min(9, ∞) = 9).
//
// At PTS 3 (before trackStart 5):
//   silence — boundary timer armed at delay (5.0 − 3.0) = 2.0 s.
//
// At PTS 5 (timer fires, clock+2.0 s):
//   sourcePosition = 2.0 + (5.0 − 5.0) = 2.0
//   startFrame     = ⌊2.0 × 48000⌋      = 96000
//   scheduledEnd   = 2.0 + (9.0 − 5.0)  = 6.0 s
//   endExclusive   = ⌊6.0 × 48000⌋      = 288000
//   frameCount     = 288000 − 96000      = 192000
//
// At PTS 7 (seek, clock 2.0 s from new playStartHostTime):
//   sourcePosition = 2.0 + (7.0 − 5.0) = 4.0
//   startFrame     = ⌊4.0 × 48000⌋     = 192000
//   endExclusive   = 288000
//   frameCount     = 288000 − 192000    = 96000
//
// At PTS 9 (timer fires, half-open end):
//   no new segment scheduled; state transitions to Ended.
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSliceE_sourceTrimAndTimelineOffsetCombined {
  double sr = 48000.0, fileDur = 20.0;
  AVAudioFramePosition totalFrames = (AVAudioFramePosition)(fileDur * sr); // 960000

  NSURL *url = VGAPrCreateTempWAVURL(totalFrames, sr);
  if (!url) {
    XCTSkip(@"temp WAV needed for SE-T1");
    return;
  }
  NSError *openErr = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&openErr];
  if (!_fileProvider.stubbedFile) {
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    XCTSkip(@"could not open WAV for SE-T1");
    return;
  }

  // Build the descriptor inline — sourceTrimStart must be non-zero.
  NSDictionary *trackDict = @{
    @"trackId"        : @"t1",
    @"role"           : @"music",
    @"url"            : url.path,
    @"startTime"      : @(5.0),
    @"sourceTrimStart": @(2.0),
    @"duration"       : @(4.0),
    @"volume"         : @(1.0),
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult prepResult =
      [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  XCTAssertEqual(prepResult, VGAudioPreviewPreparationResultReady,
                 @"SE-T1: prepare must return Ready");

  // ── A. Before timeline start at PTS 3 ────────────────────────────────────

  _clock.currentTime = 0.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS       = 3.0,
      .playStartPTS      = 3.0,
      .playStartHostTime = 0.0,
      .generation        = 1,
      .isPlaying         = YES,
      .isValid           = YES,
  };

  [rt commandPlay];
  // Drain the scheduler queue: any block enqueued by commandPlay must complete
  // before assertions.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertEqual(_player.scheduleCount, 0,
                 @"SE-T1-A: no segment may be scheduled before trackStart");
  XCTAssertEqual(_timer.armCount, 1,
                 @"SE-T1-A: one boundary timer must be armed");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 2.0, 0.001,
                 @"SE-T1-A: timer delay must be trackStart − PTS = 2.0 s");
  XCTAssertNotNil(_timer.pendingBlock,
                 @"SE-T1-A: timer must hold a pending block");

  // ── B. Exact timeline start at PTS 5 ─────────────────────────────────────
  //   estimated PTS = playStartPTS + (currentTime − playStartHostTime)
  //                 = 3.0 + (2.0 − 0.0) = 5.0

  _clock.currentTime = 2.0;
  _stubbedSnapshot.timelinePTS = 5.0; // consistency; isPlaying/generation unchanged

  [_timer fireForcefully]; // executes pending block synchronously on queue

  XCTAssertEqual(_player.scheduleCount, 1,
                 @"SE-T1-B: exactly one segment must be scheduled at PTS 5");
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)96000,
                 @"SE-T1-B: startFrame must be sourceTrimStart(2s) × sr = 96000");
  XCTAssertEqual(_player.lastFrameCount, (AVAudioFrameCount)192000,
                 @"SE-T1-B: frameCount must be 192000 (4 s × 48000 Hz)");
  XCTAssertEqual(_player.playCount, 1,
                 @"SE-T1-B: player must be started");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 4.0, 0.001,
                 @"SE-T1-B: boundary timer must be armed at trackEnd − PTS = 4.0 s");

  // ── C. Seek inside the active range at PTS 7 ──────────────────────────────
  //   estimated PTS = playStartPTS + (currentTime − playStartHostTime)
  //                 = 7.0 + (2.0 − 2.0) = 7.0

  NSInteger stopCountBeforeSeek = _player.stopCount;

  _stubbedSnapshot.generation        = 2;
  _stubbedSnapshot.timelinePTS       = 7.0;
  _stubbedSnapshot.playStartPTS      = 7.0;
  _stubbedSnapshot.playStartHostTime = 2.0;
  // _clock.currentTime already 2.0

  [rt commandSeek];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertGreaterThan(_player.stopCount, stopCountBeforeSeek,
                 @"SE-T1-C: seek must stop the player");
  XCTAssertEqual(_player.scheduleCount, 2,
                 @"SE-T1-C: seek must reschedule — total 2 segments");
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)192000,
                 @"SE-T1-C: startFrame at PTS 7 must be 4.0 s × 48000 = 192000");
  XCTAssertEqual(_player.lastFrameCount, (AVAudioFrameCount)96000,
                 @"SE-T1-C: frameCount at PTS 7 must be 2.0 s × 48000 = 96000");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 2.0, 0.001,
                 @"SE-T1-C: boundary timer must be armed at trackEnd − PTS = 2.0 s");

  // ── D. Half-open track end at PTS 9 ──────────────────────────────────────
  //   estimated PTS = playStartPTS + (currentTime − playStartHostTime)
  //                 = 7.0 + (4.0 − 2.0) = 9.0

  NSInteger stopCountBeforeEnd = _player.stopCount;

  // generation/playStartPTS/playStartHostTime unchanged from C.
  _clock.currentTime = 4.0;
  _stubbedSnapshot.timelinePTS = 9.0; // consistency

  [_timer fireForcefully]; // executes pending block synchronously on queue

  XCTAssertEqual(_player.scheduleCount, 2,
                 @"SE-T1-D: no new segment may be scheduled at half-open end");
  XCTAssertEqual(_player.stopCount, stopCountBeforeEnd,
                 @"SE-T1-D: natural half-open end must not issue an additional explicit stop");
  XCTAssertNil(_timer.pendingBlock,
                 @"SE-T1-D: no pending timer block at the end boundary");

  // Verify the runtime reached Ended state.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStateEnded,
                   @"SE-T1-D: runtime must be Ended at the half-open boundary");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
