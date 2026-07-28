// VGAudioPreviewFileResolverTests.m
// Vanguard Media Engine — S-P2 MOV original-audio repair
//
// Deterministic native unit tests for VGAudioPreviewFileResolver.
// Simulator-safe. No sleeps. Bounded XCTest expectations throughout.
//
// UMF source paths read:
//   /Users/foxy/connects_app/packages/UMF/ios/Classes/VGAudioSidecarPlan.h
//   /Users/foxy/connects_app/packages/UMF/ios/Classes/VGAudioSidecarPlan.m
//
// Fixture used (read-only):
//   ios/Tests/Fixtures/benchmark_face_clip.mov
//   SHA-256: 564637daab642e3f4679706199446987f54178acd7f112262ae03915daa42b41

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import "VGAudioPreviewFileResolver.h"
#import <UMF/VGAudioSidecarPlan.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the URL for benchmark_face_clip.mov bundled in the test target.
/// Requires the fixture to be present as a test bundle resource
/// (Tests test spec must declare 'Tests/Fixtures/benchmark_face_clip.mov'
/// under ts.resources). Returns nil and records a failure if not found.
static NSURL * _Nullable VGResolverTest_MovFixtureURL(XCTestCase *self) {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *url = [bundle URLForResource:@"benchmark_face_clip" withExtension:@"mov"];
    if (url && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return url;
    }
    XCTFail(@"benchmark_face_clip.mov was not found in the test bundle. "
            @"Ensure 'Tests/Fixtures/benchmark_face_clip.mov' is listed under "
            @"ts.resources in the Tests test_spec of vanguard_media_engine.podspec "
            @"and that pod install has been run.");
    return nil;
}

/// Builds a minimal, well-formed sidecar plan with a single music track
/// pointing at |url|. Optional |keyframes|, |waveformCache|, and
/// |remapPolicy| are preserved verbatim by the resolver and checked
/// by the plan-preservation test.
static VGAudioSidecarPlan *VGResolverTest_PlanForURL(
    NSURL *url,
    NSArray<NSDictionary<NSString *, id> *> * _Nullable keyframes,
    NSDictionary<NSString *, id> * _Nullable waveformCache,
    NSString * _Nullable remapPolicy)
{
    NSDictionary *track = @{
        @"trackId"         : @"t1",
        @"role"            : @"music",
        @"url"             : url.path,
        @"startTime"       : @(0.0),
        @"sourceTrimStart" : @(0.0),
        @"duration"        : @(-1.0),
        @"volume"          : @(0.8),
        @"customField"     : @"preserved_value",
    };
    return [[VGAudioSidecarPlan alloc]
                initWithTracks:@[track]
               volumeKeyframes:keyframes
                 waveformCache:waveformCache
         timeRemapAudioPolicy:remapPolicy];
}

// ─────────────────────────────────────────────────────────────────────────────
// Test case
// ─────────────────────────────────────────────────────────────────────────────

@interface VGAudioPreviewFileResolverTests : XCTestCase
@end

@implementation VGAudioPreviewFileResolverTests

// ─────────────────────────────────────────────────────────────────────────────
// S-P2-T1: MOV extraction and plan preservation
// ─────────────────────────────────────────────────────────────────────────────
//
// Scenario: resolve a sidecar plan whose source URL is benchmark_face_clip.mov.
//
// Verifies:
//   - completion fires exactly once on the main thread.
//   - resolvedPlan is non-nil.
//   - resolved track URL differs from the original MOV URL.
//   - resolved track URL has a .caf path extension.
//   - the CAF file exists on disk.
//   - the CAF file can be opened by AVAudioFile.
//   - AVAudioFile reports positive frameLength, sampleRate, and channelCount.
//   - all original track fields except "url" are preserved verbatim.
//   - volumeKeyframes, waveformCache, and timeRemapAudioPolicy are preserved.
//
// IMPLEMENTED.

- (void)test_SP2T1_movExtractionAndPlanPreservation {
    NSURL *movURL = VGResolverTest_MovFixtureURL(self);
    if (!movURL) return; // failure already recorded

    // Build a plan with non-nil optional fields so preservation can be checked.
    NSArray *keyframes = @[@{@"trackId": @"t1", @"time": @(1.0), @"volume": @(0.5)}];
    NSDictionary *cache = @{@"t1": @"hint_data"};
    NSString *remap = @"preserve";

    VGAudioSidecarPlan *sourcePlan =
        VGResolverTest_PlanForURL(movURL, keyframes, cache, remap);

    NSDictionary *sourceTrack = sourcePlan.tracks.firstObject;
    XCTAssertNotNil(sourceTrack);

    VGAudioPreviewFileResolver *resolver = [[VGAudioPreviewFileResolver alloc] init];

    XCTestExpectation *resolveExp =
        [self expectationWithDescription:@"SP2T1 resolvePlan completion"];
    resolveExp.expectedFulfillmentCount = 1;
    resolveExp.assertForOverFulfill = YES;

    __block VGAudioSidecarPlan *resolvedPlan = nil;
    __block BOOL firedOnMain = NO;

    [resolver resolvePlan:sourcePlan
               completion:^(VGAudioSidecarPlan *_Nullable plan) {
        firedOnMain = [NSThread isMainThread];
        resolvedPlan = plan;
        [resolveExp fulfill];
    }];

    [self waitForExpectations:@[resolveExp] timeout:30.0];

    // ── Completion thread ────────────────────────────────────────────────────
    XCTAssertTrue(firedOnMain,
                  @"resolution completion must fire on the main thread");

    // ── Non-nil result ───────────────────────────────────────────────────────
    XCTAssertNotNil(resolvedPlan,
                    @"resolved plan must be non-nil for a valid MOV with audio");

    if (!resolvedPlan) {
        XCTestExpectation *bailExp =
            [self expectationWithDescription:@"SP2T1 bail cleanup"];
        [resolver cancelAndCleanupWithCompletion:^{ [bailExp fulfill]; }];
        [self waitForExpectations:@[bailExp] timeout:5.0];
        return;
    }

    // ── Track count preserved ────────────────────────────────────────────────
    XCTAssertEqual(resolvedPlan.tracks.count, (NSUInteger)1,
                   @"resolved plan must have exactly one track");

    NSDictionary *resolvedTrack = resolvedPlan.tracks.firstObject;
    XCTAssertNotNil(resolvedTrack);

    // ── URL rewritten to CAF, differs from MOV ───────────────────────────────
    NSString *resolvedURLString = resolvedTrack[@"url"];
    XCTAssertNotNil(resolvedURLString,
                    @"resolved track must contain a url field");
    XCTAssertFalse([resolvedURLString isEqualToString:movURL.path],
                   @"resolved url must differ from the original MOV path");
    XCTAssertEqualObjects(
        [resolvedURLString.pathExtension lowercaseString], @"caf",
        @"resolved url must use .caf path extension");

    // ── CAF file exists — guard before any path-based operations ────────────
    // resolvedURLString must be non-empty and the file must exist before we
    // call fileExistsAtPath: or fileURLWithPath: with it.
    if (resolvedURLString.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:resolvedURLString]) {
        XCTFail(@"SP2T1: resolved URL string must be non-empty and the extracted "
                @"CAF must exist on disk before AVAudioFile verification");
        XCTestExpectation *bailExp =
            [self expectationWithDescription:@"SP2T1 bail cleanup (no CAF)"];
        [resolver cancelAndCleanupWithCompletion:^{ [bailExp fulfill]; }];
        [self waitForExpectations:@[bailExp] timeout:5.0];
        return;
    }

    // ── AVAudioFile opens the CAF and reports valid audio properties ─────────
    {
        NSError *audioFileErr = nil;
        AVAudioFile *audioFile =
            [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:resolvedURLString]
                                          error:&audioFileErr];
        XCTAssertNil(audioFileErr,
                     @"AVAudioFile must open the CAF without error: %@",
                     audioFileErr.localizedDescription);
        XCTAssertNotNil(audioFile, @"AVAudioFile must be non-nil");
        if (audioFile) {
            XCTAssertGreaterThan(audioFile.length, (AVAudioFramePosition)0,
                                 @"extracted CAF must contain at least one frame");
            XCTAssertGreaterThan(
                audioFile.processingFormat.sampleRate, 0.0,
                @"extracted CAF must report a positive sample rate");
            XCTAssertGreaterThan(
                (NSUInteger)audioFile.processingFormat.channelCount, (NSUInteger)0,
                @"extracted CAF must report at least one channel");
        }
    }

    // ── Non-url track fields preserved verbatim ──────────────────────────────
    NSArray<NSString *> *preservedKeys = @[
        @"trackId", @"role", @"startTime", @"sourceTrimStart",
        @"duration", @"volume", @"customField"
    ];
    for (NSString *key in preservedKeys) {
        XCTAssertEqualObjects(resolvedTrack[key], sourceTrack[key],
                              @"track field '%@' must be preserved unchanged", key);
    }

    // ── Optional plan fields preserved ───────────────────────────────────────
    XCTAssertEqualObjects(resolvedPlan.volumeKeyframes, sourcePlan.volumeKeyframes,
                          @"volumeKeyframes must be preserved verbatim");
    XCTAssertEqualObjects(resolvedPlan.waveformCache, sourcePlan.waveformCache,
                          @"waveformCache must be preserved verbatim");
    XCTAssertEqualObjects(resolvedPlan.timeRemapAudioPolicy,
                          sourcePlan.timeRemapAudioPolicy,
                          @"timeRemapAudioPolicy must be preserved verbatim");

    // ── Cleanup ──────────────────────────────────────────────────────────────
    XCTestExpectation *cleanupExp =
        [self expectationWithDescription:@"SP2T1 cleanup"];
    [resolver cancelAndCleanupWithCompletion:^{ [cleanupExp fulfill]; }];
    [self waitForExpectations:@[cleanupExp] timeout:5.0];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-P2-T2: Pure-audio pass-through
// ─────────────────────────────────────────────────────────────────────────────
//
// Scenario: pass an already-extracted CAF URL (produced by a first resolver)
// through a second resolver. The second resolver must preserve the URL
// unchanged because the CAF file contains no video track.
//
// This test intentionally reuses the CAF file produced by T1 rather than an
// unrelated external audio fixture, as specified by the task contract.
//
// IMPLEMENTED.

- (void)test_SP2T2_pureAudioPassThrough {
    NSURL *movURL = VGResolverTest_MovFixtureURL(self);
    if (!movURL) return;

    // Step 1: Extract the MOV with a first resolver to get a real CAF file.
    VGAudioPreviewFileResolver *resolver1 = [[VGAudioPreviewFileResolver alloc] init];
    VGAudioSidecarPlan *plan1 = VGResolverTest_PlanForURL(movURL, nil, nil, nil);

    XCTestExpectation *resolve1Exp =
        [self expectationWithDescription:@"SP2T2 first resolve"];
    resolve1Exp.expectedFulfillmentCount = 1;
    resolve1Exp.assertForOverFulfill = YES;

    __block VGAudioSidecarPlan *resolved1 = nil;
    [resolver1 resolvePlan:plan1
                completion:^(VGAudioSidecarPlan *_Nullable p) {
        resolved1 = p;
        [resolve1Exp fulfill];
    }];
    [self waitForExpectations:@[resolve1Exp] timeout:30.0];

    if (!resolved1) {
        XCTFail(@"SP2T2: first resolve must succeed (prerequisite)");
        XCTestExpectation *c1 = [self expectationWithDescription:@"SP2T2 c1"];
        [resolver1 cancelAndCleanupWithCompletion:^{ [c1 fulfill]; }];
        [self waitForExpectations:@[c1] timeout:5.0];
        return;
    }

    NSString *cafPath = resolved1.tracks.firstObject[@"url"];
    // Guard: cafPath must be non-nil, non-empty, and the file must exist before
    // we can safely call fileURLWithPath: and construct a second plan.
    if (cafPath.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:cafPath]) {
        XCTFail(@"SP2T2: extracted CAF path must be non-empty and exist on disk "
                @"(prerequisite for pure-audio pass-through)");
        XCTestExpectation *c1 = [self expectationWithDescription:@"SP2T2 c1 cafPath guard"];
        [resolver1 cancelAndCleanupWithCompletion:^{ [c1 fulfill]; }];
        [self waitForExpectations:@[c1] timeout:5.0];
        return;
    }

    // Step 2: Pass the extracted CAF through a second resolver.
    // resolver1 is intentionally NOT cleaned up yet — it still owns the temp dir.
    NSURL *cafURL = [NSURL fileURLWithPath:cafPath];
    VGAudioSidecarPlan *plan2 = VGResolverTest_PlanForURL(cafURL, nil, nil, nil);

    VGAudioPreviewFileResolver *resolver2 = [[VGAudioPreviewFileResolver alloc] init];

    XCTestExpectation *resolve2Exp =
        [self expectationWithDescription:@"SP2T2 second resolve"];
    resolve2Exp.expectedFulfillmentCount = 1;
    resolve2Exp.assertForOverFulfill = YES;

    __block VGAudioSidecarPlan *resolved2 = nil;
    __block BOOL firedOnMain = NO;

    [resolver2 resolvePlan:plan2
                completion:^(VGAudioSidecarPlan *_Nullable p) {
        firedOnMain = [NSThread isMainThread];
        resolved2 = p;
        [resolve2Exp fulfill];
    }];
    [self waitForExpectations:@[resolve2Exp] timeout:10.0];

    XCTAssertTrue(firedOnMain,
                  @"pure-audio pass-through completion must fire on the main thread");
    XCTAssertNotNil(resolved2,
                    @"pure-audio pass-through must return a non-nil resolved plan");
    if (resolved2) {
        NSString *passedURL = resolved2.tracks.firstObject[@"url"];
        XCTAssertEqualObjects(passedURL, cafPath,
                              @"pure-audio source URL must be preserved unchanged");
    }

    // ── Cleanup both resolvers ────────────────────────────────────────────────
    XCTestExpectation *cleanup2Exp =
        [self expectationWithDescription:@"SP2T2 cleanup resolver2"];
    [resolver2 cancelAndCleanupWithCompletion:^{ [cleanup2Exp fulfill]; }];
    [self waitForExpectations:@[cleanup2Exp] timeout:5.0];

    XCTestExpectation *cleanup1Exp =
        [self expectationWithDescription:@"SP2T2 cleanup resolver1"];
    [resolver1 cancelAndCleanupWithCompletion:^{ [cleanup1Exp fulfill]; }];
    [self waitForExpectations:@[cleanup1Exp] timeout:5.0];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-P2-T3: Successful cleanup removes the extracted CAF
// ─────────────────────────────────────────────────────────────────────────────
//
// Scenario: after successful extraction, call cancelAndCleanupWithCompletion:.
//
// Verifies:
//   - cleanup completion fires exactly once on the main thread.
//   - the previously extracted CAF file no longer exists after completion.
//
// IMPLEMENTED.

- (void)test_SP2T3_cleanupRemovesExtractedCAF {
    NSURL *movURL = VGResolverTest_MovFixtureURL(self);
    if (!movURL) return;

    VGAudioPreviewFileResolver *resolver = [[VGAudioPreviewFileResolver alloc] init];
    VGAudioSidecarPlan *plan = VGResolverTest_PlanForURL(movURL, nil, nil, nil);

    XCTestExpectation *resolveExp =
        [self expectationWithDescription:@"SP2T3 resolve"];
    resolveExp.expectedFulfillmentCount = 1;
    resolveExp.assertForOverFulfill = YES;

    __block NSString *cafPath = nil;
    [resolver resolvePlan:plan
               completion:^(VGAudioSidecarPlan *_Nullable p) {
        cafPath = p.tracks.firstObject[@"url"];
        [resolveExp fulfill];
    }];
    [self waitForExpectations:@[resolveExp] timeout:30.0];

    if (!cafPath) {
        XCTFail(@"SP2T3: resolve must succeed (prerequisite)");
        XCTestExpectation *bailExp = [self expectationWithDescription:@"SP2T3 bail"];
        [resolver cancelAndCleanupWithCompletion:^{ [bailExp fulfill]; }];
        [self waitForExpectations:@[bailExp] timeout:5.0];
        return;
    }

    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:cafPath],
                  @"CAF must exist before cleanup");

    XCTestExpectation *cleanupExp =
        [self expectationWithDescription:@"SP2T3 cleanup"];
    cleanupExp.expectedFulfillmentCount = 1;
    cleanupExp.assertForOverFulfill = YES;

    __block BOOL cleanupOnMain = NO;
    [resolver cancelAndCleanupWithCompletion:^{
        cleanupOnMain = [NSThread isMainThread];
        [cleanupExp fulfill];
    }];
    [self waitForExpectations:@[cleanupExp] timeout:5.0];

    XCTAssertTrue(cleanupOnMain,
                  @"cleanup completion must fire on the main thread");
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:cafPath],
                   @"extracted CAF must not exist after cleanup completes");
}

// ─────────────────────────────────────────────────────────────────────────────
// S-P2-T4: Repeated cleanup — immediate double call, then idempotent call
// ─────────────────────────────────────────────────────────────────────────────
//
// Prerequisite: resolver must have produced a valid CAF on disk before cleanup
// calls are issued. If extraction failed the test records a failure and returns
// rather than passing trivially on a no-op resolver.
//
// VERIFIED by this test:
//   - Two cancelAndCleanupWithCompletion: calls issued without an intervening
//     wait each fire their completion exactly once on the main thread.
//   - A third call, issued after both first completions have returned, fires
//     its completion exactly once on the main thread.
//   - No crash or timeout at any stage.
//   - The CAF file is absent after all three completions have fired.
//
// NOT_VERIFIED (requires an internal seam):
//   - Whether both immediate calls were simultaneously pending in the
//     _cleanupWaiters array at the same instant. The resolver queue is serial;
//     the second call may arrive after the first has already dispatched the
//     main-queue delivery, in which case it takes the fast "already clean"
//     path rather than the waiter-accumulation path. Distinguishing these
//     paths requires inspection of internal state, which is not available
//     without a production seam.

- (void)test_SP2T4_repeatedCleanupAllCompletionsFire {
    NSURL *movURL = VGResolverTest_MovFixtureURL(self);
    if (!movURL) return;

    VGAudioPreviewFileResolver *resolver = [[VGAudioPreviewFileResolver alloc] init];
    VGAudioSidecarPlan *plan = VGResolverTest_PlanForURL(movURL, nil, nil, nil);

    // Resolve first so a CAF exists on disk.
    XCTestExpectation *resolveExp =
        [self expectationWithDescription:@"SP2T4 resolve"];
    resolveExp.expectedFulfillmentCount = 1;
    resolveExp.assertForOverFulfill = YES;

    __block NSString *cafPath = nil;
    [resolver resolvePlan:plan
               completion:^(VGAudioSidecarPlan *_Nullable p) {
        cafPath = p.tracks.firstObject[@"url"];
        [resolveExp fulfill];
    }];
    [self waitForExpectations:@[resolveExp] timeout:30.0];

    // Prerequisite: cafPath must be non-empty and the file must exist.
    // If extraction failed, the cleanup calls would trivially succeed on a
    // no-op resolver, which is not the scenario under test.
    if (cafPath.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:cafPath]) {
        XCTFail(@"SP2T4: extraction must have produced a valid CAF on disk "
                @"before repeated-cleanup coverage can be exercised");
        XCTestExpectation *bailExp =
            [self expectationWithDescription:@"SP2T4 bail cleanup"];
        [resolver cancelAndCleanupWithCompletion:^{ [bailExp fulfill]; }];
        [self waitForExpectations:@[bailExp] timeout:5.0];
        return;
    }

    // Issue two cleanup calls without waiting between them.
    XCTestExpectation *cleanup1Exp =
        [self expectationWithDescription:@"SP2T4 immediate cleanup 1"];
    cleanup1Exp.expectedFulfillmentCount = 1;
    cleanup1Exp.assertForOverFulfill = YES;

    XCTestExpectation *cleanup2Exp =
        [self expectationWithDescription:@"SP2T4 immediate cleanup 2"];
    cleanup2Exp.expectedFulfillmentCount = 1;
    cleanup2Exp.assertForOverFulfill = YES;

    __block BOOL cleanup1OnMain = NO;
    __block BOOL cleanup2OnMain = NO;

    [resolver cancelAndCleanupWithCompletion:^{
        cleanup1OnMain = [NSThread isMainThread];
        [cleanup1Exp fulfill];
    }];
    // Second call dispatched immediately — no wait.
    [resolver cancelAndCleanupWithCompletion:^{
        cleanup2OnMain = [NSThread isMainThread];
        [cleanup2Exp fulfill];
    }];

    // Wait for both immediate completions together.
    [self waitForExpectations:@[cleanup1Exp, cleanup2Exp] timeout:10.0];
    XCTAssertTrue(cleanup1OnMain, @"first immediate cleanup completion must be on main");
    XCTAssertTrue(cleanup2OnMain, @"second immediate cleanup completion must be on main");

    // Third call: issued after the first two have completed.
    // Exercises the already-clean path.
    XCTestExpectation *cleanup3Exp =
        [self expectationWithDescription:@"SP2T4 already-clean cleanup 3"];
    cleanup3Exp.expectedFulfillmentCount = 1;
    cleanup3Exp.assertForOverFulfill = YES;

    __block BOOL cleanup3OnMain = NO;
    [resolver cancelAndCleanupWithCompletion:^{
        cleanup3OnMain = [NSThread isMainThread];
        [cleanup3Exp fulfill];
    }];
    [self waitForExpectations:@[cleanup3Exp] timeout:5.0];
    XCTAssertTrue(cleanup3OnMain, @"already-clean third cleanup completion must be on main");

    // Confirm the output file is absent.
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:cafPath],
                   @"output CAF must be absent after all cleanup completions have fired");
}

// ─────────────────────────────────────────────────────────────────────────────
// S-P2-T5: Immediate-cancellation structural coverage
// ─────────────────────────────────────────────────────────────────────────────
//
// Classification: STRUCTURAL IMMEDIATE-CANCELLATION COVERAGE.
// This is NOT a deterministic in-flight-cancellation proof.
//
// Verified: resolvePlan:completion: and cancelAndCleanupWithCompletion: compose
// correctly when cancellation is requested immediately after resolution begins.
// Both completions fire exactly once on the main thread regardless of whether
// the cancel flag was observed by the extraction loop before or after it ran.
// No output CAF file is retained after the cleanup completion fires.
//
// NOT_VERIFIED (requires production seam): whether the _cancelled flag was
// observed in-flight (i.e. during extraction) versus post-completion. The
// resolver provides no synchronisation point — no semaphore, delegate, or
// interruptionHook — between the start of resolvePlan: and the extraction
// loop's first buffer read. Adding such a seam would require a production
// source change, which is forbidden by this task's constraints.

- (void)test_SP2T5_immediateCancellationStructuralCoverage {
    NSURL *movURL = VGResolverTest_MovFixtureURL(self);
    if (!movURL) return;

    VGAudioSidecarPlan *plan = VGResolverTest_PlanForURL(movURL, nil, nil, nil);
    VGAudioPreviewFileResolver *resolver = [[VGAudioPreviewFileResolver alloc] init];

    // Both resolve and cleanup must fire exactly once, regardless of race outcome.
    XCTestExpectation *resolveExp =
        [self expectationWithDescription:@"SP2T5 resolve (nil or non-nil)"];
    resolveExp.expectedFulfillmentCount = 1;
    resolveExp.assertForOverFulfill = YES;

    XCTestExpectation *cleanupExp =
        [self expectationWithDescription:@"SP2T5 cleanup"];
    cleanupExp.expectedFulfillmentCount = 1;
    cleanupExp.assertForOverFulfill = YES;

    __block BOOL resolveOnMain = NO;
    __block BOOL cleanupOnMain = NO;
    __block NSString *resolvedCafPath = nil;

    [resolver resolvePlan:plan
               completion:^(VGAudioSidecarPlan *_Nullable p) {
        resolveOnMain = [NSThread isMainThread];
        // Capture any CAF path returned (extraction may have completed before
        // the cancel flag was seen — both nil and non-nil are valid outcomes).
        resolvedCafPath = p.tracks.firstObject[@"url"];
        [resolveExp fulfill];
    }];

    // Request cancellation immediately from the calling (main) queue.
    // No sleep. Whether this races with in-flight extraction is non-deterministic.
    [resolver cancelAndCleanupWithCompletion:^{
        cleanupOnMain = [NSThread isMainThread];
        [cleanupExp fulfill];
    }];

    // Generous timeout: accommodates the case where extraction completes first.
    [self waitForExpectations:@[resolveExp, cleanupExp] timeout:60.0];

    XCTAssertTrue(resolveOnMain,
                  @"resolution completion must fire on main regardless of cancel timing");
    XCTAssertTrue(cleanupOnMain,
                  @"cleanup completion must fire on main thread");

    // If extraction completed before cancellation was observed, a CAF path was
    // returned. After cleanup fires, that file must no longer exist.
    if (resolvedCafPath.length > 0) {
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:resolvedCafPath],
                       @"any CAF produced before cancellation was observed must be "
                       @"removed by cleanup");
    }
    // No crash: implicit.
}

// ─────────────────────────────────────────────────────────────────────────────
// S-P2-T6a: Nil plan → nil completion exactly once on main
// ─────────────────────────────────────────────────────────────────────────────
//
// IMPLEMENTED.

- (void)test_SP2T6a_nilPlanReturnsNilExactlyOnceOnMain {
    VGAudioPreviewFileResolver *resolver = [[VGAudioPreviewFileResolver alloc] init];

    XCTestExpectation *exp =
        [self expectationWithDescription:@"SP2T6a nil plan completion"];
    exp.expectedFulfillmentCount = 1;
    exp.assertForOverFulfill = YES;

    __block BOOL firedOnMain = NO;
    // Use a non-nil sentinel so we can distinguish "block ran with nil" from
    // "block never ran".
    __block VGAudioSidecarPlan *result = (VGAudioSidecarPlan *)(id)@"sentinel";

    [resolver resolvePlan:nil
               completion:^(VGAudioSidecarPlan *_Nullable p) {
        firedOnMain = [NSThread isMainThread];
        result = p;
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:5.0];

    XCTAssertTrue(firedOnMain, @"nil-plan completion must fire on main thread");
    XCTAssertNil(result, @"nil plan must produce a nil resolved plan");

    // Cleanup (idempotent; no CAF was written).
    XCTestExpectation *cleanupExp =
        [self expectationWithDescription:@"SP2T6a cleanup"];
    [resolver cancelAndCleanupWithCompletion:^{ [cleanupExp fulfill]; }];
    [self waitForExpectations:@[cleanupExp] timeout:5.0];
}

// ─────────────────────────────────────────────────────────────────────────────
// S-P2-T6b: Zero-track plan — UMF construction precondition enforced by initializer
// ─────────────────────────────────────────────────────────────────────────────
//
// VGAudioSidecarPlan's designated initializer contains
// NSParameterAssert(tracks.count > 0), which fires an NSInternalInconsistencyException
// when passed an empty array. This test verifies that precondition via
// XCTAssertThrowsSpecificNamed so that any accidental removal of the assertion is caught.
//
// The resolver's internal zero-track branch (`plan.tracks.count == 0`) is
// therefore unreachable through the public VGAudioSidecarPlan API and is NOT
// reported as covered here. The nil-plan branch of the resolver is covered by T6a.

- (void)test_SP2T6b_zeroTrackPlanRejectedByInitializer {
    // Verify the UMF construction precondition: VGAudioSidecarPlan must raise
    // NSInternalInconsistencyException when initialised with an empty tracks
    // array. NSParameterAssert(tracks.count > 0) produces this exception in
    // debug builds (the test target compiles with assertions enabled by default).
    // Any accidental removal of the assertion would cause this test to fail.
    //
    // The resolver's internal zero-track branch (plan.tracks.count == 0) is NOT
    // reported as covered: it is unreachable through the public API because
    // VGAudioSidecarPlan refuses construction. The nil-plan resolver branch is
    // covered by T6a.
    XCTAssertThrowsSpecificNamed(
        [[VGAudioSidecarPlan alloc] initWithTracks:@[]
                                   volumeKeyframes:nil
                                     waveformCache:nil
                             timeRemapAudioPolicy:nil],
        NSException,
        NSInternalInconsistencyException,
        @"VGAudioSidecarPlan must raise NSInternalInconsistencyException when "
        @"tracks is empty (NSParameterAssert tracks.count > 0). "
        @"The resolver zero-track branch is unreachable through the public API."
    );
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
