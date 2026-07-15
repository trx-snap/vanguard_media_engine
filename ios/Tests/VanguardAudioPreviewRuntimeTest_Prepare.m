// VanguardAudioPreviewRuntimeTest_Prepare.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (Preparation) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (Preparation)

// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// S-1: testPrepareSelectsFirstValidMusicDictionary
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPrepareSelectsFirstValidMusicDictionary {
  double sr = 44100.0, dur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(dur * sr), sr);
  XCTAssertNotNil(url, @"temp WAV must be created");
  if (!url)
    return;
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&err];

  NSDictionary *invalidDict = @{
    @"trackId" : @"inv1",
    @"role" : @"unknown",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  NSDictionary *musicDict = @{
    @"trackId" : @"m1",
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ invalidDict, musicDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];

  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady,
                 @"must skip invalid-role dict and select first valid music dict (second entry)");
  XCTAssertEqual(_engine.startCount, 1, @"engine must start once");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-2: testPrepareSkipsMalformedMusicAndSelectsNextValidMusic
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPrepareSkipsMalformedMusicAndSelectsNextValidMusic {
  double sr = 44100.0, dur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(dur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV needed");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url
                                                            error:&err];

  // Malformed: no trackId.
  NSDictionary *badDict = @{
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  NSDictionary *goodDict = @{
    @"trackId" : @"m2",
    @"role" : @"music",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ badDict, goodDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];

  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady,
                 @"must skip malformed and use second valid dict");
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-3: testPrepareReturnsSilentWhenNoEligibleMusicTrack
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPrepareReturnsSilentWhenNoEligibleMusicTrack {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:nil
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultSilentNoEligibleTrack);
  XCTAssertEqual(_engine.startCount, 0, @"engine must not start");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-4: testPrepareReportsMissingFileWithoutFailingVideoPreview
//
// When the file provider returns nil with NO error (file does not exist),
// preparation returns FailedMissingFile and engine is not started.
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPrepareReportsMissingFileWithoutFailingVideoPreview {
  // Simulate missing file: fileExistsAtURL: returns NO, open returns nil/no
  // error.
  _fileProvider.fileDoesNotExist = YES;
  _fileProvider.shouldFailWithNoError = YES;

  NSDictionary *trackDict = [self trackDictWithStartTime:0.0
                                                duration:5.0
                                                  volume:1.0];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];

  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedMissingFile,
                 @"missing file must return FailedMissingFile");
  XCTAssertEqual(_engine.startCount, 0, @"engine must not start");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-5: testPrepareReportsUnsupportedFormatWithoutFailingVideoPreview
//
// When the file exists but cannot be opened (provider returns error),
// preparation returns FailedUnsupportedFormat.
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPrepareReportsUnsupportedFormatWithoutFailingVideoPreview {
  // File exists but open fails with error.
  _fileProvider.fileDoesNotExist = NO;
  _fileProvider.shouldFail = YES;

  NSDictionary *trackDict = [self trackDictWithStartTime:0.0
                                                duration:5.0
                                                  volume:1.0];
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];

  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedUnsupportedFormat,
                 @"open-failure must return FailedUnsupportedFormat");
  XCTAssertEqual(_engine.startCount, 0, @"engine must not start");
  [self invalidateAndWait:rt];
}


// ─── Legacy tests (D-T1 through D-T12 migrated from
// VGAudioPreviewRuntimeTest.m) ───

- (void)testD_T1_trackDescriptorRejectsUnknownRole {
  NSDictionary *dict = @{
    @"trackId" : @"t1",
    @"role" : @"unknown",
    @"url" : @"/tmp/x.mp3",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  XCTAssertNil([[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict]);
}


- (void)testD_T2_trackDescriptorRejectsMalformedFields {
  NSDictionary *noId = @{
    @"trackId" : @"",
    @"role" : @"music",
    @"url" : @"/tmp/x.mp3",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  XCTAssertNil([[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:noId]);

  NSDictionary *noUrl = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : @"",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  XCTAssertNil(
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:noUrl]);

  NSDictionary *negStart = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : @"/tmp/x.mp3",
    @"startTime" : @(-1.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  XCTAssertNil(
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:negStart]);

  NSDictionary *badVol = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : @"/tmp/x.mp3",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.5)
  };
  XCTAssertNil(
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:badVol]);
}


- (void)testD_T3_trackDescriptorAcceptsValidMusicTrack {
  NSDictionary *dict = [self trackDictWithStartTime:2.0
                                           duration:10.0
                                             volume:0.8];
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNotNil(d);
  XCTAssertEqualObjects(d.trackId, @"test_music_track");
  XCTAssertEqualWithAccuracy(d.timelineStart, 2.0, 0.001);
  XCTAssertEqualWithAccuracy(d.requestedDuration, 10.0, 0.001);
  XCTAssertEqualWithAccuracy(d.staticVolume, 0.8f, 0.001f);
  XCTAssertEqualWithAccuracy(d.sourceTrimStart, 0.0, 0.001);
}


- (void)testD_T4_prepareWithNilPlanYieldsReadySilent {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:nil
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultSilentNoEligibleTrack);
  XCTAssertEqual(_engine.startCount, 0);
  [self invalidateAndWait:rt];
}


- (void)testD_T5_prepareWithMissingFileYieldsReadySilent {
  _fileProvider.shouldFail = YES;
  NSDictionary *d = [self trackDictWithStartTime:0.0 duration:5.0 volume:1.0];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[ d ]
                                                        volumeKeyframes:nil
                                                          waveformCache:nil
                                                   timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];
  XCTAssertTrue(res == VGAudioPreviewPreparationResultFailedMissingFile ||
                res == VGAudioPreviewPreparationResultFailedUnsupportedFormat);
  XCTAssertEqual(_engine.startCount, 0);
  [self invalidateAndWait:rt];
}


- (void)testD_T12_prepareWithEngineFailureYieldsFailed {
  _engine.shouldFailStart = YES;
  double sr = 44100.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(5.0 * sr), sr);
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
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[ d ]
                                                        volumeKeyframes:nil
                                                          waveformCache:nil
                                                   timeRemapAudioPolicy:nil];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedEnginePreparation);
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// SF-T1: descriptor accepts original role
- (void)testSF_T1_descriptorAcceptsOriginalRole {
  NSDictionary *dict = @{
    @"trackId" : @"orig-1",
    @"role" : @"original",
    @"url" : @"/tmp/clip.mp4",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNotNil(d, @"original role must be accepted");
  XCTAssertEqualObjects(d.trackId, @"orig-1");
}


// SF-T2: descriptor accepts voiceover (updated for Slice G)
- (void)testSF_T2_descriptorAcceptsVoiceover {
  NSDictionary *dict = @{
    @"trackId" : @"vo-1",
    @"role" : @"voiceover",
    @"url" : @"/tmp/vo.mp3",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNotNil(d, @"voiceover role must be accepted in Slice G");
}


// SF-T7: muted track excluded -- yields silent, no engine start
- (void)testSF_T7_mutedTrackExcludedYieldsSilent {
  NSDictionary *dict = @{
    @"trackId" : @"orig-muted",
    @"role" : @"original",
    @"url" : @"/tmp/audio.mp4",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(0.0)
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ dict ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultSilentNoEligibleTrack,
                 @"muted original must yield silent");
  XCTAssertEqual(_engine.startCount, 0, @"engine must not start");
  [self invalidateAndWait:rt];
}


// SF-T8: voiceover plan with unavailable file yields a file-open failure, no engine start.
// (Updated for Slice G: voiceover descriptor is now accepted; the fake URL causes a
// missing-file error rather than SilentNoEligibleTrack.)
- (void)testSF_T8_voiceoverPlanWithMissingFileYieldsFailedFile {
  NSDictionary *vo = @{
    @"trackId" : @"vo-1",
    @"role" : @"voiceover",
    @"url" : @"/tmp/vo.mp3",   // No stubbedFile set; provider returns nil, no error.
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ vo ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  XCTAssertTrue(res == VGAudioPreviewPreparationResultFailedMissingFile ||
                res == VGAudioPreviewPreparationResultFailedUnsupportedFormat,
                @"voiceover plan with unavailable file must return a file-open failure");
  XCTAssertEqual(_engine.startCount, 0, @"engine must not start on file-open failure");
  [self invalidateAndWait:rt];
}


// SF-T9: failed file marked and not retried on commandPlay
- (void)testSF_T9_failedFileNotRetried {
  _fileProvider.shouldFail = YES;
  NSDictionary *dict = [self trackDictWithStartTime:0.0 duration:5.0 volume:1.0];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ dict ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  NSInteger openAfterPrepare = _fileProvider.openCount;

  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .playStartPTS = 0.0, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_fileProvider.openCount, openAfterPrepare,
                 @"failed track must not be retried on commandPlay");
  XCTAssertEqual(_engine.startCount, 0, @"engine must not start on file failure");
  [self invalidateAndWait:rt];
}


// ─────────────────────────────────────────────────────────────────────────────
// Slice G: descriptor-role compatibility (sfx + voiceover)
// ─────────────────────────────────────────────────────────────────────────────

// G-T1: descriptor accepts sfx role
- (void)testG_T1_descriptorAcceptsSfxRole {
  NSDictionary *dict = @{
    @"trackId" : @"sfx-1",
    @"role" : @"sfx",
    @"url" : @"/tmp/clip.mp4",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(3.0),
    @"volume" : @(0.8)
  };
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNotNil(d, @"sfx role must be accepted by the descriptor");
  XCTAssertEqualObjects(d.trackId, @"sfx-1");
  XCTAssertEqualObjects(d.role, @"sfx");
}


// G-T3: sfx-only plan with a valid file yields Ready and starts engine
- (void)testG_T3_sfxOnlyPlanYieldsReady {
  double sr = 44100.0, dur = 4.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(dur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV needed");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open WAV");
    return;
  }

  NSDictionary *sfxDict = @{
    @"trackId" : @"sfx-g3",
    @"role" : @"sfx",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(dur),
    @"volume" : @(0.9)
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ sfxDict ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady,
                 @"sfx-only plan with valid file must yield Ready");
  XCTAssertEqual(_engine.startCount, 1, @"engine must start for sfx track");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// G-T4: voiceover-only plan with a valid file yields Ready and starts engine
- (void)testG_T4_voiceoverOnlyPlanYieldsReady {
  double sr = 44100.0, dur = 3.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(dur * sr), sr);
  if (!url) {
    XCTSkip(@"temp WAV needed");
    return;
  }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) {
    XCTSkip(@"could not open WAV");
    return;
  }

  NSDictionary *voDict = @{
    @"trackId" : @"vo-g4",
    @"role" : @"voiceover",
    @"url" : url.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(dur),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ voDict ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res =
      [rt prepareWithSidecarPlan:plan timelineDuration:10.0];

  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady,
                 @"voiceover-only plan with valid file must yield Ready");
  XCTAssertEqual(_engine.startCount, 1, @"engine must start for voiceover track");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
