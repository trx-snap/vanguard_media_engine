// VanguardAudioPreviewRuntimeTest_SourceRange.m
// Vanguard Media Engine — Audio Modularity M1
//
// Category (SourceRange) on VanguardAudioPreviewRuntimeTest.
// Compiled as an independent translation unit.

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

@implementation VanguardAudioPreviewRuntimeTest (SourceRange)


// ─────────────────────────────────────────────────────────────────────────────
// S-13: testPlayInsideRangeSchedulesExpectedSourceFrames
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPlayInsideRangeSchedulesExpectedSourceFrames {
  double sr = 44100.0, fileDur = 10.0, trackStart = 0.0, pts = 0.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = pts,
                                               .playStartPTS = pts,
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
    @"startTime" : @(trackStart),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(fileDur),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  XCTAssertEqual([rt prepareWithSidecarPlan:plan timelineDuration:fileDur],
                 VGAudioPreviewPreparationResultReady);

  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 1, @"must schedule exactly once");
  XCTAssertEqual(_player.lastStartFrame, 0, @"start frame must be 0 for PTS=0");
  XCTAssertGreaterThan(_player.lastFrameCount, 0u,
                       @"frame count must be positive");
  XCTAssertGreaterThan(_player.playCount, 0, @"player must be started");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-14: testSourceTrimStartIsIncludedInFrameMapping
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSourceTrimStartIsIncludedInFrameMapping {
  double sr = 44100.0, fileDur = 10.0, trimStart = 2.0;
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
    @"sourceTrimStart" : @(trimStart),
    @"duration" : @(-1.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  XCTAssertEqual([rt prepareWithSidecarPlan:plan timelineDuration:fileDur],
                 VGAudioPreviewPreparationResultReady);
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 1);
  // startFrame must be trimStart * sampleRate.
  AVAudioFramePosition expectedStart = (AVAudioFramePosition)(trimStart * sr);
  XCTAssertEqual(_player.lastStartFrame, expectedStart,
                 @"start frame must account for source trim start");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-15: testDurationMinusOneUsesRemainingFileDuration
// ─────────────────────────────────────────────────────────────────────────────

- (void)testDurationMinusOneUsesRemainingFileDuration {
  double sr = 44100.0, fileDur = 8.0;
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
    @"duration" : @(-1.0),
    @"volume" : @(1.0) // -1 means full file
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  XCTAssertEqual([rt prepareWithSidecarPlan:plan timelineDuration:100.0],
                 VGAudioPreviewPreparationResultReady);
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 1);
  // frameCount should be ≈ fileDur * sampleRate frames.
  AVAudioFrameCount expected = (AVAudioFrameCount)(fileDur * sr);
  XCTAssertEqualWithAccuracy(
      (double)_player.lastFrameCount, (double)expected, 2.0,
      @"frame count should match full file when duration=-1");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-16: testRequestedDurationClipsToRemainingFileDuration
// ─────────────────────────────────────────────────────────────────────────────

- (void)testRequestedDurationClipsToRemainingFileDuration {
  double sr = 44100.0, fileDur = 5.0, requestedDur = 100.0;
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
    @"duration" : @(requestedDur),
    @"volume" : @(1.0) // request more than file has
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  XCTAssertEqual([rt prepareWithSidecarPlan:plan timelineDuration:1000.0],
                 VGAudioPreviewPreparationResultReady);
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 1);
  // Frame count must be clamped to file length, not requestedDur.
  AVAudioFrameCount expectedMax = (AVAudioFrameCount)(fileDur * sr);
  XCTAssertLessThanOrEqual(_player.lastFrameCount, expectedMax,
                           @"frame count must not exceed file length");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-17: testTrackClipsToTimelineDuration
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTrackClipsToTimelineDuration {
  // timelineDuration is shorter than the file. activeDuration should be
  // clamped.
  double sr = 44100.0, fileDur = 20.0, tlDur = 3.0;
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
    @"duration" : @(-1.0),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  XCTAssertEqual([rt prepareWithSidecarPlan:plan timelineDuration:tlDur],
                 VGAudioPreviewPreparationResultReady);
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 1);
  AVAudioFrameCount expectedMax = (AVAudioFrameCount)(tlDur * sr);
  XCTAssertLessThanOrEqual(_player.lastFrameCount, expectedMax + 1,
                           @"frame count must be clipped to timeline duration");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-18: testBoundaryEqualityProducesSilence
// ─────────────────────────────────────────────────────────────────────────────

- (void)testBoundaryEqualityProducesSilence {
  // PTS exactly at trackStart + activeDuration → past the end → silence.
  double sr = 44100.0, fileDur = 5.0, pts = 5.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = pts,
                                               .playStartPTS = pts,
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
    @"duration" : @(pts),
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

  XCTAssertEqual(_player.scheduleCount, 0,
                 @"boundary equality must produce silence");
  XCTAssertEqual(_player.playCount, 0);

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// S-19: testZeroRemainingFramesDoesNotSchedule
// ─────────────────────────────────────────────────────────────────────────────

- (void)testZeroRemainingFramesDoesNotSchedule {
  // PTS already past the track end.
  double sr = 44100.0, fileDur = 5.0;
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 20.0,
                                               .playStartPTS = 20.0,
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
  [rt prepareWithSidecarPlan:plan timelineDuration:100.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 0,
                 @"no schedule when PTS past track end");
  XCTAssertEqual(_player.playCount, 0);

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}


- (void)testSliceD_sourceTrimStart_missingAcceptedAndDefaultsToZero {
  NSDictionary *dict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : @"/tmp/fake.mp3",
    @"startTime" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNotNil(d);
  XCTAssertEqualWithAccuracy(d.sourceTrimStart, 0.0, 0.001);
}


- (void)testSliceD_sourceTrimStart_explicitZeroAccepted {
  NSDictionary *dict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : @"/tmp/fake.mp3",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNotNil(d);
  XCTAssertEqualWithAccuracy(d.sourceTrimStart, 0.0, 0.001);
}


- (void)testSliceD_sourceTrimStart_positivePreserved {
  NSDictionary *dict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : @"/tmp/fake.mp3",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(2.5),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNotNil(d);
  XCTAssertEqualWithAccuracy(d.sourceTrimStart, 2.5, 0.001);
}


- (void)testSliceD_sourceTrimStart_negativeRejected {
  NSDictionary *dict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : @"/tmp/fake.mp3",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(-1.0),
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNil(d);
}


- (void)testSliceD_sourceTrimStart_nonNumberRejected {
  NSDictionary *dict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : @"/tmp/fake.mp3",
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @"not_a_number",
    @"duration" : @(5.0),
    @"volume" : @(1.0)
  };
  VGAudioPreviewTrackDescriptor *d =
      [[VGAudioPreviewTrackDescriptor alloc] initWithDictionary:dict];
  XCTAssertNil(d);
}


- (void)
    testSliceD_sourceTrimStart_missingZeroTrimPlanReachesNonSilentPreparation {
  double sr = 44100.0;
  double fileDur = 5.0;
  AVAudioFramePosition frames = (AVAudioFramePosition)(fileDur * sr);
  NSURL *tempURL = VGAPrCreateTempWAVURL(frames, sr);
  XCTAssertNotNil(tempURL);
  if (!tempURL)
    return;

  NSError *openErr = nil;
  AVAudioFile *realFile = [[AVAudioFile alloc] initForReading:tempURL
                                                        error:&openErr];
  XCTAssertNotNil(realFile);
  if (!realFile) {
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    return;
  }
  _fileProvider.stubbedFile = realFile;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];

  // Serialized shape matching the physical Slice D track (missing
  // sourceTrimStart)
  NSDictionary *trackDict = @{
    @"trackId" : @"slice-d-music",
    @"role" : @"music",
    @"url" : tempURL.path,
    @"startTime" : @(0.0),
    @"duration" : @(5.0),
    @"volume" : @(0.85),
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];

  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];

  // Prove the result is not SilentNoEligibleTrack (res 0)
  XCTAssertNotEqual(res, VGAudioPreviewPreparationResultSilentNoEligibleTrack);

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
