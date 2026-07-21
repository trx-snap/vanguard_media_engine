// VGWaveformCacheTests.m
// vanguard_media_engine — Slice Q
//
// Unit tests for VGWaveformCache namespaced disk storage and security invariants.

#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import "VGWaveformCache.h"

static NSString *VGTestSHA256Hex(NSString *input) {
    NSData *inputData = [input dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(inputData.bytes, (CC_LONG)inputData.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

static VGWaveformResult *VGTestMakeResult(NSInteger sps, NSInteger pointCount, double duration) {
    NSMutableData *data = [NSMutableData dataWithCapacity:pointCount * sizeof(float)];
    for (NSInteger i = 0; i < pointCount; i++) {
        float val = (float)(i + 1) * 0.1f;
        [data appendBytes:&val length:sizeof(float)];
    }
    return [[VGWaveformResult alloc] initWithSamplesData:data
                                         durationSeconds:duration
                                        samplesPerSecond:sps
                                              pointCount:pointCount];
}

@interface VGWaveformCacheTests : XCTestCase
@property (nonatomic, copy) NSString *tmpRootPath;
@property (nonatomic, copy) NSString *externalTmpPath;
@property (nonatomic, copy) NSString *symlinkRootPath;
@property (nonatomic, strong) VGWaveformCache *cache;
@end

@implementation VGWaveformCacheTests

- (void)setUp {
    [super setUp];
    NSString *uuidStr = [[NSUUID UUID] UUIDString];
    _tmpRootPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"VGWaveformCacheTest_%@", uuidStr]];
    _externalTmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"VGWaveformExternal_%@", uuidStr]];
    
    NSURL *url = [NSURL fileURLWithPath:_tmpRootPath isDirectory:YES];
    _cache = [[VGWaveformCache alloc] initWithRootDirectoryURL:url];
}

- (void)tearDown {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Symlink paths FIRST unconditionally (do not depend on fileExistsAtPath which follows symlinks)
    if (_symlinkRootPath) {
        [fm removeItemAtPath:_symlinkRootPath error:nil];
    }
    if (_tmpRootPath) {
        [fm removeItemAtPath:_tmpRootPath error:nil];
    }
    // External target directory LAST
    if (_externalTmpPath) {
        [fm removeItemAtPath:_externalTmpPath error:nil];
    }
    _cache = nil;
    _tmpRootPath = nil;
    _externalTmpPath = nil;
    _symlinkRootPath = nil;
    [super tearDown];
}

// 1. Namespaced save/load round trip
- (void)testNamespacedSaveLoadRoundTrip {
    VGWaveformResult *res = VGTestMakeResult(100, 10, 2.5);
    NSError *saveError = nil;
    BOOL saveOk = [_cache saveNamespacedResult:res namespace:@"ns_main" assetKey:@"asset_1" samplesPerSecond:100 error:&saveError];
    XCTAssertTrue(saveOk, @"Save should succeed: %@", saveError);
    XCTAssertNil(saveError);

    NSError *loadError = nil;
    VGWaveformResult *loaded = [_cache loadNamespacedResultForNamespace:@"ns_main" assetKey:@"asset_1" samplesPerSecond:100 error:&loadError];
    XCTAssertNotNil(loaded, @"Loaded result should be non-nil: %@", loadError);
    XCTAssertNil(loadError);
    XCTAssertEqual(loaded.samplesPerSecond, 100);
    XCTAssertEqual(loaded.pointCount, 10);
    XCTAssertEqualWithAccuracy(loaded.durationSeconds, 2.5, 1e-6);
    XCTAssertEqualObjects(loaded.samplesData, res.samplesData);
}

// 2. On-disk topology exact layout and raw values never leak into paths
- (void)testOnDiskTopologyExactLayout {
    VGWaveformResult *res = VGTestMakeResult(50, 4, 1.0);
    NSString *rawNs = @"proj_123";
    NSString *rawKey = @"clip_abc";
    BOOL ok = [_cache saveNamespacedResult:res namespace:rawNs assetKey:rawKey samplesPerSecond:50 error:nil];
    XCTAssertTrue(ok);

    NSString *expectedNsDir = [NSString stringWithFormat:@"n_%@", VGTestSHA256Hex(rawNs)];
    NSString *expectedKeyDir = [NSString stringWithFormat:@"k_%@", VGTestSHA256Hex(rawKey)];
    NSString *expectedFilePath = [[[_tmpRootPath stringByAppendingPathComponent:expectedNsDir]
                                    stringByAppendingPathComponent:expectedKeyDir]
                                   stringByAppendingPathComponent:@"50.vgwc"];

    NSFileManager *fm = [NSFileManager defaultManager];
    XCTAssertTrue([fm fileExistsAtPath:expectedFilePath], @"Expected exact hashed path file to exist: %@", expectedFilePath);

    // Verify raw values never appear in path components
    NSString *rawNsPath = [_tmpRootPath stringByAppendingPathComponent:rawNs];
    NSString *rawKeyPath = [[_tmpRootPath stringByAppendingPathComponent:expectedNsDir] stringByAppendingPathComponent:rawKey];
    XCTAssertFalse([fm fileExistsAtPath:rawNsPath], @"Raw namespace must not exist as path component");
    XCTAssertFalse([fm fileExistsAtPath:rawKeyPath], @"Raw asset key must not exist as path component");
}

// 3. Requested SPS mismatch returns a miss
- (void)testRequestedSPSMismatchReturnsMiss {
    VGWaveformResult *res = VGTestMakeResult(100, 10, 2.0);
    BOOL ok = [_cache saveNamespacedResult:res namespace:@"ns1" assetKey:@"key1" samplesPerSecond:100 error:nil];
    XCTAssertTrue(ok);

    NSError *loadError = nil;
    VGWaveformResult *loaded = [_cache loadNamespacedResultForNamespace:@"ns1" assetKey:@"key1" samplesPerSecond:200 error:&loadError];
    XCTAssertNil(loaded, @"Mismatch SPS must return miss (nil)");
    XCTAssertNil(loadError, @"Mismatch SPS is a miss, not an error");
}

// 4. Save rejects result-SPS disagreement
- (void)testSaveRejectsResultSPSDisagreement {
    VGWaveformResult *res = VGTestMakeResult(100, 10, 2.0);
    NSError *error = nil;
    BOOL ok = [_cache saveNamespacedResult:res namespace:@"ns1" assetKey:@"key1" samplesPerSecond:200 error:&error];
    XCTAssertFalse(ok, @"Save with mismatched requested SPS must fail");
    XCTAssertNotNil(error);
    XCTAssertEqual(error.code, 11);
}

// 5. Missing asset and namespace invalidation are idempotent successes
- (void)testMissingTargetInvalidationIsIdempotentSuccess {
    NSError *err1 = nil;
    BOOL ok1 = [_cache invalidateAssetForNamespace:@"absent_ns" assetKey:@"absent_key" error:&err1];
    XCTAssertTrue(ok1, @"Absent asset invalidation must return YES");
    XCTAssertNil(err1);

    NSError *err2 = nil;
    BOOL ok2 = [_cache invalidateNamespace:@"absent_ns" error:&err2];
    XCTAssertTrue(ok2, @"Absent namespace invalidation must return YES");
    XCTAssertNil(err2);
}

// 6. Asset invalidation removes only targeted asset; siblings remain
- (void)testAssetInvalidationRemovesTargetedAssetOnly {
    VGWaveformResult *res = VGTestMakeResult(100, 5, 1.0);
    [_cache saveNamespacedResult:res namespace:@"ns1" assetKey:@"key1" samplesPerSecond:100 error:nil];
    [_cache saveNamespacedResult:res namespace:@"ns1" assetKey:@"key2" samplesPerSecond:100 error:nil];
    [_cache saveNamespacedResult:res namespace:@"ns2" assetKey:@"key1" samplesPerSecond:100 error:nil];

    NSError *invError = nil;
    BOOL ok = [_cache invalidateAssetForNamespace:@"ns1" assetKey:@"key1" error:&invError];
    XCTAssertTrue(ok, @"Invalidate asset should succeed: %@", invError);

    XCTAssertNil([_cache loadNamespacedResultForNamespace:@"ns1" assetKey:@"key1" samplesPerSecond:100 error:nil]);
    XCTAssertNotNil([_cache loadNamespacedResultForNamespace:@"ns1" assetKey:@"key2" samplesPerSecond:100 error:nil]);
    XCTAssertNotNil([_cache loadNamespacedResultForNamespace:@"ns2" assetKey:@"key1" samplesPerSecond:100 error:nil]);
}

// 7. Namespace invalidation removes only targeted namespace
- (void)testNamespaceInvalidationRemovesTargetedNamespaceOnly {
    VGWaveformResult *res = VGTestMakeResult(100, 5, 1.0);
    [_cache saveNamespacedResult:res namespace:@"ns1" assetKey:@"key1" samplesPerSecond:100 error:nil];
    [_cache saveNamespacedResult:res namespace:@"ns2" assetKey:@"key1" samplesPerSecond:100 error:nil];

    NSError *invError = nil;
    BOOL ok = [_cache invalidateNamespace:@"ns1" error:&invError];
    XCTAssertTrue(ok, @"Invalidate namespace should succeed: %@", invError);

    XCTAssertNil([_cache loadNamespacedResultForNamespace:@"ns1" assetKey:@"key1" samplesPerSecond:100 error:nil]);
    XCTAssertNotNil([_cache loadNamespacedResultForNamespace:@"ns2" assetKey:@"key1" samplesPerSecond:100 error:nil]);
}

// 8. Symlinks at namespace, asset, and density levels are rejected without following/deleting external targets
- (void)testSymlinksAreRejectedWithoutFollowingOrDeletingExternalTargets {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:_externalTmpPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *extTargetFile = [_externalTmpPath stringByAppendingPathComponent:@"ext_file.txt"];
    [@"external payload" writeToFile:extTargetFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Case A: Namespace directory is symlink to external directory
    NSString *nsDir = [_tmpRootPath stringByAppendingPathComponent:[NSString stringWithFormat:@"n_%@", VGTestSHA256Hex(@"sym_ns")]];
    [fm createDirectoryAtPath:_tmpRootPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createSymbolicLinkAtPath:nsDir withDestinationPath:_externalTmpPath error:nil];

    NSError *loadErr = nil;
    XCTAssertNil([_cache loadNamespacedResultForNamespace:@"sym_ns" assetKey:@"key1" samplesPerSecond:100 error:&loadErr]);
    XCTAssertNotNil(loadErr);

    NSError *invNsErr = nil;
    BOOL okInvNs = [_cache invalidateNamespace:@"sym_ns" error:&invNsErr];
    XCTAssertFalse(okInvNs);
    XCTAssertNotNil(invNsErr);
    XCTAssertTrue([fm fileExistsAtPath:extTargetFile], @"External target file must NOT be deleted by symlink namespace invalidation");

    [fm removeItemAtPath:nsDir error:nil];

    // Case B: Asset directory is symlink to external directory
    NSString *realNsDir = [_tmpRootPath stringByAppendingPathComponent:[NSString stringWithFormat:@"n_%@", VGTestSHA256Hex(@"real_ns")]];
    [fm createDirectoryAtPath:realNsDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *assetDir = [realNsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"k_%@", VGTestSHA256Hex(@"sym_key")]];
    [fm createSymbolicLinkAtPath:assetDir withDestinationPath:_externalTmpPath error:nil];

    NSError *invAssetErr = nil;
    BOOL okInvAsset = [_cache invalidateAssetForNamespace:@"real_ns" assetKey:@"sym_key" error:&invAssetErr];
    XCTAssertFalse(okInvAsset);
    XCTAssertNotNil(invAssetErr);
    XCTAssertTrue([fm fileExistsAtPath:extTargetFile], @"External target file must NOT be deleted by symlink asset invalidation");

    [fm removeItemAtPath:assetDir error:nil];

    // Case C: Density file is symlink to external target file
    NSString *realAssetDir = [realNsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"k_%@", VGTestSHA256Hex(@"real_key")]];
    [fm createDirectoryAtPath:realAssetDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *symDensityFile = [realAssetDir stringByAppendingPathComponent:@"100.vgwc"];
    [fm createSymbolicLinkAtPath:symDensityFile withDestinationPath:extTargetFile error:nil];

    VGWaveformResult *res = VGTestMakeResult(100, 5, 1.0);
    NSError *saveErr = nil;
    BOOL okSave = [_cache saveNamespacedResult:res namespace:@"real_ns" assetKey:@"real_key" samplesPerSecond:100 error:&saveErr];
    XCTAssertFalse(okSave);
    XCTAssertNotNil(saveErr);

    NSError *loadDensityErr = nil;
    XCTAssertNil([_cache loadNamespacedResultForNamespace:@"real_ns" assetKey:@"real_key" samplesPerSecond:100 error:&loadDensityErr]);
    XCTAssertNotNil(loadDensityErr);

    XCTAssertTrue([fm fileExistsAtPath:extTargetFile], @"External target file must NOT be deleted or overwritten");
}

// 9. Root symlink is rejected without following or deleting external target
- (void)testRootSymlinkIsRejectedWithoutFollowingOrDeletingExternalTargets {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:_externalTmpPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *markerFile = [_externalTmpPath stringByAppendingPathComponent:@"root_marker.txt"];
    [@"root_marker_payload" writeToFile:markerFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

    _symlinkRootPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"VGRootSym_%@", [[NSUUID UUID] UUIDString]]];
    [fm createSymbolicLinkAtPath:_symlinkRootPath withDestinationPath:_externalTmpPath error:nil];

    NSURL *symRootURL = [NSURL fileURLWithPath:_symlinkRootPath isDirectory:YES];
    VGWaveformCache *symCache = [[VGWaveformCache alloc] initWithRootDirectoryURL:symRootURL];

    @try {
        VGWaveformResult *res = VGTestMakeResult(100, 5, 1.0);
        NSError *saveErr = nil;
        BOOL saveOk = [symCache saveNamespacedResult:res namespace:@"ns1" assetKey:@"key1" samplesPerSecond:100 error:&saveErr];
        XCTAssertFalse(saveOk, @"Save on root symlink must fail");
        XCTAssertNotNil(saveErr);
        XCTAssertEqual(saveErr.code, 13);

        NSError *loadErr = nil;
        VGWaveformResult *loaded = [symCache loadNamespacedResultForNamespace:@"ns1" assetKey:@"key1" samplesPerSecond:100 error:&loadErr];
        XCTAssertNil(loaded, @"Load on root symlink must return nil");
        XCTAssertNotNil(loadErr);
        XCTAssertEqual(loadErr.code, 50);

        NSError *invAssetErr = nil;
        BOOL invAssetOk = [symCache invalidateAssetForNamespace:@"ns1" assetKey:@"key1" error:&invAssetErr];
        XCTAssertFalse(invAssetOk, @"Asset invalidation on root symlink must fail");
        XCTAssertNotNil(invAssetErr);
        XCTAssertEqual(invAssetErr.code, 20);

        NSError *invNsErr = nil;
        BOOL invNsOk = [symCache invalidateNamespace:@"ns1" error:&invNsErr];
        XCTAssertFalse(invNsOk, @"Namespace invalidation on root symlink must fail");
        XCTAssertNotNil(invNsErr);
        XCTAssertEqual(invNsErr.code, 30);

        XCTAssertTrue([fm fileExistsAtPath:markerFile], @"Marker file in external target must remain intact");
        NSString *markerContent = [NSString stringWithContentsOfFile:markerFile encoding:NSUTF8StringEncoding error:nil];
        XCTAssertEqualObjects(markerContent, @"root_marker_payload", @"Marker file content must remain unchanged");
    } @finally {
        if (_symlinkRootPath) {
            [fm removeItemAtPath:_symlinkRootPath error:nil];
        }
    }
}

// 10. Unexpected children and noncanonical filenames block recursive deletion and preserve evidence
- (void)testUnexpectedChildrenBlockDeletionAndPreserveEvidence {
    NSFileManager *fm = [NSFileManager defaultManager];
    VGWaveformResult *res = VGTestMakeResult(100, 5, 1.0);
    [_cache saveNamespacedResult:res namespace:@"ns_dirty" assetKey:@"key_dirty" samplesPerSecond:100 error:nil];

    NSString *nsDirPath = [_tmpRootPath stringByAppendingPathComponent:[NSString stringWithFormat:@"n_%@", VGTestSHA256Hex(@"ns_dirty")]];
    NSString *assetDirPath = [nsDirPath stringByAppendingPathComponent:[NSString stringWithFormat:@"k_%@", VGTestSHA256Hex(@"key_dirty")]];

    // Add unexpected file in asset directory
    NSString *dirtyAssetChild = [assetDirPath stringByAppendingPathComponent:@"invalid_sibling.bin"];
    [@"evidence" writeToFile:dirtyAssetChild atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSError *invAssetErr = nil;
    BOOL okInvAsset = [_cache invalidateAssetForNamespace:@"ns_dirty" assetKey:@"key_dirty" error:&invAssetErr];
    XCTAssertFalse(okInvAsset, @"Invalidate asset must fail due to unexpected sibling");
    XCTAssertNotNil(invAssetErr);
    XCTAssertTrue([fm fileExistsAtPath:dirtyAssetChild], @"Dirty sibling evidence must be preserved");
    XCTAssertTrue([fm fileExistsAtPath:assetDirPath], @"Asset directory must be preserved");

    // Remove dirty asset child so we can test namespace level unexpected child
    [fm removeItemAtPath:dirtyAssetChild error:nil];

    // Add unexpected regular file in namespace directory (namespace children must be directories with k_ prefix)
    NSString *dirtyNsChild = [nsDirPath stringByAppendingPathComponent:@"unexpected_file.txt"];
    [@"evidence" writeToFile:dirtyNsChild atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSError *invNsErr = nil;
    BOOL okInvNs = [_cache invalidateNamespace:@"ns_dirty" error:&invNsErr];
    XCTAssertFalse(okInvNs, @"Invalidate namespace must fail due to unexpected child file");
    XCTAssertNotNil(invNsErr);
    XCTAssertTrue([fm fileExistsAtPath:dirtyNsChild], @"Dirty child file evidence must be preserved");
    XCTAssertTrue([fm fileExistsAtPath:nsDirPath], @"Namespace directory must be preserved");
}

// 11. Explicitly cover invalid density names
- (void)testInvalidDensityFilenamesBlockInvalidation {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *invalidNames = @[
        @"0.vgwc",
        @"1001.vgwc",
        @"01.vgwc",
        @"+1.vgwc",
        @"1 .vgwc",
        @"١.vgwc" // Arabic-Indic digit 1
    ];

    for (NSString *invalidName in invalidNames) {
        NSString *ns = [NSString stringWithFormat:@"ns_inv_%@", invalidName];
        NSString *key = @"key1";
        VGWaveformResult *res = VGTestMakeResult(100, 5, 1.0);
        [_cache saveNamespacedResult:res namespace:ns assetKey:key samplesPerSecond:100 error:nil];

        NSString *nsDirPath = [_tmpRootPath stringByAppendingPathComponent:[NSString stringWithFormat:@"n_%@", VGTestSHA256Hex(ns)]];
        NSString *assetDirPath = [nsDirPath stringByAppendingPathComponent:[NSString stringWithFormat:@"k_%@", VGTestSHA256Hex(key)]];
        NSString *badDensityPath = [assetDirPath stringByAppendingPathComponent:invalidName];

        [@"bad density content" writeToFile:badDensityPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSError *invErr = nil;
        BOOL ok = [_cache invalidateAssetForNamespace:ns assetKey:key error:&invErr];
        XCTAssertFalse(ok, @"Invalidate asset must fail for invalid density filename '%@'", invalidName);
        XCTAssertNotNil(invErr);
        XCTAssertTrue([fm fileExistsAtPath:badDensityPath], @"Bad density file must be preserved");
        XCTAssertTrue([fm fileExistsAtPath:assetDirPath], @"Asset directory must be preserved");
    }
}

// 12. Valid boundary density names 1.vgwc and 1000.vgwc are accepted
- (void)testValidBoundaryDensityNamesAccepted {
    VGWaveformResult *res1 = VGTestMakeResult(1, 4, 1.0);
    BOOL save1 = [_cache saveNamespacedResult:res1 namespace:@"ns_bound" assetKey:@"key_bound" samplesPerSecond:1 error:nil];
    XCTAssertTrue(save1);

    VGWaveformResult *res1000 = VGTestMakeResult(1000, 4, 1.0);
    BOOL save1000 = [_cache saveNamespacedResult:res1000 namespace:@"ns_bound" assetKey:@"key_bound" samplesPerSecond:1000 error:nil];
    XCTAssertTrue(save1000);

    XCTAssertNotNil([_cache loadNamespacedResultForNamespace:@"ns_bound" assetKey:@"key_bound" samplesPerSecond:1 error:nil]);
    XCTAssertNotNil([_cache loadNamespacedResultForNamespace:@"ns_bound" assetKey:@"key_bound" samplesPerSecond:1000 error:nil]);

    NSError *invErr = nil;
    BOOL invOk = [_cache invalidateAssetForNamespace:@"ns_bound" assetKey:@"key_bound" error:&invErr];
    XCTAssertTrue(invOk, @"Invalidation of valid boundary density files must succeed: %@", invErr);
}

// 13. Unrelated unsafe topology does not block operations in a separate valid namespace
- (void)testUnrelatedUnsafeTopologyDoesNotBlockSeparateValidNamespace {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:_externalTmpPath withIntermediateDirectories:YES attributes:nil error:nil];

    // Create unsafe symlinked namespace ns_unsafe
    [fm createDirectoryAtPath:_tmpRootPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *unsafeNsDir = [_tmpRootPath stringByAppendingPathComponent:[NSString stringWithFormat:@"n_%@", VGTestSHA256Hex(@"ns_unsafe")]];
    [fm createSymbolicLinkAtPath:unsafeNsDir withDestinationPath:_externalTmpPath error:nil];

    // Perform operations in valid namespace ns_valid
    VGWaveformResult *res = VGTestMakeResult(100, 5, 1.0);
    NSError *saveErr = nil;
    BOOL saveOk = [_cache saveNamespacedResult:res namespace:@"ns_valid" assetKey:@"key1" samplesPerSecond:100 error:&saveErr];
    XCTAssertTrue(saveOk, @"Save in valid namespace must succeed despite sibling unsafe namespace: %@", saveErr);

    NSError *loadErr = nil;
    VGWaveformResult *loaded = [_cache loadNamespacedResultForNamespace:@"ns_valid" assetKey:@"key1" samplesPerSecond:100 error:&loadErr];
    XCTAssertNotNil(loaded, @"Load in valid namespace must succeed: %@", loadErr);

    NSError *invErr = nil;
    BOOL invOk = [_cache invalidateNamespace:@"ns_valid" error:&invErr];
    XCTAssertTrue(invOk, @"Invalidation of valid namespace must succeed: %@", invErr);
}

@end
