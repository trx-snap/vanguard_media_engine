// VGGraphSchedulerSkeletonTest.m
// vanguard_media_engine — Phase 4, P4-2
//
// Regression gate for P4-2: Scheduler Skeleton Lifecycle.
//
// Contract reference:
//   packages/UMF/implementation/phase4_unified_plan.md § P4-2 (line 82–94)
//   plan regression table line 360:
//     "VGGraphSchedulerSkeletonTest | P4-2 | Init/start/invalidate lifecycle.
//      Double-invalidate idempotency."
//   plan INV-5 (line 420): invalidate idempotency via _Atomic(BOOL) _invalidated.
//
// What this test covers:
//   1.  init — scheduler is non-nil, isRunning = NO.
//   2.  startWithClock:device: — no crash; isRunning transitions to YES
//       (VanguardGraphScheduler.m:46 sets _isRunning = YES in P4-2).
//   3.  pause — no crash; isRunning returns to NO (.m:52).
//   4.  resume — no crash; isRunning returns to YES (.m:58).
//   5.  seekTo:generation: — no crash (dormant log-and-return, .m:62–67).
//   6.  invalidate — no crash; isRunning = NO (.m:116).
//   7.  double invalidate — idempotent; atomic CAS prevents double teardown (.m:103–104).
//   8.  startWithClock: after invalidate — silently ignored (.m:45 early return).
//
// What this test MUST NOT cover (out of scope):
//   - Frame delivery / didReceiveRawFrame: (P4-5, method does not exist yet)
//   - processEnvelope: filter execution (P4-5 scope)
//   - chain swap concurrency (VGSchedulerChainSwapTest, next step)
//   - sink property (P4-5, property does not exist yet)
//
// Metal device note:
//   startWithClock:device: accepts an id<MTLDevice>. The P4-2 implementation
//   (.m:44–48) does NOT dereference the device — it is logged and ignored
//   (dormant). MTLCreateSystemDefaultDevice() is used where available on
//   simulator. If the simulator returns nil (CI machines without GPU), the
//   nil device is passed; the dormant implementation does not crash on nil.
//
// Simulator-safe: no frame I/O, no GPU rendering, no physical device required.

#import <XCTest/XCTest.h>
#import <Metal/Metal.h>
#import <stdatomic.h>

// SUT
#import "VanguardGraphScheduler.h"

// UMF clock protocol — VGMasterClock stub satisfies startWithClock: parameter.
#import <UMF/VGMasterClock.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGSkeletonMockClock: minimal VGMasterClock stub
// ─────────────────────────────────────────────────────────────────────────────

/// Minimal clock stub satisfying the VGMasterClock protocol.
/// VanguardGraphScheduler.startWithClock:device: is dormant in P4-2 (.m:44–48)
/// and does not invoke any clock methods — the stub is never called.
@interface VGSkeletonMockClock : NSObject <VGMasterClock>
@end

@implementation VGSkeletonMockClock
- (CMTime)currentTime { return kCMTimeZero; }
- (double)currentTimeSeconds { return 0.0; }
- (BOOL)isActive { return NO; }
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - VGGraphSchedulerSkeletonTest
// ─────────────────────────────────────────────────────────────────────────────

@interface VGGraphSchedulerSkeletonTest : XCTestCase
@end

@implementation VGGraphSchedulerSkeletonTest

// ─────────────────────────────────────────────────────────────────────────────
// TC-S1 — init: scheduler is non-nil; isRunning is NO
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-2 contract:
///   - VanguardGraphScheduler can be instantiated.
///   - isRunning is NO immediately after init (VanguardGraphScheduler.m:37).
- (void)testInitSucceedsAndIsNotRunning {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];

    XCTAssertNotNil(scheduler,
        @"TC-S1 FAIL: VanguardGraphScheduler alloc/init returned nil — "
         "scheduler cannot be created.");

    XCTAssertFalse(scheduler.isRunning,
        @"TC-S1 FAIL: isRunning should be NO after init "
         "(VanguardGraphScheduler.m:37 sets _isRunning = NO).");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-S2 — startWithClock:device: does not crash; isRunning becomes YES
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-2 contract:
///   - startWithClock:device: executes without crash.
///   - isRunning transitions to YES (VanguardGraphScheduler.m:46).
///
/// Metal device note: MTLCreateSystemDefaultDevice() may return nil on
/// simulator CI. The P4-2 dormant implementation does NOT dereference the
/// device (logs and returns), so nil is safe to pass.
- (void)testStartWithClockDoesNotCrash {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];
    VGSkeletonMockClock    *clock     = [[VGSkeletonMockClock alloc] init];

    // May be nil on headless CI simulators — safe because .m:44–48 is dormant.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();

    XCTAssertNoThrow(
        [scheduler startWithClock:clock device:device],
        @"TC-S2 FAIL: startWithClock:device: threw an exception — "
         "dormant scheduler must not throw.");

    XCTAssertTrue(scheduler.isRunning,
        @"TC-S2 FAIL: isRunning should be YES after startWithClock:device: "
         "(VanguardGraphScheduler.m:46 sets _isRunning = YES).");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-S3 — pause does not crash; isRunning becomes NO
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-2 contract:
///   - pause executes without crash.
///   - isRunning returns to NO (VanguardGraphScheduler.m:52).
- (void)testPauseDoesNotCrash {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];
    VGSkeletonMockClock    *clock     = [[VGSkeletonMockClock alloc] init];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();

    [scheduler startWithClock:clock device:device];
    XCTAssertTrue(scheduler.isRunning, @"TC-S3 prerequisite: isRunning must be YES after start.");

    XCTAssertNoThrow(
        [scheduler pause],
        @"TC-S3 FAIL: pause threw an exception — dormant scheduler must not throw.");

    XCTAssertFalse(scheduler.isRunning,
        @"TC-S3 FAIL: isRunning should be NO after pause "
         "(VanguardGraphScheduler.m:52 sets _isRunning = NO).");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-S4 — resume does not crash; isRunning becomes YES
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-2 contract:
///   - resume executes without crash.
///   - isRunning returns to YES (VanguardGraphScheduler.m:58).
- (void)testResumeDoesNotCrash {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];
    VGSkeletonMockClock    *clock     = [[VGSkeletonMockClock alloc] init];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();

    [scheduler startWithClock:clock device:device];
    [scheduler pause];
    XCTAssertFalse(scheduler.isRunning, @"TC-S4 prerequisite: isRunning must be NO after pause.");

    XCTAssertNoThrow(
        [scheduler resume],
        @"TC-S4 FAIL: resume threw an exception — dormant scheduler must not throw.");

    XCTAssertTrue(scheduler.isRunning,
        @"TC-S4 FAIL: isRunning should be YES after resume "
         "(VanguardGraphScheduler.m:58 sets _isRunning = YES).");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-S5 — seekTo:generation: does not crash (dormant log-and-return)
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-2 contract:
///   - seekTo:generation: executes without crash in dormant state.
///   - isRunning is unaffected (VanguardGraphScheduler.m:62–67 logs only).
- (void)testSeekToDoesNotCrash {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];
    VGSkeletonMockClock    *clock     = [[VGSkeletonMockClock alloc] init];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();

    [scheduler startWithClock:clock device:device];

    XCTAssertNoThrow(
        [scheduler seekTo:1.5 generation:42],
        @"TC-S5 FAIL: seekTo:generation: threw an exception — "
         "dormant scheduler must not throw.");

    // seekTo: does not modify isRunning in P4-2.
    XCTAssertTrue(scheduler.isRunning,
        @"TC-S5 FAIL: isRunning must remain YES after seekTo:generation: — "
         "seek must not modify running state in dormant P4-2 implementation.");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-S6 — invalidate does not crash; isRunning becomes NO
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-2 contract / INV-5:
///   - invalidate executes without crash.
///   - isRunning is NO after invalidate (VanguardGraphScheduler.m:116).
- (void)testInvalidateDoesNotCrash {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];
    VGSkeletonMockClock    *clock     = [[VGSkeletonMockClock alloc] init];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();

    [scheduler startWithClock:clock device:device];
    XCTAssertTrue(scheduler.isRunning, @"TC-S6 prerequisite: isRunning must be YES before invalidate.");

    XCTAssertNoThrow(
        [scheduler invalidate],
        @"TC-S6 FAIL: invalidate threw an exception — must not throw.");

    XCTAssertFalse(scheduler.isRunning,
        @"TC-S6 FAIL: isRunning should be NO after invalidate "
         "(VanguardGraphScheduler.m:116 sets _isRunning = NO).");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-S7 — double invalidate is idempotent (INV-5, atomic CAS)
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies INV-5 / P4-2 plan:420:
///   - A second invalidate call is a no-op — no crash, no double teardown.
///   - Idempotency enforced by atomic_compare_exchange_strong on _invalidated
///     (VanguardGraphScheduler.m:103–104).
- (void)testDoubleInvalidateIsIdempotent {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];
    VGSkeletonMockClock    *clock     = [[VGSkeletonMockClock alloc] init];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();

    [scheduler startWithClock:clock device:device];
    [scheduler invalidate];

    // Second invalidate must not crash or throw.
    XCTAssertNoThrow(
        [scheduler invalidate],
        @"TC-S7 FAIL: second invalidate threw an exception — "
         "invalidate must be idempotent (VanguardGraphScheduler.m:103–104 "
         "atomic CAS prevents double teardown).");

    XCTAssertFalse(scheduler.isRunning,
        @"TC-S7 FAIL: isRunning must remain NO after second invalidate.");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-S8 — startWithClock: after invalidate is silently ignored
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-2 contract:
///   - startWithClock:device: after invalidate returns immediately without
///     setting isRunning = YES (VanguardGraphScheduler.m:45 early-return
///     when atomic_load(&_invalidated) is YES).
- (void)testStartAfterInvalidateIsIgnored {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];
    VGSkeletonMockClock    *clock     = [[VGSkeletonMockClock alloc] init];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();

    [scheduler invalidate];
    XCTAssertFalse(scheduler.isRunning,
        @"TC-S8 prerequisite: isRunning must be NO after invalidate.");

    // Must not crash, and must NOT set isRunning = YES.
    XCTAssertNoThrow(
        [scheduler startWithClock:clock device:device],
        @"TC-S8 FAIL: startWithClock:device: after invalidate threw — must not throw.");

    XCTAssertFalse(scheduler.isRunning,
        @"TC-S8 FAIL: isRunning must remain NO after startWithClock: on an "
         "invalidated scheduler (VanguardGraphScheduler.m:45 early return "
         "when _invalidated is YES).");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-S9 — applyThermalState: does not crash (dormant log-and-return)
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies P4-2 contract:
///   - applyThermalState: executes without crash.
///   - isRunning is unaffected (VanguardGraphScheduler.m:95–99).
///
/// Note: DEC-55 — isExpensive retained only for VanguardGraphRuntime.
/// applyThermalState: on the scheduler is a dormant stub in P4-2.
- (void)testApplyThermalStateDoesNotCrash {
    VanguardGraphScheduler *scheduler = [[VanguardGraphScheduler alloc] init];

    XCTAssertNoThrow(
        [scheduler applyThermalState:NSProcessInfoThermalStateSerious],
        @"TC-S9 FAIL: applyThermalState: threw — dormant scheduler must not throw.");

    XCTAssertNoThrow(
        [scheduler applyThermalState:NSProcessInfoThermalStateCritical],
        @"TC-S9 FAIL: applyThermalState: Critical threw.");

    XCTAssertNoThrow(
        [scheduler applyThermalState:NSProcessInfoThermalStateNominal],
        @"TC-S9 FAIL: applyThermalState: Nominal threw.");
}

@end
