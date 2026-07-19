// VanguardAudioRecorderTests.m
// Vanguard Media Engine — Audio Slice M
//
// Isolation tests for VanguardAudioRecorder.
//
// Test design:
//   - Uses real VanguardGraphRuntime (prepared via mock texture/channel seams
//     from VGTimelineSnapshotTest.m pattern) to produce real snapshots.
//   - Uses mock VGAudioRecorderTimeProvider to control CACurrentMediaTime().
//   - Uses mock VGAudioRecorderSessionManager to avoid real AVAudioSession.
//   - Uses mock VGAudioRecorderBackendFactory + mock VGAudioRecorderBackend
//     to avoid real AVAudioRecorder / real microphone / real file IO.
//   - All success-path tests go through the full startRecordingWithRuntime:
//     code path, exercising snapshot reading, PTS math, and session switching.
//
// Tests:
//   SM-1  Paused snapshot uses timelinePTS as startPTS.
//   SM-2  Playing snapshot computes playStartPTS + max(0, now - playStartHostTime).
//   SM-2b Negative elapsed (clock skew) clamps to 0.
//   SM-3  Invalid snapshot (unprepared runtime) → VGRecorderErrorInvalidSnapshot.
//   SM-4  Nil runtime → VGRecorderErrorNoRuntime.
//   SM-5  Empty outputPath → VGRecorderErrorBadOutputPath.
//   SM-6  Session activation failure → VGRecorderErrorSessionActivation;
//         AVAudioSession NOT marked switched (restorePlayback not called).
//   SM-7  Backend init failure → VGRecorderErrorRecorderInit;
//         AVAudioSession restored to Playback.
//   SM-8  Backend prepareToRecord failure → VGRecorderErrorRecorderInit;
//         AVAudioSession restored to Playback.
//   SM-9  Backend record() failure → VGRecorderErrorRecorderInit;
//         AVAudioSession restored to Playback.
//   SM-10 Successful stop returns filePath / startPTS / durationSeconds;
//         AVAudioSession restored.
//   SM-11 Second startRecording while active → VGRecorderErrorAlreadyRecording.
//   SM-12 cancelRecording restores Playback and clears state.

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "VanguardAudioRecorder.h"
#import "VGTimelineStateSnapshot.h"
#import "VanguardGraphRuntime.h"

#if VG_USE_V2_GRAPH

// ─── Mock infrastructure shared prefix: VGARTest_ ─────────────────────────────
// Prefix chosen to avoid ObjC runtime name collisions with VGSnap_ / VGAPr_
// mocks declared in other test files in the same bundle.

// ── Mock texture registry ─────────────────────────────────────────────────────

@interface VGARTest_MockTextureRegistry : NSObject <FlutterTextureRegistry>
@end
@implementation VGARTest_MockTextureRegistry
- (int64_t)registerTexture:(id<FlutterTexture>)texture { return 42; }
- (void)textureFrameAvailable:(int64_t)textureId {}
- (void)unregisterTexture:(int64_t)textureId {}
@end

// ── Mock method channel ───────────────────────────────────────────────────────

@interface VGARTest_MockMethodChannel : NSObject
- (void)invokeMethod:(NSString *)method arguments:(nullable id)arguments;
@end
@implementation VGARTest_MockMethodChannel
- (void)invokeMethod:(NSString *)method arguments:(nullable id)arguments {}
@end

// ── VanguardGraphRuntime seam ─────────────────────────────────────────────────
// Redeclare verified private accessors from VanguardGraphRuntime.m.
// These are the same accessors used by VGTimelineSnapshotTest.m.

@interface VanguardGraphRuntime (VGARTestSeam)
- (void)_timelinePlay;
- (void)_timelinePause;
- (void)_publishTimelineSnapshot;
@property(nonatomic, assign) double  timelineCurrentPTS;
@property(nonatomic, assign) double  timelinePlayStartTime;
@property(nonatomic, assign) double  timelineBasePTS;
@property(atomic,    assign) uint64_t timelineGeneration;
@property(nonatomic, assign) BOOL    timelineIsPlaying;
@end

// ── Mock source node (minimal, satisfies <VGSourceNode>) ──────────────────────

#import <UMF/VGSourceNode.h>
#import <UMF/VGNode.h>
#import <UMF/VGFrameResult.h>
#import <UMF/VGFrameRequest.h>

@interface VGARTest_MockSourceNode : NSObject <VGSourceNode>
@property(nonatomic, copy) NSString *nodeId;
@property(nonatomic, copy) NSString *nodeClass;
@property(nonatomic) VGNodeRole nodeRole;
@end

@implementation VGARTest_MockSourceNode

- (instancetype)init {
    self = [super init];
    if (self) {
        _nodeId = @"vgar_mock_source";
        _nodeClass = @"VGARTest_MockSourceNode";
        _nodeRole = VGNodeRoleSource;
    }
    return self;
}

// VGSourceNode
- (void)startProducing {}
- (void)stopProducing {}
- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    return [VGFrameResult skippedWithGeneration:request.generation];
}
- (void)seekTo:(CMTime)time generation:(uint64_t)gen {}

// VGNode
- (NSArray<VGMediaPort *> *)declaredPorts { return @[]; }
- (void)prepareWithContext:(VGGraphExecutionContext *)ctx
                completion:(void (^)(NSError * _Nullable))completion {
    completion(nil);
}
- (void)invalidate {}
- (nullable VGMediaFormat *)negotiateFormatForPort:(NSString *)portId
                                      inputFormats:(NSDictionary<NSString *, VGMediaFormat *> *)inputFormats {
    return nil;
}
@end

// ── Mock time provider ────────────────────────────────────────────────────────

@interface VGARTest_MockTimeProvider : NSObject <VGAudioRecorderTimeProvider>
@property(nonatomic) NSTimeInterval currentTime;
@end
@implementation VGARTest_MockTimeProvider
@end

// ── Mock session manager ──────────────────────────────────────────────────────

@interface VGARTest_MockSessionManager : NSObject <VGAudioRecorderSessionManager>
@property(nonatomic) BOOL activateShouldFail;
@property(nonatomic) BOOL headphonesConnected;
@property(nonatomic) NSInteger activateCount;
@property(nonatomic) NSInteger restoreCount;
@end

@implementation VGARTest_MockSessionManager

- (BOOL)activatePlayAndRecordWithError:(NSError **)error {
    _activateCount++;
    if (_activateShouldFail) {
        if (error) *error = [NSError errorWithDomain:@"MockSessionDomain"
                                                code:999
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           @"mock activation failure"}];
        return NO;
    }
    return YES;
}

- (void)restorePlayback { _restoreCount++; }
- (BOOL)isHeadphonesConnected { return _headphonesConnected; }

@end

// ── Mock backend ──────────────────────────────────────────────────────────────

@interface VGARTest_MockBackend : NSObject <VGAudioRecorderBackend>
@property(nonatomic) BOOL prepareShouldFail;
@property(nonatomic) BOOL recordShouldFail;
@property(nonatomic) NSInteger prepareCount;
@property(nonatomic) NSInteger recordCount;
@property(nonatomic) NSInteger stopCount;
/// Simulated elapsed time returned by currentTime after record starts.
@property(nonatomic) NSTimeInterval stubbedCurrentTime;
/// Tracks the recording state.
@property(nonatomic) BOOL isRecording;
@end

@implementation VGARTest_MockBackend

- (BOOL)prepareToRecord {
    _prepareCount++;
    return !_prepareShouldFail;
}

- (BOOL)record {
    _recordCount++;
    if (_recordShouldFail) { return NO; }
    _isRecording = YES;
    return YES;
}

- (void)stop {
    _stopCount++;
    _isRecording = NO;
}

- (NSTimeInterval)currentTime { return _stubbedCurrentTime; }

@end

// ── Mock backend factory ──────────────────────────────────────────────────────

@interface VGARTest_MockBackendFactory : NSObject <VGAudioRecorderBackendFactory>
/// When non-nil, returned for any backendWithURL: call.
@property(nonatomic, strong, nullable) VGARTest_MockBackend *stubbedBackend;
/// When YES, returns nil + error.
@property(nonatomic) BOOL shouldFail;
@end

@implementation VGARTest_MockBackendFactory

- (nullable id<VGAudioRecorderBackend>)backendWithURL:(NSURL *)url
                                             settings:(NSDictionary<NSString *, id> *)settings
                                                error:(NSError **)error {
    if (_shouldFail) {
        if (error) *error = [NSError errorWithDomain:@"MockBackendDomain"
                                                code:888
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           @"mock backend init failure"}];
        return nil;
    }
    return _stubbedBackend ?: [[VGARTest_MockBackend alloc] init];
}

@end

// ─── Test case ────────────────────────────────────────────────────────────────

@interface VanguardAudioRecorderTests : XCTestCase
@end

@implementation VanguardAudioRecorderTests {
    VGARTest_MockTimeProvider    *_time;
    VGARTest_MockSessionManager  *_session;
    VGARTest_MockBackendFactory  *_factory;
    VGARTest_MockBackend         *_backend;
    NSString                     *_tmpPath;
}

- (void)setUp {
    [super setUp];
    _time    = [[VGARTest_MockTimeProvider alloc] init];
    _session = [[VGARTest_MockSessionManager alloc] init];
    _backend = [[VGARTest_MockBackend alloc] init];
    _backend.stubbedCurrentTime = 3.5;   // default simulated recording duration

    _factory = [[VGARTest_MockBackendFactory alloc] init];
    _factory.stubbedBackend = _backend;

    _tmpPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"VGARTest_SliceM.m4a"];
    [[NSFileManager defaultManager] removeItemAtPath:_tmpPath error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:_tmpPath error:nil];
    [super tearDown];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Builds the system-under-test with shared mocks.
- (VanguardAudioRecorder *)makeRecorder {
    return [[VanguardAudioRecorder alloc] initWithTimeProvider:_time
                                                sessionManager:_session
                                                backendFactory:_factory];
}

/// Builds and returns a prepared VanguardGraphRuntime with mock seams.
- (VanguardGraphRuntime *)makePreparedRuntime {
    VGARTest_MockTextureRegistry *reg = [[VGARTest_MockTextureRegistry alloc] init];
    VGARTest_MockMethodChannel   *ch  = [[VGARTest_MockMethodChannel alloc] init];
    VanguardGraphRuntime *rt = [[VanguardGraphRuntime alloc]
                                    initWithTextureRegistry:reg
                                              methodChannel:(FlutterMethodChannel *)ch];
    VGARTest_MockSourceNode *src = [[VGARTest_MockSourceNode alloc] init];
    XCTestExpectation *exp = [self expectationWithDescription:@"prepare"];
    [rt prepareWithSourceNode:src completion:^(int64_t tid, NSError *err) {
        XCTAssertNil(err);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:5.0];
    return rt;
}

// ── SM-1: Paused snapshot uses timelinePTS ────────────────────────────────────

- (void)test_SM1_pausedSnapshotUsesTimelinePTS {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    // Drive to a known paused PTS by playing then pausing.
    [rt _timelinePlay];
    rt.timelineCurrentPTS = 5.0;
    [rt _publishTimelineSnapshot];
    [rt _timelinePause];

    VGTimelineStateSnapshot snap = [rt readTimelineStateSnapshot];
    XCTAssertTrue(snap.isValid);
    XCTAssertFalse(snap.isPlaying);
    XCTAssertEqual(snap.timelinePTS, 5.0);

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(err,  @"SM-1: start must succeed for paused runtime");
    XCTAssertNotNil(info);
    XCTAssertEqualWithAccuracy(info.startPTS, 5.0, 1e-9,
        @"SM-1: startPTS must equal timelinePTS when paused");
    XCTAssertEqual(_session.activateCount, 1, @"SM-1: session must be activated");

    [rt invalidate];
}

// ── SM-2: Playing snapshot computes estimated PTS ─────────────────────────────

- (void)test_SM2_playingSnapshotComputesEstimatedPTS {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    // Drive into playing state.
    [rt _timelinePlay];
    VGTimelineStateSnapshot snap = [rt readTimelineStateSnapshot];
    XCTAssertTrue(snap.isPlaying);

    // Inject mock time: now = playStartHostTime + 1.5 s.
    _time.currentTime = snap.playStartHostTime + 1.5;
    // Expected PTS = playStartPTS + max(0, 1.5) = 0.0 + 1.5 = 1.5
    double expectedPTS = snap.playStartPTS + 1.5;

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(err, @"SM-2: start must succeed for playing runtime");
    XCTAssertNotNil(info);
    XCTAssertEqualWithAccuracy(info.startPTS, expectedPTS, 1e-6,
        @"SM-2: startPTS must equal playStartPTS + elapsed");
    XCTAssertEqual(_session.activateCount, 1);

    [rt invalidate];
}

// ── SM-2b: Negative elapsed clamps to zero ────────────────────────────────────

- (void)test_SM2b_negativeElapsedClampedToZero {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    [rt _timelinePlay];
    VGTimelineStateSnapshot snap = [rt readTimelineStateSnapshot];

    // Set now to slightly before playStartHostTime (clock skew edge case).
    _time.currentTime = snap.playStartHostTime - 0.5;
    double expectedPTS = snap.playStartPTS;  // elapsed clamped to 0

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(err);
    XCTAssertNotNil(info);
    XCTAssertEqualWithAccuracy(info.startPTS, expectedPTS, 1e-9,
        @"SM-2b: negative elapsed must clamp to 0");

    [rt invalidate];
}

// ── SM-3: Unprepared (invalid) runtime → VGRecorderErrorInvalidSnapshot ───────

- (void)test_SM3_invalidSnapshotFails {
    // Unprepared runtime has isValid == NO.
    VGARTest_MockTextureRegistry *reg = [[VGARTest_MockTextureRegistry alloc] init];
    VGARTest_MockMethodChannel   *ch  = [[VGARTest_MockMethodChannel alloc] init];
    VanguardGraphRuntime *rt = [[VanguardGraphRuntime alloc]
                                    initWithTextureRegistry:reg
                                              methodChannel:(FlutterMethodChannel *)ch];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(info, @"SM-3: must fail for unprepared runtime");
    XCTAssertNotNil(err);
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err.code, VGRecorderErrorInvalidSnapshot);
    XCTAssertEqual(_session.activateCount, 0,
                   @"SM-3: session must NOT be activated on invalid snapshot");
    XCTAssertEqual(_session.restoreCount, 0,
                   @"SM-3: restorePlayback must NOT be called");

    [rt invalidate];
}

// ── SM-4: Nil runtime → VGRecorderErrorNoRuntime ─────────────────────────────

- (void)test_SM4_nilRuntimeFails {
    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:nil
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(info);
    XCTAssertNotNil(err);
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err.code, VGRecorderErrorNoRuntime);
    XCTAssertEqual(_session.activateCount, 0);
}

// ── SM-5: Empty outputPath → VGRecorderErrorBadOutputPath ────────────────────

- (void)test_SM5_emptyOutputPathFails {
    // Must reach path guard: use a prepared runtime.
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:@""
                                                               error:&err];
    XCTAssertNil(info);
    XCTAssertNotNil(err);
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err.code, VGRecorderErrorBadOutputPath);
    XCTAssertEqual(_session.activateCount, 0,
                   @"SM-5: session must NOT be activated for bad path");

    [rt invalidate];
}

// ── SM-6: Session activation failure → error; Playback NOT corrupted ──────────

- (void)test_SM6_sessionActivationFailureReturnsError {
    _session.activateShouldFail = YES;
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(info, @"SM-6: must fail when session activation fails");
    XCTAssertNotNil(err);
    // Top-level error must always be in VGRecorderErrorDomain with the correct code.
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain,
                          @"SM-6: top-level domain must be VGRecorderErrorDomain");
    XCTAssertEqual(err.code, VGRecorderErrorSessionActivation,
                   @"SM-6: code must be VGRecorderErrorSessionActivation");
    // The original collaborator error must be preserved for diagnostics.
    XCTAssertNotNil(err.userInfo[NSUnderlyingErrorKey],
                    @"SM-6: underlying session error must be present in NSUnderlyingErrorKey");
    XCTAssertEqual(_session.activateCount, 1,
                   @"SM-6: activate must be called exactly once");
    XCTAssertEqual(_session.restoreCount, 0,
                   @"SM-6: restorePlayback must NOT be called — session never switched");
    XCTAssertFalse(rec.isRecording, @"SM-6: recorder must not be in recording state");

    [rt invalidate];
}

// ── SM-7: Backend factory failure → VGRecorderErrorRecorderInit; Playback restored ──

- (void)test_SM7_backendFactoryFailureRestoresPlayback {
    _factory.stubbedBackend = nil;
    _factory.shouldFail = YES;
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(info);
    XCTAssertNotNil(err);
    // Top-level error must always be in VGRecorderErrorDomain with the correct code.
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain,
                          @"SM-7: top-level domain must be VGRecorderErrorDomain");
    XCTAssertEqual(err.code, VGRecorderErrorRecorderInit,
                   @"SM-7: code must be VGRecorderErrorRecorderInit");
    // The original collaborator error must be preserved for diagnostics.
    XCTAssertNotNil(err.userInfo[NSUnderlyingErrorKey],
                    @"SM-7: underlying backend error must be present in NSUnderlyingErrorKey");
    XCTAssertEqual(_session.activateCount, 1,
                   @"SM-7: session must have been activated before factory called");
    XCTAssertEqual(_session.restoreCount, 1,
                   @"SM-7: Playback must be restored after factory failure");
    XCTAssertFalse(rec.isRecording);

    [rt invalidate];
}

// ── SM-8: prepareToRecord failure → VGRecorderErrorRecorderInit; Playback restored ──

- (void)test_SM8_prepareToRecordFailureRestoresPlayback {
    _backend.prepareShouldFail = YES;
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(info);
    XCTAssertNotNil(err);
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err.code, VGRecorderErrorRecorderInit);
    XCTAssertEqual(_session.restoreCount, 1,
                   @"SM-8: Playback must be restored after prepareToRecord failure");
    XCTAssertFalse(rec.isRecording);

    [rt invalidate];
}

// ── SM-9: record() failure → VGRecorderErrorRecorderInit; Playback restored ───

- (void)test_SM9_recordFailureRestoresPlayback {
    _backend.recordShouldFail = YES;
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(info);
    XCTAssertNotNil(err);
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err.code, VGRecorderErrorRecorderInit);
    XCTAssertEqual(_session.restoreCount, 1,
                   @"SM-9: Playback must be restored after record() failure");
    XCTAssertFalse(rec.isRecording);

    [rt invalidate];
}

// ── SM-10: Successful stop returns {filePath, startPTS, durationSeconds} ──────

- (void)test_SM10_stopReturnsCorrectResult {
    _backend.stubbedCurrentTime = 7.25;   // simulate 7.25 s recorded
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    [rt _timelinePlay];
    rt.timelineCurrentPTS = 2.0;
    [rt _publishTimelineSnapshot];
    [rt _timelinePause];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *startErr = nil;
    VGAudioRecordingStartInfo *startInfo = [rec startRecordingWithRuntime:rt
                                                               outputPath:_tmpPath
                                                                    error:&startErr];
    XCTAssertNotNil(startInfo, @"SM-10: start must succeed");
    XCTAssertNil(startErr);
    double expectedStartPTS = startInfo.startPTS;

    XCTestExpectation *exp = [self expectationWithDescription:@"stop completion"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo *stopInfo, NSError *stopErr) {
        XCTAssertNil(stopErr, @"SM-10: stop must succeed");
        XCTAssertNotNil(stopInfo);
        XCTAssertEqualObjects(stopInfo.filePath, self->_tmpPath,
                              @"SM-10: filePath must match");
        XCTAssertEqualWithAccuracy(stopInfo.startPTS, expectedStartPTS, 1e-9,
                                   @"SM-10: startPTS must be preserved from start");
        XCTAssertEqualWithAccuracy(stopInfo.durationSeconds, 7.25, 1e-9,
                                   @"SM-10: durationSeconds must match backend.currentTime");
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:1.0];
    XCTAssertEqual(_session.restoreCount, 1,
                   @"SM-10: Playback must be restored after stop");
    XCTAssertFalse(rec.isRecording, @"SM-10: recorder must not be recording after stop");

    [rt invalidate];
}

// ── SM-11: Second start while recording → VGRecorderErrorAlreadyRecording ─────

- (void)test_SM11_secondStartWhileActiveReturnsAlreadyRecording {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err1 = nil;
    VGAudioRecordingStartInfo *info1 = [rec startRecordingWithRuntime:rt
                                                           outputPath:_tmpPath
                                                                error:&err1];
    XCTAssertNotNil(info1, @"SM-11: first start must succeed");
    XCTAssertNil(err1);
    XCTAssertTrue(rec.isRecording, @"SM-11: must be recording after first start");

    NSError *err2 = nil;
    VGAudioRecordingStartInfo *info2 = [rec startRecordingWithRuntime:rt
                                                           outputPath:_tmpPath
                                                                error:&err2];
    XCTAssertNil(info2, @"SM-11: second start must fail");
    XCTAssertNotNil(err2);
    XCTAssertEqualObjects(err2.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err2.code, VGRecorderErrorAlreadyRecording,
                   @"SM-11: error must be ALREADY_RECORDING");
    XCTAssertTrue(rec.isRecording, @"SM-11: first recording must still be active");
    // Session must have been activated only once (for the first start).
    XCTAssertEqual(_session.activateCount, 1, @"SM-11: session activated only once");
    XCTAssertEqual(_session.restoreCount, 0,
                   @"SM-11: Playback must NOT be restored — first recording still active");

    [rt invalidate];
}

// ── SM-12: cancelRecording restores Playback and clears state ─────────────────

- (void)test_SM12_cancelRestoresPlayback {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNotNil(info, @"SM-12: start must succeed");
    XCTAssertNil(err);
    XCTAssertTrue(rec.isRecording);

    [rec cancelRecording];

    XCTAssertFalse(rec.isRecording, @"SM-12: must not be recording after cancel");
    XCTAssertEqual(_session.restoreCount, 1,
                   @"SM-12: Playback must be restored after cancel");
    XCTAssertEqual(_backend.stopCount, 1,
                   @"SM-12: backend stop must be called");

    // Cancel again — must be idempotent.
    [rec cancelRecording];
    XCTAssertEqual(_session.restoreCount, 1,
                   @"SM-12: restorePlayback must not be called again on double-cancel");

    [rt invalidate];
}

@end

#endif // VG_USE_V2_GRAPH
