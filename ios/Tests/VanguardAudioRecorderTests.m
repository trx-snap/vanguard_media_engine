// VanguardAudioRecorderTests.m
// Vanguard Media Engine — Audio Slice N
//
// Isolation tests for VanguardAudioRecorder.

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "VanguardAudioRecorder.h"
#import "VGTimelineStateSnapshot.h"
#import "VanguardGraphRuntime.h"

#if VG_USE_V2_GRAPH

static NSMutableArray<NSString *> *VGARTest_SharedTrace;

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

// ── Mock source node ──────────────────────────────────────────────────────────

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

- (void)startProducing {}
- (void)stopProducing {}
- (VGFrameResult *)pullFrame:(VGFrameRequest *)request {
    return [VGFrameResult skippedWithGeneration:request.generation];
}
- (void)seekTo:(CMTime)time generation:(uint64_t)gen {}

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
- (NSTimeInterval)currentTime {
    [VGARTest_SharedTrace addObject:@"time"];
    return _currentTime;
}
@end

// ── Mock backend ──────────────────────────────────────────────────────────────

@interface VGARTest_MockBackend : NSObject <VGAudioRecorderBackend>
@property(nonatomic) BOOL prepareShouldFail;
@property(nonatomic) BOOL recordShouldFail;
@property(nonatomic) NSInteger prepareCount;
@property(nonatomic) NSInteger recordCount;
@property(nonatomic) NSInteger stopCount;
@property(nonatomic) NSTimeInterval stubbedCurrentTime;
@property(nonatomic) BOOL isRecording;
@end

@implementation VGARTest_MockBackend

- (BOOL)prepareToRecord {
    [VGARTest_SharedTrace addObject:@"prepare"];
    _prepareCount++;
    return !_prepareShouldFail;
}

- (BOOL)record {
    [VGARTest_SharedTrace addObject:@"record"];
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
@property(nonatomic, strong, nullable) VGARTest_MockBackend *stubbedBackend;
@property(nonatomic) BOOL shouldFail;
@end

@implementation VGARTest_MockBackendFactory

- (nullable id<VGAudioRecorderBackend>)backendWithURL:(NSURL *)url
                                             settings:(NSDictionary<NSString *, id> *)settings
                                                error:(NSError **)error {
    [VGARTest_SharedTrace addObject:@"create"];
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

// ── Mock duration probe ───────────────────────────────────────────────────────

@interface VGARTest_MockDurationProbe : NSObject <VGAudioRecorderDurationProbe>
@property(nonatomic) NSTimeInterval stubbedDuration;
@property(nonatomic) BOOL shouldNeverComplete;
@property(nonatomic, copy, nullable) void (^capturedCompletion)(NSTimeInterval duration);
@property(nonatomic) NSInteger probeCount;
@property(nonatomic) BOOL callbackOffMain;
@end

@implementation VGARTest_MockDurationProbe

- (void)probeDurationOfFileAtURL:(NSURL *)fileURL
                      completion:(void (^)(NSTimeInterval duration))completion {
    [VGARTest_SharedTrace addObject:@"probe"];
    _probeCount++;
    if (_shouldNeverComplete) {
        _capturedCompletion = completion;
        return;
    }
    
    void (^cb)(NSTimeInterval) = [completion copy];
    if (_callbackOffMain) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            cb(self->_stubbedDuration);
        });
    } else {
        cb(_stubbedDuration);
    }
}

@end

// ─── Test case ────────────────────────────────────────────────────────────────

@interface VanguardAudioRecorderTests : XCTestCase
@end

@implementation VanguardAudioRecorderTests {
    VGARTest_MockTimeProvider    *_time;
    VGARTest_MockBackendFactory  *_factory;
    VGARTest_MockBackend         *_backend;
    VGARTest_MockDurationProbe   *_probe;
    NSString                     *_tmpPath;
}

- (void)setUp {
    [super setUp];
    VGARTest_SharedTrace = [NSMutableArray array];
    _time    = [[VGARTest_MockTimeProvider alloc] init];
    _backend = [[VGARTest_MockBackend alloc] init];
    _backend.stubbedCurrentTime = 3.5;

    _factory = [[VGARTest_MockBackendFactory alloc] init];
    _factory.stubbedBackend = _backend;

    _probe = [[VGARTest_MockDurationProbe alloc] init];
    _probe.stubbedDuration = 4.8;

    _tmpPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"VGARTest_SliceN.m4a"];
    [[NSFileManager defaultManager] removeItemAtPath:_tmpPath error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:_tmpPath error:nil];
    [super tearDown];
}

- (VanguardAudioRecorder *)makeRecorder {
    return [[VanguardAudioRecorder alloc] initWithTimeProvider:_time
                                                backendFactory:_factory
                                                 durationProbe:_probe
                                              probeTimeoutSecs:1.0];
}

- (VanguardAudioRecorder *)makeRecorderWithProbe:(id<VGAudioRecorderDurationProbe>)probe
                                        timeout:(NSTimeInterval)timeout {
    return [[VanguardAudioRecorder alloc] initWithTimeProvider:_time
                                                backendFactory:_factory
                                                 durationProbe:probe
                                              probeTimeoutSecs:timeout];
}

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

// ── Paused snapshot uses timelinePTS as startPTS ──────────────────────────────

- (void)test_pausedSnapshotUsesTimelinePTS {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    [rt _timelinePlay];
    rt.timelineCurrentPTS = 5.0;
    [rt _publishTimelineSnapshot];
    [rt _timelinePause];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(err);
    XCTAssertNotNil(info);
    XCTAssertEqualWithAccuracy(info.startPTS, 5.0, 1e-9);
    XCTAssertEqual(self->_backend.recordCount, 1);

    [rt invalidate];
}

// ── Playing snapshot computes playStartPTS + elapsed ──────────────────────────

- (void)test_playingSnapshotComputesEstimatedPTS {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    [rt _timelinePlay];
    VGTimelineStateSnapshot snap = [rt readTimelineStateSnapshot];
    XCTAssertTrue(snap.isPlaying);

    _time.currentTime = snap.playStartHostTime + 1.5;
    double expectedPTS = snap.playStartPTS + 1.5;

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(err);
    XCTAssertNotNil(info);
    XCTAssertEqualWithAccuracy(info.startPTS, expectedPTS, 1e-6);

    [rt invalidate];
}

// ── Negative elapsed (clock skew) clamps to 0 ─────────────────────────────────

- (void)test_negativeElapsedClampedToZero {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    [rt _timelinePlay];
    VGTimelineStateSnapshot snap = [rt readTimelineStateSnapshot];

    _time.currentTime = snap.playStartHostTime - 0.5;
    double expectedPTS = snap.playStartPTS;

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(err);
    XCTAssertNotNil(info);
    XCTAssertEqualWithAccuracy(info.startPTS, expectedPTS, 1e-9);

    [rt invalidate];
}

// ── Nil runtime → VGRecorderErrorNoRuntime ────────────────────────────────────

- (void)test_nilRuntimeFails {
    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:nil
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(info);
    XCTAssertNotNil(err);
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err.code, VGRecorderErrorNoRuntime);
}

// ── Empty outputPath → VGRecorderErrorBadOutputPath ───────────────────────────

- (void)test_emptyOutputPathFails {
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

    [rt invalidate];
}

// ── Backend factory failure → VGRecorderErrorRecorderInit ─────────────────────

- (void)test_backendFactoryFailureReturnsError {
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
    XCTAssertEqualObjects(err.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err.code, VGRecorderErrorRecorderInit);
    XCTAssertNotNil(err.userInfo[NSUnderlyingErrorKey]);

    [rt invalidate];
}

// ── prepareToRecord failure → VGRecorderErrorRecorderInit ─────────────────────

- (void)test_prepareToRecordFailureReturnsError {
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

    [rt invalidate];
}

// ── record() failure → VGRecorderErrorRecorderInit ────────────────────────────

- (void)test_recordFailureReturnsError {
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

    [rt invalidate];
}

// ── Second start while recording → VGRecorderErrorAlreadyRecording ────────────

- (void)test_secondStartWhileActiveReturnsAlreadyRecording {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err1 = nil;
    VGAudioRecordingStartInfo *info1 = [rec startRecordingWithRuntime:rt
                                                           outputPath:_tmpPath
                                                                error:&err1];
    XCTAssertNotNil(info1);
    XCTAssertNil(err1);

    NSError *err2 = nil;
    VGAudioRecordingStartInfo *info2 = [rec startRecordingWithRuntime:rt
                                                           outputPath:_tmpPath
                                                                error:&err2];
    XCTAssertNil(info2);
    XCTAssertNotNil(err2);
    XCTAssertEqualObjects(err2.domain, VGRecorderErrorDomain);
    XCTAssertEqual(err2.code, VGRecorderErrorAlreadyRecording);

    [rt invalidate];
}

// ── Prove backend creation → prepareToRecord → snapshot/time sampling ─────────
//    → record ordering.

- (void)test_startRecordingOrdering {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    [rt _timelinePlay];
    VGTimelineStateSnapshot snap = [rt readTimelineStateSnapshot];
    _time.currentTime = snap.playStartHostTime + 1.0;

    VanguardAudioRecorder *rec = [self makeRecorder];
    NSError *err = nil;
    VGAudioRecordingStartInfo *info = [rec startRecordingWithRuntime:rt
                                                          outputPath:_tmpPath
                                                               error:&err];
    XCTAssertNil(err);
    XCTAssertNotNil(info);

    // Expected sequence: create -> prepare -> time -> record -> time
    NSArray<NSString *> *expected = @[@"create", @"prepare", @"time", @"record", @"time"];
    XCTAssertEqualObjects(VGARTest_SharedTrace, expected);

    [rt invalidate];
}

// ── Prove invalid snapshot never calls record ─────────────────────────────────

- (void)test_invalidSnapshotNeverCallsRecord {
    // Unprepared runtime has isValid == NO
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
    XCTAssertNil(info);
    XCTAssertNotNil(err);
    XCTAssertEqual(err.code, VGRecorderErrorInvalidSnapshot);

    // Verify trace: "create" and "prepare" can run, but "record" must NOT run
    XCTAssertTrue([VGARTest_SharedTrace containsObject:@"create"]);
    XCTAssertTrue([VGARTest_SharedTrace containsObject:@"prepare"]);
    XCTAssertFalse([VGARTest_SharedTrace containsObject:@"record"]);

    [rt invalidate];
}

// ── Focused duration fallback tests ──────────────────────────────────────────

- (void)testStopDurationNormalPreserved {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 4.8;
    _time.currentTime = 105.0; // Monotonic elapsed = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 4.8, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationNegativeFallback {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = -5.0;
    _time.currentTime = 105.0; // Monotonic elapsed = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 5.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationEnormousPositivePreserved {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 76842.41;
    _time.currentTime = 105.0; // Monotonic elapsed = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 76842.41, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationNaNFallback {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = NAN;
    _time.currentTime = 105.0; // Monotonic elapsed = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 5.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationPositiveInfinityFallback {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = INFINITY;
    _time.currentTime = 105.0; // Monotonic elapsed = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 5.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationNegativeInfinityFallback {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = -INFINITY;
    _time.currentTime = 105.0; // Monotonic elapsed = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 5.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationPlausibleButWrongLowPreserved {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 0.2;
    _time.currentTime = 108.0; // Monotonic elapsed = 8.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 0.2, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationAtOneSecondBoundaryPreserved {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 4.0; // exactly 1.0s difference from 5.0s
    _time.currentTime = 105.0; // Monotonic elapsed = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 4.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationBeyondOneSecondBoundaryPreserved {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 3.99; // 1.01s difference from 5.0s
    _time.currentTime = 105.0; // Monotonic elapsed = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 3.99, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testRecorderReuseAfterStopUsesFreshTimestamp {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    // First run
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    _probe.stubbedDuration = 4.8;
    _time.currentTime = 105.0;
    XCTestExpectation *exp1 = [self expectationWithDescription:@"stop1"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        [exp1 fulfill];
    }];
    [self waitForExpectations:@[exp1] timeout:1.0];
    
    // Second run
    _time.currentTime = 200.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    _probe.stubbedDuration = NAN; // force fallback
    _time.currentTime = 208.0; // elapsed = 8.0 (if fresh), or 108.0 (if stale)
    
    XCTestExpectation *exp2 = [self expectationWithDescription:@"stop2"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 8.0, 1e-9);
        [exp2 fulfill];
    }];
    [self waitForExpectations:@[exp2] timeout:1.0];
    [rt invalidate];
}

- (void)testRecorderReuseAfterCancelUsesFreshTimestamp {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    // First run -> cancel
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    [rec cancelRecording];
    
    // Second run
    _time.currentTime = 200.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    _probe.stubbedDuration = NAN; // force fallback
    _time.currentTime = 208.0; // elapsed = 8.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 8.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testFailedRecordDoesNotCommitStaleTimingState {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    // Make record fail
    _backend.recordShouldFail = YES;
    _time.currentTime = 100.0;
    NSError *err = nil;
    XCTAssertNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:&err]);
    XCTAssertNotNil(err);
    
    // Restore record success
    _backend.recordShouldFail = NO;
    _time.currentTime = 200.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    _probe.stubbedDuration = NAN; // force fallback
    _time.currentTime = 208.0; // elapsed = 8.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 8.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testCancelDeletesPartialFile {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    // Create a dummy file to verify cancel deletes it
    [@"dummy data" writeToFile:_tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:_tmpPath]);
    
    [rec cancelRecording];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:_tmpPath]);
    [rt invalidate];
}

- (void)testEmittedDurationIsAlwaysFiniteAndNonnegative {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    // Simulate backward clock jump: stop time (95.0) < start time (100.0) -> elapsed < 0
    _time.currentTime = 95.0;
    _probe.stubbedDuration = NAN;
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqual(info.durationSeconds, 0.0);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

// ── New Slice O tests ──────────────────────────────────────────────────────────

- (void)testStopDurationExactPhysicalDiscrepancy {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 4.48;
    _time.currentTime = 106.42; // monotonic = 6.42
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 4.48, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationZeroProbeFallback {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 0.0;
    _time.currentTime = 105.0; // monotonic = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 5.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationNeverCompletesTimeoutFallback {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:0.1];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = YES;
    _time.currentTime = 105.0; // monotonic = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 5.0, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationLateCallbackIgnored {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:0.1];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = YES;
    _time.currentTime = 105.0; // monotonic = 5.0
    
    __block NSInteger callbackCount = 0;
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        callbackCount++;
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 5.0, 1e-9);
        [exp fulfill];
    }];
    
    [self waitForExpectations:@[exp] timeout:1.0];
    
    XCTAssertNotNil(_probe.capturedCompletion);
    _probe.capturedCompletion(10.0);
    
    XCTAssertEqual(callbackCount, 1);
    [rt invalidate];
}

- (void)testStopDurationRepeatedCallbacksDeliverOnce {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = YES;
    _time.currentTime = 105.0; // monotonic = 5.0
    
    __block NSInteger callbackCount = 0;
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        callbackCount++;
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 4.5, 1e-9);
        [exp fulfill];
    }];
    
    _probe.capturedCompletion(4.5);
    [self waitForExpectations:@[exp] timeout:1.0];
    
    _probe.capturedCompletion(7.5);
    
    XCTAssertEqual(callbackCount, 1);
    [rt invalidate];
}

- (void)testStopDurationSynchronousCallbackWorks {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 4.2;
    _probe.callbackOffMain = NO; // synchronous
    _time.currentTime = 105.0; // monotonic = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 4.2, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationOffMainCallbackMarshalled {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 4.2;
    _probe.callbackOffMain = YES; // off-main
    _time.currentTime = 105.0; // monotonic = 5.0
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertTrue([NSThread isMainThread]);
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 4.2, 1e-9);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationProbeFirstPreventsTimeout {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:0.2];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.stubbedDuration = 4.2;
    _time.currentTime = 105.0;
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(error);
        XCTAssertNotNil(info);
        XCTAssertEqualWithAccuracy(info.durationSeconds, 4.2, 1e-9);
        [exp fulfill];
    }];
    
    [self waitForExpectations:@[exp] timeout:1.0];
    
    XCTestExpectation *delayExp = [self expectationWithDescription:@"delay"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [delayExp fulfill];
    });
    [self waitForExpectations:@[delayExp] timeout:1.0];
    [rt invalidate];
}

- (void)testStopDurationIsolatedPerStop {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:0.1];
    
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    _probe.shouldNeverComplete = YES;
    
    _time.currentTime = 105.0;
    
    XCTestExpectation *exp1 = [self expectationWithDescription:@"stop1"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertEqualWithAccuracy(info.durationSeconds, 5.0, 1e-9);
        [exp1 fulfill];
    }];
    
    [self waitForExpectations:@[exp1] timeout:1.0];
    
    _time.currentTime = 200.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = NO;
    _probe.stubbedDuration = 3.3;
    _time.currentTime = 205.0;
    
    XCTestExpectation *exp2 = [self expectationWithDescription:@"stop2"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertEqualWithAccuracy(info.durationSeconds, 3.3, 1e-9);
        [exp2 fulfill];
    }];
    [self waitForExpectations:@[exp2] timeout:1.0];
    [rt invalidate];
}

- (void)testCancelDoesNotInvokeProbeAndPreservesDeletion {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorder];
    
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    [@"dummy" writeToFile:_tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:_tmpPath]);
    
    _probe.probeCount = 0;
    [rec cancelRecording];
    
    XCTAssertEqual(_probe.probeCount, 0);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:_tmpPath]);
    [rt invalidate];
}

- (void)testZeroTimeoutDefaultsSafely {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:0.0];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = YES;
    _time.currentTime = 105.0;
    
    __block BOOL called = NO;
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        called = YES;
    }];
    
    XCTestExpectation *delay = [self expectationWithDescription:@"delay"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [delay fulfill];
    });
    [self waitForExpectations:@[delay] timeout:1.0];
    XCTAssertFalse(called);
    
    if (_probe.capturedCompletion) {
        _probe.capturedCompletion(1.5);
    }
    [rt invalidate];
}

- (void)testNegativeTimeoutDefaultsSafely {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:-1.0];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = YES;
    _time.currentTime = 105.0;
    
    __block BOOL called = NO;
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        called = YES;
    }];
    
    XCTestExpectation *delay = [self expectationWithDescription:@"delay"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [delay fulfill];
    });
    [self waitForExpectations:@[delay] timeout:1.0];
    XCTAssertFalse(called);
    
    if (_probe.capturedCompletion) {
        _probe.capturedCompletion(1.5);
    }
    [rt invalidate];
}

- (void)testNaNTimeoutDefaultsSafely {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:NAN];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = YES;
    _time.currentTime = 105.0;
    
    __block BOOL called = NO;
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        called = YES;
    }];
    
    XCTestExpectation *delay = [self expectationWithDescription:@"delay"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [delay fulfill];
    });
    [self waitForExpectations:@[delay] timeout:1.0];
    XCTAssertFalse(called);
    
    if (_probe.capturedCompletion) {
        _probe.capturedCompletion(1.5);
    }
    [rt invalidate];
}

- (void)testPosInfinityTimeoutDefaultsSafely {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:INFINITY];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = YES;
    _time.currentTime = 105.0;
    
    __block BOOL called = NO;
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        called = YES;
    }];
    
    XCTestExpectation *delay = [self expectationWithDescription:@"delay"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [delay fulfill];
    });
    [self waitForExpectations:@[delay] timeout:1.0];
    XCTAssertFalse(called);
    
    if (_probe.capturedCompletion) {
        _probe.capturedCompletion(1.5);
    }
    [rt invalidate];
}

- (void)testNegInfinityTimeoutDefaultsSafely {
    VanguardGraphRuntime *rt = [self makePreparedRuntime];
    VanguardAudioRecorder *rec = [self makeRecorderWithProbe:_probe timeout:-INFINITY];
    _time.currentTime = 100.0;
    XCTAssertNotNil([rec startRecordingWithRuntime:rt outputPath:_tmpPath error:nil]);
    
    _probe.shouldNeverComplete = YES;
    _time.currentTime = 105.0;
    
    __block BOOL called = NO;
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        called = YES;
    }];
    
    XCTestExpectation *delay = [self expectationWithDescription:@"delay"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [delay fulfill];
    });
    [self waitForExpectations:@[delay] timeout:1.0];
    XCTAssertFalse(called);
    
    if (_probe.capturedCompletion) {
        _probe.capturedCompletion(1.5);
    }
    [rt invalidate];
}

- (void)testLegacyTwoArgumentInitializerUsable {
    VanguardAudioRecorder *rec = [[VanguardAudioRecorder alloc] initWithTimeProvider:_time backendFactory:_factory];
    XCTAssertNotNil(rec);
}

- (void)testStopNotRecordingReturnsNotRecordingWithoutProbing {
    VanguardAudioRecorder *rec = [self makeRecorder];
    _probe.probeCount = 0;
    
    XCTestExpectation *exp = [self expectationWithDescription:@"stop"];
    [rec stopRecordingWithCompletion:^(VGAudioRecordingStopInfo * _Nullable info, NSError * _Nullable error) {
        XCTAssertNil(info);
        XCTAssertNotNil(error);
        XCTAssertEqual(error.code, VGRecorderErrorNotRecording);
        [exp fulfill];
    }];
    [self waitForExpectations:@[exp] timeout:1.0];
    XCTAssertEqual(_probe.probeCount, 0);
}

@end

#endif // VG_USE_V2_GRAPH
