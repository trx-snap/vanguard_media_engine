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

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
