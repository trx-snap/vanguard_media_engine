// VGAudioSessionTransitionCoordinatorTests.m
// Vanguard Media Engine — Audio Slice N
//
// Isolation tests for VGAudioSessionTransitionCoordinator.

#import <XCTest/XCTest.h>
#import "VGAudioSessionTransitionCoordinator.h"

#if VG_USE_V2_GRAPH

// ── Mock Session Backend ──────────────────────────────────────────────────────

@interface VGCASTest_MockSessionBackend : NSObject <VGAudioSessionBackend>
@property(nonatomic, copy) NSString *stubbedCategory;
@property(nonatomic) AVAudioSessionCategoryOptions stubbedOptions;
@property(nonatomic) BOOL categoryShouldFail;
@property(nonatomic) BOOL activeShouldFail;
@property(nonatomic) BOOL rollbackActiveShouldFail;
@property(nonatomic) NSInteger setCategoryCount;
@property(nonatomic) NSInteger setActiveCount;
@property(nonatomic, strong) VGRouteSnapshot *stubbedRoute;
@property(nonatomic, strong) NSArray<VGPortSnapshot *> *stubbedAvailableInputs;
@end

@implementation VGCASTest_MockSessionBackend

- (instancetype)init {
    self = [super init];
    if (self) {
        _stubbedCategory = AVAudioSessionCategoryPlayback;
        _stubbedRoute = [[VGRouteSnapshot alloc] initWithInputs:@[] outputs:@[]];
        _stubbedAvailableInputs = @[];
    }
    return self;
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
          withOptions:(AVAudioSessionCategoryOptions)options
                error:(NSError * _Nullable * _Nullable)outError {
    _setCategoryCount++;
    if (_categoryShouldFail) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MockBackend" code:101 userInfo:nil];
        }
        return NO;
    }
    _stubbedCategory = category;
    _stubbedOptions = options;
    return YES;
}

- (BOOL)setActiveYesWithError:(NSError * _Nullable * _Nullable)outError {
    _setActiveCount++;
    // If category is Playback and we are doing rollback, check if rollbackActiveShouldFail is set
    if ([_stubbedCategory isEqualToString:AVAudioSessionCategoryPlayback] && _rollbackActiveShouldFail) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MockBackend" code:103 userInfo:nil];
        }
        return NO;
    }
    if ([_stubbedCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord] && _activeShouldFail) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"MockBackend" code:102 userInfo:nil];
        }
        return NO;
    }
    return YES;
}

- (VGRouteSnapshot *)currentRoute {
    return _stubbedRoute;
}

- (NSArray<VGPortSnapshot *> *)availableInputs {
    return _stubbedAvailableInputs;
}

@end

// ─── Test Case ────────────────────────────────────────────────────────────────

@interface VGAudioSessionTransitionCoordinatorTests : XCTestCase
@end

@implementation VGAudioSessionTransitionCoordinatorTests {
    VGCASTest_MockSessionBackend *_backend;
    VGAudioSessionTransitionCoordinator *_coordinator;
}

- (void)setUp {
    [super setUp];
    _backend = [[VGCASTest_MockSessionBackend alloc] init];
    _coordinator = [[VGAudioSessionTransitionCoordinator alloc] initWithSessionBackend:_backend];
}

- (void)test_initialStateIsPlayback {
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStatePlayback);
}

- (void)test_switchToPlayAndRecordSuccess {
    VGSessionTransitionOutcome *outcome = [_coordinator switchToPlayAndRecord];
    XCTAssertEqual(outcome.status, VGSessionTransitionStatusSuccess);
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStateRecord);
    XCTAssertEqualObjects(_backend.stubbedCategory, AVAudioSessionCategoryPlayAndRecord);
    AVAudioSessionCategoryOptions expectedOptions = AVAudioSessionCategoryOptionMixWithOthers |
                                                    AVAudioSessionCategoryOptionAllowBluetoothHFP |
                                                    AVAudioSessionCategoryOptionAllowBluetoothA2DP;
    XCTAssertEqual(_backend.stubbedOptions, expectedOptions);
    XCTAssertEqual(_backend.setCategoryCount, 1);
    XCTAssertEqual(_backend.setActiveCount, 1);
}

- (void)test_switchToPlayAndRecordCategoryFailure {
    _backend.categoryShouldFail = YES;
    VGSessionTransitionOutcome *outcome = [_coordinator switchToPlayAndRecord];
    XCTAssertEqual(outcome.status, VGSessionTransitionStatusFailedNoMutation);
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStatePlayback);
    XCTAssertEqual(_backend.setCategoryCount, 1);
    XCTAssertEqual(_backend.setActiveCount, 0);
}

- (void)test_switchToPlayAndRecordActiveFailureRollbackSuccess {
    _backend.activeShouldFail = YES;
    VGSessionTransitionOutcome *outcome = [_coordinator switchToPlayAndRecord];
    XCTAssertEqual(outcome.status, VGSessionTransitionStatusFailedKnownPlayback);
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStatePlayback);
    XCTAssertEqualObjects(_backend.stubbedCategory, AVAudioSessionCategoryPlayback);
    XCTAssertEqual(_backend.setCategoryCount, 2); // 1 to PlayAndRecord, 1 rollback
    XCTAssertEqual(_backend.setActiveCount, 2); // 1 initial, 1 rollback
}

- (void)test_switchToPlayAndRecordActiveFailureRollbackFailure {
    _backend.activeShouldFail = YES;
    _backend.rollbackActiveShouldFail = YES;
    VGSessionTransitionOutcome *outcome = [_coordinator switchToPlayAndRecord];
    XCTAssertEqual(outcome.status, VGSessionTransitionStatusFailedUnknown);
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStateUnknown);
    XCTAssertEqualObjects(_backend.stubbedCategory, AVAudioSessionCategoryPlayback);
    XCTAssertEqual(_backend.setCategoryCount, 2);
    XCTAssertEqual(_backend.setActiveCount, 2);
    XCTAssertNotNil(outcome.secondaryError);
}

- (void)test_restorePlaybackFromRecord {
    // Drive to Record state
    [_coordinator switchToPlayAndRecord];
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStateRecord);

    VGSessionTransitionOutcome *outcome = [_coordinator restorePlayback];
    XCTAssertEqual(outcome.status, VGSessionTransitionStatusSuccess);
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStatePlayback);
    XCTAssertEqualObjects(_backend.stubbedCategory, AVAudioSessionCategoryPlayback);
}

- (void)test_restorePlaybackFromPlaybackIsNoOp {
    VGSessionTransitionOutcome *outcome = [_coordinator restorePlayback];
    XCTAssertEqual(outcome.status, VGSessionTransitionStatusSuccess);
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStatePlayback);
    XCTAssertEqual(_backend.setCategoryCount, 0);
}

- (void)test_normalizationAttemptFromPlaybackIsNoOp {
    VGSessionTransitionOutcome *outcome = [_coordinator normalizationAttempt];
    XCTAssertEqual(outcome.status, VGSessionTransitionStatusSuccess);
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStatePlayback);
    XCTAssertEqual(_backend.setCategoryCount, 0);
}

- (void)test_normalizationAttemptFromUnknownSuccess {
    // Drive to Unknown state
    _backend.activeShouldFail = YES;
    _backend.rollbackActiveShouldFail = YES;
    [_coordinator switchToPlayAndRecord];
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStateUnknown);

    // Reset failure flags for normalization
    _backend.activeShouldFail = NO;
    _backend.rollbackActiveShouldFail = NO;

    VGSessionTransitionOutcome *outcome = [_coordinator normalizationAttempt];
    XCTAssertEqual(outcome.status, VGSessionTransitionStatusSuccess);
    XCTAssertEqual(_coordinator.state, VGSessionCoordinatorStatePlayback);
    XCTAssertEqualObjects(_backend.stubbedCategory, AVAudioSessionCategoryPlayback);
}

@end

#endif // VG_USE_V2_GRAPH
