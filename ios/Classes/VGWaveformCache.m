// VGWaveformCache.m
// vanguard_media_engine — Phase 8.17
//
// Implementation notes:
//   - Cache directory: NSCachesDirectory/vanguard_waveforms/ (created on first write).
//   - Filename: lowercase hex SHA-256 of the UTF-8 cacheKey + ".vgwc" extension.
//     This prevents path traversal and sanitizes any special characters in the key.
//   - File format: fixed binary header followed by raw Float32 samples.
//     See header comment for byte layout. Version field allows future migration.
//   - Atomic write via NSDataWritingAtomic: writes to a temp file then renames,
//     preventing partial/corrupt cache files on crash or out-of-space conditions.
//   - Load validates: version, metadata types and ranges, byte-length of samples.
//     Any mismatch returns nil — never crashes on bad data.
//   - No in-memory cache. No eviction. No extraction.

#import "VGWaveformCache.h"
#import <CommonCrypto/CommonDigest.h>

static NSString * const VGWaveformCacheErrorDomain  = @"VGWaveformCache";
static NSString * const VGWaveformCacheSubdirectory = @"vanguard_waveforms";
static NSString * const VGWaveformCacheExtension    = @".vgwc";

static const uint32_t VGWaveformCacheVersion = 1;

// Binary header layout (little-endian, packed):
// offset  size  field
//  0       4    version        (uint32)
//  4       8    durationSeconds (double)
// 12       4    samplesPerSecond (uint32)
// 16       4    pointCount       (uint32)
// 20+      4*N  Float32 samples[N]
static const NSUInteger VGWaveformCacheHeaderSize = 20;

// ─── Private helpers ──────────────────────────────────────────────────────────

static NSString *VGWaveformCacheSHA256Hex(NSString *input) {
    NSData *inputData = [input dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(inputData.bytes, (CC_LONG)inputData.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

static NSString * _Nullable VGWaveformCacheDirectory(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0) return nil;
    return [dirs.firstObject stringByAppendingPathComponent:VGWaveformCacheSubdirectory];
}

static NSString * _Nullable VGWaveformCacheFilePath(NSString *cacheKey) {
    if (cacheKey.length == 0) return nil;
    NSString *dir = VGWaveformCacheDirectory();
    if (!dir) return nil;
    NSString *filename = [NSString stringWithFormat:@"%@%@",
                          VGWaveformCacheSHA256Hex(cacheKey),
                          VGWaveformCacheExtension];
    return [dir stringByAppendingPathComponent:filename];
}

// ─── VGWaveformCache ──────────────────────────────────────────────────────────

@implementation VGWaveformCache

+ (BOOL)saveResult:(VGWaveformResult *)result
       forCacheKey:(NSString *)cacheKey
              error:(NSError * _Nullable * _Nullable)error {

    if (cacheKey.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"cacheKey must not be empty"}];
        }
        return NO;
    }

    NSData *samplesData = result.samplesData;
    if (!samplesData || samplesData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"result.samplesData must not be empty"}];
        }
        return NO;
    }

    // Ensure cache directory exists.
    NSString *dir = VGWaveformCacheDirectory();
    if (!dir) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not resolve NSCachesDirectory"}];
        }
        return NO;
    }

    NSError *mkdirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&mkdirError];
    if (mkdirError) {
        if (error) *error = mkdirError;
        return NO;
    }

    // Build binary payload.
    NSMutableData *payload = [NSMutableData dataWithCapacity:VGWaveformCacheHeaderSize + samplesData.length];

    uint32_t version         = VGWaveformCacheVersion;
    double   durationSeconds = result.durationSeconds;
    uint32_t sps             = (uint32_t)result.samplesPerSecond;
    uint32_t pointCount      = (uint32_t)result.pointCount;

    [payload appendBytes:&version         length:sizeof(version)];
    [payload appendBytes:&durationSeconds length:sizeof(durationSeconds)];
    [payload appendBytes:&sps             length:sizeof(sps)];
    [payload appendBytes:&pointCount      length:sizeof(pointCount)];
    [payload appendData:samplesData];

    // Validate that samplesData length matches pointCount * 4.
    NSUInteger expectedBytes = (NSUInteger)pointCount * sizeof(float);
    if (samplesData.length != expectedBytes) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                     @"samplesData length %lu != pointCount*4 %lu",
                                                     (unsigned long)samplesData.length,
                                                     (unsigned long)expectedBytes]}];
        }
        return NO;
    }

    NSString *filePath = VGWaveformCacheFilePath(cacheKey);
    if (!filePath) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not build cache file path"}];
        }
        return NO;
    }

    NSError *writeError = nil;
    BOOL ok = [payload writeToFile:filePath
                           options:NSDataWritingAtomic
                             error:&writeError];
    if (!ok && error) {
        *error = writeError;
    }
    return ok;
}

+ (nullable VGWaveformResult *)loadResultForCacheKey:(NSString *)cacheKey {
    if (cacheKey.length == 0) return nil;

    NSString *filePath = VGWaveformCacheFilePath(cacheKey);
    if (!filePath) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) return nil;

    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data || data.length < VGWaveformCacheHeaderSize) return nil;

    const uint8_t *bytes = (const uint8_t *)data.bytes;

    // Read header fields.
    uint32_t version         = 0;
    double   durationSeconds = 0.0;
    uint32_t sps             = 0;
    uint32_t pointCount      = 0;

    memcpy(&version,         bytes,      sizeof(version));
    memcpy(&durationSeconds, bytes + 4,  sizeof(durationSeconds));
    memcpy(&sps,             bytes + 12, sizeof(sps));
    memcpy(&pointCount,      bytes + 16, sizeof(pointCount));

    // Validate schema version.
    if (version != VGWaveformCacheVersion) {
        NSLog(@"[VGWaveformCache] schema version mismatch: expected %u, got %u — cache miss",
              VGWaveformCacheVersion, version);
        return nil;
    }

    // Validate metadata ranges.
    if (durationSeconds <= 0.0 || isnan(durationSeconds) || isinf(durationSeconds)) return nil;
    if (sps == 0) return nil;
    if (pointCount == 0) return nil;

    // Validate sample byte length.
    NSUInteger expectedSampleBytes = (NSUInteger)pointCount * sizeof(float);
    NSUInteger actualSampleBytes   = data.length - VGWaveformCacheHeaderSize;
    if (actualSampleBytes != expectedSampleBytes) {
        NSLog(@"[VGWaveformCache] sample byte length mismatch: expected %lu, got %lu — cache miss",
              (unsigned long)expectedSampleBytes, (unsigned long)actualSampleBytes);
        return nil;
    }

    // Extract samples data.
    NSData *samplesData = [data subdataWithRange:NSMakeRange(VGWaveformCacheHeaderSize,
                                                              expectedSampleBytes)];

    return [[VGWaveformResult alloc] initWithSamplesData:samplesData
                                         durationSeconds:durationSeconds
                                        samplesPerSecond:(NSInteger)sps
                                              pointCount:(NSInteger)pointCount];
}

@end
