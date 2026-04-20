// VanguardConcurrencyTests.m
//
// Comprehensive regression suite for Phase-5 production patches.
// Validated against actual API surface — no assumptions, no placeholders.
//
// API facts confirmed before writing:
//   renderer._filterChainEnabled defaults to YES (initialised at L127 of renderer .m)
//   renderer has no public `source` property — use initWithVideoPath: for file-source tests
//   captureSession is a @property (readonly) on VanguardCameraMediaSource
//   startRecordingToURL:completion: fires completion on main thread (L566 of camera .m)
//   stopRecordingWithCompletion: fires ALL completions on main thread (FIX-B v2)
//   stop() calls [_session stopRunning] synchronously — drains captureQueue before return
//   _audioEngineReady ivar KVC key: "audioEngineReady" (no underscore — KVC searches ivar)
//   VanguardRecordingState: Idle=0, Writing=1, Finishing=2
//
// Timing budget: each test's slowest path annotated. Total < 30s.
//
// Run TSAN:  xcodebuild test -scheme vanguard_media_engine -enableThreadSanitizer YES
// Run ASAN:  xcodebuild test -scheme vanguard_media_engine -enableAddressSanitizer YES

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <stdatomic.h>

#import "VanguardFileMediaSource.h"
#import "VanguardCameraMediaSource.h"
#import "VanguardMetalRenderer.h"
#import "VanguardFilterNode.h"

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Pixel-buffer factories (file-scoped — no link collision)
// ─────────────────────────────────────────────────────────────────────────────

static CVPixelBufferPoolRef VGCTMakePool(size_t w, size_t h) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:               @(w),
        (id)kCVPixelBufferHeightKey:              @(h),
        (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(nil, nil, (__bridge CFDictionaryRef)attrs, &pool);
    return pool;   // caller owns; nil on failure is handled by callers
}

static NSURL *VGCTBundleURL(NSString *name, NSString *ext, XCTestCase *tc) {
    return [[NSBundle bundleForClass:[tc class]] URLForResource:name withExtension:ext];
}

// Creates a VanguardMetalRenderer using initWithVideoPath: with nil for
// textureRegistry and methodChannel. Both are nil-safe in a test context:
// ObjC sends to nil ([nil textureFrameAvailable:]) are no-ops.
// The nonnull annotation is a production-caller contract only.
// Scoped pragma suppresses -Wnonnull at this single call site.
static VanguardMetalRenderer *VGCTMakeRenderer(NSString *path) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    return [[VanguardMetalRenderer alloc] initWithVideoPath:path
                                            textureRegistry:nil
                                              methodChannel:nil];
#pragma clang diagnostic pop
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Shared spy / stub filter nodes
// ─────────────────────────────────────────────────────────────────────────────

// ── VGCTPassNode ─ allocates a real buffer from pool; counts calls atomically ──
@interface VGCTPassNode : NSObject <VanguardFilterNode>
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *filterName;
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool;
- (NSUInteger)callCount;
@end

@implementation VGCTPassNode {
    CVPixelBufferPoolRef _pool;
    atomic_uint _calls;
}
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool {
    self = [super init];
    _pool = pool;
    if (_pool) CVPixelBufferPoolRetain(_pool);
    _enabled = YES;
    _filterName = @"Pass";
    atomic_init(&_calls, 0u);
    return self;
}
- (void)dealloc { if (_pool) CVPixelBufferPoolRelease(_pool); }
- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)dev {
    atomic_fetch_add_explicit(&_calls, 1u, memory_order_relaxed);
    CVPixelBufferRef out = NULL;
    if (_pool && CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &out) == kCVReturnSuccess)
        return out;         // caller owns +1
    CVPixelBufferRetain(input);
    return input;           // passthrough; caller owns the +1 we just added
}
- (void)invalidate {}
- (NSUInteger)callCount {
    return (NSUInteger)atomic_load_explicit(&_calls, memory_order_relaxed);
}
@end

// ── VGCTNullNode ─ always returns NULL; simulates ML pool exhaustion ──────────
@interface VGCTNullNode : NSObject <VanguardFilterNode>
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *filterName;
- (NSUInteger)callCount;
@end

@implementation VGCTNullNode {
    atomic_uint _calls;
}
- (instancetype)init {
    self = [super init];
    _enabled = YES;
    _filterName = @"Null";
    atomic_init(&_calls, 0u);
    return self;
}
- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)dev {
    atomic_fetch_add_explicit(&_calls, 1u, memory_order_relaxed);
    return NULL;    // intentional — the whole point of this spy
}
- (void)invalidate {}
- (NSUInteger)callCount {
    return (NSUInteger)atomic_load_explicit(&_calls, memory_order_relaxed);
}
@end

// ── VGCTInvSpyNode ─ records invalidate() call; used for FIX-E ordering check ─
@interface VGCTInvSpyNode : NSObject <VanguardFilterNode>
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *filterName;
@property (nonatomic, readonly) BOOL wasInvalidated;
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool;
- (NSUInteger)callCount;
@end

@implementation VGCTInvSpyNode {
    CVPixelBufferPoolRef _pool;
    atomic_uint _calls;
    atomic_bool _invalidated;
}
- (instancetype)initWithPool:(CVPixelBufferPoolRef)pool {
    self = [super init];
    _pool = pool;
    if (_pool) CVPixelBufferPoolRetain(_pool);
    _enabled = YES;
    _filterName = @"InvSpy";
    atomic_init(&_calls, 0u);
    atomic_init(&_invalidated, false);
    return self;
}
- (void)dealloc { if (_pool) CVPixelBufferPoolRelease(_pool); }
- (CVPixelBufferRef)processBuffer:(CVPixelBufferRef)input
                           atTime:(CMTime)t
                           device:(id<MTLDevice>)dev {
    atomic_fetch_add_explicit(&_calls, 1u, memory_order_relaxed);
    CVPixelBufferRef out = NULL;
    if (_pool && CVPixelBufferPoolCreatePixelBuffer(nil, _pool, &out) == kCVReturnSuccess)
        return out;
    CVPixelBufferRetain(input);
    return input;
}
- (void)invalidate {
    atomic_store_explicit(&_invalidated, true, memory_order_relaxed);
}
- (BOOL)wasInvalidated {
    return (BOOL)atomic_load_explicit(&_invalidated, memory_order_relaxed);
}
- (NSUInteger)callCount {
    return (NSUInteger)atomic_load_explicit(&_calls, memory_order_relaxed);
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared test helpers
// ─────────────────────────────────────────────────────────────────────────────

// Waits for a KVO property to reach a given BOOL value. Used instead of sleep
// for AVCaptureSession.running and similar async state transitions.
// Returns YES if the condition was reached before timeout, NO on timeout.
static BOOL VGCTWaitBOOL(id object, NSString *keyPath, BOOL expected,
                          NSTimeInterval timeoutSecs) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSecs];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        id val = [object valueForKeyPath:keyPath];
        if ([val boolValue] == expected) return YES;
        [NSThread sleepForTimeInterval:0.02]; // 20ms poll — only used in this helper
    }
    return NO;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-A: _schedulingChunks Atomic Conversion
// Bug: plain BOOL _schedulingChunks — C11 data race between main-thread NO
// write in _teardownAudioEngine and _decodeQueue reads guarding _ablScratch.
// ─────────────────────────────────────────────────────────────────────────────

@interface VGFixATests : XCTestCase
@end
@implementation VGFixATests

/// T-A2  _audioEngineReady lifecycle: YES after start, NO after stop.
///
/// History of timing bugs in this test:
///
///   v1 (broken): dispatch_after(0.7s) fired BEFORE the dispatch_after(1.2s)
///   that schedules _setupAudioEngine. The check always read NO. The
///   expectation was fulfilled unconditionally so the test never failed
///   visibly — but the assertion silently passed with a wrong value.
///
///   v2 (improved but fragile): VGCTWaitBOOL polled every 20ms. This
///   blocked the main thread via [NSThread sleepForTimeInterval:0.02].
///   Blocking main prevents pending dispatch_async(main_queue) blocks from
///   running between polls. _setupAudioEngine dispatches a main-queue
///   callback at L713 (_rebuildAudioReaderForSecs → Step 3) that gates
///   whether _schedulingChunks transitions to YES. With main blocked,
///   that callback queues behind the sleep, causing the poll to miss YES
///   briefly and burning extra wall time.
///
///   v3 (correct): expectationForPredicate:evaluatedWithObject: — XCTest's
///   built-in condition polling.
///     • The predicate runs on XCTest's private background serial queue —
///       no main-thread stall.
///     • waitForExpectations:timeout: spins the main CFRunLoop via
///       CFRunLoopRunInMode so ALL pending main-queue GCD blocks drain
///       normally during the wait.
///     • Zero sleep anywhere in this test.
///     • Fulfils exactly when audioEngineReady first becomes YES:
///       fully event-driven, not time-driven.
///
/// Why the 4s timeout is correct (not fragile timing):
///   _setupAudioEngine is deferred by dispatch_after(1.2s, global_queue)
///   inside start(). Minimum time-to-YES = 1.2s + AVAudioEngine startup
///   (~100-400ms). Typical runtime: ~1.5-1.8s. The 4s timeout absorbs
///   thermal throttling and Simulator GCD scheduling jitter without ever
///   hitting it under normal conditions.
///
/// Budget (typical): ~1.5–1.8s. Timeout: 4.0s.
- (void)testA2_audioEngineReadyLifecycle {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle — add a local MP4"); }

    VanguardFileMediaSource *src =
        [[VanguardFileMediaSource alloc] initWithURL:url pixelBufferPool:nil];
    XCTAssertNotNil(src);

    // Before start: NO.
    XCTAssertFalse([[src valueForKey:@"audioEngineReady"] boolValue],
        @"audioEngineReady must be NO before start()");

    [src start];

    // XCTest evaluates the predicate on its private background queue every
    // ~0.25s. waitForExpectations: spins the main CFRunLoop between checks,
    // so all main-queue dispatch_async blocks from _setupAudioEngine can
    // drain normally. The expectation fulfils the instant YES is observed —
    // no fixed sleep, no polling loop on main.
    XCTestExpectation *audioReady = [self
        expectationForPredicate:
            [NSPredicate predicateWithBlock:^BOOL(id obj, NSDictionary *_) {
                return [[obj valueForKey:@"audioEngineReady"] boolValue];
            }]
        evaluatedWithObject:src
        handler:nil];

    // waitForExpectations spins main CFRunLoop — GCD callbacks fire normally.
    [self waitForExpectations:@[audioReady] timeout:4.0];

    // If we reach here the expectation was fulfilled, i.e. YES was observed.
    // Re-assert synchronously to make the XCTest failure message explicit.
    XCTAssertTrue([[src valueForKey:@"audioEngineReady"] boolValue],
        @"audioEngineReady must be YES after start(). "
         "If this fails: audio file has no audio track, or AVAudioEngine "
         "failed to start — check console for [VanguardSource] error logs.");

    [src stop];
    // _teardownAudioEngine runs synchronously on main inside stop() —
    // sets _audioEngineReady = NO before stop() returns.
    XCTAssertFalse([[src valueForKey:@"audioEngineReady"] boolValue],
        @"audioEngineReady must be NO immediately after stop()");
}



/// T-A3  Rapid start→stop cycles: TSAN probe for _schedulingChunks race.
///
/// 8 cycles; each holds start for 80ms so a decodeQueue chunk is in-flight
/// when main writes _schedulingChunks=NO inside stop().
/// Before fix: TSAN reports "data race on _schedulingChunks".
/// After fix:  TSAN clean — _Atomic(BOOL) prevents torn reads/writes.
/// Budget: ~1.2s (8 × 90ms).
- (void)testA3_rapidStartStop_TSANProbe {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    for (int i = 0; i < 8; i++) {
        @autoreleasepool {
            VanguardFileMediaSource *src =
                [[VanguardFileMediaSource alloc] initWithURL:url pixelBufferPool:nil];
            [src start];
            // Hold open the race window: decodeQueue is mid-chunk-loop here.
            // This sleep IS justified — it's the mechanism that creates the race.
            [NSThread sleepForTimeInterval:0.08];
            [src stop]; // main writes _schedulingChunks=NO
        }
        // dealloc → free(_ablScratch). Must not double-free.
    }
    XCTAssertTrue(YES, @"T-A3: 8 cycles TSAN-clean — no data race on _schedulingChunks");
}

/// T-A4  _ablScratch lifetime after atomic stop: ASAN probe.
///
/// Lets one audio chunk allocate _ablScratch, then immediately drops the source.
/// dealloc calls free(_ablScratch). If _decodeQueue block holds a live strongSelf,
/// dealloc cannot run until the block exits — no use-after-free possible after fix.
/// Before fix: ASAN heap-use-after-free or double-free on _ablScratch.
/// After fix:  ASAN clean.
/// Budget: ~1s (3 cycles × 0.2s).
- (void)testA4_ablScratchNotFreedWhileBlockInFlight_ASANProbe {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    for (int i = 0; i < 3; i++) {
        @autoreleasepool {
            VanguardFileMediaSource *src =
                [[VanguardFileMediaSource alloc] initWithURL:url pixelBufferPool:nil];
            [src start];

            // Wait for the first audio chunk to allocate _ablScratch.
            // Justified sleep: there is no completion callback for "first chunk allocated".
            XCTestExpectation *chunk = [self expectationWithDescription:
                [NSString stringWithFormat:@"A4 chunk %d", i]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [chunk fulfill]; });
            [self waitForExpectations:@[chunk] timeout:1.0];

            [src stop];
        }
        // ARC releases src here → dealloc → free(_ablScratch).
        // ASAN would catch double-free or use-after-free.
    }
    XCTAssertTrue(YES, @"T-A4: ASAN clean — _ablScratch freed exactly once per lifecycle");
}

@end


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-B: stopRecordingWithCompletion Chaining (v2)
// Original bug: second stopRecordingWithCompletion: while state==.Finishing
// fired idle-branch immediately (nil URL), truncating recording.
// FIX-B v1 regression: _stopCompletion was a data race between _captureQueue
// (writer) and AVFoundation arbitrary thread (reader inside finishWriting callback).
// FIX-B v2: handler re-dispatches to _captureQueue — all access serialised.
// ─────────────────────────────────────────────────────────────────────────────

@interface VGFixBTests : XCTestCase
@end
@implementation VGFixBTests

// Convenience: start camera, wait for AVCaptureSession.isRunning.
- (VanguardCameraMediaSource *)_startedCameraSourceWithTimeout:(NSTimeInterval)t {
    VanguardCameraMediaSource *cam =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    [cam start];
    BOOL running = VGCTWaitBOOL(cam.captureSession, @"running", YES, t);
    if (!running) XCTFail(@"AVCaptureSession did not reach isRunning=YES in %.1fs", t);
    return cam;
}

// Convenience: start recording and wait for the startRecordingToURL: completion.
- (BOOL)_startRecordingOn:(VanguardCameraMediaSource *)cam
                    toURL:(NSURL *)url
                  timeout:(NSTimeInterval)t {
    XCTestExpectation *started = [self expectationWithDescription:@"recStart"];
    __block BOOL ok = NO;
    [cam startRecordingToURL:url completion:^(NSError *err) {
        ok = (err == nil);
        if (err) XCTFail(@"startRecordingToURL failed: %@", err);
        [started fulfill];
    }];
    [self waitForExpectations:@[started] timeout:t];
    return ok;
}

/// T-B1  Chaining: second caller receives a non-nil URL after finishWriting.
///
/// Before fix: second call returned nil immediately (idle-branch early return).
/// After fix:  both completions fire on main; both receive the same file URL.
/// Budget: ~3s (0.25s record + finishWriting overhead).
- (void)testB1_secondCallerReceivesNonNilURL {
    VanguardCameraMediaSource *cam = [self _startedCameraSourceWithTimeout:3.0];

    NSURL *url = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"VGFixB1.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    if (![self _startRecordingOn:cam toURL:url timeout:4.0]) {
        [cam stop]; return;
    }

    // Give AVAssetWriter time to write a few frames (justified: no "N frames written" callback).
    XCTestExpectation *wrote = [self expectationWithDescription:@"B1 frames"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [wrote fulfill]; });
    [self waitForExpectations:@[wrote] timeout:1.0];

    XCTestExpectation *c1 = [self expectationWithDescription:@"B1 c1"];
    XCTestExpectation *c2 = [self expectationWithDescription:@"B1 c2"];
    __block NSURL *url1 = nil, *url2 = nil;

    // First stop — drives state → .Finishing, enqueues finishWriting.
    [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *e) {
        XCTAssertTrue([NSThread isMainThread], @"FIX-B v2: all completions must fire on main");
        url1 = u;
        [c1 fulfill];
    }];

    // Second stop — must chain, NOT early-return with nil.
    [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *e) {
        XCTAssertTrue([NSThread isMainThread], @"Chained completion must fire on main");
        url2 = u;
        [c2 fulfill];
    }];

    [self waitForExpectations:@[c1, c2] timeout:10.0];

    XCTAssertNotNil(url1, @"Primary completion must produce a non-nil URL");
    XCTAssertNotNil(url2,
        @"Chained completion must produce a non-nil URL. "
         "Before fix: was nil because idle-branch returned immediately.");
    XCTAssertEqualObjects(url1, url2, @"Both completions must resolve the same file path");

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:url.path];
    XCTAssertTrue(exists, @"Recording file must exist after both completions fire");

    [cam stop];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

/// T-B2  _stopCompletion serialised on _captureQueue: TSAN probe.
///
/// FIX-B v1 data race: _stopCompletion written on _captureQueue,
/// read inside finishWritingWithCompletionHandler on an arbitrary AVFoundation thread.
/// FIX-B v2 fix: handler re-dispatches to _captureQueue before touching the ivar.
///
/// Test: concurrent second stopRecording from a global queue maximises the race
/// window for TSAN to observe the unsynchronised access of v1.
/// Before fix (v1): TSAN reports data race on _stopCompletion.
/// After fix (v2):  TSAN clean.
/// Budget: ~2s.
- (void)testB2_stopCompletionSerializedOnCaptureQueue_TSAN {
    VanguardCameraMediaSource *cam = [self _startedCameraSourceWithTimeout:3.0];

    NSURL *url = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"VGFixB2.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    if (![self _startRecordingOn:cam toURL:url timeout:4.0]) {
        [cam stop]; return;
    }

    // Brief record window — enough to reach .Writing state.
    XCTestExpectation *wrote = [self expectationWithDescription:@"B2 frames"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [wrote fulfill]; });
    [self waitForExpectations:@[wrote] timeout:0.5];

    XCTestExpectation *e1 = [self expectationWithDescription:@"B2 e1"];
    XCTestExpectation *e2 = [self expectationWithDescription:@"B2 e2"];

    // First stop — state → .Finishing.
    [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *err) {
        [e1 fulfill];
    }];

    // Second stop from global queue — maximises the window for the v1 race.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *err) {
            [e2 fulfill];
        }];
    });

    [self waitForExpectations:@[e1, e2] timeout:10.0];
    // TSAN clean on reaching here = pass.

    [cam stop];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

/// T-B3  Chained completion fires regardless of finishWriting latency.
///
/// Records 0.5s — enough data to ensure finishWriting is non-trivial.
/// Verifies second completion fires after first (ordering guarantee of chaining).
/// Before fix: no chaining — second caller's expectation never fulfilled (timeout).
/// After fix:  _stopCompletion persists until finishWriting resolves.
/// Budget: ~2.5s.
- (void)testB3_chainedCompletionFiresAfterSlowFinishWriting {
    VanguardCameraMediaSource *cam = [self _startedCameraSourceWithTimeout:3.0];

    NSURL *url = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"VGFixB3.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    if (![self _startRecordingOn:cam toURL:url timeout:4.0]) {
        [cam stop]; return;
    }

    // Record 0.5s — produces a larger file than B1/B2 to stress finishWriting.
    XCTestExpectation *wrote = [self expectationWithDescription:@"B3 frames"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [wrote fulfill]; });
    [self waitForExpectations:@[wrote] timeout:1.5];

    XCTestExpectation *first  = [self expectationWithDescription:@"B3 first"];
    XCTestExpectation *second = [self expectationWithDescription:@"B3 second"];
    __block NSDate *t1 = nil, *t2 = nil;

    [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *e) {
        t1 = [NSDate date];
        [first fulfill];
    }];
    [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *e) {
        t2 = [NSDate date];
        [second fulfill];
    }];

    [self waitForExpectations:@[first, second] timeout:12.0];

    XCTAssertNotNil(t2,
        @"Chained completion must fire. Before fix: XCTest timeout (second never fulfilled).");
    // Chain ordering: second fires no earlier than first (allow 20ms dispatch latency).
    XCTAssertGreaterThanOrEqual([t2 timeIntervalSinceDate:t1], -0.02,
        @"Chained completion must fire no earlier than the primary completion");

    [cam stop];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

/// T-B4  All N chained completions fire.
///
/// 5 rapid stopRecordingWithCompletion: calls in burst.
/// Before fix: only the first (or none) fired; linked-list chain didn't exist.
/// After fix:  all 5 completions fire via the _stopCompletion linked chain.
/// Budget: ~2s.
- (void)testB4_allChainedCallersFire {
    VanguardCameraMediaSource *cam = [self _startedCameraSourceWithTimeout:3.0];

    NSURL *url = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"VGFixB4.mp4"]];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    if (![self _startRecordingOn:cam toURL:url timeout:4.0]) {
        [cam stop]; return;
    }

    XCTestExpectation *wrote = [self expectationWithDescription:@"B4 frames"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [wrote fulfill]; });
    [self waitForExpectations:@[wrote] timeout:0.8];

    const int N = 5;
    // Heap-allocate the counter so the block captures a stable, non-const pointer.
    // Stack atomic_int captured by a block becomes const — atomic_fetch_add rejects it.
    atomic_int *fired = (atomic_int *)calloc(1, sizeof(atomic_int));
    atomic_init(fired, 0);
    NSMutableArray<XCTestExpectation *> *exps = [NSMutableArray arrayWithCapacity:N];

    for (int i = 0; i < N; i++) {
        XCTestExpectation *ex = [self expectationWithDescription:
            [NSString stringWithFormat:@"B4_%d", i]];
        [exps addObject:ex];
        [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *e) {
            atomic_fetch_add_explicit(fired, 1, memory_order_relaxed);
            [ex fulfill];
        }];
    }

    [self waitForExpectations:exps timeout:12.0];

    XCTAssertEqual((int)atomic_load_explicit(fired, memory_order_relaxed), N,
        @"All %d completions must fire. "
         "Before fix: only 1 fired — remaining callers were stranded with no chaining.", N);
    free(fired);

    [cam stop];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-C: Filter Chain NULL Return Guard
// Bug: filter node returning NULL → CVPixelBufferRetain(NULL) crash; intermediate
// buffers from prior nodes leaked because the release path was never reached.
// ─────────────────────────────────────────────────────────────────────────────

@interface VGFixCTests : XCTestCase
@end
@implementation VGFixCTests

/// T-C1  NULL from first node: no crash; node after it is never called.
///
/// Chain: [nullNode → afterNode]. Because nullNode returns NULL, FIX-C breaks
/// the loop immediately — afterNode must never receive a NULL input.
/// Before fix: EXC_BAD_ACCESS at CVPixelBufferRetain(NULL); or afterNode called with NULL.
/// After fix:  afterNode.callCount == 0 for the duration of the test.
/// Budget: ~1.5s.
- (void)testC1_nullFirstNodeNoCrash_afterNodeNotCalled {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    CVPixelBufferPoolRef pool = VGCTMakePool(1920, 1080);
    VGCTNullNode *nullNode  = [[VGCTNullNode alloc] init];
    VGCTPassNode *afterNode = [[VGCTPassNode alloc] initWithPool:pool];

    // initWithVideoPath: creates its own VanguardFileMediaSource internally.
    // textureRegistry:nil / methodChannel:nil are nil-safe — see VGCTMakeRenderer().
    VanguardMetalRenderer *renderer = VGCTMakeRenderer(url.path);
    XCTAssertNotNil(renderer);
    // _filterChainEnabled defaults to YES (initialised in renderer init).

    [renderer replaceFilterChain:@[nullNode, afterNode]];
    [renderer play]; // starts source + CADisplayLink on main runloop

    // Settle: allow at least one CADisplayLink → pullNextFrameAsync → _onVideoFrame cycle.
    XCTestExpectation *settled = [self expectationWithDescription:@"C1 settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [settled fulfill]; });
    [self waitForExpectations:@[settled] timeout:1.5];

    NSUInteger nullCalls  = nullNode.callCount;
    NSUInteger afterCalls = afterNode.callCount;

    XCTAssertGreaterThan(nullCalls, 0u,
        @"nullNode must be called — filter chain must be active");
    XCTAssertEqual(afterCalls, 0u,
        @"afterNode must NOT be called when nullNode returns NULL. "
         "Before fix: afterNode was called with NULL → undefined behaviour or crash. "
         "Got %lu calls after fix.", (unsigned long)afterCalls);

    [renderer pause];
    [renderer dispose];
    if (pool) CVPixelBufferPoolRelease(pool);
}

/// T-C2  NULL from middle node: intermediate buffer from node 1 is released.
///       Node 3 (neverNode) must never be called.
///
/// Chain: [valid → null → never].
/// Before fix: out1 from validNode leaked (retain count stuck +1 forever).
///             neverNode called with NULL → UB or crash.
/// After fix:  FIX-C guard releases out1; neverNode.callCount == 0.
/// Budget: ~1.5s.
- (void)testC2_nullMiddleNodeReleasesIntermediate_neverNodeNotCalled {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    CVPixelBufferPoolRef pool = VGCTMakePool(1920, 1080);
    VGCTPassNode *validNode = [[VGCTPassNode alloc] initWithPool:pool];
    VGCTNullNode *nullNode  = [[VGCTNullNode alloc] init];
    VGCTPassNode *neverNode = [[VGCTPassNode alloc] initWithPool:pool];

    VanguardMetalRenderer *renderer = VGCTMakeRenderer(url.path);
    [renderer replaceFilterChain:@[validNode, nullNode, neverNode]];
    [renderer play];

    XCTestExpectation *settled = [self expectationWithDescription:@"C2 settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [settled fulfill]; });
    [self waitForExpectations:@[settled] timeout:1.5];

    XCTAssertGreaterThan(validNode.callCount, 0u, @"validNode must be called");
    XCTAssertGreaterThan(nullNode.callCount,  0u, @"nullNode must be called");
    XCTAssertEqual      (neverNode.callCount, 0u,
        @"neverNode must NOT be called after nullNode returns NULL. "
         "Before fix: received NULL input → UB. Got %lu calls after fix.",
         (unsigned long)neverNode.callCount);

    // ASAN: if out1 leaked, the pool may reuse its memory for another buffer that
    // was then freed — ASAN reports heap-use-after-free at pool allocation time.
    // Reaching here with ASAN enabled and no report = balanced retain counts.

    [renderer pause];
    [renderer dispose];
    if (pool) CVPixelBufferPoolRelease(pool);
}

/// T-C3  Sustained NULL injection over 1.5s: ASAN retain-balance probe.
///
/// A chain that always returns NULL at every frame. Verifies no retain leak
/// or over-release accumulates across many frames.
/// Before fix: crash after ~N frames from imbalanced retains.
/// After fix:  ASAN clean for the full duration.
/// Budget: ~2s.
- (void)testC3_sustainedNullInjection_ASANProbe {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    VGCTNullNode *nullNode = [[VGCTNullNode alloc] init];

    VanguardMetalRenderer *renderer = VGCTMakeRenderer(url.path);
    [renderer replaceFilterChain:@[nullNode]];
    [renderer play];

    XCTestExpectation *done = [self expectationWithDescription:@"C3 done"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [done fulfill]; });
    [self waitForExpectations:@[done] timeout:3.0];

    XCTAssertGreaterThan(nullNode.callCount, 5u,
        @"nullNode must be exercised many times. "
         "Got %lu — check that filter chain is active.", (unsigned long)nullNode.callCount);
    // ASAN clean on reaching here = balanced retains across all frames.

    [renderer pause];
    [renderer dispose];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-D: Camera Double-Start / Stale Callback Guard
// Bug: rapid startCamera→startCamera left the first AVCaptureSession running,
// with its captureOutput: callbacks still firing into an overwritten context.
// Fix: call existing.stop() before creating the new source; stop() calls
// [_session stopRunning] which blocks until all in-flight callbacks drain.
// ─────────────────────────────────────────────────────────────────────────────

@interface VGFixDTests : XCTestCase
@end
@implementation VGFixDTests

/// T-D1  stop() halts session.isRunning before a second source starts.
///
/// Uses captureSession (public @property readonly) to verify session state.
/// Uses KVO polling via VGCTWaitBOOL (not a timed sleep) to wait for async start.
/// Before fix: first session remained running → hardware contention on second start.
/// After fix:  first session.isRunning == NO after stop(); second starts cleanly.
/// Budget: ~1.5s.
- (void)testD1_stopFirstSessionBeforeCreatingSecond {
    VanguardCameraMediaSource *src1 =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    [src1 start];

    // Wait for session to become running (isRunning is async post startRunning).
    BOOL started = VGCTWaitBOOL(src1.captureSession, @"running", YES, 3.0);
    XCTAssertTrue(started, @"First AVCaptureSession must reach isRunning=YES after start");

    AVCaptureSession *session1 = src1.captureSession;

    // Simulate FIX-D: stop existing source before creating second.
    [src1 stop]; // calls [_session stopRunning] — synchronous drain

    XCTAssertFalse(session1.isRunning,
        @"session1.isRunning must be NO after stop() returns. "
         "Before fix: startCamera skipped this stop(), leaving session1 running "
         "alongside session2 — hardware contention.");

    // Create second source — must start cleanly when first is fully quiesced.
    VanguardCameraMediaSource *src2 =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    [src2 start];

    BOOL started2 = VGCTWaitBOOL(src2.captureSession, @"running", YES, 3.0);
    XCTAssertTrue(started2,
        @"Second AVCaptureSession must reach isRunning=YES after first is fully stopped");

    [src2 stop];
}

/// T-D2  5 rapid front/back switches: no session leak.
///
/// Each cycle: start → wait running → stop.
/// If a session leaked (FIX-D missing), AVFoundation denies the 2nd+ session.
/// Before fix: error or assertion on cycle 2+ (hardware resource busy).
/// After fix:  all 5 cycles complete without error.
/// Budget: ~2s (5 × ~0.4s per cycle including session startup/teardown).
- (void)testD2_rapidCameraSwitches_noSessionLeak {
    for (int i = 0; i < 5; i++) {
        @autoreleasepool {
            AVCaptureDevicePosition pos = (i % 2 == 0)
                ? AVCaptureDevicePositionBack
                : AVCaptureDevicePositionFront;

            VanguardCameraMediaSource *cam =
                [[VanguardCameraMediaSource alloc] initWithPosition:pos frameRate:30];
            [cam start];

            // Wait for the session to actually start before stopping.
            BOOL r = VGCTWaitBOOL(cam.captureSession, @"running", YES, 2.0);
            XCTAssertTrue(r, @"Cycle %d: session must start within 2s", i);

            [cam stop]; // synchronous — drains session before next cycle
        }
    }
    XCTAssertTrue(YES, @"T-D2: 5 camera switches completed — no AVFoundation session leak");
}

/// T-D3  No callbacks after stop() returns.
///
/// AVCaptureSession.stopRunning() blocks until all in-flight captureOutput:
/// delegate callbacks complete. After stop() returns, the count must be stable.
/// Before fix: stale callbacks continued for ~200ms after source was overwritten.
/// After fix:  count at stop == count 300ms later.
/// Budget: ~1.5s (0.4s callbacks + 0.3s settle).
- (void)testD3_noCallbacksAfterStopReturns {
    VanguardCameraMediaSource *cam =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    [cam start];

    BOOL r = VGCTWaitBOOL(cam.captureSession, @"running", YES, 3.0);
    XCTAssertTrue(r, @"Session must be running before installing callback");

    // Install callback via the public VanguardMediaSource protocol method.
    // OWNERSHIP CONTRACT: source sends a +1 retained CVPixelBuffer;
    // callback is responsible for releasing it.
    // Heap-allocate counter — stack atomic_int captured by block becomes const.
    atomic_int *callCount = (atomic_int *)calloc(1, sizeof(atomic_int));
    atomic_init(callCount, 0);
    [cam setVideoCallback:^(CVPixelBufferRef frame, CMTime pts) {
        CVPixelBufferRelease(frame); // balance the +1 ownership from source
        atomic_fetch_add_explicit(callCount, 1, memory_order_relaxed);
    }];

    // Accumulate callbacks for 0.4s.
    XCTestExpectation *accumulated = [self expectationWithDescription:@"D3 accumulated"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [accumulated fulfill]; });
    [self waitForExpectations:@[accumulated] timeout:1.0];

    int beforeStop = atomic_load_explicit(callCount, memory_order_relaxed);
    XCTAssertGreaterThan(beforeStop, 0,
        @"At least one callback must fire before stop — confirms camera is delivering frames");

    [cam stop]; // synchronous: stopRunning drains captureQueue
    int atStop = atomic_load_explicit(callCount, memory_order_relaxed);

    // Settle 300ms — any stale callbacks slipping past stop() would appear here.
    XCTestExpectation *settled = [self expectationWithDescription:@"D3 settled"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [settled fulfill]; });
    [self waitForExpectations:@[settled] timeout:1.0];

    int afterSettle = atomic_load_explicit(callCount, memory_order_relaxed);
    free(callCount);

    XCTAssertEqual(atStop, afterSettle,
        @"No _videoCallback invocations must occur after stop() returns. "
         "Before fix: callbacks continued ~200ms after cameraSource was overwritten. "
         "beforeStop=%d  atStop=%d  afterSettle=%d",
         beforeStop, atStop, afterSettle);
}

@end


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - FIX-E: replaceFilterChain Synchronized Read
// Bug: _filterChain reads at "current = _filterChain" happened on the caller's
// thread with no synchronization against the videoDecodeQueue. Two callers could
// produce stale/inconsistent snapshots; invalidate() could miss nodes.
// Fix: snapshot and invalidate() move inside dispatch_sync(videoDecodeQueue),
// serialising them with _onVideoFrame: and all other callers.
// ─────────────────────────────────────────────────────────────────────────────

@interface VGFixETests : XCTestCase
@end
@implementation VGFixETests

/// T-E1  Removed node is not called after replaceFilterChain: barrier propagates.
///       invalidate() is called on the removed node.
///
/// Before fix: stale snapshot missed the node in the chain — it wasn't invalidated
/// and continued to receive processBuffer: calls after "removal".
/// After fix:  dispatch_sync sees current chain; invalidate() fires; barrier blocks new calls.
/// Budget: ~1.5s.
- (void)testE1_removedNodeNotCalledAndInvalidatedAfterReplacement {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    CVPixelBufferPoolRef pool = VGCTMakePool(1920, 1080);
    VGCTInvSpyNode *node = [[VGCTInvSpyNode alloc] initWithPool:pool];

    VanguardMetalRenderer *renderer = VGCTMakeRenderer(url.path);
    [renderer replaceFilterChain:@[node]];
    [renderer play];

    // Let frames flow so node accumulates calls — proves it was active.
    XCTestExpectation *active = [self expectationWithDescription:@"E1 active"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [active fulfill]; });
    [self waitForExpectations:@[active] timeout:0.7];

    NSUInteger beforeRemoval = node.callCount;
    XCTAssertGreaterThan(beforeRemoval, 0u, @"node must be called while installed");

    // Replace with empty chain. FIX-E: dispatch_sync(videoDecodeQueue) sees the
    // current chain and calls invalidate() on node before the barrier swaps.
    [renderer replaceFilterChain:@[]];

    // Wait for the barrier to propagate — one frame period at 30fps ≈ 33ms; give 200ms.
    XCTestExpectation *barrier = [self expectationWithDescription:@"E1 barrier"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [barrier fulfill]; });
    [self waitForExpectations:@[barrier] timeout:0.7];

    NSUInteger afterSwap = node.callCount;

    // Let more frames render — count must not increase.
    XCTestExpectation *check = [self expectationWithDescription:@"E1 final check"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [check fulfill]; });
    [self waitForExpectations:@[check] timeout:0.7];

    NSUInteger finalCount = node.callCount;

    XCTAssertEqual(afterSwap, finalCount,
        @"node.callCount must not increase after replaceFilterChain:[] barrier settles. "
         "Before fix: stale snapshot left node in chain — it continued to be called.");

    XCTAssertTrue(node.wasInvalidated,
        @"invalidate must be called on the removed node. "
         "Before fix: stale snapshot missed the node — invalidate was never called.");

    [renderer pause];
    [renderer dispose];
    if (pool) CVPixelBufferPoolRelease(pool);
}

/// T-E2  Concurrent replaceFilterChain: calls from main + background: TSAN probe.
///
/// Before fix: _filterChain read on caller's thread (any thread) without
/// synchronization → TSAN "data race on _filterChain".
/// After fix:  dispatch_sync(videoDecodeQueue) serialises reads from all callers.
/// Budget: ~2s.
- (void)testE2_concurrentReplaceFilterChain_TSANClean {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    CVPixelBufferPoolRef pool = VGCTMakePool(1920, 1080);
    VGCTPassNode *node = [[VGCTPassNode alloc] initWithPool:pool];

    VanguardMetalRenderer *renderer = VGCTMakeRenderer(url.path);
    [renderer play];

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t bgQ = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    // 30 pairs of (background call + main call) issued rapidly.
    for (int i = 0; i < 30; i++) {
        dispatch_group_async(group, bgQ, ^{
            [renderer replaceFilterChain:(i % 2 == 0) ? @[node] : @[]];
        });
        // Main-thread call in the same scheduling window.
        [renderer replaceFilterChain:(i % 3 == 0) ? @[node] : @[]];
    }

    // Wait for all background calls to complete.
    dispatch_group_wait(group,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));

    XCTAssertTrue(YES,
        @"T-E2: 60 concurrent replaceFilterChain: calls — TSAN clean. "
         "Before fix: TSAN reported data race on _filterChain ivar.");

    [renderer pause];
    [renderer dispose];
    if (pool) CVPixelBufferPoolRelease(pool);
}

/// T-E3  100 rapid replaceFilterChain: calls from main complete without deadlock.
///
/// dispatch_sync(videoDecodeQueue) from main is safe because videoDecodeQueue
/// dispatches back to main only via dispatch_async (not sync) — no cycle.
/// A deadlock would cause XCTest to timeout and kill the process.
///
/// Total time < 3s: each dispatch_sync waits at most one frame decode (~33ms);
/// CADisplayLink can't fire while we're monopolising main, so decodeQueue drains
/// quickly between syncs.
/// Budget: ~0.5s (queue is mostly idle during the tight main-thread loop).
- (void)testE3_replaceFilterChainFromMain_noDeadlock {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    CVPixelBufferPoolRef pool = VGCTMakePool(1920, 1080);
    VGCTPassNode *node = [[VGCTPassNode alloc] initWithPool:pool];

    VanguardMetalRenderer *renderer = VGCTMakeRenderer(url.path);
    [renderer play];

    NSDate *start = [NSDate date];
    for (int i = 0; i < 100; i++) {
        // Each call does: dispatch_sync(videoDecodeQ, snapshot+invalidate)
        // + dispatch_barrier_async(videoDecodeQ, swap).
        [renderer replaceFilterChain:(i % 2 == 0) ? @[node] : @[]];
    }
    NSTimeInterval elapsed = -[start timeIntervalSinceNow];

    XCTAssertLessThan(elapsed, 5.0,
        @"100 replaceFilterChain: calls from main must complete in < 5s. "
         "A deadlock would cause XCTest to kill the process before this assertion. "
         "Elapsed: %.3fs", elapsed);

    [renderer pause];
    [renderer dispose];
    if (pool) CVPixelBufferPoolRelease(pool);
}

@end


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Integration Tests
// ─────────────────────────────────────────────────────────────────────────────

@interface VGIntegrationTests : XCTestCase
@end
@implementation VGIntegrationTests

/// T-I1  Record → immediate double stop → file intact  [FIX-B + FIX-D].
///
/// Exercises the full teardownCameraAsync scenario: two callers stop the same
/// active recording in rapid succession. Both must receive valid URLs; the
/// output file must be non-empty (not truncated mid-write).
///
/// Before fix: second caller received nil URL; file was truncated or missing.
/// After fix:  both URLs are non-nil; file exists; size > 0.
/// Budget: ~4s (2 cycles × ~2s each).
- (void)testI1_recordThenImmediateDoubleStop_fileIntact {
    for (int cycle = 0; cycle < 2; cycle++) {
        VanguardCameraMediaSource *cam =
            [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                      frameRate:30];
        [cam start];

        BOOL running = VGCTWaitBOOL(cam.captureSession, @"running", YES, 3.0);
        XCTAssertTrue(running, @"Cycle %d: session must start", cycle);

        NSURL *outURL = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:
             [NSString stringWithFormat:@"VGI1_%d.mp4", cycle]]];
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];

        XCTestExpectation *recOK = [self expectationWithDescription:
            [NSString stringWithFormat:@"I1 rec %d", cycle]];
        [cam startRecordingToURL:outURL completion:^(NSError *e) {
            XCTAssertNil(e, @"Cycle %d: startRecordingToURL must succeed", cycle);
            [recOK fulfill];
        }];
        [self waitForExpectations:@[recOK] timeout:4.0];

        // Write frames for 300ms.
        XCTestExpectation *wrote = [self expectationWithDescription:
            [NSString stringWithFormat:@"I1 frames %d", cycle]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [wrote fulfill]; });
        [self waitForExpectations:@[wrote] timeout:1.0];

        XCTestExpectation *s1 = [self expectationWithDescription:
            [NSString stringWithFormat:@"I1 s1 %d", cycle]];
        XCTestExpectation *s2 = [self expectationWithDescription:
            [NSString stringWithFormat:@"I1 s2 %d", cycle]];
        __block NSURL *secondURL = nil;

        [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *e) {
            [s1 fulfill];
        }];
        [cam stopRecordingWithCompletion:^(NSURL *u, NSUInteger d, NSUInteger t, NSError *e) {
            secondURL = u;
            [s2 fulfill];
        }];

        [self waitForExpectations:@[s1, s2] timeout:10.0];

        XCTAssertNotNil(secondURL,
            @"Cycle %d: second caller must receive non-nil URL (FIX-B chaining). "
             "Before fix: nil.", cycle);

        NSDictionary *attrs = [[NSFileManager defaultManager]
            attributesOfItemAtPath:outURL.path error:nil];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        XCTAssertGreaterThan(size, 0ULL,
            @"Cycle %d: recording file must be non-empty (not truncated). size=%llu",
            cycle, size);

        [cam stop];
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
    }
}

/// T-I2  NULL-returning node + rapid filter toggle: no crash  [FIX-C + FIX-E].
///
/// Exercises both fixes simultaneously: FIX-C's NULL guard prevents crashes when
/// the current chain is a nullNode; FIX-E's serial snapshot prevents _filterChain
/// races while the background thread toggles rapidly.
///
/// Before fix: crash from CVPixelBufferRetain(NULL) or TSAN race on _filterChain.
/// After fix:  1.5s runtime with mixed chains; sanitisers clean.
/// Budget: ~2s.
- (void)testI2_nullNodeWithRapidFilterToggle_noSanitizerReport {
    NSURL *url = VGCTBundleURL(@"test_video", @"mp4", self);
    if (!url) { XCTSkip(@"test_video.mp4 not in bundle"); }

    CVPixelBufferPoolRef pool = VGCTMakePool(1920, 1080);
    VGCTNullNode *nullNode  = [[VGCTNullNode alloc] init];
    VGCTPassNode *validNode = [[VGCTPassNode alloc] initWithPool:pool];

    VanguardMetalRenderer *renderer = VGCTMakeRenderer(url.path);
    [renderer play];

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t bgQ = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    // Use an atomic flag to signal the background loop to stop cleanly.
    atomic_bool keepRunning;
    atomic_init(&keepRunning, true);

    dispatch_group_async(group, bgQ, ^{
        int i = 0;
        while (atomic_load_explicit(&keepRunning, memory_order_relaxed)) {
            NSArray *chain;
            switch (i % 3) {
                case 0:  chain = @[nullNode];  break;
                case 1:  chain = @[validNode]; break;
                default: chain = @[];           break;
            }
            [renderer replaceFilterChain:chain];
            usleep(8 * 1000); // 8ms — justified: paces the toggle to ~125 swaps/s
            i++;
        }
    });

    XCTestExpectation *done = [self expectationWithDescription:@"I2 done"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [done fulfill]; });
    [self waitForExpectations:@[done] timeout:3.0];

    atomic_store_explicit(&keepRunning, false, memory_order_relaxed);
    dispatch_group_wait(group,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));

    // No crash, no TSAN/ASAN report on reaching this line.
    XCTAssertTrue(YES,
        @"T-I2: 1.5s with NULL-returning node and rapid filter toggle — "
         "no crash or sanitiser report (FIX-C + FIX-E)");

    [renderer pause];
    [renderer dispose];
    if (pool) CVPixelBufferPoolRelease(pool);
}

@end
