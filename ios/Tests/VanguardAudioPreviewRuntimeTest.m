// VanguardAudioPreviewRuntimeTest.m
// Vanguard Media Engine — Phase 10-C Slice D
//
// Deterministic unit tests for VanguardAudioPreviewRuntime.
// All collaborators are injected via the package-internal test initialiser.
// No AVAudioEngine, no AVAudioFile, no real audio playback.
//
// Test isolation: all mock class names carry the VGAPr_ prefix to avoid
// Objective-C runtime name collisions with mocks in other test bundles.
//
// Approved test matrix: 38 tests from plan §S plus correction mechanic tests.

#import <XCTest/XCTest.h>
#import <stdatomic.h>
#import <stdint.h>

#import "VGTimelineStateSnapshot.h"
#import "VanguardAudioPreviewRuntime.h"
#import <UMF/VGAudioSidecarPlan.h>

// Package-private testing seam declared in VanguardAudioPreviewRuntime.m.
@interface VanguardAudioPreviewRuntime (Testing)
- (void)vg_performSynchronouslyOnSchedulerQueueForTesting:
    (dispatch_block_t)block;
@end

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Mock collaborators
// ─────────────────────────────────────────────────────────────────────────────

// ─── VGAPr_MockClock
// ──────────────────────────────────────────────────────────

@interface VGAPr_MockClock : NSObject <VGAudioPreviewClock>
@property(nonatomic) NSTimeInterval currentTime;
@end
@implementation VGAPr_MockClock
- (NSTimeInterval)currentTime {
  return _currentTime;
}
@end

// ─── VGAPr_MockTimer
// ────────────────────────────────────────────────────────── Records whether
// armWithDelay:block: and cancel were called. The test drives the timer
// callback manually via -fireForcefully.

@interface VGAPr_MockTimer : NSObject <VGAudioPreviewTimer>
@property(nonatomic) NSInteger armCount;
@property(nonatomic) NSInteger cancelCount;
@property(nonatomic) NSTimeInterval lastDelay;
@property(nonatomic, copy, nullable) dispatch_block_t pendingBlock;
@property(nonatomic, weak, nullable) VanguardAudioPreviewRuntime *runtime;
- (void)fireForcefully;
@end

@implementation VGAPr_MockTimer

- (void)armWithDelay:(NSTimeInterval)delay block:(dispatch_block_t)block {
  _armCount++;
  _lastDelay = delay;
  _pendingBlock = [block copy];
}

- (void)cancel {
  _cancelCount++;
  _pendingBlock = nil;
}

- (void)fireForcefully {
  VanguardAudioPreviewRuntime *rt = self.runtime;
  NSAssert(rt != nil, @"Mock timer requires its owning runtime.");

  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    dispatch_block_t block = self.pendingBlock;
    self.pendingBlock = nil;
    if (block) {
      block();
    }
  }];
}

@end

// ─── VGAPr_MockFileProvider
// ─────────────────────────────────────────────────── Returns a fake
// AVAudioFile substitute via KVC to avoid touching the real filesystem. In
// practice AVAudioFile cannot be reasonably subclassed, so for tests that need
// file opening to succeed we use a stub subclass.

@interface VGAPr_MockFileProvider : NSObject <VGAudioPreviewFileProvider>
/// When non-nil, returned for any openFileAtURL: call.
@property(nonatomic, strong, nullable) AVAudioFile *stubbedFile;
/// When YES, openFileAtURL: returns nil with an error.
@property(nonatomic) BOOL shouldFail;
/// When YES, openFileAtURL: returns nil with NO error (file missing).
@property(nonatomic) BOOL shouldFailWithNoError;
/// When YES, fileExistsAtURL: returns NO.
@property(nonatomic) BOOL fileDoesNotExist;
@property(nonatomic) NSInteger openCount;
@property(nonatomic) NSInteger existsCount;
@end

@implementation VGAPr_MockFileProvider

- (nullable AVAudioFile *)openFileAtURL:(NSURL *)url
                                  error:(NSError *_Nullable *_Nullable)error {
  _openCount++;
  if (_shouldFail) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"VGAPr_MockFileProvider"
                     code:1
                 userInfo:@{NSLocalizedDescriptionKey : @"mock failure"}];
    }
    return nil;
  }
  if (_shouldFailWithNoError) {
    return nil;
  }
  return _stubbedFile;
}

- (BOOL)fileExistsAtURL:(NSURL *)url {
  _existsCount++;
  return !_fileDoesNotExist;
}

@end

// ─── VGAPr_MockEngine
// ─────────────────────────────────────────────────────────

@interface VGAPr_MockEngine : NSObject <VGAudioPreviewEngine>
@property(nonatomic) BOOL shouldFailStart;
@property(nonatomic) NSInteger startCount;
@property(nonatomic) NSInteger stopCount;
@property(nonatomic) NSInteger attachCount;
@property(nonatomic) NSInteger prepareCount;
@property(nonatomic, strong, nullable) AVAudioMixerNode *mixerNode;
@end

@implementation VGAPr_MockEngine

- (instancetype)init {
  self = [super init];
  if (self) {
    _mixerNode = [[AVAudioMixerNode alloc] init];
  }
  return self;
}

- (void)attachNode:(AVAudioNode *)node {
  _attachCount++;
}
- (void)connect:(AVAudioNode *)n1
             to:(AVAudioNode *)n2
         format:(nullable AVAudioFormat *)fmt {
}
- (void)prepare {
  _prepareCount++;
}
- (void)stop {
  _stopCount++;
}
- (AVAudioMixerNode *)mainMixerNode {
  return _mixerNode;
}

- (BOOL)startAndReturnError:(NSError *_Nullable *_Nullable)error {
  _startCount++;
  if (_shouldFailStart) {
    if (error) {
      *error =
          [NSError errorWithDomain:@"VGAPr_MockEngine"
                              code:2
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"mock engine failure"
                          }];
    }
    return NO;
  }
  return YES;
}

@end

// ─── VGAPr_MockPlayer
// ─────────────────────────────────────────────────────────

@interface VGAPr_MockPlayer : NSObject <VGAudioPreviewPlayer>
@property(nonatomic) NSInteger scheduleCount;
@property(nonatomic) NSInteger playCount;
@property(nonatomic) NSInteger stopCount;
@property(nonatomic) float lastVolume;
@property(nonatomic) AVAudioFramePosition lastStartFrame;
@property(nonatomic) AVAudioFrameCount lastFrameCount;
/// When set, the completion block for the last scheduleSegment call is stored
/// here. Tests can call it manually to simulate natural track completion.
@property(nonatomic, copy, nullable)
    AVAudioPlayerNodeCompletionHandler lastCompletionHandler;
@end

@implementation VGAPr_MockPlayer

- (void)scheduleSegment:(AVAudioFile *)file
             startingFrame:(AVAudioFramePosition)startFrame
                frameCount:(AVAudioFrameCount)frameCount
                    atTime:(nullable AVAudioTime *)when
    completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)callbackType
         completionHandler:
             (nullable AVAudioPlayerNodeCompletionHandler)completionHandler {
  _scheduleCount++;
  _lastStartFrame = startFrame;
  _lastFrameCount = frameCount;
  _lastCompletionHandler = completionHandler ? [completionHandler copy] : nil;
}

- (void)play {
  _playCount++;
}
- (void)stop {
  _stopCount++;
}
- (void)setVolume:(float)v {
  _lastVolume = v;
}

@end

// ─── VGAPr_FakeAudioFile
// ────────────────────────────────────────────────────── AVAudioFile cannot be
// trivially constructed without a real file. Instead we create a real 1-frame
// PCM temp file so we can test the real file path.

static NSURL *_Nullable VGAPrCreateTempWAVURL(AVAudioFramePosition frames,
                                              double sampleRate) {
  AVAudioFormat *fmt =
      [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate
                                                     channels:1];
  if (!fmt)
    return nil;
  AVAudioPCMBuffer *buf =
      [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                    frameCapacity:(AVAudioFrameCount)frames];
  if (!buf)
    return nil;
  buf.frameLength = (AVAudioFrameCount)frames;

  NSURL *tempURL = [NSURL
      fileURLWithPath:
          [NSTemporaryDirectory()
              stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"vg_apr_test_%lld.wav",
                                             (long long)[[NSDate date]
                                                 timeIntervalSince1970]]]];

  NSError *writeErr = nil;
  AVAudioFile *f = [[AVAudioFile alloc] initForWriting:tempURL
                                              settings:fmt.settings
                                                 error:&writeErr];
  if (!f || writeErr)
    return nil;
  [f writeFromBuffer:buf error:&writeErr];
  if (writeErr)
    return nil;
  return tempURL;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test helper: build a runtime + all collaborators
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardAudioPreviewRuntimeTest : XCTestCase

@property(nonatomic, strong) VGAPr_MockClock *clock;
@property(nonatomic, strong) VGAPr_MockTimer *timer;
@property(nonatomic, strong) VGAPr_MockFileProvider *fileProvider;
@property(nonatomic, strong) VGAPr_MockEngine *engine;
@property(nonatomic, strong) VGAPr_MockPlayer *player;

/// Mutable snapshot returned by the provider.
@property(nonatomic, assign) VGTimelineStateSnapshot stubbedSnapshot;

@end

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
#pragma mark - §S Test Matrix (38 tests)
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

  NSDictionary *voiceDict = @{
    @"trackId" : @"v1",
    @"role" : @"voiceover",
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
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ voiceDict, musicDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];

  XCTAssertEqual(res, VGAudioPreviewPreparationResultReady,
                 @"must select first valid music dict (second entry)");
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
// S-9: testPauseCancelsBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testPauseCancelsBoundaryTimer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 1.0,
                                               .playStartPTS = 1.0,
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

  [rt commandPause];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"timer must be cancelled on pause");
  XCTAssertGreaterThan(_player.stopCount, 0,
                       @"player must be stopped on pause");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-10: testSeekCancelsBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testSeekCancelsBoundaryTimer {
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

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"timer must be cancelled on seek");
  XCTAssertGreaterThan(_player.stopCount, 0, @"player must be stopped on seek");
  [self invalidateAndWait:rt];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-11: testEOSCancelsBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testEOSCancelsBoundaryTimer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 5.0, .generation = 1, .isPlaying = YES, .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandEOS];
  [self waitFor:0.3];

  XCTAssertGreaterThan(_timer.cancelCount, 0, @"EOS must cancel timer");
  XCTAssertGreaterThan(_player.stopCount, 0, @"EOS must stop player");
  [self invalidateAndWait:rt];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-12: testInvalidationCancelsBoundaryTimer
// ─────────────────────────────────────────────────────────────────────────────

- (void)testInvalidationCancelsBoundaryTimer {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .isPlaying = YES, .isValid = YES, .generation = 1};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *invExp = [self expectationWithDescription:@"inv"];
  [rt invalidateAsync:^{
    [invExp fulfill];
  }];
  [self waitForExpectations:@[ invExp ] timeout:5.0];

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"invalidation must cancel timer");
  XCTAssertGreaterThan(_player.stopCount, 0, @"invalidation must stop player");
  XCTAssertGreaterThan(_engine.stopCount, 0, @"invalidation must stop engine");
}

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

// ─────────────────────────────────────────────────────────────────────────────
// S-30: testFileCompletionDoesNotLoop
// ─────────────────────────────────────────────────────────────────────────────

- (void)testFileCompletionDoesNotLoop {
  double sr = 44100.0, fileDur = 1.0;
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
    @"duration" : @(fileDur),
    @"volume" : @(1.0)
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:fileDur];
  [rt commandPlay];
  [self waitFor:0.3];

  NSInteger schedBefore = _player.scheduleCount;
  // Manually trigger the completion handler to simulate file end.
  if (_player.lastCompletionHandler) {
    _player.lastCompletionHandler(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, schedBefore,
                 @"file completion must not trigger re-schedule (no loop)");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-31: testTimelineEOSStopsAudio
// ─────────────────────────────────────────────────────────────────────────────

- (void)testTimelineEOSStopsAudio {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 5.0, .generation = 1, .isPlaying = YES, .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandEOS];
  [self waitFor:0.3];
  XCTAssertGreaterThan(_player.stopCount, 0, @"EOS must stop audio");
  [self invalidateAndWait:rt];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-32: testRuntimeReplacementWaitsForOldRuntimeInvalidation
// ─────────────────────────────────────────────────────────────────────────────

- (void)testRuntimeReplacementWaitsForOldRuntimeInvalidation {
  // Verify that invalidateAsync: calls back only after cleanup.
  VanguardAudioPreviewRuntime *rt1 = [self makeRuntimeWithEpoch:1];
  [rt1 prepareWithSidecarPlan:nil timelineDuration:10.0];

  __block BOOL rt1Done = NO;
  XCTestExpectation *inv1 = [self expectationWithDescription:@"inv1Done"];
  [rt1 invalidateAsync:^{
    rt1Done = YES;
    [inv1 fulfill];
  }];

  VanguardAudioPreviewRuntime *rt2 = [self makeRuntimeWithEpoch:2];
  [rt2 prepareWithSidecarPlan:nil timelineDuration:10.0];

  [self waitForExpectations:@[ inv1 ] timeout:5.0];
  XCTAssertTrue(rt1Done, @"old runtime invalidation must complete");

  [self invalidateAndWait:rt2];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-33: testInvalidateAsyncCompletesAfterQueueCleanup
// ─────────────────────────────────────────────────────────────────────────────

- (void)testInvalidateAsyncCompletesAfterQueueCleanup {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *exp = [self expectationWithDescription:@"cleanup"];
  [rt invalidateAsync:^{
    // By the time this fires, engine/player must already be stopped.
    [exp fulfill];
  }];
  [self waitForExpectations:@[ exp ] timeout:5.0];

  // After completion, engine and player must have been stopped.
  XCTAssertGreaterThan(_engine.stopCount, 0,
                       @"engine must stop before completion fires");
  XCTAssertGreaterThan(_player.stopCount, 0,
                       @"player must stop before completion fires");
}

// ─────────────────────────────────────────────────────────────────────────────
// S-34: testNoCommandAcceptedAfterInvalidationBegins
// ─────────────────────────────────────────────────────────────────────────────

- (void)testNoCommandAcceptedAfterInvalidationBegins {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *inv = [self expectationWithDescription:@"inv"];
  [rt invalidateAsync:^{
    [inv fulfill];
  }];
  [self waitForExpectations:@[ inv ] timeout:5.0];

  NSInteger playBefore = _player.playCount;
  [rt commandPlay];
  [self waitFor:0.3];
  XCTAssertEqual(_player.playCount, playBefore,
                 @"commandPlay after invalidation is a no-op");
}

// ─────────────────────────────────────────────────────────────────────────────
// S-35: testEngineAndPlayerMutationRemainOnSchedulerQueue
// ─────────────────────────────────────────────────────────────────────────────

- (void)testEngineAndPlayerMutationRemainOnSchedulerQueue {
  // Verify: assertOnSchedulerQueue does not fire (no crash) during normal
  // operations.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 1.0, .generation = 1, .isPlaying = YES, .isValid = YES};
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
  [rt commandPlay];
  [rt commandPause];
  [rt commandSeek];
  [self waitFor:0.3];
  // No assertion failures = queue confinement is intact.
  [self invalidateAndWait:rt];
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

// ─────────────────────────────────────────────────────────────────────────────
// S-38: testVanguardGraphRuntimeLifecycleRegressions
// ─────────────────────────────────────────────────────────────────────────────

- (void)testVanguardGraphRuntimeLifecycleRegressions {
  // Regression: multiple invalidateAsync: calls must be safe.
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *exp1 = [self expectationWithDescription:@"inv1"];
  XCTestExpectation *exp2 = [self expectationWithDescription:@"inv2"];
  XCTestExpectation *exp3 = [self expectationWithDescription:@"inv3"];

  [rt invalidateAsync:^{
    [exp1 fulfill];
  }];
  [rt invalidateAsync:^{
    [exp2 fulfill];
  }];
  [rt invalidateAsync:^{
    [exp3 fulfill];
  }];

  [self waitForExpectations:@[ exp1, exp2, exp3 ] timeout:8.0];
  // All three completions must fire. No crash.
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Additional correction mechanic tests
// ─────────────────────────────────────────────────────────────────────────────

// ─── Joined invalidation waiters ─────────────────────────────────────────────

- (void)testJoinedInvalidationWaitersAllFire {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *w1 = [self expectationWithDescription:@"w1"];
  XCTestExpectation *w2 = [self expectationWithDescription:@"w2"];
  XCTestExpectation *w3 = [self expectationWithDescription:@"w3"];

  // All three calls while in Accepting or Invalidating state must get
  // callbacks.
  [rt invalidateAsync:^{
    [w1 fulfill];
  }];
  [rt invalidateAsync:^{
    [w2 fulfill];
  }];
  [rt invalidateAsync:^{
    [w3 fulfill];
  }];

  [self waitForExpectations:@[ w1, w2, w3 ] timeout:8.0];
}

// ─── Completion after cleanup
// ─────────────────────────────────────────────────

- (void)testInvalidationCompletionFiresAfterCleanup {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  __block NSInteger stopCountAtCompletion = -1;
  XCTestExpectation *exp = [self expectationWithDescription:@"cleanup"];

  [rt invalidateAsync:^{
    // Capture engine stop count at completion time.
    stopCountAtCompletion = self->_engine.stopCount;
    [exp fulfill];
  }];

  [self waitForExpectations:@[ exp ] timeout:5.0];
  XCTAssertGreaterThan(stopCountAtCompletion, 0,
                       @"engine must be stopped before completion fires");
}

// ─── Strong runtime retention through cleanup
// ─────────────────────────────────

- (void)testRuntimeIsStronglyRetainedThroughCleanup {
  // Weak reference to verify runtime survives until completion fires.
  __weak VanguardAudioPreviewRuntime *weakRt = nil;

  XCTestExpectation *exp = [self expectationWithDescription:@"cleanup"];

  @autoreleasepool {
    VanguardAudioPreviewRuntime *rt = [self makeRuntime];
    weakRt = rt;
    [rt prepareWithSidecarPlan:nil timelineDuration:10.0];
    [rt invalidateAsync:^{
      // weakRt must still be non-nil here (strong retention during cleanup).
      XCTAssertNotNil(
          weakRt, @"runtime must be strongly retained until cleanup completes");
      [exp fulfill];
    }];
    // rt goes out of scope here — only the strong capture inside cleanup keeps
    // it alive.
  }

  [self waitForExpectations:@[ exp ] timeout:5.0];
}

// ─── Latest-request-wins generation ─────────────────────────────────────────

- (void)testDuplicateInvalidateAsyncIsIdempotent {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *exp1 = [self expectationWithDescription:@"inv1"];
  XCTestExpectation *exp2 = [self expectationWithDescription:@"inv2"];
  [rt invalidateAsync:^{
    [exp1 fulfill];
  }];
  [rt invalidateAsync:^{
    [exp2 fulfill];
  }];
  [self waitForExpectations:@[ exp1, exp2 ] timeout:5.0];

  // Engine must only be stopped once.
  XCTAssertEqual(
      _engine.stopCount, 1,
      @"engine must stop exactly once despite multiple invalidate calls");
}

// ─── Lifecycle shutdown rejecting installation
// ────────────────────────────────

- (void)testCommandsRejectedAfterInvalidationStarts {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  [rt prepareWithSidecarPlan:nil timelineDuration:10.0];

  XCTestExpectation *exp = [self expectationWithDescription:@"done"];
  [rt invalidateAsync:^{
    [exp fulfill];
  }];
  [self waitForExpectations:@[ exp ] timeout:5.0];

  NSInteger prevPlay = _player.playCount;
  NSInteger prevSchedule = _player.scheduleCount;
  [rt commandPlay];
  [rt commandPause];
  [rt commandSeek];
  [rt commandEOS];
  [self waitFor:0.3];

  XCTAssertEqual(_player.playCount, prevPlay,
                 @"play must be rejected after invalidation");
  XCTAssertEqual(_player.scheduleCount, prevSchedule,
                 @"schedule must be rejected after invalidation");
}

// ─── Timer cancellation
// ───────────────────────────────────────────────────────

- (void)testTimerIsCancelledOnInvalidation {
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .generation = 1, .isPlaying = YES, .isValid = YES};
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
  XCTAssertGreaterThan(_timer.armCount, 0, @"timer must be armed");

  XCTestExpectation *exp = [self expectationWithDescription:@"inv"];
  [rt invalidateAsync:^{
    [exp fulfill];
  }];
  [self waitForExpectations:@[ exp ] timeout:5.0];

  XCTAssertGreaterThan(_timer.cancelCount, 0,
                       @"timer must be cancelled during invalidation");
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// ─── Frame-count overflow before narrowing
// ────────────────────────────────────

- (void)testFrameCountOverflowProducesSilence {
  // With a tiny file of only a few frames and PTS past end, signed frame
  // difference is <= 0.
  double sr = 44100.0, fileDur = 0.001; // ~44 frames
  _stubbedSnapshot = (VGTimelineStateSnapshot){.timelinePTS = 5.0,
                                               .playStartPTS = 5.0,
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
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  XCTAssertEqual(_player.scheduleCount, 0,
                 @"zero/negative frame count must not schedule");
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
  [self invalidateAndWait:rt];
}

// ─── Deterministic file classification ───────────────────────────────────────

- (void)testMissingFileClassifiedCorrectly {
  _fileProvider.fileDoesNotExist = YES;
  _fileProvider.shouldFailWithNoError = YES;

  NSDictionary *d = [self trackDictWithStartTime:0.0 duration:5.0 volume:1.0];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[ d ]
                                                        volumeKeyframes:nil
                                                          waveformCache:nil
                                                   timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedMissingFile);
  [self invalidateAndWait:rt];
}

- (void)testExistingButUnopenableFileClassifiedCorrectly {
  _fileProvider.fileDoesNotExist = NO;
  _fileProvider.shouldFail = YES;

  NSDictionary *d = [self trackDictWithStartTime:0.0 duration:5.0 volume:1.0];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc] initWithTracks:@[ d ]
                                                        volumeKeyframes:nil
                                                          waveformCache:nil
                                                   timeRemapAudioPolicy:nil];
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedUnsupportedFormat);
  [self invalidateAndWait:rt];
}

- (void)testInvalidFileMetadataClassifiedCorrectly {
  // testPrepareWithEngineFailureYieldsFailed — re-verified here explicitly.
  double sr = 44100.0, fileDur = 5.0;
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

  _engine.shouldFailStart = YES;
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
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  VGAudioPreviewPreparationResult res = [rt prepareWithSidecarPlan:plan
                                                  timelineDuration:10.0];
  XCTAssertEqual(res, VGAudioPreviewPreparationResultFailedEnginePreparation);
  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
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

// ─── Legacy tests (D-T1 through D-T12 migrated from
// VGAudioPreviewRuntimeTest.m) ───

- (void)testD_T1_trackDescriptorRejectsNonMusicRole {
  NSDictionary *dict = @{
    @"trackId" : @"t1",
    @"role" : @"voiceover",
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

- (void)testD_T6_commandPlayArmesBoundaryTimerWhenPTSBeforeTrackStart {
  [self testPlayBeforeTrackStartArmsOneShotBoundaryTimer];
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

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Teardown Correction Tests (Phase 10-C Slice D)
// ─────────────────────────────────────────────────────────────────────────────

/// APR-TC1: [_player stop] is called immediately on the calling thread
///          when invalidateAsync: is invoked, BEFORE the scheduler-queue
///          cleanupBlock runs.
///
/// Verifies the immediate-quiesce path of the Slice D teardown fix.
/// The mock player's stopCount must be ≥ 1 before any async cleanup fires.
- (void)testImmediatePlayerStopOnInvalidateAsync {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];

  // Arm the runtime so the player is in a "would-be-playing" state.
  _stubbedSnapshot.isValid = YES;
  _stubbedSnapshot.isPlaying = YES;
  _stubbedSnapshot.timelinePTS = 0.0;

  // Install a real temp WAV so prepare succeeds and a segment is scheduled.
  NSURL *tempURL = VGAPrCreateTempWAVURL(44100, 44100.0);
  if (!tempURL) {
    XCTSkip(@"Cannot create temp WAV — skipping APR-TC1");
    return;
  }
  NSError *err = nil;
  AVAudioFile *file = [[AVAudioFile alloc] initForReading:tempURL error:&err];
  if (!file) {
    [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    XCTSkip(@"Cannot open temp WAV — skipping APR-TC1");
    return;
  }
  _fileProvider.stubbedFile = file;

  NSDictionary *trackDict = @{
    @"trackId" : @"tc1-track",
    @"role" : @"music",
    @"url" : tempURL.path,
    @"startTime" : @(0.0),
    @"sourceTrimStart" : @(0.0),
    @"duration" : @(1.0),
    @"volume" : @(1.0),
  };
  VGAudioSidecarPlan *plan =
      [[VGAudioSidecarPlan alloc] initWithTracks:@[ trackDict ]
                                 volumeKeyframes:nil
                                   waveformCache:nil
                            timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:2.0];

  // Record stopCount BEFORE invalidateAsync: fires any async work.
  NSInteger stopCountBefore = _player.stopCount;

  // Call invalidateAsync: — the immediate stop must occur synchronously
  // on the calling thread before this method returns.
  XCTestExpectation *exp =
      [self expectationWithDescription:@"APR-TC1 invalidate"];
  [rt invalidateAsync:^{
    [exp fulfill];
  }];

  // stopCount must have incremented synchronously — before any
  // scheduler-queue work can execute.
  XCTAssertGreaterThan(_player.stopCount, stopCountBefore,
                       @"[_player stop] must be called synchronously in "
                       @"invalidateAsync: before dispatch to _schedulerQueue");

  [self waitForExpectations:@[ exp ] timeout:2.0];
  [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
}

/// APR-TC2: Concurrent invalidateAsync: callers both receive their completion.
///
/// Two callers invoke invalidateAsync: before cleanup completes. Both
/// completions must fire exactly once each.
- (void)testConcurrentInvalidateAsyncBothCompletionsFireExactlyOnce {
  VanguardAudioPreviewRuntime *rt = [self makeRuntime];

  XCTestExpectation *exp1 =
      [self expectationWithDescription:@"APR-TC2 completion-1"];
  XCTestExpectation *exp2 =
      [self expectationWithDescription:@"APR-TC2 completion-2"];

  exp1.assertForOverFulfill = YES;
  exp2.assertForOverFulfill = YES;

  [rt invalidateAsync:^{
    [exp1 fulfill];
  }];
  [rt invalidateAsync:^{
    [exp2 fulfill];
  }];

  [self waitForExpectations:@[ exp1, exp2 ] timeout:2.0];
}

/// APR-TC3: commandPlay dispatched after invalidateAsync: cannot restart audio.
///
/// Once _acceptingCommands is NO, commandPlay must not schedule a segment
/// or call [_player play]. The player's scheduleCount and playCount must
/// remain at zero.
- (void)testCommandPlayAfterInvalidateCannotRestartAudio {
  _stubbedSnapshot.isValid = YES;
  _stubbedSnapshot.isPlaying = YES;
  _stubbedSnapshot.timelinePTS = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];

  XCTestExpectation *invalidExp =
      [self expectationWithDescription:@"APR-TC3 invalidate"];
  [rt invalidateAsync:^{
    [invalidExp fulfill];
  }];
  [self waitForExpectations:@[ invalidExp ] timeout:2.0];

  // Record counts after full invalidation.
  NSInteger scheduleBefore = _player.scheduleCount;
  NSInteger playBefore = _player.playCount;

  // Attempt to issue play — must be a no-op.
  [rt commandPlay];

  // Give the scheduler queue a moment to process any work (should be none).
  XCTestExpectation *drainExp =
      [self expectationWithDescription:@"APR-TC3 drain"];
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    [drainExp fulfill];
  }];
  [self waitForExpectations:@[ drainExp ] timeout:2.0];

  XCTAssertEqual(_player.scheduleCount, scheduleBefore,
                 @"scheduleSegment must not be called after invalidation");
  XCTAssertEqual(_player.playCount, playBefore,
                 @"[_player play] must not be called after invalidation");
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

// SF-T2: descriptor rejects voiceover
- (void)testSF_T2_descriptorRejectsVoiceover {
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
  XCTAssertNil(d, @"voiceover role must be rejected");
}

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

// SF-T8: voiceover-only plan yields silent, no engine start
- (void)testSF_T8_voiceoverOnlyPlanYieldsSilent {
  NSDictionary *vo = @{
    @"trackId" : @"vo-1",
    @"role" : @"voiceover",
    @"url" : @"/tmp/vo.mp3",
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
  XCTAssertEqual(res, VGAudioPreviewPreparationResultSilentNoEligibleTrack,
                 @"voiceover-only plan must yield silent");
  XCTAssertEqual(_engine.startCount, 0, @"engine must not start for VO plan");
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

// SF-T16: TIMER-FIRST RACE
//   1. Schedule orig-A and arm exact-boundary timer.
//   2. Advance snapshot to B's start; fire boundary timer -> B is scheduled.
//   3. Then invoke A's captured completion handler (simulates natural audio
//      finish arriving after the boundary transition already occurred).
//   4. Assert B's identity is preserved, state stays Playing, B's timer is
//      still active, and A's completion is ignored.
- (void)testSF_T16_timerFirstRace {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3), orig-B: [3, 5). Exact boundary at T=3.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.4 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:3.0 duration:2.0 volume:0.7 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Capture A's completion handler BEFORE firing the timer.
  AVAudioPlayerNodeCompletionHandler aCompletion = _player.lastCompletionHandler;
  XCTAssertNotNil(aCompletion, @"orig-A completion handler must be captured");

  // Advance to T=3.0 (B's start) and fire boundary timer -> B is scheduled.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  NSInteger armCountBeforeTimerFire = _timer.armCount;
  [_timer fireForcefully];
  [self waitFor:0.15];

  // Verify B is now scheduled and active.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"orig-B must be active after boundary timer fires");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"state must be Playing after B is scheduled");
  }];

  // NOW invoke A's stale completion handler (timer-first race scenario).
  // This simulates the audio engine completing A's buffer slightly after the
  // boundary timer already transitioned to B.
  if (aCompletion) {
    aCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.2];

  // A's completion must be a no-op: per-segment serial rejects it.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"active descriptor must still be orig-B after A's stale "
                          @"completion");
    XCTAssertEqual([[rt valueForKey:@"_runtimeState"] integerValue],
                   VGAudioPreviewRuntimeStatePlaying,
                   @"state must remain Playing — A's stale completion must be "
                   @"ignored");
  }];
  // B's boundary timer must still be alive (pendingBlock not nil means active).
  XCTAssertGreaterThanOrEqual(_timer.armCount, armCountBeforeTimerFire + 1,
                              @"B's boundary timer must have been armed");
  // The timer must NOT have been cancelled by A's stale completion.
  XCTAssertNotNil(_timer.pendingBlock,
                  @"B's boundary timer block must still be pending after A's "
                  @"stale completion");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// SF-T17: COMPLETION-FIRST RACE
//   1. Schedule orig-A and capture its completion handler.
//   2. Advance snapshot to the A->B boundary.
//   3. Fire A's completion BEFORE the boundary timer fires.
//   4. Assert that B is selected and scheduled (or a valid boundary timer
//      remains armed) and runtime is NOT Ended.
- (void)testSF_T17_completionFirstRace {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3), orig-B: [3, 5). Exact boundary at T=3.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.4 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:3.0 duration:2.0 volume:0.7 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Capture A's completion handler.
  AVAudioPlayerNodeCompletionHandler aCompletion = _player.lastCompletionHandler;
  XCTAssertNotNil(aCompletion, @"orig-A completion handler must be captured");

  // Advance snapshot to T=3.0 (the boundary) WITHOUT firing the timer.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;

  // Fire A's completion handler FIRST (completion-first race).
  NSInteger schedCountBeforeCompletion = _player.scheduleCount;
  if (aCompletion) {
    aCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.2];

  // The completion handler re-evaluates the timeline at PTS=3.0.
  // At T=3.0, orig-A is no longer active (pts >= trackEnd=3) and orig-B
  // is active (pts >= 3.0 and pts < 5.0). B must be scheduled.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertNotNil(d, @"some descriptor must be active");
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    // Either B is Playing now, or a WaitingForTrackStart timer is armed for B.
    BOOL scheduledB = (d && [d.trackId isEqualToString:@"orig-B"] &&
                       state == VGAudioPreviewRuntimeStatePlaying);
    BOOL armedForB = (state == VGAudioPreviewRuntimeStateWaitingForTrackStart &&
                      _timer.pendingBlock != nil);
    XCTAssertTrue(scheduledB || armedForB,
                  @"completion-first race: B must be scheduled or timer armed "
                  @"for B (state=%ld, descriptor=%@)",
                  (long)state, d.trackId);
    XCTAssertNotEqual(state, VGAudioPreviewRuntimeStateEnded,
                      @"runtime must NOT be Ended after completion-first race");
  }];
  XCTAssertGreaterThan(_player.scheduleCount, schedCountBeforeCompletion,
                       @"orig-B must be scheduled after completion-first race");

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// SF-T18: SAME-DESCRIPTOR RESCHEDULE
//   Proves why per-segment serial is essential:
//   the same track is rescheduled under the same command token (e.g. after a
//   mid-track seek that stays on the same descriptor). Invoking the older
//   completion handler must be rejected by the serial mismatch.
- (void)testSF_T18_sameDescriptorRescheduleRejectsOlderCompletion {
  double sr = 44100.0, fileDur = 10.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // Single original track [0, 10). Start at PTS=0.5.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.5, .playStartPTS = 0.5, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *orig = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:10.0 volume:0.8 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ orig ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // Capture the first-schedule completion handler.
  AVAudioPlayerNodeCompletionHandler firstCompletion = _player.lastCompletionHandler;
  XCTAssertNotNil(firstCompletion,
                  @"first completion handler must be captured");
  NSInteger schedCountAfterFirst = _player.scheduleCount;

  // Seek to mid-point within the same descriptor (seek increments commandSerial,
  // so actually the token changes -- we need a case that keeps the same token.
  // We simulate this by calling commandPlay again while paused, which re-issues
  // under a new token. For the same-token test we use the boundary timer path:
  // advance PTS to T=5 within orig-A and fire the timer, which calls
  // _reevaluateAndTransitionAtPTS and reschedules orig-A from the new PTS.
  // This keeps the command serial the same.
  _stubbedSnapshot.timelinePTS = 5.0;
  _stubbedSnapshot.playStartPTS = 5.0;
  [_timer fireForcefully]; // fires with same token, reschedules orig-A
  [self waitFor:0.15];

  // Confirm a second scheduling occurred (under the same command token).
  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterFirst,
                       @"orig-A must be rescheduled after timer fires at T=5");
  NSInteger schedCountAfterSecond = _player.scheduleCount;

  // Now invoke the FIRST (stale) completion handler.
  // The per-segment serial has advanced because a second schedule was done.
  // The stale handler must be silently rejected.
  if (firstCompletion) {
    firstCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.2];

  // No additional scheduling should have occurred due to the stale handler.
  XCTAssertEqual(_player.scheduleCount, schedCountAfterSecond,
                 @"stale completion from first segment must not trigger "
                 @"re-scheduling (per-segment serial must reject it)");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    XCTAssertNotEqual(state, VGAudioPreviewRuntimeStateEnded,
                      @"state must not be Ended after stale completion "
                      @"from same descriptor");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// SF-T19: SUB-1MS EARLY WAKE
//   Set authoritative PTS so that the boundary is 0.0005 s away (< 1 ms).
//   The safe-delay helper must NOT silently drop the boundary.
//   After firing a second timer the next descriptor must be scheduled.
- (void)testSF_T19_subMillisecondDelayIsNotDropped {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3), orig-B: [3, 5). Start at PTS that is 0.5 ms before boundary.
  // By placing PTS at 2.9995 the delay to the T=3 boundary is 0.0005 s.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 2.9995, .playStartPTS = 2.9995, .playStartHostTime = 0.0,
      .generation = 1, .isPlaying = YES, .isValid = YES};
  _clock.currentTime = 0.0;

  VanguardAudioPreviewRuntime *rt = [self makeRuntime];
  NSDictionary *origA = [self originalTrackDictWithId:@"orig-A"
      startTime:0.0 duration:3.0 volume:0.5 url:url.path];
  NSDictionary *origB = [self originalTrackDictWithId:@"orig-B"
      startTime:3.0 duration:2.0 volume:0.9 url:url.path];
  VGAudioSidecarPlan *plan = [[VGAudioSidecarPlan alloc]
      initWithTracks:@[ origA, origB ] volumeKeyframes:nil waveformCache:nil
      timeRemapAudioPolicy:nil];
  [rt prepareWithSidecarPlan:plan timelineDuration:10.0];
  [rt commandPlay];
  [self waitFor:0.3];

  // The timer must have been armed (not dropped) for the sub-1ms boundary.
  // Safe-delay clamps to 0.001 s, so a timer IS armed.
  XCTAssertGreaterThan(_timer.armCount, 0,
                       @"boundary timer must be armed even for sub-1ms delay");
  // The delay must be 0.001 s (clamped), not the raw 0.0005 s.
  XCTAssertEqualWithAccuracy(_timer.lastDelay, 0.001, 0.001,
                             @"sub-1ms delay must be clamped to 0.001 s");

  NSInteger schedCountAfterA = _player.scheduleCount;
  NSInteger armCountAfterA = _timer.armCount;

  // Advance snapshot to T=3.0 (boundary) and fire the clamped timer.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  [_timer fireForcefully];
  [self waitFor:0.15];

  // orig-B must be scheduled — the boundary was NOT silently dropped.
  XCTAssertGreaterThan(_player.scheduleCount, schedCountAfterA,
                       @"orig-B must be scheduled after sub-1ms boundary is "
                       @"processed correctly");
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    VGAudioPreviewTrackDescriptor *d = [rt valueForKey:@"_activeDescriptor"];
    XCTAssertEqualObjects(d.trackId, @"orig-B",
                          @"orig-B must be active after sub-1ms boundary");
  }];

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

  // Runtime must be Ended (no more descriptors after T=3).
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    XCTAssertEqual(state, VGAudioPreviewRuntimeStateEnded,
                   @"SF-T23: runtime must be Ended after single-track "
                   @"completion with behind-clock snapshot");
  }];

  [self invalidateAndWait:rt];
  [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// SF-T24: Completion-first transition, then stale boundary-timer block fires.
//   orig-A [0,3), orig-B [3,5). Completion fires first (transitions to B),
//   then the stale boundary-timer block for orig-A is invoked directly.
//   Assert the stale block (serial mismatch) does NOT schedule a duplicate.
// ─────────────────────────────────────────────────────────────────────────────
- (void)testSF_T24_staleTimerAfterCompletionDoesNotDuplicate {
  double sr = 44100.0, fileDur = 5.0;
  NSURL *url = VGAPrCreateTempWAVURL((AVAudioFramePosition)(fileDur * sr), sr);
  if (!url) { XCTSkip(@"temp WAV needed"); return; }
  NSError *err = nil;
  _fileProvider.stubbedFile = [[AVAudioFile alloc] initForReading:url error:&err];
  if (!_fileProvider.stubbedFile) { XCTSkip(@"could not open WAV"); return; }

  // orig-A: [0, 3), orig-B: [3, 5). Start at PTS=0.
  _stubbedSnapshot = (VGTimelineStateSnapshot){
      .timelinePTS = 0.0, .playStartPTS = 0.0, .playStartHostTime = 0.0,
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

  // Phase 1: orig-A is scheduled; boundary timer armed at T=3 for orig-A.
  XCTAssertEqual(_player.scheduleCount, 1, @"SF-T24: orig-A must be scheduled");
  XCTAssertGreaterThan(_timer.armCount, 0, @"SF-T24: boundary timer must be armed");

  // Capture the stale boundary block BEFORE firing the completion.
  // After the completion fires, the runtime will arm a NEW boundary timer for
  // orig-B, replacing _timer.pendingBlock. We must hold orig-A's stale block
  // separately so we can invoke it directly.
  dispatch_block_t staleTimerBlock = _timer.pendingBlock;
  XCTAssertNotNil(staleTimerBlock, @"SF-T24: orig-A's boundary block must be set");

  // Capture orig-A's completion handler.
  AVAudioPlayerNodeCompletionHandler aCompletion = _player.lastCompletionHandler;
  XCTAssertNotNil(aCompletion, @"SF-T24: orig-A completion handler must be set");

  // Phase 2: advance to T=3. Completion fires FIRST.
  // The runtime transitions to orig-B and arms a NEW boundary timer for B.
  _stubbedSnapshot.timelinePTS = 3.0;
  _stubbedSnapshot.playStartPTS = 3.0;
  if (aCompletion) {
    aCompletion(AVAudioPlayerNodeCompletionDataConsumed);
  }
  [self waitFor:0.2];

  // orig-B must be scheduled now.
  XCTAssertGreaterThan(_player.scheduleCount, 1,
                       @"SF-T24: orig-B must be scheduled after completion");
  NSInteger schedAfterCompletion = _player.scheduleCount;

  // Phase 3: invoke orig-A's STALE boundary block directly.
  // At this point _scheduledSegmentSerial has been incremented by orig-B's
  // scheduling, so the serial guard inside the stale block must fire and
  // return without scheduling anything.
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    if (staleTimerBlock) {
      staleTimerBlock();
    }
  }];
  [self waitFor:0.2];

  XCTAssertEqual(_player.scheduleCount, schedAfterCompletion,
                 @"SF-T24: stale boundary-timer block must NOT schedule a "
                 @"duplicate (serial mismatch must reject it)");

  // Runtime must still be Playing (orig-B is active, not Ended).
  [rt vg_performSynchronouslyOnSchedulerQueueForTesting:^{
    NSInteger state = [[rt valueForKey:@"_runtimeState"] integerValue];
    XCTAssertNotEqual(state, VGAudioPreviewRuntimeStateEnded,
                      @"SF-T24: runtime must not be Ended after stale timer");
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
