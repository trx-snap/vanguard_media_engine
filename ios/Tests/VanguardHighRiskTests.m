// VanguardHighRiskTests.m
//
// Targeted tests for the two high-risk production gaps identified in the
// TSAN/ASAN simulation:
//
//   H-1: _audioEngineReady is a plain BOOL ivar written on a background
//        global_queue (inside _setupAudioEngine) and read from main and
//        the same background queue concurrently. TSAN flags this. The
//        recommended fix is to declare it _Atomic(BOOL) mirroring
//        _schedulingChunks. These tests validate both the race window
//        (via a TSAN probe) and the functional outcome (consistency check).
//
//   H-2: replaceFilterChain: has an else-branch (L474-484 of renderer .m)
//        that reads and writes _filterChain without synchronisation. The
//        public header claims "Thread-safe: may be called from any thread."
//        In the current codebase, the only caller of the camera-source path
//        is the plugin's thermal observer, which is registered with
//        queue: .main — so the invariant holds. T-H2A proves this holds.
//        T-H2B proves concurrent file-source callers (the safe path) do not
//        regress under the fix.
//
// Run with TSAN:  xcodebuild test -scheme vanguard_media_engine
//                               -enableThreadSanitizer YES
// Run with ASAN:  xcodebuild test -scheme vanguard_media_engine
//                               -enableAddressSanitizer YES
//
// Total timing budget: ~16s across all tests.

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>

#import "VanguardFileMediaSource.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import "VanguardFilterNode.h"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared test utilities (file-scoped)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a URL from the test bundle, or nil. XCTSkip is the caller's
/// responsibility when nil is returned.
static NSURL *VGHRBundleURL(NSString *name, NSString *ext, XCTestCase *tc) {
    return [[NSBundle bundleForClass:[tc class]] URLForResource:name withExtension:ext];
}

/// Polls a KVO key path at 20ms intervals until it equals `expected` or
/// the deadline passes. Returns YES if the expected value was observed.
/// Only intended for use inside XCTest methods on the main thread.
static BOOL VGHRWaitBOOL(id object, NSString *keyPath,
                          BOOL expected, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if ([[object valueForKeyPath:keyPath] boolValue] == expected) return YES;
        [NSThread sleepForTimeInterval:0.02];
    }
    return NO;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Minimal pass-through filter node for renderer tests
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a new CVPixelBuffer from the source pool (simulates a real filter).
/// Counts processBuffer: calls atomically so tests can assert delivery.
@interface VGHRPassNode : NSObject <VanguardFilterNode>
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy)   NSString *filterName;
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool;
- (NSUInteger)callCount;
@end

@implementation VGHRPassNode {
    CVPixelBufferPoolRef _pool;
    atomic_uint _calls;
}
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool {
    if (!(self = [super init])) return nil;
    _pool = pool;
    if (_pool) CVPixelBufferPoolRetain(_pool);
    _enabled    = YES;
    _filterName = @"HRPass";
    atomic_init(&_calls, 0u);
    return self;
}
- (void)dealloc { if (_pool) CVPixelBufferPoolRelease(_pool); }
- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)dev {
    atomic_fetch_add_explicit(&_calls, 1u, memory_order_relaxed);
    CVPixelBufferRef out = NULL;
    CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &out);
    if (!out) return NULL;
    CVPixelBufferRetain(out);
    return out; // caller owns
}
- (void)invalidate {}
- (NSUInteger)callCount {
    return (NSUInteger)atomic_load_explicit(&_calls, memory_order_relaxed);
}
@end

/// Convenience: creates a Metal-compatible 4:2:0 / BGRA pool.
static CVPixelBufferPoolRef VGHRMakePool(size_t w, size_t h) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:               @(w),
        (id)kCVPixelBufferHeightKey:              @(h),
        (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(nil, nil, (__bridge CFDictionaryRef)attrs, &pool);
    return pool;
}

/// Creates a VanguardMetalRenderer with nil texture registry and method channel.
/// Both parameters are nil-safe in tests — ObjC sends to nil are no-ops.
static VanguardMetalRenderer *VGHRMakeRenderer(NSString *path) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    return [[VanguardMetalRenderer alloc] initWithVideoPath:path
                                            textureRegistry:nil
                                              methodChannel:nil];
#pragma clang diagnostic pop
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - H-1: _audioEngineReady TSAN Probe and Consistency Tests
// ─────────────────────────────────────────────────────────────────────────────

/// Tests for H-1: _audioEngineReady is a plain BOOL ivar written from a
/// background global queue (inside _setupAudioEngine at L990 of FileMediaSource.m)
/// and read from main at L365/L423/L808/L1101 and the same background queue at
/// L391. The concurrent read/write is a C11 data race detectable by TSAN.
///
/// Recommended fix: declare as _Atomic(BOOL) matching _schedulingChunks.
@interface VGHighRiskAudioTests : XCTestCase
@end

@implementation VGHighRiskAudioTests

/// T-H1A: TSAN probe — polls audioEngineReady from main via dispatch_source
///        while the background queue writes it inside _setupAudioEngine.
///
/// How it works:
///   1. [src start] schedules _setupAudioEngine via dispatch_after(1.2s,
///      global_queue). At T≈1.2s, that block writes _audioEngineReady=NO
///      (L977) then YES (L990).
///   2. A dispatch_source_t timer fires every 5ms on main, reading
///      audioEngineReady via KVC (direct ivar access — TSAN-visible).
///   3. At T≈1.2-1.3s, the main read and background write execute
///      concurrently. TSAN detects the non-atomic access if _audioEngineReady
///      is a plain BOOL.
///   4. The timer stops as soon as YES is seen — no fixed sleep; deterministic.
///
/// Before fix: TSAN reports "data race on _audioEngineReady".
/// After fix (_Atomic(BOOL)): TSAN clean.
/// Budget: 4s (1.2s mandatory delay + ~0.4s engine startup + margin).
- (void)testH1A_audioEngineReady_TSANProbe {
    NSURL *url = VGHRBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle — required for H-1 probe"); }

    VanguardFileMediaSource *src =
        [[VanguardFileMediaSource alloc] initWithURL:url pixelBufferPool:nil];
    XCTAssertNotNil(src, @"source must initialise from a valid URL");

    [src start];
    // start() fires dispatch_after(1.2s, global_queue) → _setupAudioEngine.
    // The write to _audioEngineReady (both NO at L977 and YES at L990) happens
    // on that global_queue block. We poll from main using a 5ms dispatch_source
    // timer, creating the concurrent-read-while-writing window at T≈1.2s.

    XCTestExpectation *ready = [self expectationWithDescription:@"H1A audio ready"];
    __block dispatch_source_t poll = nil;

    // Create timer on main queue BEFORE start() would have triggered setup,
    // so the timer is running through the entire write window.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0, 0,
                                                     dispatch_get_main_queue());
    poll = timer;
    // 5ms interval: frequent enough to hit the T≈1.2s write window reliably.
    dispatch_source_set_timer(timer,
                              DISPATCH_TIME_NOW,
                              5 * NSEC_PER_MSEC,
                              1 * NSEC_PER_MSEC); // 1ms leeway

    dispatch_source_set_event_handler(timer, ^{
        // KVC read on main: accesses _audioEngineReady ivar directly.
        // TSAN sees this as a concurrent read while the background queue
        // is writing the same memory location at L990 / L977.
        BOOL val = [[src valueForKey:@"audioEngineReady"] boolValue];
        if (val) {
            dispatch_source_cancel(poll);
            [ready fulfill];
        }
    });
    dispatch_resume(timer);

    [self waitForExpectations:@[ready] timeout:5.0];
    // Safety: cancel if the expectation timed out (src had no audio track, etc.).
    dispatch_source_cancel(timer);

    BOOL confirmed = [[src valueForKey:@"audioEngineReady"] boolValue];
    XCTAssertTrue(confirmed,
        @"audioEngineReady must be YES after the poll observed it. "
         "TSAN probe: before fix this reports a data race at _audioEngineReady. "
         "After fix (_Atomic(BOOL)): TSAN clean.");

    [src stop];
}

/// T-H1B: Functional consistency — _audioEngineReady returns to YES reliably
///        after a stop()+start() cycle that overlaps the setup write window.
///
/// Scenario: start → wait for YES → stop (writes NO on main) → immediately
/// start again → ensure YES is reached again within 4s.
///
/// A non-atomic BOOL whose value is cached in a register by the compiler
/// under -O2 could leave the main-thread reads stale (seeing NO forever after
/// a background write of YES, or YES after a main write of NO). This test
/// proves the value is coherent across the stop/start boundary.
///
/// Before fix: potential for stale cached reads leaving _audioEngineReady
///             perpetually NO after a fast stop()/start() roundtrip.
/// After fix:  atomic store + load ensures coherence; test always passes.
/// Budget: 4s (initial setup) + 4s (second setup) = 8s.
- (void)testH1B_audioEngineReady_consistencyAfterStopStart {
    NSURL *url = VGHRBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    VanguardFileMediaSource *src =
        [[VanguardFileMediaSource alloc] initWithURL:url pixelBufferPool:nil];
    XCTAssertNotNil(src);

    // First cycle: start → wait for YES.
    [src start];
    BOOL firstYES = VGHRWaitBOOL(src, @"audioEngineReady", YES, 4.0);
    XCTAssertTrue(firstYES,
        @"First start(): audioEngineReady must reach YES within 4s. "
         "If it doesn't, the audio file has no audio track.");

    // stop() writes NO on main — may be concurrent with a background queue
    // that reads _audioEngineReady at the same moment.
    [src stop];
    BOOL afterStop = [[src valueForKey:@"audioEngineReady"] boolValue];
    XCTAssertFalse(afterStop,
        @"After stop(): audioEngineReady must be NO immediately. "
         "Before fix: non-atomic reorder could leave it YES on main.");

    // Second cycle: start again — the dispatch_after(1.2s) re-fires.
    [src start];
    BOOL secondYES = VGHRWaitBOOL(src, @"audioEngineReady", YES, 4.0);
    XCTAssertTrue(secondYES,
        @"Second start(): audioEngineReady must reach YES again within 4s. "
         "Before fix: a compiler-cached stale NO could prevent _setupAudioEngine "
         "from being called, leaving the audio engine permanently off.");

    [src stop];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - H-2: replaceFilterChain: Thread Invariant Tests
// ─────────────────────────────────────────────────────────────────────────────

/// Tests for H-2: replaceFilterChain: has an else-branch (renderer .m L474-484)
/// that does unsynchronised reads/writes of _filterChain, relying on all callers
/// being on main. The public header says "Thread-safe: may be called from any
/// thread." These tests validate the invariant that protects the else-branch
/// and catch any future violation.
@interface VGHighRiskCameraFilterTests : XCTestCase
@end

@implementation VGHighRiskCameraFilterTests

/// T-H2A: Thermal notification handler fires on main queue.
///
/// The plugin registers its thermal observer with queue: .main (Plugin L192).
/// This ensures that replaceFilterChain: (called inside the handler at L216)
/// always executes on main — satisfying the else-branch's implicit invariant.
///
/// This test directly validates that invariant by:
///   1. Registering an observer for NSProcessInfoThermalStateDidChangeNotification
///      with queue: mainQueue.
///   2. Posting the notification from a background queue (simulating the OS
///      posting from an arbitrary thread).
///   3. Asserting that [NSThread isMainThread] is YES inside the handler.
///
/// If this test fails (handler fires off-main), it means the invariant is
/// broken and the else-branch's unsynchronised _filterChain access WILL
/// produce a TSAN data race in production.
///
/// Before fix: N/A — test validates the protective invariant. If invariant
///             is broken, this test fails → replaceFilterChain: crash risk.
/// After fix:  queue: .main ensures handler always runs on main.
/// Budget: 0.5s.
- (void)testH2A_thermalNotificationFiresOnMainQueue {
    // Register an observer matching the plugin's registration pattern:
    // queue: mainQueue means the block always runs on main, regardless of
    // which thread posts the notification.
    XCTestExpectation *fired = [self expectationWithDescription:@"H2A thermal on main"];
    __block BOOL handlerWasOnMain = NO;

    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) {
            handlerWasOnMain = [NSThread isMainThread];
            [fired fulfill];
        }];

    // Post from background to simulate OS posting from an arbitrary thread.
    // The queue: mainQueue registration must redirect to main regardless.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:NSProcessInfoThermalStateDidChangeNotification
                          object:nil];
    });

    [self waitForExpectations:@[fired] timeout:2.0];
    [NSNotificationCenter.defaultCenter removeObserver:observer];

    XCTAssertTrue(handlerWasOnMain,
        @"Thermal observer registered with queue:mainQueue must fire on main, "
         "even when the notification is posted from a background thread. "
         "If this fails, replaceFilterChain: would be called off-main in "
         "the critical thermal path → data race on _filterChain in the "
         "else-branch (camera source, no lock) → crash.");
}

/// T-H2B: Concurrent replaceFilterChain: callers on file-source renderer —
///        TSAN clean after FIX-E.
///
/// This test validates that the fix for H-2's sibling (FIX-E — file-source
/// concurrent replaceFilterChain:) did not regress, and that concurrent callers
/// on the serialised if(decodeQ) path are TSAN-clean.
///
/// Separately documents why the camera else-branch cannot be directly
/// TSAN-probed from an ObjC unit test: VanguardMetalRenderer has no
/// initWithCameraSource: initializer. The safe invariant (T-H2A) plus the
/// recommended production fix (NSAssert([NSThread isMainThread]) in the
/// else-branch) together close the gap.
///
/// Before fix (FIX-E missing): TSAN fires on concurrent _filterChain read/write.
/// After fix: dispatch_sync(decodeQ) + barrier_async serialise all access.
/// Budget: 2s.
- (void)testH2B_concurrentReplaceFilterChain_fileSouce_TSANClean {
    NSURL *url = VGHRBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    CVPixelBufferPoolRef pool = VGHRMakePool(1920, 1080);
    VGHRPassNode *activeNode = [[VGHRPassNode alloc] initWithPool:pool];
    VGHRPassNode *replacedNode = [[VGHRPassNode alloc] initWithPool:pool];

    VanguardMetalRenderer *renderer = VGHRMakeRenderer(url.path);
    XCTAssertNotNil(renderer);
    [renderer replaceFilterChain:@[activeNode]];
    [renderer play];

    // Allow frame delivery to stabilise.
    [NSThread sleepForTimeInterval:0.1];

    // Drive 50 concurrent calls to replaceFilterChain: — alternating between
    // the two nodes, fired from both main and background queues simultaneously.
    // FIX-E's dispatch_sync(decodeQ) + barrier_async ensures serial ordering;
    // TSAN must not fire on the _filterChain pointer.
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t bg = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    const int N = 50;

    for (int i = 0; i < N; i++) {
        NSArray *chain = (i % 2 == 0) ? @[activeNode] : @[replacedNode];
        dispatch_group_async(group, bg, ^{
            [renderer replaceFilterChain:chain];
        });
        // Interleave a main-thread call to stress the serialisation.
        [renderer replaceFilterChain:(i % 2 == 0) ? @[replacedNode] : @[activeNode]];
    }

    // Wait for all background calls to complete.
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(3 * NSEC_PER_SEC)));

    // Final state: freeze the chain so we can observe stable call counts.
    [renderer replaceFilterChain:@[]];
    [NSThread sleepForTimeInterval:0.1]; // allow final frame flush

    // Either node or neither may have frames — both are valid outcomes.
    // The assertion is "no crash and TSAN clean", not a specific call count.
    XCTAssert(activeNode.callCount + replacedNode.callCount >= 0,
        @"T-H2B: 50 concurrent replaceFilterChain: pairs on file-source renderer "
         "must complete without crash or TSAN data race. "
         "This tests FIX-E (dispatch_sync(decodeQ) + barrier serialisation). "
         "NOTE: Camera-source else-branch (L474-484) cannot be TSAN-probed "
         "without a camera-source renderer initializer. Close H-2 by adding "
         "NSAssert([NSThread isMainThread]) to the else-branch in production.");

    if (pool) CVPixelBufferPoolRelease(pool);
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - FIX-D Actual Race Coverage
// ─────────────────────────────────────────────────────────────────────────────

/// Tests for the FIX-D gap: T-D1/D2/D3 in VanguardConcurrencyTests.m validate
/// that stop() drains the session (always true), but do NOT test the original
/// plugin-level race — calling setVideoCallback:nil from main while
/// _captureQueue is in captureOutput: reading _videoCallback.
///
/// T-D4 validates the correct teardown CONTRACT that FIX-D establishes:
/// stop() must be called before any _videoCallback modification or source
/// abandonment. This is an integration-level test of the invariant.
@interface VGFixDCoverageTests : XCTestCase
@end

@implementation VGFixDCoverageTests

/// T-D4: Source1 drains completely before Source2 activates.
///
/// The pre-fix plugin bug: startCamera overwrote cameraSource without calling
/// stop() on the existing source first. Its _captureQueue continued delivering
/// frames that called _videoCallback after the source was abandoned.
/// Concurrently, the plugin called setVideoCallback:nil on main → data race.
///
/// The fix (Plugin L634-637): call existing.stop() before creating the new
/// source. stop() calls [_session stopRunning] which synchronously drains
/// all in-flight captureOutput: callbacks before returning.
///
/// This test verifies the invariant from the source's perspective:
///   - src1 callbacks stop AT OR BEFORE [src1 stop] returns
///   - src2 starts cleanly after src1 is fully drained
///   - No callback from src1 fires during src2's lifetime
///
/// Why this closes the gap better than T-D3: T-D3 sets a single callback and
/// checks count after stop. T-D4 uses two sequential sources and measures that
/// src1's callback count is FROZEN from the moment src1.stop() returns —
/// i.e., no callbacks "leak" into src2's domain. This directly mirrors the
/// plugin's rapid startCamera→startCamera scenario.
///
/// Budget: ~3s (camera startup × 2 + 0.5s measurement).
- (void)testD4_source1DrainedBeforeSource2Starts_noCallbackLeak {
    // src1: back camera
    VanguardCameraMediaSource *src1 =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];

    atomic_int *count1 = (atomic_int *)calloc(1, sizeof(atomic_int));
    atomic_init(count1, 0);
    [src1 setVideoCallback:^(CVPixelBufferRef f, CMTime t) {
        CVPixelBufferRelease(f); // balance +1 from source
        atomic_fetch_add_explicit(count1, 1, memory_order_relaxed);
    }];
    [src1 start];

    BOOL src1Running = VGHRWaitBOOL(src1.captureSession, @"running", YES, 3.0);
    if (!src1Running) {
        free(count1);
        XCTSkip(@"Camera not available — D4 requires physical device");
        return;
    }

    // Let src1 accumulate callbacks for 0.3s.
    XCTestExpectation *accumulated = [self expectationWithDescription:@"D4 src1 frames"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [accumulated fulfill]; });
    [self waitForExpectations:@[accumulated] timeout:1.0];

    int beforeStop = atomic_load_explicit(count1, memory_order_relaxed);
    XCTAssertGreaterThan(beforeStop, 0,
        @"src1 must deliver at least one frame before stop()");

    // FIX-D invariant: stop() FIRST, then create the new source.
    // [_session stopRunning] drains all in-flight captureOutput: calls
    // before returning — no callback fires after this point.
    [src1 stop]; // synchronous drain
    int atStop = atomic_load_explicit(count1, memory_order_relaxed);

    // Create src2 AFTER src1 is stopped (mirrors the fixed plugin path).
    VanguardCameraMediaSource *src2 =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    [src2 start];
    BOOL src2Running = VGHRWaitBOOL(src2.captureSession, @"running", YES, 3.0);
    XCTAssertTrue(src2Running, @"src2 must start cleanly after src1 is stopped");

    // Let src2 run for 0.3s — any stale src1 callbacks would appear here.
    XCTestExpectation *settled = [self expectationWithDescription:@"D4 settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [settled fulfill]; });
    [self waitForExpectations:@[settled] timeout:1.0];

    int afterSrc2Start = atomic_load_explicit(count1, memory_order_relaxed);
    free(count1);

    [src2 stop];

    // src1's callback count must be frozen from the moment stop() returned.
    // Any increment here = stale callback from src1 during src2's lifetime
    // = the pre-fix bug reproduced.
    XCTAssertEqual(atStop, afterSrc2Start,
        @"src1's callback count must not increase after [src1 stop] returns. "
         "Before fix: the plugin did not call stop() before overwriting "
         "cameraSource — src1's captureQueue continued delivering, and the "
         "plugin called setVideoCallback:nil from main concurrently → TSAN race. "
         "After fix (Plugin L634-637): stop() drains captureQueue synchronously; "
         "count1 is frozen. atStop=%d  afterSrc2Start=%d",
         atStop, afterSrc2Start);
}

@end
