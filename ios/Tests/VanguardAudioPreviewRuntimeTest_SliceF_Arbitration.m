// VanguardAudioPreviewRuntimeTest_SliceF_Arbitration.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (Arbitration) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (Arbitration)


// SF-T3: single original descriptor -> Ready, engine starts once
- (void)testSF_T3_singleOriginalDescriptorReturnsReady {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *dict = [self originalTrackDictWithId:@"orig-1"
      startTime:0.0 duration:5.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ dict ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady,
                 @"single original must yield Ready");
  XCTAssertEqual(_engine.startCount, 1, @"engine must start exactly once");
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T4: single original descriptor schedules segment when played
- (void)testSF_T4_singleOriginalSchedulesOnPlay {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *dict = [self originalTrackDictWithId:@"orig-1"
      startTime:0.0 duration:5.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ dict ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_player.scheduleCount, 0, @"must schedule original segment");
  XCTAssertGreaterThan(_player.playCount, 0, @"must play");
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T5: silent gap before later original arms timer
- (void)testSF_T5_silentGapBeforeOriginalArmsTimer {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *dict = [self originalTrackDictWithId:@"orig-1"
      startTime:3.0 duration:5.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ dict ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.armCount, 0, @"boundary timer must be armed");
  XCTAssertEqual(_player.playCount, 0, @"must not play during gap");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 2.5, 0.15,
                             @"delay must equal trackStart(3.0) - PTS(0.5) = 2.5");
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T6: music priority over simultaneously active original
- (void)testSF_T6_musicPriorityOverOriginal {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 1.0, .playStartPTS = 1.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:8.0 volume:0.6 url:url.path];
  NSDictionary *music = [self musicTrackDictWithId:@"music-1"
      startTime:0.0 duration:8.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig, music ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqualWithAccuracy(_player.lastVolume, 1.0f, 0.01f,
                             @"music (vol 1.0) must win over original (vol 0.6)");
  XCTAssertGreaterThan(_player.scheduleCount, 0, @"must schedule");
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T10: overlapping originals -- latest startTime wins
- (void)testSF_T10_overlappingOriginalsLatestStartWins {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 3.0, .playStartPTS = 3.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:8.0 volume:0.6 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:2.0 duration:6.0 volume:0.9 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.9f, 0.01f,
                             @"orig-B (later start) must win -- vol=0.9");
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T11: half-open boundary -- PTS at trackEnd is exclusive (no scheduling)
- (void)testSF_T11_halfOpenBoundaryEndIsExclusive {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 5.0, .playStartPTS = 5.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *dict = [self originalTrackDictWithId:@"orig-1"
      startTime:0.0 duration:5.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ dict ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 0,
                 @"scheduleSegment must NOT be called at exclusive trackEnd");
  XCTAssertEqual(_player.playCount, 0,
                 @"player must not play at exclusive trackEnd");
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T20: ORIGINAL -> MUSIC TRANSITION
//   orig is playing when music starts later. Fire the music-start boundary.
//   Assert active descriptor switches to music.
- (void)testSF_T20_originalToMusicTransition {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig: [0, 10), music: [4, 8). At PTS=0 orig plays. At T=4 music wins.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:10.0 volume:0.6 url:url.path];
  NSDictionary *music = [self musicTrackDictWithId:@"music-1"
      startTime:4.0 duration:4.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig, music ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // At PTS=0.5 orig-A must be playing; timer armed for T=4.0 (music start).
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-A",
                          @"orig-A must be active initially");
  }];
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"boundary timer must be armed for music-start T=4.0");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 3.5, 0.5,
                             @"timer delay ~= T=4.0 - PTS=0.5 = 3.5 s");

  NSInteger schedCountBefore = _player.scheduleCount;
  // Advance to T=4.0 and fire the timer -> music must win.
  _stubbedSnapshot.timelinePTS = 4.0;
  _stubbedSnapshot.playStartPTS = 4.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  XCTAssertGreaterThan(_player.scheduleCount, schedCountBefore,
                       @"music must be scheduled at T=4.0");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"music-1",
                          @"active descriptor must be music-1 after transition");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after music starts");
  }];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 1.0f, 0.01f,
                             @"volume must be music-1 staticVolume (1.0)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T21: SEEK INTO LATER ORIGINAL
//   Seek directly into orig-B (which starts later on the timeline).
//   Assert track identity and correct source start frame.
- (void)testSF_T21_seekIntoLaterOriginal {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 5), orig-B: [6, 10). Seek to PTS=7.0 (inside orig-B).
  // At PTS=7.0 inside orig-B: trackRelative = 7.0 - 6.0 = 1.0 s
  //   sourcePosition = trimStart(0) + 1.0 = 1.0 s
  //   expectedFrame = floor(1.0 * 44100) = 44100.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 7.0, .playStartPTS = 7.0, .playStartHostTime = 0.0,
      .generation = 2, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:5.0 volume:0.5 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:6.0 duration:4.0 volume:0.9 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  // commandPlay with snapshot already at T=7.0 inside orig-B.
  [rt commandPlay];
  [self waitFor:0.3];

  // orig-B must be selected and scheduled from the correct source frame.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"orig-B must be active after seeking into its range");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after seek into orig-B");
  }];
  // sourceFrame = floor((trimStart + (PTS - timelineStart)) * sr)
  //             = floor((0 + (7.0 - 6.0)) * 44100) = 44100
  AVAudioFramePosition expectedFrame = (AVAudioFramePosition)(1.0 * sr);
  XCTAssertEqual(_player.lastStartFrame, expectedFrame,
                 @"seek into orig-B must start from the correct source frame");
  XCTAssertGreaterThan(_player.scheduleCount, 0,
                       @"orig-B must be scheduled after seek");
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.9f, 0.01f,
                             @"volume must be orig-B staticVolume (0.9)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// SF-T22: Original [0,10), Music starts at T=3.
//   The first Original segment must be clipped at T=3 (music-start boundary),
//   NOT at T=10 (track end).  Assert lastFrameCount == 3*sr, not 10*sr.
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSF_T22_originalSegmentClippedAtMusicStartBoundary {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig: [0, 10). music: [3, 8). PTS starts at 0.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:10.0 volume:0.6 url:url.path];
  NSDictionary *music = [self musicTrackDictWithId:@"music-1"
      startTime:3.0 duration:5.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig, music ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // At PTS=0 orig-A is active. The next decision boundary is T=3 (music start).
  // The scheduled segment must end at T=3, not T=10.
  //   expectedFrameCount = (3.0 - 0.0) * sr = 3 * 44100 = 132300 frames.
  AVAudioFrameCount expectedFrames = (AVAudioFrameCount)(3.0 * sr);
  AVAudioFrameCount wrongFrames   = (AVAudioFrameCount)(10.0 * sr);

  XCTAssertEqual(_player.scheduleCount, 1,
                 @"SF-T22: exactly one segment must be scheduled");
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)0,
                 @"SF-T22: start frame must be 0 (PTS=0 == orig.timelineStart)");
  XCTAssertEqual(_player.lastFrameCount, expectedFrames,
                 @"SF-T22: frame count must end at T=3 (music start), not T=10");
  XCTAssertNotEqual(_player.lastFrameCount, wrongFrames,
                    @"SF-T22: frame count must NOT extend to T=10");

  // KVC: orig-A is the active descriptor.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-A",
                          @"SF-T22: orig-A must be the active descriptor");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// SF-T25: Original → Music → Original transition chain.
//   orig-full: [0, 10), music-part: [2, 5).
//   Assert:
//     1. Original is clipped at T=2 (music start);
//     2. Music begins from source frame 0 (music.timelineStart == T=2);
//     3. After music ends at T=5, original resumes from the correct mid-track
//        source frame = floor((0 + (5.0 - 0.0)) * sr) = 5*sr.
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSF_T25_originalMusicOriginalChain {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-full: [0, 10), music-part: [2, 5). PTS starts at 0.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-full"
      startTime:0.0 duration:10.0 volume:0.5 url:url.path];
  NSDictionary *music = [self musicTrackDictWithId:@"music-part"
      startTime:2.0 duration:3.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig, music ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // ── Phase 1: Original clipped at T=2 ────────────────────────────────────
  // At PTS=0, orig-full is active. nextDecision = T=2 (music start).
  // Segment must end at T=2, frame count = 2*sr.
  XCTAssertEqual(_player.scheduleCount, 1,
                 @"SF-T25 Ph1: exactly one segment scheduled");
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)0,
                 @"SF-T25 Ph1: orig start frame = 0");
  AVAudioFrameCount expectedOrigFrames = (AVAudioFrameCount)(2.0 * sr);
  XCTAssertEqual(_player.lastFrameCount, expectedOrigFrames,
                 @"SF-T25 Ph1: orig frame count must end at T=2 (music start)");
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"SF-T25 Ph1: boundary timer must be armed at T=2");

  NSInteger schedAfterPhase1 = _player.scheduleCount;
  NSInteger playAfterPhase1  = _player.playCount;

  // ── Phase 2: Advance to T=2, fire timer → Music starts ──────────────────
  _stubbedSnapshot.timelinePTS = 2.0;
  _stubbedSnapshot.playStartPTS = 2.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  XCTAssertGreaterThan(_player.scheduleCount, schedAfterPhase1,
                       @"SF-T25 Ph2: music must be scheduled at T=2");
  XCTAssertGreaterThan(_player.playCount, playAfterPhase1,
                       @"SF-T25 Ph2: player must play music");
  // Music.timelineStart=2 == PTS=2 → sourcePosition=0 → startFrame=0.
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)0,
                 @"SF-T25 Ph2: music starts from source frame 0");
  // Music segment = [2, 5): frame count = 3*sr.
  AVAudioFrameCount expectedMusicFrames = (AVAudioFrameCount)(3.0 * sr);
  XCTAssertEqual(_player.lastFrameCount, expectedMusicFrames,
                 @"SF-T25 Ph2: music frame count must be 3 s (T=2 to T=5)");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"music-part",
                          @"SF-T25 Ph2: music-part must be active");
  }];

  NSInteger schedAfterPhase2 = _player.scheduleCount;
  NSInteger playAfterPhase2  = _player.playCount;

  // ── Phase 3: Advance to T=5, fire timer → Original resumes ──────────────
  _stubbedSnapshot.timelinePTS = 5.0;
  _stubbedSnapshot.playStartPTS = 5.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  XCTAssertGreaterThan(_player.scheduleCount, schedAfterPhase2,
                       @"SF-T25 Ph3: orig must be scheduled after music ends");
  XCTAssertGreaterThan(_player.playCount, playAfterPhase2,
                       @"SF-T25 Ph3: player must play original");
  // sourcePosition = trimStart(0) + (PTS(5.0) - timelineStart(0)) = 5.0 s
  // startFrame = floor(5.0 * 44100) = 220500.
  AVAudioFramePosition expectedResumeFrame = (AVAudioFramePosition)(5.0 * sr);
  XCTAssertEqual(_player.lastStartFrame, expectedResumeFrame,
                 @"SF-T25 Ph3: original must resume from correct mid-track "
                 @"source frame (5.0 s)");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-full",
                          @"SF-T25 Ph3: orig-full must be active after music ends");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"SF-T25 Ph3: runtime must be Playing");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// SF-T26: Seek into Original before a future Music boundary.
//   orig: [0, 10), music: [6, 9). Seek to PTS=4.
//   Assert:
//     - start frame = (0 + (4.0 - 0.0)) * sr = 4*sr (seek position);
//     - frame count ends at T=6 (music-start boundary), not T=10;
//     - boundary timer is armed.
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSF_T26_seekIntoOriginalBeforeMusic {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig: [0, 10), music: [6, 9). Seek PTS=4 (inside orig, before music).
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 4.0, .playStartPTS = 4.0, .playStartHostTime = 0.0,
      .generation = 2, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:10.0 volume:0.6 url:url.path];
  NSDictionary *music = [self musicTrackDictWithId:@"music-1"
      startTime:6.0 duration:3.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig, music ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // At PTS=4, orig-A is active. nextDecision = T=6 (music start).
  // start frame = floor((0 + (4.0 - 0.0)) * sr) = floor(4.0 * 44100) = 176400.
  // frame count = (6.0 - 4.0) * sr = 2 * 44100 = 88200 frames.
  AVAudioFramePosition expectedStartFrame = (AVAudioFramePosition)(4.0 * sr);
  AVAudioFrameCount expectedFrameCount    = (AVAudioFrameCount)(2.0 * sr);

  XCTAssertEqual(_player.scheduleCount, 1,
                 @"SF-T26: exactly one segment must be scheduled");
  XCTAssertEqual(_player.lastStartFrame, expectedStartFrame,
                 @"SF-T26: start frame must reflect seek position (4.0 s)");
  XCTAssertEqual(_player.lastFrameCount, expectedFrameCount,
                 @"SF-T26: frame count must end at T=6 (music-start boundary)");
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"SF-T26: boundary timer must be armed at T=6");

  // KVC: orig-A is the active descriptor.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-A",
                          @"SF-T26: orig-A must be the active descriptor");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"SF-T26: runtime must be Playing");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
