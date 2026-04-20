// VanguardPhotoCaptureTests.m
// Phase 4: Photo capture — automated regression suite.
//
// Covers all six invariants from the Phase 1 specification:
//
//   PC-1  NO_FRAME error when _latestBuffer is nil (startup window)
//   PC-2  Successful JPEG creation — file exists, valid magic bytes, non-zero size
//   PC-3  No crash when stop() and takePhoto race on _latestBufferLock
//   PC-4  Active video recording is unaffected by concurrent photo capture
//   PC-5  SWITCHING error while _isSwitching == YES
//   PC-6  completion: is always called on the main thread
//
// Run on a physical device for PC-3 and PC-4 (require real AVCaptureSession).
// PC-1, PC-2 (synthetic buffer), PC-5, PC-6 run on simulator.
//
// Build:
//   xcodebuild test -scheme vanguard_media_engine \
//                   -destination 'platform=iOS Simulator,name=iPhone 15'
//
// ASAN (PC-3):
//   Enable Address Sanitizer in the scheme's Diagnostics tab before running.

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>

#import "VanguardCameraMediaSource.h"

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - File-scoped helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Creates a Metal-compatible 1080×1920 BGRA CVPixelBuffer with solid colour.
/// Caller owns the returned +1 reference.
static CVPixelBufferRef VGPCMakeBuffer(void) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:     @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:               @1080,
        (id)kCVPixelBufferHeightKey:              @1920,
        (id)kCVPixelBufferMetalCompatibilityKey:  @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault,
                        1080, 1920,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs,
                        &pb);
    if (pb) {
        // Fill with a non-zero pattern so CIImage has valid content to encode.
        CVPixelBufferLockBaseAddress(pb, 0);
        void *base = CVPixelBufferGetBaseAddress(pb);
        if (base) memset(base, 0x80, CVPixelBufferGetDataSize(pb));
        CVPixelBufferUnlockBaseAddress(pb, 0);
    }
    return pb; // caller owns +1
}

/// Injects a CVPixelBuffer into the camera source's _latestBuffer ivar via
/// the videoCallback path, mimicking a real captureOutput: delivery.
///
/// This is the only safe way to set _latestBuffer from a test: the real ivar
/// is private and locked by _latestBufferLock. Calling the videoCallback block
/// exercises exactly the same retain/lock path as the production code.
///
/// Precondition: cam's videoCallback must have been set to a block that
/// retains the buffer into _latestBuffer. We install a minimal capture-queue-
/// compatible callback here that duplicates the source's own logic:
///   retain → lock → set _latestBuffer → unlock → release old.
///
/// IMPORTANT: Because we bypass the real captureOutput: gate, we drive the
/// callback directly on the calling thread. Tests must call this from a queue
/// compatible with the locking contract (main thread is fine; os_unfair_lock
/// is not thread-specific).
static void VGPCInjectBuffer(VanguardCameraMediaSource *cam,
                              CVPixelBufferRef buffer) {
    // Install a minimal callback that stores buffer into _latestBuffer via
    // the real videoCallback, which is what captureOutput: calls.
    // We reach _latestBuffer indirectly through the videoCallback retain path.
    //
    // Simpler approach: use KVC to read _videoCallback and fire it directly,
    // matching the pattern in VanguardBugFixTests.m (testLatestBufferIsAliveAfterVideoCallback).
    //
    // The videoCallback receives a +1-retained buffer (as documented in the
    // source header). We provide that +1 here.
    void (^cb)(CVPixelBufferRef, CMTime) = [cam valueForKey:@"_videoCallback"];
    if (cb) {
        CVPixelBufferRetain(buffer); // +1 for callback, matching captureOutput: line 437
        cb(buffer, kCMTimeZero);
    }
}

/// Returns a writable temporary path with a .jpg extension, unique per call.
static NSString *VGPCTempJPEGPath(void) {
    NSString *name = [NSString stringWithFormat:@"vg_photo_test_%@.jpg",
                      [[NSUUID UUID] UUIDString]];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

/// Returns YES if the file at path begins with the JPEG magic bytes FF D8 FF.
static BOOL VGPCIsJPEG(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *header = [fh readDataOfLength:3];
    [fh closeFile];
    if (header.length < 3) return NO;
    const uint8_t *b = (const uint8_t *)header.bytes;
    return b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Test class
// ─────────────────────────────────────────────────────────────────────────────

@interface VanguardPhotoCaptureTests : XCTestCase
@end

@implementation VanguardPhotoCaptureTests

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Setup helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Builds a camera source with a pass-through videoCallback pre-installed,
/// matching the callback contract expected by VGPCInjectBuffer.
///
/// The callback simulates exactly what VanguardMetalRenderer._onVideoFrame:
/// does on every frame: accept the +1 retained buffer and release it
/// (the source's _latestBuffer holds its own independent +1 retain).
- (VanguardCameraMediaSource *)makeCameraSourceWithCallback {
    VanguardCameraMediaSource *cam =
        [[VanguardCameraMediaSource alloc] initWithPosition:AVCaptureDevicePositionBack
                                                  frameRate:30];
    // Install a callback that releases rawFrame (+1 from captureOutput:/VGPCInjectBuffer).
    // This mirrors renderer line 514 (CVPixelBufferRelease(rawFrame)) so the
    // retain count arithmetic in the source is balanced.
    [cam setVideoCallback:^(CVPixelBufferRef frame, CMTime pts) {
        CVPixelBufferRelease(frame); // balance the +1 provided by the caller
    }];
    return cam;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - PC-1: NO_FRAME when _latestBuffer is nil
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that takePhotoToURL:completion: returns error code 1 (NO_FRAME)
/// when no frame has been delivered since startCamera (or in this test, before
/// any frame is injected). No file must be written.
///
/// This covers the ~100ms startup window where _latestBuffer == nil.
/// Runs on simulator — no real camera required.
- (void)testPC1_noFrameErrorWhenBufferIsNil {
    VanguardCameraMediaSource *cam = [self makeCameraSourceWithCallback];
    // _latestBuffer is nil at this point — no frame injected, no start() called.

    NSString *path = VGPCTempJPEGPath();
    NSURL *url = [NSURL fileURLWithPath:path];

    XCTestExpectation *exp =
        [self expectationWithDescription:@"PC-1 completion called"];

    [cam takePhotoToURL:url completion:^(NSURL *resultURL, NSError *err) {
        // Invariant: completion always on main thread.
        XCTAssertTrue([NSThread isMainThread],
            @"PC-1: completion must be called on the main thread");

        // Must receive an error with code 1.
        XCTAssertNil(resultURL,
            @"PC-1: url must be nil when no frame is available");
        XCTAssertNotNil(err,
            @"PC-1: error must be non-nil when no frame is available");
        XCTAssertEqual(err.code, 1,
            @"PC-1: error code must be 1 (NO_FRAME), got %ld", (long)err.code);
        XCTAssertEqualObjects(err.domain, @"VanguardCamera",
            @"PC-1: error domain must be VanguardCamera");

        // No file must have been written.
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path],
            @"PC-1: no file must be written on NO_FRAME error");

        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:2.0];
    [cam stop];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - PC-2: Successful JPEG creation
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that after a frame is injected, takePhotoToURL:completion: writes
/// a valid JPEG file and returns its path with no error.
///
/// Checks:
///   - url non-nil, err nil
///   - file exists at the returned path
///   - file begins with JPEG magic bytes FF D8 FF
///   - file size > 0
///   - returned path matches input path
///
/// Uses a synthetic CVPixelBuffer — simulator-compatible.
- (void)testPC2_successfulJPEGCreationWithSyntheticBuffer {
    VanguardCameraMediaSource *cam = [self makeCameraSourceWithCallback];

    // Inject a synthetic frame into _latestBuffer via the videoCallback path.
    CVPixelBufferRef buf = VGPCMakeBuffer();
    XCTAssertNotNil((__bridge id)buf,
        @"PC-2: test setup: synthetic buffer must be created");
    VGPCInjectBuffer(cam, buf);
    CVPixelBufferRelease(buf); // release the test's own +1 reference

    NSString *path = VGPCTempJPEGPath();
    NSURL *url = [NSURL fileURLWithPath:path];

    XCTestExpectation *exp =
        [self expectationWithDescription:@"PC-2 completion called"];

    [cam takePhotoToURL:url completion:^(NSURL *resultURL, NSError *err) {
        XCTAssertTrue([NSThread isMainThread],
            @"PC-2: completion must be on main thread");

        XCTAssertNotNil(resultURL,
            @"PC-2: url must be non-nil on success");
        XCTAssertNil(err,
            @"PC-2: error must be nil on success, got: %@", err);

        if (resultURL) {
            XCTAssertEqualObjects(resultURL.path, path,
                @"PC-2: returned path must match input path");

            NSFileManager *fm = [NSFileManager defaultManager];
            XCTAssertTrue([fm fileExistsAtPath:path],
                @"PC-2: JPEG file must exist at path");

            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            unsigned long long size =
                [attrs[NSFileSize] unsignedLongLongValue];
            XCTAssertGreaterThan(size, 0ULL,
                @"PC-2: JPEG file must be non-empty (size=%llu)", size);

            XCTAssertTrue(VGPCIsJPEG(path),
                @"PC-2: file must begin with JPEG magic bytes FF D8 FF");

            // Clean up.
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }

        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:5.0];
    [cam stop];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - PC-3: No crash during concurrent stop()
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that racing takePhotoToURL: with stop() does not crash,
/// does not cause a double-release, and completion fires exactly once.
///
/// Two outcomes are both correct:
///   A. takePhoto won the lock → snapshot retained before stop() nilled buffer
///      → encode succeeds → url non-nil, err nil
///   B. stop() won the lock first → _latestBuffer nil when takePhoto checked
///      → completion fires with err.code == 1 (NO_FRAME)
///
/// Any crash (EXC_BAD_ACCESS, assertion failure, double-free) is a test failure.
/// Run with Address Sanitizer enabled to maximise detection sensitivity.
///
/// Runs on simulator (stop() is safe without a real session running).
- (void)testPC3_noCrashOrDoubleReleaseWhenStopRacesWithTakePhoto {
    VanguardCameraMediaSource *cam = [self makeCameraSourceWithCallback];

    // Inject a frame so takePhoto has a buffer to race over.
    CVPixelBufferRef buf = VGPCMakeBuffer();
    XCTAssertNotNil((__bridge id)buf,
        @"PC-3: test setup: buffer must be created");
    VGPCInjectBuffer(cam, buf);
    CVPixelBufferRelease(buf);

    NSString *path = VGPCTempJPEGPath();
    NSURL *url = [NSURL fileURLWithPath:path];

    XCTestExpectation *exp =
        [self expectationWithDescription:@"PC-3 completion called exactly once"];
    exp.expectedFulfillmentCount = 1;  // must fire exactly once

    // Fire takePhoto and stop() in immediate succession on the main thread.
    // takePhoto dispatches to _photoQueue; stop() runs inline. The race is on
    // _latestBufferLock between the main thread (stop) and stop's nil-out of
    // _latestBuffer vs our retain already taken by takePhotoToURL:
    [cam takePhotoToURL:url completion:^(NSURL *resultURL, NSError *err) {
        XCTAssertTrue([NSThread isMainThread],
            @"PC-3: completion must always be on main thread");

        // Outcome A or B — both are valid. Assert neither outcome is impossible.
        BOOL outcomeA = (resultURL != nil && err == nil);
        BOOL outcomeB = (resultURL == nil && err != nil && err.code == 1);
        XCTAssertTrue(outcomeA || outcomeB,
            @"PC-3: must be either success (A) or NO_FRAME (B); "
             "got url=%@ err=%@", resultURL, err);

        // Clean up any written file.
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        [exp fulfill];
    }];

    // Call stop() immediately — races with the _photoQueue encode.
    // stop() acquires _latestBufferLock and nils _latestBuffer.
    // takePhotoToURL: may have already taken its retain (outcome A) or not yet
    // (outcome B). Both paths are safe by the spec's concurrent-stop invariant.
    [cam stop];

    [self waitForExpectations:@[exp] timeout:5.0];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - PC-4: Active recording unaffected by photo capture
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that takePhotoToURL: does not touch AVAssetWriter state while a
/// recording is active.
///
/// Strategy: inject a frame, begin a "virtual recording" by writing
/// _recordingState = VanguardRecordingStateWriting via KVC, take a photo,
/// then assert _recordingState is unchanged after the photo completes.
///
/// This is a unit-level verification that the photo path reads zero recording
/// ivars. A full integration test (real session + real recording) requires a
/// physical device and is covered by PC-4-Integration in the manual test plan.
///
/// Simulator-compatible.
- (void)testPC4_recordingStateUntouchedByPhotoCapture {
    VanguardCameraMediaSource *cam = [self makeCameraSourceWithCallback];

    // Inject a frame.
    CVPixelBufferRef buf = VGPCMakeBuffer();
    VGPCInjectBuffer(cam, buf);
    CVPixelBufferRelease(buf);

    // Simulate "recording active" by setting _recordingState = Writing (1)
    // via KVC — the same technique used in VanguardBugFixTests.m L434.
    // This does NOT create a real AVAssetWriter; it only sets the state flag.
    [cam setValue:@1 forKey:@"_recordingState"];
    NSInteger stateBefore =
        [[cam valueForKey:@"_recordingState"] integerValue];
    XCTAssertEqual(stateBefore, 1,
        @"PC-4: setup: _recordingState must be 1 (Writing)");

    NSString *path = VGPCTempJPEGPath();
    NSURL *url = [NSURL fileURLWithPath:path];

    XCTestExpectation *exp =
        [self expectationWithDescription:@"PC-4 completion called"];

    [cam takePhotoToURL:url completion:^(NSURL *resultURL, NSError *err) {
        XCTAssertTrue([NSThread isMainThread],
            @"PC-4: completion must be on main thread");

        // Photo must succeed (frame was available before KVC state assignment).
        // If it fails, the photo path has a dependency on _recordingState —
        // which would be a bug.
        XCTAssertNotNil(resultURL,
            @"PC-4: photo must succeed regardless of _recordingState; err=%@", err);
        XCTAssertNil(err,
            @"PC-4: no error expected during simulated recording; err=%@", err);

        // _recordingState must still be Writing (1) — photo path must not
        // have read or modified it.
        NSInteger stateAfter =
            [[cam valueForKey:@"_recordingState"] integerValue];
        XCTAssertEqual(stateAfter, 1,
            @"PC-4: _recordingState must remain Writing (1) after photo capture; "
             "got %ld", (long)stateAfter);

        // Clean up.
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:5.0];

    // Reset state before stop() to avoid stopRecordingWithCompletion: being
    // incorrectly triggered by stop().
    [cam setValue:@0 forKey:@"_recordingState"];
    [cam stop];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - PC-5: SWITCHING error during camera switch window
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that takePhotoToURL: returns error code 3 (SWITCHING) when
/// _isSwitching is YES, without reading _latestBuffer and without writing
/// any file.
///
/// _isSwitching is set to YES by moveCameraToPosition: before beginConfiguration
/// and cleared after commitConfiguration (synchronous, ~150ms).
///
/// This test simulates the switch window by setting _isSwitching = YES directly
/// via KVC, identical to how VanguardHighRiskTests.m validates ivar state.
///
/// Simulator-compatible — no camera session required.
- (void)testPC5_switchingErrorWhenIsSwitchingIsYES {
    VanguardCameraMediaSource *cam = [self makeCameraSourceWithCallback];

    // Inject a frame first — ensures any buffer-nil check is NOT the cause
    // of failure. The SWITCHING check must fire before the buffer check.
    CVPixelBufferRef buf = VGPCMakeBuffer();
    VGPCInjectBuffer(cam, buf);
    CVPixelBufferRelease(buf);

    // Simulate the switch window: _isSwitching = YES.
    // Both takePhotoToURL: and moveCameraToPosition: run on the main thread,
    // so this is a legitimate simulation of the window.
    [cam setValue:@YES forKey:@"_isSwitching"];
    XCTAssertTrue([[cam valueForKey:@"_isSwitching"] boolValue],
        @"PC-5: setup: _isSwitching must be YES");

    NSString *path = VGPCTempJPEGPath();
    NSURL *url = [NSURL fileURLWithPath:path];

    XCTestExpectation *exp =
        [self expectationWithDescription:@"PC-5 completion called"];

    [cam takePhotoToURL:url completion:^(NSURL *resultURL, NSError *err) {
        XCTAssertTrue([NSThread isMainThread],
            @"PC-5: completion must be on main thread");

        XCTAssertNil(resultURL,
            @"PC-5: url must be nil during switch window");
        XCTAssertNotNil(err,
            @"PC-5: error must be non-nil during switch window");
        XCTAssertEqual(err.code, 3,
            @"PC-5: error code must be 3 (SWITCHING), got %ld", (long)err.code);
        XCTAssertEqualObjects(err.domain, @"VanguardCamera",
            @"PC-5: error domain must be VanguardCamera");

        // No file must be written — the SWITCHING check fires before any I/O.
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path],
            @"PC-5: no file must be written during switch window");

        [exp fulfill];
    }];

    [self waitForExpectations:@[exp] timeout:2.0];

    // Reset before stop().
    [cam setValue:@NO forKey:@"_isSwitching"];
    [cam stop];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - PC-6: Completion always on main thread
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that all four completion paths deliver the result on the main thread,
/// regardless of which thread calls takePhotoToURL:completion:.
///
/// Paths exercised:
///   A. SWITCHING path (immediate dispatch_async to main)
///   B. NO_FRAME path (immediate dispatch_async to main)
///   C. Success path (dispatch_async to main after _photoQueue encode)
///   D. Call initiated from a background thread (must still deliver to main)
///
/// The spec invariant: "FlutterResult is called exactly once per
/// method-channel call, on the main thread."
- (void)testPC6_completionAlwaysOnMainThread_allPaths {
    VanguardCameraMediaSource *cam = [self makeCameraSourceWithCallback];

    // ── Path A: SWITCHING ────────────────────────────────────────────────────
    XCTestExpectation *expA =
        [self expectationWithDescription:@"PC-6A SWITCHING on main"];
    [cam setValue:@YES forKey:@"_isSwitching"];
    [cam takePhotoToURL:[NSURL fileURLWithPath:VGPCTempJPEGPath()]
             completion:^(NSURL *u, NSError *e) {
        XCTAssertTrue([NSThread isMainThread], @"PC-6A: SWITCHING path must call back on main");
        XCTAssertEqual(e.code, 3, @"PC-6A: must be SWITCHING error");
        [expA fulfill];
    }];
    [self waitForExpectations:@[expA] timeout:2.0];
    [cam setValue:@NO forKey:@"_isSwitching"];

    // ── Path B: NO_FRAME ─────────────────────────────────────────────────────
    // _latestBuffer is nil here (no frame injected yet).
    XCTestExpectation *expB =
        [self expectationWithDescription:@"PC-6B NO_FRAME on main"];
    [cam takePhotoToURL:[NSURL fileURLWithPath:VGPCTempJPEGPath()]
             completion:^(NSURL *u, NSError *e) {
        XCTAssertTrue([NSThread isMainThread], @"PC-6B: NO_FRAME path must call back on main");
        XCTAssertEqual(e.code, 1, @"PC-6B: must be NO_FRAME error");
        [expB fulfill];
    }];
    [self waitForExpectations:@[expB] timeout:2.0];

    // ── Path C: Success ──────────────────────────────────────────────────────
    CVPixelBufferRef buf = VGPCMakeBuffer();
    VGPCInjectBuffer(cam, buf);
    CVPixelBufferRelease(buf);

    NSString *pathC = VGPCTempJPEGPath();
    XCTestExpectation *expC =
        [self expectationWithDescription:@"PC-6C success on main"];
    [cam takePhotoToURL:[NSURL fileURLWithPath:pathC]
             completion:^(NSURL *u, NSError *e) {
        XCTAssertTrue([NSThread isMainThread], @"PC-6C: success path must call back on main");
        XCTAssertNil(e, @"PC-6C: no error expected on success path; got: %@", e);
        [[NSFileManager defaultManager] removeItemAtPath:pathC error:nil];
        [expC fulfill];
    }];
    [self waitForExpectations:@[expC] timeout:5.0];

    // ── Path D: Called from background thread ────────────────────────────────
    // The spec guarantees completion on main regardless of the caller's thread.
    // takePhotoToURL: is designed for main-thread callers, but the completion
    // dispatch_async(main_queue, ...) is unconditional — it fires on main even
    // if the method is called from a background thread.
    CVPixelBufferRef buf2 = VGPCMakeBuffer();
    VGPCInjectBuffer(cam, buf2);
    CVPixelBufferRelease(buf2);

    NSString *pathD = VGPCTempJPEGPath();
    XCTestExpectation *expD =
        [self expectationWithDescription:@"PC-6D background-caller completion on main"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        // Calling from a background thread. This is not the intended usage
        // (production always calls from main via the method channel), but the
        // completion delivery guarantee must hold regardless.
        [cam takePhotoToURL:[NSURL fileURLWithPath:pathD]
                 completion:^(NSURL *u, NSError *e) {
            XCTAssertTrue([NSThread isMainThread],
                @"PC-6D: completion must be on main thread even when called from bg");
            // Either success or NO_FRAME depending on lock race with bg thread.
            // Both are valid — we only assert the thread.
            [[NSFileManager defaultManager] removeItemAtPath:pathD error:nil];
            [expD fulfill];
        }];
    });
    [self waitForExpectations:@[expD] timeout:5.0];

    [cam stop];
}

@end
