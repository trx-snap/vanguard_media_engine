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

// ─── Test case ────────────────────────────────────────────────────────────────

@interface VanguardAudioRecorderTests : XCTestCase
@end

@implementation VanguardAudioRecorderTests {
    VGARTest_MockTimeProvider    *_time;
    VGARTest_MockBackendFactory  *_factory;
    VGARTest_MockBackend         *_backend;
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
                                                backendFactory:_factory];
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

    // Expected sequence: create -> prepare -> time -> record
    NSArray<NSString *> *expected = @[@"create", @"prepare", @"time", @"record"];
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

@end

#endif // VG_USE_V2_GRAPH
