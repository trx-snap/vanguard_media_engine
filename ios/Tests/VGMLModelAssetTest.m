// VGMLModelAssetTest.m
// Phase 9B-0 — Model asset integrity smoke test.
//
// Validates that:
//   1. VanguardMLModels.bundle is present in the test host bundle.
//   2. selfie_multiclass_256x256.tflite exists inside the bundle.
//   3. File size matches the known Apache 2.0 asset (16,371,837 bytes).
//   4. SHA256 digest matches the known hash for the Google MediaPipe release.
//
// These checks are intentionally compile-time-free of TFLite headers so the
// test target does not need a GPU device or TFLite runtime linkage to pass.
// The TFLite pod brings headers and binary; this test only touches NSBundle + CC.
//
// Non-goals:
//   Does NOT test inference — that requires Phase 9B-1 (VGLiteRTMaskProvider).
//   Does NOT test the GPU delegate — deferred to on-device smoke test (Phase 9B-2).

#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import "VGMLModelBundle.h"

// ─── Expected asset constants ────────────────────────────────────────────────

/// Known file size of selfie_multiclass_256x256.tflite (Apache 2.0, FP32).
static const long long kExpectedModelFileSize = 16371837LL;

/// Expected SHA256 hex digest (lowercase).
static NSString * const kExpectedSHA256 =
    @"c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0";

static NSString * const kModelName = @"selfie_multiclass_256x256";

// ─── Helpers ─────────────────────────────────────────────────────────────────

static NSString *sha256HexForURL(NSURL *fileURL) {
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (!data) return nil;

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

// ─── Test class ──────────────────────────────────────────────────────────────

@interface VGMLModelAssetTest : XCTestCase
@end

@implementation VGMLModelAssetTest

// ── P9B-MA-1: Bundle resolution ───────────────────────────────────────────────
// VGMLModelBundle must resolve a non-nil URL for the model.
// This proves VanguardMLModels.bundle is embedded in the test host.
- (void)testModelURLIsNonNil {
    NSURL *url = [VGMLModelBundle URLForModelNamed:kModelName];
    XCTAssertNotNil(url, @"P9B-MA-1: VGMLModelBundle returned nil for '%@' — "
                    "VanguardMLModels.bundle may be missing from the test host", kModelName);
}

// ── P9B-MA-2: File existence ──────────────────────────────────────────────────
// The resolved URL must point to an actual readable file on disk.
- (void)testModelFileExists {
    NSURL *url = [VGMLModelBundle URLForModelNamed:kModelName];
    if (!url) { XCTSkip("URL is nil — covered by P9B-MA-1"); }

    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&isDir];
    XCTAssertTrue(exists && !isDir,
                  @"P9B-MA-2: '%@' does not exist as a regular file at %@", kModelName, url.path);
}

// ── P9B-MA-3: File size ───────────────────────────────────────────────────────
// File size must match the known 16,371,837-byte release asset.
// A mismatch indicates a corrupted copy or wrong model variant.
- (void)testModelFileSizeMatchesExpected {
    NSURL *url = [VGMLModelBundle URLForModelNamed:kModelName];
    if (!url) { XCTSkip("URL is nil — covered by P9B-MA-1"); }

    NSError *err = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:&err];
    XCTAssertNil(err, @"P9B-MA-3: attributesOfItemAtPath error: %@", err);

    long long size = [attrs[NSFileSize] longLongValue];
    XCTAssertEqual(size, kExpectedModelFileSize,
                   @"P9B-MA-3: File size %lld != expected %lld — asset may be corrupted",
                   size, kExpectedModelFileSize);
}

// ── P9B-MA-4: SHA256 integrity ────────────────────────────────────────────────
// SHA256 must match the known Apache 2.0 asset hash.
// This guards against silent bit-rot, accidental model substitution,
// or uncommitted prototype variants being bundled.
- (void)testModelSHA256MatchesExpected {
    NSURL *url = [VGMLModelBundle URLForModelNamed:kModelName];
    if (!url) { XCTSkip("URL is nil — covered by P9B-MA-1"); }

    NSString *actual = sha256HexForURL(url);
    XCTAssertNotNil(actual, @"P9B-MA-4: Failed to read file data for SHA256 computation");
    XCTAssertEqualObjects(actual, kExpectedSHA256,
                          @"P9B-MA-4: SHA256 mismatch — got %@ expected %@", actual, kExpectedSHA256);
}

@end
