// VanguardAudioPreviewRuntimeTest.m
// Vanguard Media Engine — Phase 10-C Slice D
//
// Main implementation for VanguardAudioPreviewRuntimeTest.
// Contains setUp, tearDown, runtime factories, plan/track helpers,
// wait and invalidation helpers.
//
// Test methods are implemented in responsibility-based category files:
//   VanguardAudioPreviewRuntimeTest_Prepare.m         (Preparation)
//   VanguardAudioPreviewRuntimeTest_StateTransitions.m (StateTransitions)
//   VanguardAudioPreviewRuntimeTest_SourceRange.m      (SourceRange)
//   VanguardAudioPreviewRuntimeTest_Rescheduling.m     (Rescheduling)
//   VanguardAudioPreviewRuntimeTest_Teardown.m         (Lifecycle)
//   VanguardAudioPreviewRuntimeTest_SliceF_Arbitration.m (Arbitration)
//   VanguardAudioPreviewRuntimeTest_SliceF_Races.m     (SliceFRaces)
//   VanguardAudioPreviewRuntimeTest_SliceF_Sequences.m (SliceFSequences)
//   VanguardAudioPreviewRuntimeTest_SliceE.m           (SliceEContract)

#import "VanguardAudioPreviewRuntimeTest.h"

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test helper: build a runtime + all collaborators
// ─────────────────────────────────────────────────────────────────────────────

@implementation VanguardAudioPreviewRuntimeTest

- (void)setUp {
  [super setUp];
  _clock = [[VGAPr_MockClock alloc] init];
  _timer = [[VGAPr_MockTimer alloc] init];
  _automationTimer = [[VGAPr_MockAutomationTimer alloc] init];
  _fileProvider = [[VGAPr_MockFileProvider alloc] init];
  _engine = [[VGAPr_MockEngine alloc] init];
  _player = [[VGAPr_MockPlayer alloc] init];
  _stubbedSnapshot = (VGTimelineStateSnapshot){0};
}

- (void)tearDown {
  [super tearDown];
}

/// Builds a runtime whose snapshot provider returns a copy of _stubbedSnapshot.
- (VanguardAudioPreviewRuntime *)makeRuntime {
  return [self makeRuntimeWithEpoch:1];
}

- (VanguardAudioPreviewRuntime *)makeRuntimeWithEpoch:(uint64_t)epoch {
  __weak typeof(self) weakSelf = self;
  VGTimelineSnapshotProvider provider = ^VGTimelineStateSnapshot {
    typeof(self) ss = weakSelf;
    if (!ss)
      return (VGTimelineStateSnapshot){.isValid = NO};
    return ss.stubbedSnapshot;
  };
  VanguardAudioPreviewRuntime *rt = [[VanguardAudioPreviewRuntime alloc]
      initWithSnapshotProvider:provider
                lifecycleEpoch:epoch
                         clock:_clock
                         timer:_timer
               automationTimer:_automationTimer
                  fileProvider:_fileProvider
                        engine:_engine
                        player:_player];
  _timer.runtime = rt;
  return rt;
}

/// Builds a valid music track dictionary.
- (NSDictionary<NSString *, id> *)trackDictWithStartTime:(double)start
                                                 duration:(double)duration
                                                   volume:(double)volume {
  return @{
    @"trackId" : @"test_music_track",
    @"role" : @"music",
    @"url" : @"/tmp/fake_test_audio.mp3",
    @"startTime" : @(start),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(duration),
    @"volume" : @(volume),
  };
}

/// Prepares a runtime with a real temp WAV file. Returns nil if temp WAV
/// creation fails.
- (nullable VanguardAudioPreviewRuntime *)
    makePreparedRuntimeWithTrackStart:(double)start
                             duration:(double)duration
                           sampleRate:(double)sr
                         fileDuration:(double)fileDur
                     timelineDuration:(double)tlDur
                               result:(VGAudioPreviewPreparationResult *)
                                          outResult {
  AVAudioFramePosition frames = (AVAudioFramePosition)(fileDur * sr);
  NSURL *tempURL = VGAPrCreateTempWAVURL(frames, sr);
  if (!tempURL)
    return nil;
  NSError *openErr = nil;
  AVAudioFile *realFile = [[AVAudioFile alloc] initForReading:tempURL
                                                        error:&openErr];
  if (!realFile) {
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    return nil;
  }
  _fileProvider.stubbedFile = realFile;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *trackDict = @{
    @"trackId" : @"t1",
    @"role" : @"music",
    @"url" : tempURL.path,
    @"startTime" : @(start),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(duration),
    @"volume" : @(1.0),
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:tlDur];
  if (outResult)
    *outResult = res;
  return rt;
}

// Synchronously waits for an expectation with a short timeout.
- (void)waitFor:(NSTimeInterval)seconds {
  XCTestExpectation *exp = [self expectationWithDescription:@"delay"];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [exp fulfill];
      });
  [self waitForExpectations:@[ exp ] timeout:seconds + 1.0];
}

- (void)invalidateAndWait:(VanguardAudioPreviewRuntime *)rt {
  XCTestExpectation *exp = [self expectationWithDescription:@"inv"];
  [rt invalidateAsync:^{
    [exp fulfill];
  }];
  [self waitForExpectations:@[ exp ] timeout:5.0];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - §SF Slice F Test Matrix
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an original-role track dictionary.
- (NSDictionary<NSString *, id> *)originalTrackDictWithId:(NSString *)tid
                                                startTime:(double)start
                                                 duration:(double)dur
                                                   volume:(double)vol
                                                      url:(NSString *)path {
  return @{
    @"trackId" : tid,
    @"role" : @"original",
    @"url" : path,
    @"startTime" : @(start),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(dur),
    @"volume" : @(vol),
  };
}

/// Builds a music-role track dictionary with a custom id and URL.
- (NSDictionary<NSString *, id> *)musicTrackDictWithId:(NSString *)tid
                                             startTime:(double)start
                                              duration:(double)dur
                                                volume:(double)vol
                                                   url:(NSString *)path {
  return @{
    @"trackId" : tid,
    @"role" : @"music",
    @"url" : path,
    @"startTime" : @(start),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(dur),
    @"volume" : @(vol),
  };
}

/// Builds a track dictionary with optional volumeKeyframes.
- (NSDictionary<NSString *, id> *)trackDictWithId:(NSString *)tid
                                             role:(NSString *)role
                                        startTime:(double)start
                                         duration:(double)dur
                                           volume:(double)vol
                                              url:(NSString *)path
                                       keyframes:(nullable NSArray *)keyframes {
  NSMutableDictionary *dict = [@{
    @"trackId" : tid,
    @"role" : role,
    @"url" : path,
    @"startTime" : @(start),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(dur),
    @"volume" : @(vol),
  } mutableCopy];
  if (keyframes)
    dict[@"volumeKeyframes"] = keyframes;
  return [dict copy];
}

/// Builds a voiceover-role track dictionary with a custom id and URL.
- (NSDictionary<NSString *, id> *)voiceoverTrackDictWithId:(NSString *)tid
                                                 startTime:(double)start
                                                  duration:(double)dur
                                                    volume:(double)vol
                                                       url:(NSString *)path {
  return @{
    @"trackId" : tid,
    @"role" : @"voiceover",
    @"url" : path,
    @"startTime" : @(start),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(dur),
    @"volume" : @(vol),
  };
}

/// Builds a two-slot runtime for Slice K tests.
/// _voiceoverPlayer and _voiceoverAutomationTimer must be allocated before
/// calling this. _timer, _automationTimer, _clock, _fileProvider, _engine, and
/// _player are used for the Added Audio slot (same as single-slot tests).
- (VanguardAudioPreviewRuntime *)makeMultiSlotRuntime {
  NSAssert(_voiceoverPlayer != nil,
           @"makeMultiSlotRuntime: _voiceoverPlayer must be set by the caller");
  NSAssert(_voiceoverAutomationTimer != nil,
           @"makeMultiSlotRuntime: _voiceoverAutomationTimer must be set");

  __weak typeof(self) weakSelf = self;
  VGTimelineSnapshotProvider provider = ^VGTimelineStateSnapshot {
    typeof(self) ss = weakSelf;
    if (!ss)
      return (VGTimelineStateSnapshot){.isValid = NO};
    return ss.stubbedSnapshot;
  };
  VanguardAudioPreviewRuntime *rt = [[VanguardAudioPreviewRuntime alloc]
      initWithSnapshotProvider:provider
                lifecycleEpoch:1
                         clock:_clock
                         timer:_timer
       addedAudioAutomationTimer:_automationTimer
       voiceoverAutomationTimer:_voiceoverAutomationTimer
                  fileProvider:_fileProvider
                        engine:_engine
              addedAudioPlayer:_player
               voiceoverPlayer:_voiceoverPlayer];
  _timer.runtime = rt;
  return rt;
}

/// Builds a four-slot runtime with independent music, sfx, and voice-over
/// mock players. _sfxPlayer, _sfxAutomationTimer, _voiceoverPlayer, and
/// _voiceoverAutomationTimer must be allocated before calling this. The
/// Original slot reuses _player / _automationTimer (same convention as
/// makeMultiSlotRuntime).
- (VanguardAudioPreviewRuntime *)makeFourSlotRuntime {
  NSAssert(_sfxPlayer != nil,
           @"makeFourSlotRuntime: _sfxPlayer must be set by the caller");
  NSAssert(_sfxAutomationTimer != nil,
           @"makeFourSlotRuntime: _sfxAutomationTimer must be set");
  NSAssert(_voiceoverPlayer != nil,
           @"makeFourSlotRuntime: _voiceoverPlayer must be set by the caller");
  NSAssert(_voiceoverAutomationTimer != nil,
           @"makeFourSlotRuntime: _voiceoverAutomationTimer must be set");

  __weak typeof(self) weakSelf = self;
  VGTimelineSnapshotProvider provider = ^VGTimelineStateSnapshot {
    typeof(self) ss = weakSelf;
    if (!ss)
      return (VGTimelineStateSnapshot){.isValid = NO};
    return ss.stubbedSnapshot;
  };
  VanguardAudioPreviewRuntime *rt = [[VanguardAudioPreviewRuntime alloc]
          initWithSnapshotProvider:provider
                    lifecycleEpoch:1
                             clock:_clock
                             timer:_timer
         addedAudioAutomationTimer:_automationTimer
                sfxAutomationTimer:_sfxAutomationTimer
          voiceoverAutomationTimer:_voiceoverAutomationTimer
      originalAudioAutomationTimer:_automationTimer
                      fileProvider:_fileProvider
                            engine:_engine
                  addedAudioPlayer:_player
                         sfxPlayer:_sfxPlayer
                   voiceoverPlayer:_voiceoverPlayer
               originalAudioPlayer:_player];
  _timer.runtime = rt;
  return rt;
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
