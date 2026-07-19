// VanguardAudioPreviewRuntimeTest_SliceF_Sequences.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (SliceFSequences) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (SliceFSequences)



// SF-T12: sequential originals -- boundary timer fires and orig-B is actually
//         scheduled. KVC assertions verify descriptor identity and state.
- (void)testSF_T12_sequentialOriginalsTimerArmedAtFirstEnd {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3); orig-B: [4, 5). Gap at [3, 4). PTS starts at 0.5.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.5 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:4.0 duration:1.0 volume:0.8 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Phase 1: orig-A must be scheduled; timer armed at A-end (T=3.0).
  XCTAssertGreaterThan(_player.scheduleCount, 0, @"orig-A must be scheduled");
  XCTAssertGreaterThan(_timer.armCount, 0, @"boundary timer must be armed at A-end");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 2.5, 0.2,
                             @"delay == 3.0 (A-end) - 0.5 (PTS) = 2.5 s");
  // KVC: confirm orig-A is the active descriptor.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-A",
                          @"active descriptor must be orig-A after Phase 1");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after Phase 1");
  }];

  // Phase 2: advance to T=3.0 (gap), fire timer -> silence + new timer for B.
  NSInteger schedCountAfterA = _player.scheduleCount;
  NSInteger playCountAfterA = _player.playCount;
  NSInteger armCountAfterA = _timer.armCount;
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  XCTAssertGreaterThan(_timer.armCount, armCountAfterA,
                       @"timer must rearm for B-start during gap");
  XCTAssertEqual(_player.scheduleCount, schedCountAfterA,
                 @"must not schedule during gap");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    XCTAssertEqual(state, VGAudioPreviewRuntimeStateWaitingForTrackStart,
                   @"runtime must be WaitingForTrackStart during gap");
  }];

  // Phase 3: advance to T=4.0 (orig-B start), fire timer -> B scheduled.
  _stubbedSnapshot.timelinePTS = 4.0;
  _stubbedSnapshot.playStartPTS = 4.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterA,
                       @"orig-B must be scheduled after B-start timer fires");
  XCTAssertGreaterThan(_player.playCount, playCountAfterA,
                       @"player must play orig-B");
  // KVC: confirm orig-B is now the active descriptor.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"active descriptor must be orig-B after Phase 3");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after orig-B starts");
  }];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.8f, 0.01f,
                             @"volume must match orig-B's staticVolume");
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)0,
                 @"orig-B starts at source frame 0 (PTS == B.timelineStart)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T13: exact same-PTS boundary -- orig-A ends at T, orig-B starts at T.
//         The boundary timer must fire, select B, and schedule it from frame 0.
- (void)testSF_T13_exactBoundaryAtoB {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3); orig-B: [3, 5) - B starts exactly where A ends.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.5 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:3.0 duration:2.0 volume:0.8 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // A scheduled; timer armed at T=3.0 (nextBoundary == trackEnd).
  XCTAssertGreaterThan(_player.scheduleCount, 0, @"orig-A must be scheduled");
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"boundary timer must arm at exact-end boundary T=3.0");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 2.5, 0.2,
                             @"delay == 3.0 - 0.5 = 2.5 s");

  NSInteger schedCountAfterA = _player.scheduleCount;
  NSInteger playCountAfterA = _player.playCount;

  // Advance to T=3.0 and fire timer -> B must be scheduled immediately.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterA,
                       @"orig-B must be scheduled at exact boundary T=3.0");
  XCTAssertGreaterThan(_player.playCount, playCountAfterA,
                       @"player must play orig-B");
  // B.timelineStart==PTS -> trackRelative=0 -> sourcePosition=0 -> startFrame=0.
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)0,
                 @"orig-B starts at source frame 0");
  // KVC: prove active descriptor is orig-B, not orig-A.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"active descriptor must be orig-B after transition");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after orig-B is scheduled");
  }];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.8f, 0.01f,
                             @"volume must be orig-B's staticVolume (0.8)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T14: music restoration -- original spans full timeline, music [0,4).
//         At music end T=4, original resumes from correct mid-track source frame.
- (void)testSF_T14_musicRestorationAtMusicEnd {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-full: [0, 10). music-part: [0, 4). Music wins until T=4.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-full"
      startTime:0.0 duration:10.0 volume:0.6 url:url.path];
  NSDictionary *music = [self musicTrackDictWithId:@"music-part"
      startTime:0.0 duration:4.0 volume:1.0 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig, music ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Music scheduled at PTS=0; timer armed at T=4.0 (music trackEnd).
  XCTAssertGreaterThan(_player.scheduleCount, 0, @"music must be scheduled");
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"boundary timer must arm at music end T=4.0");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 4.0, 0.25,
                             @"delay == 4.0 (music-end) - 0.0 (PTS) = 4.0 s");
  // KVC: music-part is initially active.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"music-part",
                          @"music-part must be active initially");
  }];

  NSInteger schedCountAfterMusic = _player.scheduleCount;
  NSInteger playCountAfterMusic = _player.playCount;

  // Advance to T=4.0 and fire timer -> original resumes mid-track.
  _stubbedSnapshot.timelinePTS = 4.0;
  _stubbedSnapshot.playStartPTS = 4.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  // sourcePosition = trimStart(0) + (PTS(4.0) - timelineStart(0)) = 4.0 s
  // startFrame = floor(4.0 * 44100) = 176400.
  AVAudioFramePosition expectedFrame = (AVAudioFramePosition)(4.0 * sr);
  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterMusic,
                       @"original must be scheduled after music ends");
  XCTAssertGreaterThan(_player.playCount, playCountAfterMusic,
                       @"player must play original after music ends");
  XCTAssertEqual(_player.lastStartFrame, expectedFrame,
                 @"original scheduled from correct mid-track source frame (4.0s)");
  // KVC: orig-full must now be the active descriptor.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-full",
                          @"orig-full must be active after music ends");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after original resumes");
  }];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.6f, 0.01f,
                             @"volume must match orig-full staticVolume (0.6)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T15: gap transition -- orig-A [0,2), gap [2,5), orig-B [5,7).
//         Phase 1: A-end fires -> silence, new timer for B.
//         Phase 2: B-start fires -> B scheduled at source frame 0.
- (void)testSF_T15_gapTransitionAEndsThenBScheduled {
  double sr = 44100.0, fileDur = 7.0;
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
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:2.0 volume:0.5 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:5.0 duration:2.0 volume:0.9 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Phase 1: A scheduled; timer armed at T=2.0 (A-end == nextBoundary).
  XCTAssertGreaterThan(_player.scheduleCount, 0, @"orig-A must be scheduled");
  XCTAssertGreaterThan(_timer.armCount, 0, @"boundary timer must arm at A-end T=2.0");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 2.0, 0.2,
                             @"delay == 2.0 (A-end) - 0.0 (PTS) = 2.0 s");

  NSInteger schedCountAfterA = _player.scheduleCount;
  NSInteger playCountAfterA = _player.playCount;
  NSInteger armCountAfterA = _timer.armCount;

  // Fire A-end boundary at T=2.0 -> gap: no scheduling, timer re-arms for B.
  _stubbedSnapshot.timelinePTS = 2.0;
  _stubbedSnapshot.playStartPTS = 2.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  XCTAssertGreaterThan(_timer.armCount, armCountAfterA,
                       @"timer must rearm for B-start T=5.0 during gap");
  XCTAssertEqual(_player.scheduleCount, schedCountAfterA,
                 @"must not schedule during gap");
  XCTAssertEqual(_player.playCount, playCountAfterA,
                 @"player must not play during gap");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStateWaitingForTrackStart,
                   @"must be WaitingForTrackStart during gap");
  }];

  // Fire B-start timer at T=5.0 -> B scheduled at source frame 0.
  _stubbedSnapshot.timelinePTS = 5.0;
  _stubbedSnapshot.playStartPTS = 5.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterA,
                       @"orig-B must be scheduled at B-start T=5.0");
  XCTAssertGreaterThan(_player.playCount, playCountAfterA,
                       @"player must play orig-B");
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)0,
                 @"orig-B starts at source frame 0 (PTS == B.timelineStart)");
  // KVC: prove descriptor identity and state.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"active descriptor must be orig-B after gap");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after orig-B starts");
  }];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.9f, 0.01f,
                             @"volume must be orig-B staticVolume (0.9)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// SF-T23: Completion fires while snapshot clock is behind the segment end.
//   The runtime must use MAX(snapshotPTS, capturedEndPTS) as evaluationPTS,
//   NOT reschedule the same completed descriptor from before the end.
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSF_T23_completionUsesMaxEvalPTSWhenSnapshotBehind {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // Single original [0, 3). timelineDuration=3 so trackEnd==timelineDuration.
  // PTS=0, segment ends at T=3.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.8 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:3.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 1, @"SF-T23: segment must be scheduled");
  AVAudioPlayerNodeCompletionHandler completionHandler =
      _player.lastCompletionHandler;
  XCTAssertNotNil(completionHandler, @"SF-T23: completion handler must be set");

  NSInteger schedBeforeCompletion = _player.scheduleCount;

  // Simulate: snapshot clock is still at PTS=1.0 (behind the segment end T=3)
  // when completion fires.  The runtime must use evaluationPTS=3.0 (the
  // capturedScheduledEndPTS) and transition to Ended, NOT reschedule orig-A.
  _stubbedSnapshot.timelinePTS = 1.0;
  _stubbedSnapshot.playStartPTS = 1.0;
  if (completionHandler) {
    completionHandler(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.3];

  // Must NOT reschedule orig-A.
  XCTAssertEqual(_player.scheduleCount, schedBeforeCompletion,
                 @"SF-T23: completed segment must NOT be rescheduled when "
                 @"snapshot clock is behind");

  // Runtime must remain Playing initially due to deferred stop.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    XCTAssertEqual(state, VGAudioPreviewRuntimeStatePlaying,
                   @"SF-T23: runtime must remain Playing (deferred stop) when snapshot is behind");
  }];

  // Now advance the snapshot PTS to the physical end and fire the timer to finalize termination.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  // Now the runtime must be Ended.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    XCTAssertEqual(state, VGAudioPreviewRuntimeStateEnded,
                   @"SF-T23: runtime must be Ended after boundary timer fires at T=3");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// G-T7: music → sfx sequential transition at exact boundary.
//   music-A: [0, 3). sfx-B: [3, 5). PTS starts at 0.5.
//   After the boundary timer fires at T=3, sfx-B must become the active
//   descriptor and be scheduled — proving cross-role sequential preview works.
- (void)testG_T7_sequentialMusicToSfxTransition {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // music-A: [0, 3); sfx-B: [3, 5) — exact boundary, no gap.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *musicA = [self musicTrackDictWithId:@"music-A"
      startTime:0.0 duration:3.0 volume:0.7 url:url.path];
  NSDictionary *sfxB = @{
    @"trackId" : @"sfx-B",
    @"role" : @"sfx",
    @"url" : url.path,
    @"startTime" : @(3.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(2.0),
    @"volume" : @(0.9),
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ musicA, sfxB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Phase 1: music-A scheduled; boundary timer armed at T=3.0.
  XCTAssertGreaterThan(_player.scheduleCount, 0, @"music-A must be scheduled");
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"boundary timer must arm at music-A end T=3.0");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 2.5, 0.2,
                             @"delay == 3.0 - 0.5 (PTS) = 2.5 s");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"music-A",
                          @"music-A must be the active descriptor initially");
    XCTAssertEqualObjects(d.role, @"music",
                          @"initial role must be music");
  }];

  NSInteger schedCountAfterMusic = _player.scheduleCount;
  NSInteger playCountAfterMusic = _player.playCount;

  // Phase 2: advance to T=3.0 (sfx-B start), fire boundary timer.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  // sfx-B must be scheduled immediately at the exact boundary.
  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterMusic,
                       @"sfx-B must be scheduled after music-A ends at T=3.0");
  XCTAssertGreaterThan(_player.playCount, playCountAfterMusic,
                       @"player must play sfx-B");
  // B.timelineStart==PTS -> trackRelative=0 -> startFrame=0.
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)0,
                 @"sfx-B must start at source frame 0 (PTS == B.timelineStart)");
  // KVC: prove sfx-B is now the active descriptor, not music-A.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"sfx-B",
                          @"active descriptor must be sfx-B after transition");
    XCTAssertEqualObjects(d.role, @"sfx",
                          @"role must be sfx after transition from music");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after sfx-B is scheduled");
  }];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 0.9f, 0.01f,
                             @"volume must match sfx-B staticVolume (0.9)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// G-T8: sfx → voiceover sequential transition at exact boundary.
//   sfx-A: [0, 3). voiceover-B: [3, 5). PTS starts at 0.5.
//   After the boundary timer fires at T=3, voiceover-B must become the active
//   descriptor and be scheduled — proving sfx-to-voiceover transition works.
- (void)testG_T8_sequentialSfxToVoiceoverTransition {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // sfx-A: [0, 3); voiceover-B: [3, 5) — exact boundary, no gap.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *sfxA = @{
    @"trackId" : @"sfx-A",
    @"role" : @"sfx",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(3.0),
    @"volume" : @(0.8),
  };
  NSDictionary *voiceoverB = @{
    @"trackId" : @"vo-B",
    @"role" : @"voiceover",
    @"url" : url.path,
    @"startTime" : @(3.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(2.0),
    @"volume" : @(1.0),
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ sfxA, voiceoverB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Phase 1: sfx-A scheduled; boundary timer armed at T=3.0.
  XCTAssertGreaterThan(_player.scheduleCount, 0, @"sfx-A must be scheduled");
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"boundary timer must arm at sfx-A end T=3.0");
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 2.5, 0.2,
                             @"delay == 3.0 - 0.5 (PTS) = 2.5 s");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"sfx-A",
                          @"sfx-A must be the active descriptor initially");
    XCTAssertEqualObjects(d.role, @"sfx",
                          @"initial role must be sfx");
  }];

  NSInteger schedCountAfterSfx = _player.scheduleCount;
  NSInteger playCountAfterSfx = _player.playCount;

  // Phase 2: advance to T=3.0 (voiceover-B start), fire boundary timer.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  // voiceover-B must be scheduled immediately at the exact boundary.
  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterSfx,
                       @"voiceover-B must be scheduled after sfx-A ends at T=3.0");
  XCTAssertGreaterThan(_player.playCount, playCountAfterSfx,
                       @"player must play voiceover-B");
  // B.timelineStart==PTS -> trackRelative=0 -> startFrame=0.
  XCTAssertEqual(_player.lastStartFrame, (AVAudioFramePosition)0,
                 @"voiceover-B must start at source frame 0");
  // KVC: prove voiceover-B is now the active descriptor, not sfx-A.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"vo-B",
                          @"active descriptor must be vo-B after transition");
    XCTAssertEqualObjects(d.role, @"voiceover",
                          @"role must be voiceover after transition from sfx");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"runtime must be Playing after voiceover-B is scheduled");
  }];
  XCTAssertEqualWithAccuracy(_player.lastVolume, 1.0f, 0.01f,
                             @"volume must match voiceover-B staticVolume (1.0)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
