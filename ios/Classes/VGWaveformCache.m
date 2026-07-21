// VGWaveformCache.m
// vanguard_media_engine — Phase 8.17 / Slice Q
//
// Implementation notes:
//   - Cache root is injected at init time. The default instance uses
//     NSCachesDirectory/vanguard_waveforms/.
//   - Legacy filename: lowercase hex SHA-256 of the UTF-8 cacheKey + ".vgwc".
//   - Namespaced paths (relative to root):
//       n_<SHA256(namespace)>/k_<SHA256(assetKey)>/<samplesPerSecond>.vgwc
//   - File format: fixed binary header followed by raw Float32 samples.
//   - Atomic write via NSDataWritingAtomic.
//   - Load validates version, metadata, byte-length, and SPS exact match.
//     Any mismatch returns nil — never crashes on bad data.
//   - No in-memory cache. No eviction. No extraction.
//
// Symlink / path safety (Slice Q):
//   - Resolved canonical path components are compared, not plain string prefixes.
//     realpath(3) resolves every existing ancestor component; the result is used
//     for containment checks instead of stringByStandardizingPath.
//   - lstat(2) is called on every directory level (root, namespace, asset)
//     before any write or removal.
//   - S_IFLNK or unexpected type → error, operation rejected.
//   - Root, namespace, and asset directories are created separately with
//     lstat validation after each creation.
//   - Before recursive invalidation, the expected shallow subtree contents
//     are validated. Unexpected siblings block that specific invalidation.
//     An unexpected sibling in one namespace/key must not block an unrelated lookup.
//   - Missing invalidation target: success (idempotent).
//   - Accepted TOCTOU residual: app-private iOS sandbox; no other process
//     has write access to NSCachesDirectory.

#import "VGWaveformCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#include <stdlib.h>
#include <limits.h>

static NSString * const VGWaveformCacheErrorDomain  = @"VGWaveformCache";
static NSString * const VGWaveformCacheSubdirectory = @"vanguard_waveforms";
static NSString * const VGWaveformCacheExtension    = @".vgwc";
static NSString * const VGWaveformCacheNsPrefix     = @"n_";
static NSString * const VGWaveformCacheKeyPrefix    = @"k_";

static const uint32_t VGWaveformCacheVersion  = 1;
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

static NSString * _Nullable VGWaveformDefaultRootDir(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0) return nil;
    return [dirs.firstObject stringByAppendingPathComponent:VGWaveformCacheSubdirectory];
}

// ── Resolved-path canonical containment ──────────────────────────────────────

/// Returns the resolved canonical absolute path using realpath(3).
/// Resolves non-existent paths through their nearest existing ancestor.
static NSString *VGWaveformResolvedPath(NSString *path) {
    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved) != NULL) {
        return [NSString stringWithUTF8String:resolved];
    }
    // Path does not exist yet — resolve nearest existing ancestor.
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    NSString *current = [path stringByStandardizingPath];
    while (current.length > 0 && ![current isEqualToString:@"/"]) {
        [components insertObject:current.lastPathComponent atIndex:0];
        current = current.stringByDeletingLastPathComponent;
        if (realpath(current.fileSystemRepresentation, resolved) != NULL) {
            NSString *resolvedAncestor = [NSString stringWithUTF8String:resolved];
            for (NSString *comp in components) {
                resolvedAncestor = [resolvedAncestor stringByAppendingPathComponent:comp];
            }
            return resolvedAncestor;
        }
    }
    return [path stringByStandardizingPath];
}

/// Returns YES if child is strictly contained inside parent using resolved paths.
static BOOL VGWaveformPathIsContainedIn(NSString *parentDir, NSString *childPath) {
    NSString *parent = VGWaveformResolvedPath(parentDir);
    NSString *child  = VGWaveformResolvedPath(childPath);
    if (child.length <= parent.length) return NO;
    if (![child hasPrefix:parent]) return NO;
    unichar sep = [child characterAtIndex:parent.length];
    return sep == '/';
}

// ── lstat helpers ─────────────────────────────────────────────────────────────

static BOOL VGWaveformExistsNoFollow(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0;
}

static BOOL VGWaveformIsSymlink(NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return NO;
    return S_ISLNK(st.st_mode);
}

static BOOL VGWaveformIsDirectory(NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return NO;
    return S_ISDIR(st.st_mode);
}

static BOOL VGWaveformIsRegularFile(NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return NO;
    return S_ISREG(st.st_mode);
}

/// Validates that [path] is a directory (not a symlink or other type).
static BOOL VGWaveformValidateDirectory(NSString *path, NSInteger code,
                                        NSError * _Nullable * _Nullable error) {
    if (!VGWaveformExistsNoFollow(path)) return YES;
    if (VGWaveformIsSymlink(path)) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:code
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                     @"Symlink at expected directory path: %@", path]}];
        }
        return NO;
    }
    if (!VGWaveformIsDirectory(path)) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:code
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                     @"Non-directory at expected directory path: %@", path]}];
        }
        return NO;
    }
    return YES;
}

// ── Topology validation helpers ──────────────────────────────────────────────

static BOOL VGWaveformIsValidDensityFilename(NSString *filename) {
    if (![filename hasSuffix:VGWaveformCacheExtension]) return NO;
    NSString *numStr = [filename substringToIndex:filename.length - VGWaveformCacheExtension.length];
    NSUInteger len = numStr.length;
    if (len < 1 || len > 4) return NO;
    const char *utf8 = numStr.UTF8String;
    if (utf8 == NULL || strlen(utf8) != len) return NO;
    if (len > 1 && utf8[0] == '0') return NO;
    for (NSUInteger i = 0; i < len; i++) {
        char c = utf8[i];
        if (c < '0' || c > '9') return NO;
    }
    int val = atoi(utf8);
    return val >= 1 && val <= 1000;
}

static BOOL VGWaveformIsValidAssetDirName(NSString *name) {
    if (![name hasPrefix:VGWaveformCacheKeyPrefix]) return NO;
    if (name.length != VGWaveformCacheKeyPrefix.length + 64) return NO;
    NSString *hex = [name substringFromIndex:VGWaveformCacheKeyPrefix.length];
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [[hex stringByTrimmingCharactersInSet:hexSet] length] == 0;
}

// ── Binary payload helpers ────────────────────────────────────────────────────

static NSData * _Nullable VGWaveformBuildPayload(VGWaveformResult *result,
                                                  NSError **error) {
    NSData *samplesData = result.samplesData;
    if (!samplesData || samplesData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"result.samplesData must not be empty"}];
        }
        return nil;
    }
    NSUInteger expectedBytes = (NSUInteger)result.pointCount * sizeof(float);
    if (samplesData.length != expectedBytes) {
        if (error) {
            *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:4
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                     @"samplesData length %lu != pointCount*4 %lu",
                                                     (unsigned long)samplesData.length,
                                                     (unsigned long)expectedBytes]}];
        }
        return nil;
    }
    NSMutableData *payload = [NSMutableData dataWithCapacity:
                              VGWaveformCacheHeaderSize + samplesData.length];
    uint32_t version         = VGWaveformCacheVersion;
    double   durationSeconds = result.durationSeconds;
    uint32_t sps             = (uint32_t)result.samplesPerSecond;
    uint32_t pointCount      = (uint32_t)result.pointCount;
    [payload appendBytes:&version         length:sizeof(version)];
    [payload appendBytes:&durationSeconds length:sizeof(durationSeconds)];
    [payload appendBytes:&sps             length:sizeof(sps)];
    [payload appendBytes:&pointCount      length:sizeof(pointCount)];
    [payload appendData:samplesData];
    return [payload copy];
}

static VGWaveformResult * _Nullable VGWaveformParsePayload(NSData *data) {
    if (!data || data.length < VGWaveformCacheHeaderSize) return nil;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint32_t version = 0;
    double   durationSeconds = 0.0;
    uint32_t sps = 0;
    uint32_t pointCount = 0;
    memcpy(&version,         bytes,      sizeof(version));
    memcpy(&durationSeconds, bytes + 4,  sizeof(durationSeconds));
    memcpy(&sps,             bytes + 12, sizeof(sps));
    memcpy(&pointCount,      bytes + 16, sizeof(pointCount));
    if (version != VGWaveformCacheVersion) return nil;
    if (durationSeconds <= 0.0 || isnan(durationSeconds) || isinf(durationSeconds)) return nil;
    if (sps == 0 || pointCount == 0) return nil;
    NSUInteger expectedSampleBytes = (NSUInteger)pointCount * sizeof(float);
    NSUInteger actualSampleBytes   = data.length - VGWaveformCacheHeaderSize;
    if (actualSampleBytes != expectedSampleBytes) return nil;
    NSData *samplesData = [data subdataWithRange:
                           NSMakeRange(VGWaveformCacheHeaderSize, expectedSampleBytes)];
    return [[VGWaveformResult alloc] initWithSamplesData:samplesData
                                         durationSeconds:durationSeconds
                                        samplesPerSecond:(NSInteger)sps
                                              pointCount:(NSInteger)pointCount];
}

// ─── VGWaveformCache ──────────────────────────────────────────────────────────

@interface VGWaveformCache ()
@property (nonatomic, copy, readonly) NSString *rootPath;
@end

@implementation VGWaveformCache {
    NSString *_rootPath;
}

@synthesize rootPath = _rootPath;

// ── Lifecycle ─────────────────────────────────────────────────────────────────

+ (instancetype)defaultCache {
    static VGWaveformCache *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = VGWaveformDefaultRootDir();
        if (!dir) {
            dir = [NSTemporaryDirectory()
                   stringByAppendingPathComponent:VGWaveformCacheSubdirectory];
        }
        instance = [[VGWaveformCache alloc]
                    initWithRootDirectoryURL:[NSURL fileURLWithPath:dir isDirectory:YES]];
    });
    return instance;
}

- (instancetype)initWithRootDirectoryURL:(NSURL *)rootDirectoryURL {
    self = [super init];
    if (self) {
        _rootPath = rootDirectoryURL.path ?: @"";
    }
    return self;
}

- (instancetype)init {
    NSString *dir = VGWaveformDefaultRootDir() ?: NSTemporaryDirectory();
    return [self initWithRootDirectoryURL:[NSURL fileURLWithPath:dir isDirectory:YES]];
}

// ── Path derivation (instance, relative to self.rootPath) ────────────────────

- (NSString *)legacyFilePathForCacheKey:(NSString *)cacheKey {
    NSString *filename = [NSString stringWithFormat:@"%@%@",
                          VGWaveformCacheSHA256Hex(cacheKey),
                          VGWaveformCacheExtension];
    return [self.rootPath stringByAppendingPathComponent:filename];
}

- (NSString *)namespaceDirForNamespace:(NSString *)ns {
    NSString *d = [NSString stringWithFormat:@"%@%@",
                   VGWaveformCacheNsPrefix, VGWaveformCacheSHA256Hex(ns)];
    return [self.rootPath stringByAppendingPathComponent:d];
}

- (NSString *)assetDirForNamespace:(NSString *)ns assetKey:(NSString *)assetKey {
    NSString *k = [NSString stringWithFormat:@"%@%@",
                   VGWaveformCacheKeyPrefix, VGWaveformCacheSHA256Hex(assetKey)];
    return [[self namespaceDirForNamespace:ns] stringByAppendingPathComponent:k];
}

- (NSString *)namespacedFilePathForNamespace:(NSString *)ns
                                    assetKey:(NSString *)assetKey
                             samplesPerSecond:(NSInteger)sps {
    NSString *filename = [NSString stringWithFormat:@"%ld%@",
                          (long)sps, VGWaveformCacheExtension];
    return [[self assetDirForNamespace:ns assetKey:assetKey]
            stringByAppendingPathComponent:filename];
}

// ── Instance legacy API ───────────────────────────────────────────────────────

- (BOOL)saveResult:(VGWaveformResult *)result
       forCacheKey:(NSString *)cacheKey
             error:(NSError * _Nullable * _Nullable)error {
    if (cacheKey.length == 0) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:1
                             userInfo:@{NSLocalizedDescriptionKey: @"cacheKey must not be empty"}];
        return NO;
    }
    NSError *mkdirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.rootPath
                              withIntermediateDirectories:YES attributes:nil
                                                    error:&mkdirError];
    if (mkdirError) { if (error) *error = mkdirError; return NO; }

    NSError *buildError = nil;
    NSData *payload = VGWaveformBuildPayload(result, &buildError);
    if (!payload) { if (error) *error = buildError; return NO; }

    NSString *filePath = [self legacyFilePathForCacheKey:cacheKey];
    NSError *writeError = nil;
    BOOL ok = [payload writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
    if (!ok && error) *error = writeError;
    return ok;
}

- (nullable VGWaveformResult *)loadResultForCacheKey:(NSString *)cacheKey {
    if (cacheKey.length == 0) return nil;
    NSString *filePath = [self legacyFilePathForCacheKey:cacheKey];
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    return VGWaveformParsePayload(data);
}

// ── Instance namespaced API (Slice Q) ─────────────────────────────────────────

- (nullable VGWaveformResult *)loadNamespacedResultForNamespace:(NSString *)ns
                                                       assetKey:(NSString *)assetKey
                                              samplesPerSecond:(NSInteger)samplesPerSecond
                                                         error:(NSError * _Nullable * _Nullable)error {
    if (ns.length == 0 || assetKey.length == 0 || samplesPerSecond <= 0) return nil;

    if (!VGWaveformValidateDirectory(self.rootPath, 50, error)) return nil;

    NSString *nsDir    = [self namespaceDirForNamespace:ns];
    NSString *assetDir = [self assetDirForNamespace:ns assetKey:assetKey];
    NSString *filePath = [self namespacedFilePathForNamespace:ns
                                                     assetKey:assetKey
                                              samplesPerSecond:samplesPerSecond];

    if (VGWaveformExistsNoFollow(nsDir)) {
        if (!VGWaveformValidateDirectory(nsDir, 51, error)) return nil;
    } else {
        return nil;
    }

    if (VGWaveformExistsNoFollow(assetDir)) {
        if (!VGWaveformValidateDirectory(assetDir, 53, error)) return nil;
    } else {
        return nil;
    }

    if (!VGWaveformExistsNoFollow(filePath)) return nil;

    if (VGWaveformIsSymlink(filePath)) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:54
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"Cache file is a symlink"}];
        return nil;
    }

    if (!VGWaveformPathIsContainedIn(self.rootPath, filePath)) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:55
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"Cache file path is outside root"}];
        return nil;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:filePath
                                          options:NSDataReadingMappedIfSafe
                                            error:&readError];
    if (!data) {
        if (error) *error = readError;
        return nil;
    }

    VGWaveformResult *parsed = VGWaveformParsePayload(data);
    if (!parsed) return nil;

    if (parsed.samplesPerSecond != samplesPerSecond) return nil;
    return parsed;
}

- (BOOL)saveNamespacedResult:(VGWaveformResult *)result
                   namespace:(NSString *)ns
                    assetKey:(NSString *)assetKey
            samplesPerSecond:(NSInteger)samplesPerSecond
                       error:(NSError * _Nullable * _Nullable)error {
    if (ns.length == 0 || assetKey.length == 0 || samplesPerSecond <= 0) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:10
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"namespace, assetKey must be non-empty; sps > 0"}];
        return NO;
    }

    if (result.samplesPerSecond != samplesPerSecond) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:11
                             userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:
                                             @"result.samplesPerSecond %ld != requested %ld",
                                             (long)result.samplesPerSecond, (long)samplesPerSecond]}];
        return NO;
    }

    NSString *nsDir    = [self namespaceDirForNamespace:ns];
    NSString *assetDir = [self assetDirForNamespace:ns assetKey:assetKey];
    NSString *filePath = [self namespacedFilePathForNamespace:ns
                                                     assetKey:assetKey
                                              samplesPerSecond:samplesPerSecond];

    if (!VGWaveformPathIsContainedIn(self.rootPath, filePath)) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:12
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"Namespaced file path is outside cache root"}];
        return NO;
    }

    NSError *mkError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.rootPath
                               withIntermediateDirectories:YES attributes:nil error:&mkError];
    if (mkError) { if (error) *error = mkError; return NO; }
    if (!VGWaveformValidateDirectory(self.rootPath, 13, error)) return NO;

    mkError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:nsDir
                               withIntermediateDirectories:NO attributes:nil error:&mkError];
    if (mkError && !VGWaveformExistsNoFollow(nsDir)) { if (error) *error = mkError; return NO; }
    if (!VGWaveformValidateDirectory(nsDir, 14, error)) return NO;

    mkError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:assetDir
                               withIntermediateDirectories:NO attributes:nil error:&mkError];
    if (mkError && !VGWaveformExistsNoFollow(assetDir)) { if (error) *error = mkError; return NO; }
    if (!VGWaveformValidateDirectory(assetDir, 15, error)) return NO;

    if (VGWaveformExistsNoFollow(filePath) && VGWaveformIsSymlink(filePath)) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:16
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"Cache file is a symlink — write rejected"}];
        return NO;
    }

    NSError *buildError = nil;
    NSData *payload = VGWaveformBuildPayload(result, &buildError);
    if (!payload) { if (error) *error = buildError; return NO; }

    NSError *writeError = nil;
    BOOL ok = [payload writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
    if (!ok && error) *error = writeError;
    return ok;
}

- (BOOL)invalidateAssetForNamespace:(NSString *)ns
                            assetKey:(NSString *)assetKey
                               error:(NSError * _Nullable * _Nullable)error {
    if (ns.length == 0 || assetKey.length == 0) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:20
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"namespace and assetKey must be non-empty"}];
        return NO;
    }

    if (!VGWaveformValidateDirectory(self.rootPath, 20, error)) return NO;

    NSString *nsDir = [self namespaceDirForNamespace:ns];
    if (!VGWaveformExistsNoFollow(nsDir)) return YES;
    if (!VGWaveformValidateDirectory(nsDir, 21, error)) return NO;

    NSString *assetDir = [self assetDirForNamespace:ns assetKey:assetKey];
    if (!VGWaveformExistsNoFollow(assetDir)) return YES;
    if (!VGWaveformValidateDirectory(assetDir, 22, error)) return NO;

    if (!VGWaveformPathIsContainedIn(self.rootPath, assetDir)) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:23
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"Asset directory is outside cache root"}];
        return NO;
    }

    NSError *enumError = nil;
    NSArray<NSString *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:assetDir error:&enumError];
    if (!children || enumError) {
        if (error) *error = enumError ?: [NSError errorWithDomain:VGWaveformCacheErrorDomain code:24
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to enumerate asset directory"}];
        return NO;
    }

    for (NSString *child in children) {
        NSString *childPath = [assetDir stringByAppendingPathComponent:child];
        if (VGWaveformIsSymlink(childPath) || !VGWaveformIsRegularFile(childPath)
            || !VGWaveformIsValidDensityFilename(child)) {
            if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:24
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:
                                                 @"Unexpected sibling in asset directory: %@", child]}];
            return NO;
        }
    }

    NSString *resolvedAssetDir = VGWaveformResolvedPath(assetDir);
    if (!VGWaveformPathIsContainedIn(self.rootPath, resolvedAssetDir)) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:23
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"Resolved asset directory is outside cache root"}];
        return NO;
    }

    NSURL *resolvedURL = [NSURL fileURLWithPath:resolvedAssetDir isDirectory:YES];
    NSError *removeError = nil;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtURL:resolvedURL error:&removeError];
    if (!ok && error) *error = removeError;
    return ok;
}

- (BOOL)invalidateNamespace:(NSString *)ns
                      error:(NSError * _Nullable * _Nullable)error {
    if (ns.length == 0) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:30
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"namespace must be non-empty"}];
        return NO;
    }

    if (!VGWaveformValidateDirectory(self.rootPath, 30, error)) return NO;

    NSString *nsDir = [self namespaceDirForNamespace:ns];

    if (!VGWaveformExistsNoFollow(nsDir)) return YES;

    if (!VGWaveformValidateDirectory(nsDir, 32, error)) return NO;

    if (!VGWaveformPathIsContainedIn(self.rootPath, nsDir)) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:33
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"Namespace directory is outside cache root"}];
        return NO;
    }

    NSError *enumError = nil;
    NSArray<NSString *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:nsDir error:&enumError];
    if (!children || enumError) {
        if (error) *error = enumError ?: [NSError errorWithDomain:VGWaveformCacheErrorDomain code:34
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to enumerate namespace directory"}];
        return NO;
    }

    for (NSString *child in children) {
        NSString *childPath = [nsDir stringByAppendingPathComponent:child];
        if (VGWaveformIsSymlink(childPath)) {
            if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:34
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:
                                                 @"Symlink in namespace directory: %@", child]}];
            return NO;
        }
        if (!VGWaveformIsDirectory(childPath)) {
            if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:35
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:
                                                 @"Non-directory in namespace directory: %@", child]}];
            return NO;
        }
        if (!VGWaveformIsValidAssetDirName(child)) {
            if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:36
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:
                                                 @"Unexpected sibling in namespace directory: %@", child]}];
            return NO;
        }
        if (!VGWaveformPathIsContainedIn(self.rootPath, childPath)) {
            if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:37
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:
                                                 @"Asset directory outside cache root: %@", child]}];
            return NO;
        }
        NSError *leafEnumError = nil;
        NSArray<NSString *> *leaves = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:childPath error:&leafEnumError];
        if (!leaves || leafEnumError) {
            if (error) *error = leafEnumError ?: [NSError errorWithDomain:VGWaveformCacheErrorDomain code:38
                                                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to enumerate asset subtree"}];
            return NO;
        }
        for (NSString *leaf in leaves) {
            NSString *leafPath = [childPath stringByAppendingPathComponent:leaf];
            if (VGWaveformIsSymlink(leafPath) || !VGWaveformIsRegularFile(leafPath)
                || !VGWaveformIsValidDensityFilename(leaf)) {
                if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:38
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                     @"Unexpected content in asset subtree %@: %@",
                                                     child, leaf]}];
                return NO;
            }
        }
    }

    NSString *resolvedNsDir = VGWaveformResolvedPath(nsDir);
    if (!VGWaveformPathIsContainedIn(self.rootPath, resolvedNsDir)) {
        if (error) *error = [NSError errorWithDomain:VGWaveformCacheErrorDomain code:33
                             userInfo:@{NSLocalizedDescriptionKey:
                                            @"Resolved namespace directory is outside cache root"}];
        return NO;
    }

    NSURL *resolvedURL = [NSURL fileURLWithPath:resolvedNsDir isDirectory:YES];
    NSError *removeError = nil;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtURL:resolvedURL error:&removeError];
    if (!ok && error) *error = removeError;
    return ok;
}

// ── Legacy class-method shims ─────────────────────────────────────────────────

+ (BOOL)saveResult:(VGWaveformResult *)result
       forCacheKey:(NSString *)cacheKey
             error:(NSError * _Nullable * _Nullable)error {
    return [[VGWaveformCache defaultCache] saveResult:result forCacheKey:cacheKey error:error];
}

+ (nullable VGWaveformResult *)loadResultForCacheKey:(NSString *)cacheKey {
    return [[VGWaveformCache defaultCache] loadResultForCacheKey:cacheKey];
}

@end
