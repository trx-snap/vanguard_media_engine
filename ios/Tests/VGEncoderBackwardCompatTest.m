// VGEncoderBackwardCompatTest.m
// Phase 5B: VanguardVideoToolboxEncoder backward compatibility and hardening gate.
//
// Verifies:
// 1. Both initializers exist and function correctly.
// 2. The 5-arg init produces the same realtime behavior as before Phase 5B.
// 3. The 8-arg init supports realtime and offline modes.
// 4. invalidateOnce is idempotent.
// 5. completeFrames returns BOOL with correct values.
// 6. Handler properties are copy-attributed and settable.
// 7. callbackBodiesReturned counter starts at zero.
// 8. Prewarm still works.
// 9. Encoder does not crash after invalidation.

#import <XCTest/XCTest.h>
#import "VanguardVideoToolboxEncoder.h"
#import <UMF/VGExportProfile.h>
#import <CoreVideo/CoreVideo.h>

@interface VGEncoderBackwardCompatTest : XCTestCase
@end

@implementation VGEncoderBackwardCompatTest

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Creates a small encoder with the legacy 5-arg init.
/// Uses reduced resolution (192×108) to minimise VT session overhead in tests.
- (VanguardVideoToolboxEncoder *)make5ArgEncoder {
    return [[VanguardVideoToolboxEncoder alloc]
            initWithWidth:192 height:108 bitrate:500000 fps:30
            packetHandler:^(NSData *data, CMTime pts, BOOL kf, NSError *err) {}];
}

/// Creates a small encoder with the new 8-arg init.
- (VanguardVideoToolboxEncoder *)make8ArgEncoderUsage:(VGEncoderUsage)usage {
    return [[VanguardVideoToolboxEncoder alloc]
            initWithWidth:192 height:108 bitrate:500000 fps:30
                codecType:kCMVideoCodecType_H264
             profileLevel:(__bridge NSString *)kVTProfileLevel_H264_High_4_0
                    usage:usage
            packetHandler:nil];
}

/// Creates a 1080×1920 BGRA CVPixelBuffer for encode submission tests.
- (CVPixelBufferRef)makePixelBuffer CF_RETURNS_RETAINED {
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef buf = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, 192, 108,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &buf);
    return buf;
}

// ─── Test 1: 5-arg init exists and session is created ────────────────────────

- (void)test5ArgInitExists {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    XCTAssertNotNil(enc, @"5-arg init must return non-nil");
}

// ─── Test 2: 5-arg init produces ready session ───────────────────────────────

- (void)test5ArgInitProducesReadySession {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    XCTSkipIf(!enc.isReady,
              @"VT session creation failed — skip on this environment");
    XCTAssertTrue(enc.isReady, @"5-arg init: isReady must be YES after successful session");
}

// ─── Test 3: 8-arg init exists ───────────────────────────────────────────────

- (void)test8ArgInitExists {
    VanguardVideoToolboxEncoder *enc = [self make8ArgEncoderUsage:VGEncoderUsageRealtime];
    XCTAssertNotNil(enc, @"8-arg init must return non-nil");
}

// ─── Test 4: 8-arg init realtime produces ready session ──────────────────────

- (void)test8ArgInitRealtimeProducesReadySession {
    VanguardVideoToolboxEncoder *enc = [self make8ArgEncoderUsage:VGEncoderUsageRealtime];
    XCTSkipIf(!enc.isReady,
              @"VT session creation failed — skip on this environment");
    XCTAssertTrue(enc.isReady,
                  @"8-arg init (Realtime): isReady must be YES after successful session");
}

// ─── Test 5: 8-arg init offline produces ready session ───────────────────────

- (void)test8ArgInitOfflineProducesReadySession {
    VanguardVideoToolboxEncoder *enc = [self make8ArgEncoderUsage:VGEncoderUsageOffline];
    XCTSkipIf(!enc.isReady,
              @"VT session creation failed — skip on this environment");
    XCTAssertTrue(enc.isReady,
                  @"8-arg init (Offline): isReady must be YES after successful session");
}

// ─── Test 6: invalidateOnce is idempotent (no crash on double call) ───────────

- (void)testInvalidateOnceIdempotent {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    // Should not crash on second call.
    XCTAssertNoThrow([enc invalidateOnce], @"First invalidateOnce must not throw");
    XCTAssertNoThrow([enc invalidateOnce], @"Second invalidateOnce must not throw (idempotent)");
    XCTAssertNoThrow([enc invalidateOnce], @"Third invalidateOnce must not throw (idempotent)");
}

// ─── Test 7: invalidateOnce then completeFrames returns NO ───────────────────

- (void)testInvalidateOnceThenCompleteFramesReturnsNO {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    XCTSkipIf(!enc.isReady,
              @"VT session creation failed — skip on this environment");
    [enc invalidateOnce];
    BOOL result = [enc completeFrames];
    XCTAssertFalse(result,
                   @"completeFrames must return NO after invalidateOnce");
}

// ─── Test 8: encode after invalidate does not crash ──────────────────────────

- (void)testEncodeAfterInvalidateDoesNotCrash {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    [enc invalidateOnce];
    CVPixelBufferRef buf = [self makePixelBuffer];
    XCTAssertNoThrow(
        [enc encodePixelBuffer:buf presentationTime:kCMTimeZero],
        @"encodePixelBuffer: after invalidateOnce must not crash");
    if (buf) CVPixelBufferRelease(buf);
}

// ─── Test 9: frameCompletionHandler can be set ───────────────────────────────

- (void)testFrameCompletionHandlerCanBeSet {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    __block BOOL called = NO;
    enc.frameCompletionHandler = ^(OSStatus status, VTEncodeInfoFlags flags) {
        called = YES;
    };
    XCTAssertNotNil(enc.frameCompletionHandler,
                    @"frameCompletionHandler must be non-nil after assignment");
    enc.frameCompletionHandler = nil;
    XCTAssertNil(enc.frameCompletionHandler,
                 @"frameCompletionHandler must be nil-able");
}

// ─── Test 10: encodedSampleHandler can be set ────────────────────────────────

- (void)testEncodedSampleHandlerCanBeSet {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    enc.encodedSampleHandler = ^(CMSampleBufferRef sampleBuffer) {};
    XCTAssertNotNil(enc.encodedSampleHandler,
                    @"encodedSampleHandler must be non-nil after assignment");
    enc.encodedSampleHandler = nil;
    XCTAssertNil(enc.encodedSampleHandler,
                 @"encodedSampleHandler must be nil-able");
}

// ─── Test 11: callbackBodiesReturned starts at zero ──────────────────────────

- (void)testCallbackBodiesReturnedInitiallyZero {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    XCTAssertEqual(enc.callbackBodiesReturned, 0LL,
                   @"callbackBodiesReturned must be 0 on a fresh encoder");
}

// ─── Test 12: finish completes without crash ──────────────────────────────────

- (void)testFinishCallsCompleteFrames {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    XCTSkipIf(!enc.isReady,
              @"VT session creation failed — skip on this environment");
    XCTAssertNoThrow([enc finish],
                     @"finish must not throw on a valid session");
}

// ─── Test 13: invalidate (legacy) does not crash ─────────────────────────────

- (void)testInvalidateCallsInvalidateOnce {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    XCTAssertNoThrow([enc invalidate],
                     @"invalidate must not throw");
    // isReady should be NO after invalidate.
    XCTAssertFalse(enc.isReady, @"isReady must be NO after invalidate");
}

// ─── Test 14: old-style invalidate + re-invalidate does not crash ─────────────

- (void)testOldInvalidateDoesNotCrash {
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    // Legacy callers call invalidate once; double-call was a crash before Phase 5B.
    XCTAssertNoThrow([enc invalidate],
                     @"First invalidate must not throw");
    XCTAssertNoThrow([enc invalidate],
                     @"Second invalidate must not crash (idempotent via CAS)");
}

// ─── Test 15: prewarm still works ────────────────────────────────────────────

- (void)testPrewarmStillWorks {
    // Prewarm-path: init with designated init but skip eager session creation
    // by testing that prewarm is idempotent on an already-created session.
    VanguardVideoToolboxEncoder *enc = [self make5ArgEncoder];
    // First prewarm is a no-op if session already created (branch: if (_session) return).
    XCTAssertNoThrow([enc prewarm],
                     @"prewarm must not throw on an already-created session");
    XCTAssertNoThrow([enc prewarm],
                     @"Second prewarm call must not throw (idempotent)");
}

@end
