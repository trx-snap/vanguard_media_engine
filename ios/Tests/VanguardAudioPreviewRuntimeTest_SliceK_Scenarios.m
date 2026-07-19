// VanguardAudioPreviewRuntimeTest_SliceK_Scenarios.m
// Vanguard Media Engine — Audio Slice K
//
// Category (SliceKScenarios) on VanguardAudioPreviewRuntimeTest.
// 12 selectors: testK_T1 through testK_T12.
//
// Proves that all four audio composition scenarios (A, B, C, D) preview
// correctly using the two-slot (Added Audio + Voice-over) architecture.
//
// All tests use deterministic mock collaborators — no real audio playback.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (SliceKScenarios)

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Sets up a real temp WAV file in _fileProvider.stubbedFile.
/// Returns the file path, or nil if WAV creation fails.
- (nullable NSString *)_setupRealWAVWithDuration:(double)dur
                                      sampleRate:(double)sr {
  AVAudioFramePosition frames = (AVAudioFramePosition)(dur * sr);
  NSURL *url = VGAPrCreateTempWAVURL(frames, sr);
  if (!url)
    return nil;
  NSError *err = nil;
  AVAudioFile *f = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!f)
    return nil;
  _fileProvider.stubbedFile = f;
  return url.path;
}

// ─── K-T1: Scenario A — video only, no sidecar schedule ──────────────────────

/// Nil sidecar plan → ReadySilent. Neither slot schedules audio.
/// Proves no duplicate Original audio — the runtime does not touch the embedded
/// video path.
- (void)testK_T1_scenarioA_videoOnly_noSidecarSchedule {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTAssertEqual(res, VGAudioPreviewPreparationResultSilentNoEligibleTrack,
                 @"nil plan must yield ReadySilent");
  XCTAssertEqual(_player.scheduleCount, 0,
                 @"Added Audio slot must not schedule for nil plan");
  XCTAssertEqual(_player.playCount, 0,
                 @"Added Audio slot must not play for nil plan");
  [self invalidateAndWait:rt];
}

// ─── K-T2: Scenario B — Added Audio only, schedules Added slot ──────────────

/// Single music track → Added slot schedules. Voice-over slot idle.
- (void)testK_T2_scenarioB_addedAudioOnly_schedulesAddedSlot {
  double sr = 44100.0, fileDur = 5.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = [_clock currentTime],
      .timelinePTS = 0.0};

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-B"
                                             startTime:0.0
                                              duration:fileDur
                                                volume:1.0
                                                   url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady);

  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_player.scheduleCount, 0,
                       @"Added Audio slot must schedule for Scenario B");
  XCTAssertGreaterThan(_player.playCount, 0,
                       @"Added Audio slot must play for Scenario B");
  // Voice-over slot must be idle.
  XCTAssertEqual(_voiceoverPlayer.scheduleCount, 0,
                 @"Voice-over slot must NOT schedule when no VO track");
  XCTAssertEqual(_voiceoverPlayer.playCount, 0,
                 @"Voice-over slot must NOT play when no VO track");
  [self invalidateAndWait:rt];
}

// ─── K-T3: Scenario C — voice-over only, schedules Voice-over slot ──────────

/// Single voice-over track → Voice-over slot schedules. Added slot idle.
- (void)testK_T3_scenarioC_voiceoverOnly_schedulesVoiceoverSlot {
  double sr = 44100.0, fileDur = 5.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = [_clock currentTime],
      .timelinePTS = 0.0};

  NSDictionary *voDict = [self voiceoverTrackDictWithId:@"vo-C"
                                              startTime:0.0
                                               duration:fileDur
                                                 volume:1.0
                                                    url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady,
                 @"voiceover track must yield Ready");

  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_voiceoverPlayer.scheduleCount, 0,
                       @"Voice-over slot must schedule for Scenario C");
  XCTAssertGreaterThan(_voiceoverPlayer.playCount, 0,
                       @"Voice-over slot must play for Scenario C");
  // Added Audio slot must be idle.
  XCTAssertEqual(_player.scheduleCount, 0,
                 @"Added Audio slot must NOT schedule when no music/sfx track");
  XCTAssertEqual(_player.playCount, 0,
                 @"Added Audio slot must NOT play when no music/sfx track");
  [self invalidateAndWait:rt];
}

// ─── K-T4: Scenario D — music and voice-over, schedules both slots ───────────

/// Music [0,10) + VO [2,8) both active at PTS=3. Both slots schedule.
- (void)testK_T4_scenarioD_musicAndVoiceover_schedulesBothSlots {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  // PTS=3: inside music [0,10) and inside VO [2,8).
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 3.0, .playStartHostTime = [_clock currentTime],
      .timelinePTS = 3.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-D"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-D"
                                                startTime:2.0
                                                 duration:6.0
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_player.scheduleCount, 0,
                       @"Added Audio slot must schedule music at PTS=3");
  XCTAssertGreaterThan(_player.playCount, 0,
                       @"Added Audio slot must play music at PTS=3");
  XCTAssertGreaterThan(_voiceoverPlayer.scheduleCount, 0,
                       @"Voice-over slot must schedule VO at PTS=3");
  XCTAssertGreaterThan(_voiceoverPlayer.playCount, 0,
                       @"Voice-over slot must play VO at PTS=3");
  [self invalidateAndWait:rt];
}

// ─── K-T5: Scenario D — ducked music keyframes route gain to Added slot only ─

/// Music with ducking keyframes + VO at static 1.0.
/// Added slot automation timer must fire; VO automation timer must NOT start.
- (void)testK_T5_scenarioD_duckedMusicKeyframes_routeGainToAddedSlotOnly {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 3.0, .playStartHostTime = [_clock currentTime],
      .timelinePTS = 3.0};
  _clock.currentTime = 0.0;

  // Ducking envelope: 0→0.4, 10→0.4 (constant 0.4 for simplicity).
  NSArray *duckKFs = @[
    @{@"time": @(0.0), @"volume": @(0.4)},
    @{@"time": @(10.0), @"volume": @(0.4)},
  ];
  NSDictionary *musicDict = [self trackDictWithId:@"music-D5"
                                             role:@"music"
                                        startTime:0.0
                                         duration:10.0
                                           volume:1.0
                                              url:path
                                       keyframes:duckKFs];
  NSDictionary *voDict = [self voiceoverTrackDictWithId:@"vo-D5"
                                              startTime:2.0
                                               duration:6.0
                                                 volume:1.0
                                                    url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Added Audio coordinator must have started the automation timer for keyframes.
  XCTAssertGreaterThan(_automationTimer.startCount, 0,
                       @"Added Audio automation timer must start for ducked music");
  // Voice-over coordinator must NOT start its timer (static volume, no keyframes).
  XCTAssertEqual(_voiceoverAutomationTimer.startCount, 0,
                 @"Voice-over automation timer must NOT start for static VO");
  [self invalidateAndWait:rt];
}

// ─── K-T6: Scenario D — seek into overlap reschedules both slots ─────────────

/// Music [0,10) + VO [2,8). Seek to PTS=5 (inside overlap) → both reschedule.
- (void)testK_T6_scenarioD_seekIntoOverlap_reschedulesBothSlots {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  // Start at PTS=0.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = [_clock currentTime],
      .timelinePTS = 0.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-D6"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-D6"
                                                startTime:2.0
                                                 duration:6.0
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [self waitFor:0.2];

  NSInteger addedBeforeSeek = _player.scheduleCount;
  NSInteger voBeforeSeek    = _voiceoverPlayer.scheduleCount;

  // Seek to PTS=5 (inside overlap).
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 2,
      .playStartPTS = 5.0, .playStartHostTime = [_clock currentTime],
      .timelinePTS = 5.0};
  [rt commandSeek];
  [self waitFor:0.3];

  // Both slots must have scheduled additional segments after the seek.
  XCTAssertGreaterThan(_player.scheduleCount, addedBeforeSeek,
                       @"Added Audio slot must reschedule after seek into overlap");
  XCTAssertGreaterThan(_voiceoverPlayer.scheduleCount, voBeforeSeek,
                       @"Voice-over slot must reschedule after seek into overlap");
  [self invalidateAndWait:rt];
}

// ─── K-T7: Scenario D — VO ends, Added slot continues ───────────────────────

/// Music [0,10) + VO [2,8). At boundary T=8, VO slot stops; Added continues.
- (void)testK_T7_scenarioD_voiceoverEnds_addedSlotContinues {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  // PTS=3: inside both music and VO.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 3.0, .playStartHostTime = [_clock currentTime],
      .timelinePTS = 3.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-D7"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-D7"
                                                startTime:2.0
                                                 duration:6.0 // ends at T=8
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [self waitFor:0.2];

  // Advance clock to PTS=8 (VO boundary) and fire boundary timer.
  _clock.currentTime = 5.0; // elapsed from playStartHostTime=0
  _stubbedSnapshot.playStartPTS = 3.0;
  _stubbedSnapshot.playStartHostTime = 0.0;
  // PTS = 3.0 + max(0, 5.0 - 0.0) = 8.0

  NSInteger voStopBefore = _voiceoverPlayer.stopCount;
  NSInteger addedStopBefore = _player.stopCount;
  [_timer fireForcefully]; // fires boundary at PTS=8

  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // VO slot must have been stopped (deactivated at boundary T=8).
  XCTAssertGreaterThan(_voiceoverPlayer.stopCount, voStopBefore,
                       @"Voice-over slot must stop when VO ends at T=8");
  // Added slot must NOT have gotten an extra stop from the VO boundary.
  // (It may have been rescheduled but must not have been stopped more times
  // than the VO boundary stop warrants.)
  XCTAssertEqual(_player.stopCount, addedStopBefore,
                 @"Added Audio slot must not stop when VO boundary fires");
  [self invalidateAndWait:rt];
}

// ─── K-T8: Added Audio boundary must not disrupt Voice-over slot ─────────────

/// Music-A [0,5) → Music-B [5,10) with VO [3,7).
/// At music boundary T=5, Added slot transitions.
/// VO slot's stopCount must NOT increase from the music transition.
- (void)testK_T8_addedAudioBoundaryDoesNotDisruptVoiceoverSlot {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  // PTS=1: inside Music-A and VO.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 1.0, .playStartHostTime = 0.0,
      .timelinePTS = 1.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicA = [self musicTrackDictWithId:@"music-A-D8"
                                          startTime:0.0
                                           duration:5.0
                                             volume:1.0
                                                url:path];
  NSDictionary *musicB = [self musicTrackDictWithId:@"music-B-D8"
                                          startTime:5.0
                                           duration:5.0
                                             volume:1.0
                                                url:path];
  NSDictionary *voDict = [self voiceoverTrackDictWithId:@"vo-D8"
                                              startTime:3.0
                                               duration:4.0 // [3,7)
                                                 volume:1.0
                                                    url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicA, musicB, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [self waitFor:0.2];

  // Advance to PTS=5 (Music-A end / Music-B start boundary).
  _clock.currentTime = 4.0; // elapsed = 4s → PTS = 1.0 + 4.0 = 5.0
  _stubbedSnapshot.playStartPTS = 1.0;
  _stubbedSnapshot.playStartHostTime = 0.0;

  NSInteger voStopBefore = _voiceoverPlayer.stopCount;
  [_timer fireForcefully]; // fires at PTS=5 — Added Audio boundary only
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertEqual(_voiceoverPlayer.stopCount, voStopBefore,
                 @"VO slot must NOT stop when Added Audio transitions at T=5");
  [self invalidateAndWait:rt];
}

// ─── K-T9: Voice-over boundary must not disrupt Added Audio slot ─────────────

/// VO-A [0,4) → VO-B [4,8) with music [0,10).
/// At VO boundary T=4, VO slot transitions; Added slot stopCount must NOT grow.
- (void)testK_T9_voiceoverBoundaryDoesNotDisruptAddedSlot {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  // PTS=1: inside both VO-A and music.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 1.0, .playStartHostTime = 0.0,
      .timelinePTS = 1.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-D9"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voA = [self voiceoverTrackDictWithId:@"vo-A-D9"
                                           startTime:0.0
                                            duration:4.0
                                              volume:1.0
                                                 url:path];
  NSDictionary *voB = [self voiceoverTrackDictWithId:@"vo-B-D9"
                                           startTime:4.0
                                            duration:4.0
                                              volume:1.0
                                                 url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voA, voB]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [self waitFor:0.2];

  // Advance to PTS=4 (VO-A end / VO-B start).
  _clock.currentTime = 3.0; // elapsed = 3 → PTS = 1.0 + 3.0 = 4.0
  _stubbedSnapshot.playStartPTS = 1.0;
  _stubbedSnapshot.playStartHostTime = 0.0;

  NSInteger addedStopBefore = _player.stopCount;
  [_timer fireForcefully]; // fires at PTS=4 — VO boundary only
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertEqual(_player.stopCount, addedStopBefore,
                 @"Added Audio slot must NOT stop when VO transitions at T=4");
  [self invalidateAndWait:rt];
}

// ─── K-T10: Stale completion from one slot cannot affect other ───────────────

/// After a seek (incrementing the shared activeToken), a stale completion
/// block from the Added slot's old segment must not stop the VO slot.
- (void)testK_T10_staleCompletionFromOneSlotCannotAffectOther {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 3.0, .playStartHostTime = 0.0,
      .timelinePTS = 3.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-D10"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-D10"
                                                startTime:2.0
                                                 duration:6.0
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [self waitFor:0.2];

  // Capture the stale completion handler from Added Audio slot before seeking.
  AVAudioPlayerNodeCompletionHandler staleHandler = _player.lastCompletionHandler;

  // Seek — advances the shared activeToken, invalidating stale completion blocks.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 2,
      .playStartPTS = 5.0, .playStartHostTime = 0.0,
      .timelinePTS = 5.0};
  [rt commandSeek];
  [self waitFor:0.2];

  NSInteger voStopBefore = _voiceoverPlayer.stopCount;

  // Fire the stale completion block (from before the seek).
  if (staleHandler) {
    staleHandler(AVAudioPlayerNodeCompletionDataConsumed);
    [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];
  }

  // The stale completion must NOT stop the VO slot.
  XCTAssertEqual(_voiceoverPlayer.stopCount, voStopBefore,
                 @"Stale Added Audio completion must not stop VO slot");
  [self invalidateAndWait:rt];
}

// ─── K-T11: Pause stops both slots ──────────────────────────────────────────

/// During Scenario D playback, commandPause stops both players.
- (void)testK_T11_pauseStopsBothSlots {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 3.0, .playStartHostTime = 0.0,
      .timelinePTS = 3.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-D11"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-D11"
                                                startTime:2.0
                                                 duration:6.0
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [self waitFor:0.2];

  NSInteger addedStopBefore = _player.stopCount;
  NSInteger voStopBefore    = _voiceoverPlayer.stopCount;

  _stubbedSnapshot.isPlaying = NO;
  [rt commandPause];
  [self waitFor:0.2];

  XCTAssertGreaterThan(_player.stopCount, addedStopBefore,
                       @"commandPause must stop Added Audio player");
  XCTAssertGreaterThan(_voiceoverPlayer.stopCount, voStopBefore,
                       @"commandPause must stop Voice-over player");
  [self invalidateAndWait:rt];
}

// ─── K-T12: Invalidate cleans both slots ────────────────────────────────────

/// invalidateAsync: stops both players and the automation timers report no
/// further starts after invalidation completes.
- (void)testK_T12_invalidateCleansBothSlots {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 3.0, .playStartHostTime = 0.0,
      .timelinePTS = 3.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-D12"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-D12"
                                                startTime:2.0
                                                 duration:6.0
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:12.0];
  [rt commandPlay];
  [self waitFor:0.2];

  NSInteger addedStopBefore = _player.stopCount;
  NSInteger voStopBefore    = _voiceoverPlayer.stopCount;

  // Invalidate — completion block fires on main queue after cleanup.
  [self invalidateAndWait:rt];

  XCTAssertGreaterThan(_player.stopCount, addedStopBefore,
                       @"invalidateAsync must stop Added Audio player");
  XCTAssertGreaterThan(_voiceoverPlayer.stopCount, voStopBefore,
                       @"invalidateAsync must stop Voice-over player");
  // After invalidation, no further timer starts should occur.
  NSInteger addedTimerStartsAfter = _automationTimer.startCount;
  NSInteger voTimerStartsAfter    = _voiceoverAutomationTimer.startCount;
  [rt commandPlay]; // must be a no-op after invalidation
  [self waitFor:0.1];
  XCTAssertEqual(_automationTimer.startCount, addedTimerStartsAfter,
                 @"Added automation timer must not start after invalidation");
  XCTAssertEqual(_voiceoverAutomationTimer.startCount, voTimerStartsAfter,
                 @"VO automation timer must not start after invalidation");
}

// ─── K-T13: Early AddedAudio completion must not activate idle VO slot ────────

/// Reproduces the physical smoke failure in unit form.
/// Music [0,10) + VO [3,7). Start at PTS=0. Boundary timer arms for PTS=3.
/// If AddedAudio completion fires early at PTS=2.05 (AVAudioPlayerNodeCompletionDataConsumed
/// fires before audio is rendered to speakers), the VO slot must remain idle.
/// Only after the boundary timer fires at PTS=3.0 must VO become active.
- (void)testK_T13_earlyAddedCompletionDoesNotActivateVoiceoverBeforeBoundary {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  // Start at PTS=0 with both music and VO in the plan.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .timelinePTS = 0.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-K13"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-K13"
                                                startTime:3.0
                                                 duration:4.0   // [3, 7)
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  // Drain scheduler queue so initial scheduling is complete.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Initial state: AddedAudio scheduled, VO must be idle.
  XCTAssertGreaterThan(_player.scheduleCount, 0,
                       @"AddedAudio must schedule at PTS=0");
  XCTAssertEqual(_voiceoverPlayer.scheduleCount, 0,
                 @"VO must NOT be scheduled at PTS=0 — timelineStart is 3.0");
  XCTAssertEqual(_voiceoverPlayer.playCount, 0,
                 @"VO must NOT play at PTS=0");

  // Capture the AddedAudio completion handler from first segment scheduling.
  AVAudioPlayerNodeCompletionHandler earlyCompletion =
      _player.lastCompletionHandler;
  NSInteger addedScheduleCountBefore = _player.scheduleCount;

  // Simulate AVAudioPlayerNodeCompletionDataConsumed firing early at PTS=2.05.
  // Set the mock clock so _currentPTSFromSnapshot returns ~2.05.
  _clock.currentTime = 2.05; // elapsed since playStartHostTime=0.0
  // playStartPTS=0, elapsed=2.05 → computedPTS=2.05

  // Fire the completion handler (on a background thread, it will dispatch_async
  // to the scheduler queue internally).
  if (earlyCompletion) {
    earlyCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  // Drain scheduler queue to process the completion callback.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // ─── Critical assertion: VO must still be idle after early completion ───
  XCTAssertEqual(_voiceoverPlayer.scheduleCount, 0,
                 @"VO slot must NOT be activated when completion fires at PTS=2.05 "
                 @"with VO timelineStart=3.0 — this is the physical smoke failure");
  XCTAssertEqual(_voiceoverPlayer.playCount, 0,
                 @"VO slot must NOT play when completion fires early at PTS=2.05");

  // AddedAudio must have rescheduled a continuation segment (same-lane continue).
  XCTAssertGreaterThan(_player.scheduleCount, addedScheduleCountBefore,
                       @"AddedAudio must reschedule a continuation segment after "
                       @"early completion at PTS=2.05");

  // ─── Now advance clock to 3.0 and fire the boundary timer ──────────────
  _clock.currentTime = 3.0;
  // Update snapshot so boundary timer re-evaluation sees PTS=3.0.
  _stubbedSnapshot.playStartHostTime = 0.0;
  _stubbedSnapshot.playStartPTS = 0.0;

  [_timer fireForcefully]; // fires boundary timer at PTS=3.0
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Now VO must be active — authoritative PTS has reached 3.0.
  XCTAssertGreaterThan(_voiceoverPlayer.scheduleCount, 0,
                       @"VO slot must activate when boundary timer fires at PTS=3.0");
  XCTAssertGreaterThan(_voiceoverPlayer.playCount, 0,
                       @"VO slot must play when boundary timer fires at PTS=3.0");

  [self invalidateAndWait:rt];
}

// ─── K-T14: Boundary timer delay corrected after early completion ─────────────

/// After a DataConsumed completion fires early with the VO activation-floor
/// guard suppressing an idle VO slot, the boundary timer must be armed for
///   delay = voStart − activationFloor   (real-time equivalent of voStart)
/// NOT for
///   delay = nextBoundary − evaluationPTS  (which overshoots by ~3 s)
///
/// Setup: music [0,10) + VO [3,7). First segment [0,3). Completion at PTS=2.05.
///   evaluationPTS = MAX(2.05, 3.0) = 3.0   — VO guard suppresses (2.05 < 3.0)
///   timerBase     = activationFloor = 2.05
///   suppressedVOStart = 3.0
///   expected delay = 3.0 − 2.05 = 0.95 s
///   wrong   delay = nextBoundary(7.0) − evaluationPTS(3.0) = 4.0 s
- (void)testK_T14_earlyCompletionTimerDelayIsVOStartMinusActivationFloor {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .timelinePTS = 0.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-K14"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-K14"
                                                startTime:3.0
                                                 duration:4.0  // [3, 7)
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // After commandPlay the initial boundary timer is armed for the first future
  // boundary from PTS=0, which is voStart=3.0 (delay 3.0 s).
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 3.0, 0.01,
                             @"Initial boundary timer must target voStart=3.0 "
                             @"(delay 3.0 s from PTS=0)");

  // Capture the completion handler from the initial AddedAudio segment.
  AVAudioPlayerNodeCompletionHandler earlyCompletion =
      _player.lastCompletionHandler;

  // Simulate DataConsumed firing at PTS=2.05 (capturedScheduledEndPTS=3.0).
  // authoritativePTS=2.05, evaluationPTS=MAX(2.05,3.0)=3.0.
  _clock.currentTime = 2.05;

  if (earlyCompletion) {
    earlyCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // ─── Critical assertion: timer delay = voStart − activationFloor ─────────
  // activationFloor = authoritativePTS = 2.05
  // suppressedVOStart = 3.0
  // expected delay = 3.0 − 2.05 = 0.95 s  ← correct (Bug 1 fix)
  // wrong   delay = nextBoundary(7.0) − evaluationPTS(3.0) = 4.0 s  ← pre-fix
  double const kVOStart         = 3.0;
  double const kActivationFloor = 2.05;
  double const expectedDelay    = kVOStart - kActivationFloor; // 0.95
  XCTAssertEqualWithAccuracy(_timer.lastDelay, expectedDelay, 0.005,
                             @"Boundary timer must be armed for voStart − "
                             @"activationFloor = %.3f s (was nextBoundary − "
                             @"evaluationPTS = 4.0 s before fix). Got %.3f s",
                             expectedDelay, _timer.lastDelay);

  // VO must still be idle — activationFloor (2.05) has not reached voStart (3.0).
  XCTAssertEqual(_voiceoverPlayer.scheduleCount, 0,
                 @"VO slot must NOT be activated when completion fires at PTS=2.05");
  XCTAssertEqual(_voiceoverPlayer.playCount, 0,
                 @"VO slot must NOT play when completion fires early at PTS=2.05");

  // AddedAudio must have rescheduled its continuation segment [3,7).
  XCTAssertEqual(_player.scheduleCount, 2,
                 @"AddedAudio must schedule continuation segment (music [3,7)) "
                 @"after early completion at PTS=2.05");

  [self invalidateAndWait:rt];
}


// ─── K-T15: Voiceover early terminal completion defers stop ─────────────────

/// Music [0,10) + VO [3,7). VO DataConsumed fires early at authoritative
/// PTS=6.2 (capturedScheduledEndPTS=7.0). Because activationFloor (6.2) <
/// scheduledEndPTS (7.0) - epsilon, the runtime must NOT stop the VO player.
/// Instead it must arm the boundary timer for the remaining 0.8 s.
/// When the timer fires at real PTS=7.0 the VO player is stopped and cleaned
/// up; music (AddedAudio) must be unaffected throughout.
- (void)testK_T15_voiceoverEarlyTerminalCompletionDefersStop {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  // Start at PTS=3: both music and VO are already active.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 3.0, .playStartHostTime = 0.0,
      .timelinePTS = 3.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-K15"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-K15"
                                                startTime:3.0
                                                 duration:4.0   // [3, 7)
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Both slots must be scheduled and playing at PTS=3.
  XCTAssertGreaterThan(_player.scheduleCount, 0,
                       @"AddedAudio must schedule at PTS=3");
  XCTAssertGreaterThan(_voiceoverPlayer.scheduleCount, 0,
                       @"VO must schedule at PTS=3");

  // Capture the VO completion handler (set by the last scheduleSegment call
  // on _voiceoverPlayer).
  AVAudioPlayerNodeCompletionHandler voCompletion =
      _voiceoverPlayer.lastCompletionHandler;

  NSInteger voStopBefore    = _voiceoverPlayer.stopCount;
  NSInteger addedStopBefore = _player.stopCount;

  // Simulate VO DataConsumed firing early at authoritativePTS = 6.2.
  // capturedScheduledEndPTS = 7.0 → evaluationPTS = MAX(6.2, 7.0) = 7.0.
  // activationFloor (crossLaneActivationFloor) = 6.2.
  // 6.2 < 7.0 - 0.001 → deferred stop.
  _clock.currentTime = 6.2; // elapsed from playStartHostTime=0 → PTS = 3+6.2... but
                              // the mock clock is read by _currentPTSFromSnapshot which
                              // uses playStartPTS + (currentTime - playStartHostTime).
                              // playStartHostTime=0, playStartPTS=3 → PTS = 3 + 6.2 = 9.2
                              // That's past 7 — so reset the snapshot to play from PTS=0.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .timelinePTS = 0.0};
  _clock.currentTime = 6.2; // PTS = 0 + 6.2 = 6.2 ✓

  if (voCompletion) {
    voCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // ─── Critical assertion: VO player must NOT have been stopped ───────────
  XCTAssertEqual(_voiceoverPlayer.stopCount, voStopBefore,
                 @"VO player must NOT be stopped when DataConsumed fires early "
                 @"at PTS=6.2 with scheduledEndPTS=7.0 — deferred stop expected");

  // AddedAudio must also not have been stopped by the VO completion.
  XCTAssertEqual(_player.stopCount, addedStopBefore,
                 @"AddedAudio must not be stopped during VO deferred-stop path");

  // Boundary timer must be armed for the remaining 0.8 s (7.0 - 6.2 = 0.8).
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 0.8, 0.02,
                             @"Boundary timer must target scheduledEndPTS - "
                             @"activationFloor = 7.0 - 6.2 = 0.8 s. Got %.3f",
                             _timer.lastDelay);

  // ─── Fire boundary timer at real PTS = 7.0 ────────────────────────────
  _clock.currentTime = 7.0;
  [_timer fireForcefully];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Now VO must have been stopped.
  XCTAssertGreaterThan(_voiceoverPlayer.stopCount, voStopBefore,
                       @"VO player must be stopped once real PTS reaches 7.0");

  // AddedAudio must still not have been stopped (it continues to 10.0).
  XCTAssertEqual(_player.stopCount, addedStopBefore,
                 @"AddedAudio must not be stopped at VO end — music continues");

  [self invalidateAndWait:rt];
}

// ─── K-T16: AddedAudio early terminal completion defers stop ────────────────

/// Symmetric of K-T15 for the AddedAudio lane.
/// AddedAudio [0,5) + VO [0,10). AddedAudio DataConsumed fires early at
/// authoritative PTS=4.2 (capturedScheduledEndPTS=5.0). Runtime must defer
/// AddedAudio stop; VO must remain unaffected.
- (void)testK_T16_addedAudioEarlyTerminalCompletionDefersStop {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  // Start at PTS=1: inside AddedAudio [0,5) and VO [0,10).
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .timelinePTS = 0.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-K16"
                                             startTime:0.0
                                              duration:5.0   // [0, 5)
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-K16"
                                                startTime:0.0
                                                 duration:10.0   // [0, 10)
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Both slots must have scheduled.
  XCTAssertGreaterThan(_player.scheduleCount, 0,
                       @"AddedAudio must schedule at PTS=0");
  XCTAssertGreaterThan(_voiceoverPlayer.scheduleCount, 0,
                       @"VO must schedule at PTS=0");

  // Capture the AddedAudio completion handler.
  AVAudioPlayerNodeCompletionHandler addedCompletion =
      _player.lastCompletionHandler;

  NSInteger addedStopBefore = _player.stopCount;
  NSInteger voStopBefore    = _voiceoverPlayer.stopCount;

  // Simulate AddedAudio DataConsumed firing early at authoritativePTS = 4.2.
  // capturedScheduledEndPTS = 5.0 → evaluationPTS = MAX(4.2, 5.0) = 5.0.
  // activationFloor = 4.2. 4.2 < 5.0 - 0.001 → deferred stop.
  _clock.currentTime = 4.2;

  if (addedCompletion) {
    addedCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // ─── Critical assertion: AddedAudio player must NOT be stopped ──────────
  XCTAssertEqual(_player.stopCount, addedStopBefore,
                 @"AddedAudio player must NOT be stopped when DataConsumed "
                 @"fires early at PTS=4.2 with scheduledEndPTS=5.0");

  // VO must not have been stopped by the AddedAudio completion path.
  XCTAssertEqual(_voiceoverPlayer.stopCount, voStopBefore,
                 @"VO player must not be stopped during AddedAudio deferred-stop path");

  // Timer must be armed for ~0.8 s (5.0 - 4.2 = 0.8).
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 0.8, 0.02,
                             @"Boundary timer must target scheduledEndPTS - "
                             @"activationFloor = 5.0 - 4.2 = 0.8 s. Got %.3f",
                             _timer.lastDelay);

  // ─── Fire boundary timer at real PTS = 5.0 ────────────────────────────
  _clock.currentTime = 5.0;
  [_timer fireForcefully];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // AddedAudio must now have been stopped.
  XCTAssertGreaterThan(_player.stopCount, addedStopBefore,
                       @"AddedAudio player must be stopped once real PTS reaches 5.0");

  // VO must still not have been stopped (it continues to 10.0).
  XCTAssertEqual(_voiceoverPlayer.stopCount, voStopBefore,
                 @"VO player must not be stopped at AddedAudio end — VO continues");

  [self invalidateAndWait:rt];
}

// ─── K-T17: commandPause during deferred stop clears deferred state ──────────

/// Verifies that commandPause (→ _cancelAndIncrementSerial:) hard-stops both
/// players even if a VO deferred stop is in progress. No residual deferred
/// cleanup must fire after pause.
- (void)testK_T17_deferredStopClearedByPause {
  double sr = 44100.0, fileDur = 10.0;
  NSString *path = [self _setupRealWAVWithDuration:fileDur sampleRate:sr];
  if (!path) { XCTSkip(@"temp WAV needed"); return; }

  _voiceoverPlayer = [[VGAPr_MockPlayer alloc] init];
  _voiceoverAutomationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  VanguardAudioPreviewRuntime *rt = [self makeMultiSlotRuntime];

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .isValid = YES, .isPlaying = YES, .generation = 1,
      .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .timelinePTS = 0.0};
  _clock.currentTime = 0.0;

  NSDictionary *musicDict = [self musicTrackDictWithId:@"music-K17"
                                             startTime:0.0
                                              duration:10.0
                                                volume:1.0
                                                   url:path];
  NSDictionary *voDict   = [self voiceoverTrackDictWithId:@"vo-K17"
                                                startTime:3.0
                                                 duration:4.0   // [3, 7)
                                                   volume:1.0
                                                      url:path];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[musicDict, voDict]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Advance clock to inside the VO window and fire boundary timer so VO starts.
  _clock.currentTime = 3.0;
  [_timer fireForcefully];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertGreaterThan(_voiceoverPlayer.scheduleCount, 0,
                       @"VO must have scheduled after boundary timer at PTS=3");

  // Capture VO completion handler.
  AVAudioPlayerNodeCompletionHandler voCompletion =
      _voiceoverPlayer.lastCompletionHandler;

  // Trigger VO deferred stop at PTS=6.2 (same as K-T15).
  _clock.currentTime = 6.2;
  if (voCompletion) {
    voCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Deferred stop is active — VO player should not yet be stopped.
  NSInteger voStopAfterDefer    = _voiceoverPlayer.stopCount;
  NSInteger addedStopAfterDefer = _player.stopCount;

  // Arm count before pause (the timer was re-armed for the deferred cleanup).
  NSInteger timerCancelBefore = _timer.cancelCount;

  // Issue commandPause — this must cancel the boundary timer and stop both
  // players immediately, regardless of the pending deferred state.
  [rt commandPause];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  // Boundary timer must have been cancelled by _cancelAndIncrementSerial:.
  XCTAssertGreaterThan(_timer.cancelCount, timerCancelBefore,
                       @"commandPause must cancel the boundary timer");

  // Both players must have been stopped by commandPause.
  XCTAssertGreaterThan(_voiceoverPlayer.stopCount, voStopAfterDefer,
                       @"commandPause must stop VO player even during deferred stop");
  XCTAssertGreaterThan(_player.stopCount, addedStopAfterDefer,
                       @"commandPause must stop AddedAudio player");

  // After pause the boundary timer must be idle — no deferred cleanup should
  // fire. Firing it now must be a no-op (stale token / not accepting commands).
  NSInteger voStopAfterPause    = _voiceoverPlayer.stopCount;
  NSInteger addedStopAfterPause = _player.stopCount;
  [_timer fireForcefully];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{}];

  XCTAssertEqual(_voiceoverPlayer.stopCount, voStopAfterPause,
                 @"No additional VO stop must occur after pause when stale "
                 @"deferred cleanup timer fires");
  XCTAssertEqual(_player.stopCount, addedStopAfterPause,
                 @"No additional AA stop must occur after pause");

  [self invalidateAndWait:rt];
}

@end


NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH

