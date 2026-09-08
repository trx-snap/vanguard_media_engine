// VGAudioPreviewFileResolver.m
// Vanguard Media Engine — S-P2 MOV original-audio repair / Phase 10F Slice 1
//
// Implementation of VGAudioPreviewFileResolver plus the file-private
// VGAudioPreviewCAFCache owner (Phase 10F Slice 1: full-source preview CAF
// cache, in-plan URL dedupe, timing instrumentation).
// See header for architecture, ownership, and threading model.
//
// Modularity note (Phase 10F Slice 1): the cache owner is a file-private
// collaborator in this translation unit rather than a new source file,
// because adding an Objective-C source file would require CocoaPods/project
// membership mutation that is out of scope for this slice. It is cohesive
// and self-contained; migrating it to its own file is deferred explicitly.

#import "VGAudioPreviewFileResolver.h"

#if VG_USE_V2_GRAPH

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <stdatomic.h>
#import <stdio.h>
#import <string.h>

NS_ASSUME_NONNULL_BEGIN

// ─── Cache constants ─────────────────────────────────────────────────────────

/// Cache directory name under NSCachesDirectory.
static NSString *const kVGCAFCacheDirectoryName = @"com.vanguard.audiopreview";

/// Audio schema/format tag folded into every cache key. Bump this whenever
/// the CAF layout produced by _extractAudioFromURL:toCAFURL:trackId: changes.
/// The CAF is float32 interleaved LPCM at the source sample rate and source
/// channel count (full source duration, never range-bounded).
static NSString *const kVGCAFCacheSchemaTag = @"lpcm_f32_interleaved_srcrate_v1";

/// Byte budget for completed CAFs in the cache directory (LRU eviction).
static const unsigned long long kVGCAFCacheByteBudget = 500ULL * 1024ULL * 1024ULL;

/// Negative-cache TTL for failed-extraction / no-audio-track sources.
static const NSTimeInterval kVGCAFCacheNegativeTTLSeconds = 30.0;

/// Upper bound on negative-cache entries held in memory.
static const NSUInteger kVGCAFCacheNegativeMaxEntries = 64;

/// Completed CAFs used (hit or published) within this window are protected
/// from eviction, so a file just handed to a runtime that has not opened it
/// yet cannot be evicted by a concurrent publish from another resolver.
static const NSTimeInterval kVGCAFCacheRecentUseProtectionSeconds = 120.0;

/// Slice length for waiting on another resolver's in-flight extraction.
/// Short slices keep cancellation responsive while blocked.
static const int64_t kVGCAFCacheInflightWaitSliceNanos = 25 * NSEC_PER_MSEC;

/// Upper bound on waiting for an in-flight extraction before falling back to
/// a resolver-owned (uncached) extraction.
static const NSTimeInterval kVGCAFCacheInflightWaitTimeoutSeconds = 180.0;

static NSString *const kVGCAFCacheFileExtension = @"caf";
static NSString *const kVGCAFCachePartialExtension = @"partial";

// ─── Small helpers ───────────────────────────────────────────────────────────

static int VGElapsedMs(CFAbsoluteTime start) {
    return (int)((CFAbsoluteTimeGetCurrent() - start) * 1000.0);
}

/// Lower-case hex SHA-256 of |input| (UTF-8).
static NSString *VGHexSHA256(NSString *input) {
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex =
        [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

/// Deterministic normalisation of a source path for cache keying and
/// in-plan dedupe. Both the cache key and the dedupe map use this form so
/// two spellings of the same file resolve once.
static NSString *VGNormalizedSourcePath(NSString *path) {
    return [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
}

/// Byte size of the file at |path|, or -1 if unavailable.
static long long VGFileSizeAtPath(NSString *path) {
    NSDictionary<NSFileAttributeKey, id> *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return attrs ? (long long)[attrs fileSize] : -1;
}

// ─── File-container category test ────────────────────────────────────────────
//
// Returns YES if |url| points to a file that contains a video track (i.e. an
// audiovisual container such as MOV or MP4). AVURLAsset.tracksWithMediaType
// is used synchronously here because we run on a private serial queue, never
// on the main thread. The call is documented as synchronous for local files.

static BOOL VGURLIsAudiovisualContainer(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset assetWithURL:url];
    return [asset tracksWithMediaType:AVMediaTypeVideo].count > 0;
}

// ─── Outcome enums ───────────────────────────────────────────────────────────

/// Result of one AVAssetReader → ExtAudioFile extraction pass.
typedef NS_ENUM(NSInteger, VGCAFExtractOutcome) {
    VGCAFExtractOutcomeSuccess = 0,
    VGCAFExtractOutcomeCancelled = 1,    ///< Resolver cancelled mid-extraction.
    VGCAFExtractOutcomeNoAudioTrack = 2, ///< Container has no audio track.
    VGCAFExtractOutcomeFailed = 3,       ///< AVFoundation/AudioToolbox failure.
};

/// Result of a cache lookup for one source identity.
typedef NS_ENUM(NSInteger, VGCAFCacheLookupState) {
    VGCAFCacheLookupMiss = 0,
    VGCAFCacheLookupHit = 1,
    VGCAFCacheLookupNegative = 2, ///< Recently failed; bounded TTL active.
};

/// Per-source resolution result inside one plan pass.
typedef NS_ENUM(NSInteger, VGSourceResolution) {
    VGSourceResolutionPassthrough = 0, ///< Pure audio: url unchanged.
    VGSourceResolutionRewritten = 1,   ///< url rewritten to a CAF path.
    VGSourceResolutionDropped = 2,     ///< Track dropped (no audio / failure).
    VGSourceResolutionCancelled = 3,   ///< Resolver cancelled.
};

// ─── VGCAFSourceIdentity ─────────────────────────────────────────────────────
//
// Stable identity of one source file for cache keying:
//   normalized path | byte size | mtime | schema tag  →  SHA-256 hex key.
// trackId is deliberately NOT part of the key (ephemeral per draft).

@interface VGCAFSourceIdentity : NSObject
@property (nonatomic, readonly, copy) NSString *normalizedPath;
@property (nonatomic, readonly) long long fileSize;
@property (nonatomic, readonly) NSTimeInterval modificationTime;
@property (nonatomic, readonly, copy) NSString *cacheKey;
/// Short key suffix for logs.
@property (nonatomic, readonly, copy) NSString *keySuffix;
/// Returns nil when the file's size/mtime cannot be read (uncacheable).
+ (nullable instancetype)identityForNormalizedPath:(NSString *)normalizedPath;
@end

@implementation VGCAFSourceIdentity

+ (nullable instancetype)identityForNormalizedPath:(NSString *)normalizedPath {
    if (normalizedPath.length == 0) return nil;
    NSDictionary<NSFileAttributeKey, id> *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:normalizedPath
                                                         error:nil];
    if (!attrs) return nil;
    NSNumber *size = attrs[NSFileSize];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (!size || !mtime) return nil;

    VGCAFSourceIdentity *identity = [[VGCAFSourceIdentity alloc] init];
    identity->_normalizedPath = [normalizedPath copy];
    identity->_fileSize = size.longLongValue;
    identity->_modificationTime = mtime.timeIntervalSince1970;
    NSString *material = [NSString stringWithFormat:@"%@|%lld|%.6f|%@",
                          identity->_normalizedPath,
                          identity->_fileSize,
                          identity->_modificationTime,
                          kVGCAFCacheSchemaTag];
    identity->_cacheKey = VGHexSHA256(material);
    identity->_keySuffix = [identity->_cacheKey substringFromIndex:
                            identity->_cacheKey.length - 12];
    return identity;
}

@end

// ─── VGCAFCacheClaim ─────────────────────────────────────────────────────────
//
// Exclusive extraction ownership for one cache key. The owner enters the
// group at creation and leaves it in releaseClaim:, so waiters can block on
// dispatch_group_wait until the owner has published, negative-cached, or
// abandoned the entry.

@interface VGCAFCacheClaim : NSObject
@property (nonatomic, readonly, copy) NSString *key;
@property (nonatomic, readonly, copy) NSString *ownerLabel;
@property (nonatomic, readonly, strong) dispatch_group_t group;
/// YES once releaseClaim: has run. Mutated on the cache state queue only.
@property (nonatomic) BOOL hasReleased;
- (instancetype)initWithKey:(NSString *)key ownerLabel:(NSString *)ownerLabel;
@end

@implementation VGCAFCacheClaim

- (instancetype)initWithKey:(NSString *)key ownerLabel:(NSString *)ownerLabel {
    self = [super init];
    if (self) {
        _key = [key copy];
        _ownerLabel = [ownerLabel copy];
        _group = dispatch_group_create();
        dispatch_group_enter(_group);
        _hasReleased = NO;
    }
    return self;
}

@end

// ─── VGAudioPreviewCAFCache ──────────────────────────────────────────────────
//
// Process-wide owner of completed full-source CAFs under
// Library/Caches/com.vanguard.audiopreview/. All mutable bookkeeping
// (in-flight claims, negative cache, recent-use protection) and all cache
// directory mutations are serialized on _stateQueue via dispatch_sync from
// resolver queues. The cache never calls back into resolver queues, so
// there is no lock-order cycle.
//
// Ownership rules:
//   - Completed <key>.caf files belong to the cache. Only LRU eviction (or
//     corruption detection on lookup) removes them.
//   - <key>.<uuid>.partial files belong to the requesting resolver until
//     publishPartialURL:… atomically renames them into place.
//   - Stale *.partial files from a crashed prior process are swept once at
//     first use, before any claim can exist in this process.

@interface VGAudioPreviewCAFCache : NSObject

+ (instancetype)sharedCache;

/// NO when the cache directory could not be created; callers fall back to
/// resolver-owned temporary extraction.
@property (nonatomic, readonly) BOOL isAvailable;

/// Looks up a completed CAF for |identity|. On hit, validates the file,
/// refreshes its LRU timestamp, and returns its path and byte size.
- (VGCAFCacheLookupState)lookupIdentity:(VGCAFSourceIdentity *)identity
                            resolvedPath:(NSString *_Nullable *_Nullable)outPath
                                cafBytes:(long long *_Nullable)outBytes
                       negativeRemaining:(NSTimeInterval *_Nullable)outRemaining;

/// Returns the exclusive claim for |identity|. If |*outOwned| is YES the
/// caller created the claim and must extract, then publish/negative-cache,
/// then releaseClaim:. If NO, another resolver owns it; wait on claim.group
/// and re-run lookupIdentity:… afterwards.
- (VGCAFCacheClaim *)claimIdentity:(VGCAFSourceIdentity *)identity
                        ownerLabel:(NSString *)ownerLabel
                             owned:(BOOL *)outOwned;

/// Releases an owned claim (idempotent) and wakes waiters.
- (void)releaseClaim:(VGCAFCacheClaim *)claim;

/// Unique resolver-owned partial URL inside the cache directory (same volume
/// as the final file so the publish rename is atomic).
- (nullable NSURL *)newPartialURLForClaim:(VGCAFCacheClaim *)claim;

/// Atomically renames |partialURL| to the final <key>.caf path, records
/// recent use, clears any negative entry, and runs byte-budget LRU eviction
/// that never touches |protectedPaths| or the newly published file.
/// Returns the final path, or nil (with |error|) if the rename failed; the
/// partial then remains at |partialURL| and still belongs to the caller.
- (nullable NSString *)publishPartialURL:(NSURL *)partialURL
                                forClaim:(VGCAFCacheClaim *)claim
                          protectedPaths:(NSSet<NSString *> *)protectedPaths
                                cafBytes:(long long *_Nullable)outBytes
                                   error:(NSError *_Nullable *_Nullable)error;

/// Records a bounded-TTL negative entry for the claim's key.
- (void)recordNegativeForClaim:(VGCAFCacheClaim *)claim reason:(NSString *)reason;

@end

@implementation VGAudioPreviewCAFCache {
    dispatch_queue_t _stateQueue;
    NSURL *_Nullable _directoryURL;
    NSMutableDictionary<NSString *, VGCAFCacheClaim *> *_inflight;  // key → claim
    NSMutableDictionary<NSString *, NSDate *> *_negativeExpiry;     // key → expiry
    NSMutableDictionary<NSString *, NSDate *> *_recentUse;          // caf path → last use
}

+ (instancetype)sharedCache {
    static VGAudioPreviewCAFCache *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[VGAudioPreviewCAFCache alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create(
            "com.vanguard.audio.preview.cafCache", DISPATCH_QUEUE_SERIAL);
        _inflight = [NSMutableDictionary new];
        _negativeExpiry = [NSMutableDictionary new];
        _recentUse = [NSMutableDictionary new];
        _directoryURL = [self _prepareDirectory];
        NSUInteger swept = _directoryURL
            ? [self _sweepStalePartialsInDirectory:(NSURL *)_directoryURL]
            : 0;
        NSLog(@"[VGAudioPreviewFileResolver][CACHE] init available=%@ dir=%@ "
              @"budgetBytes=%llu negativeTTLSeconds=%.0f sweptPartials=%lu",
              _directoryURL ? @"YES" : @"NO",
              _directoryURL.path ?: @"-",
              kVGCAFCacheByteBudget,
              kVGCAFCacheNegativeTTLSeconds,
              (unsigned long)swept);
    }
    return self;
}

- (BOOL)isAvailable {
    // _directoryURL is immutable after init; safe to read without the queue.
    return _directoryURL != nil;
}

// ── Directory setup ─────────────────────────────────────────────────────────

- (nullable NSURL *)_prepareDirectory {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject;
    if (base.length == 0) base = NSTemporaryDirectory();
    NSURL *dir = [[NSURL fileURLWithPath:base isDirectory:YES]
        URLByAppendingPathComponent:kVGCAFCacheDirectoryName isDirectory:YES];
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&err]) {
        NSLog(@"[VGAudioPreviewFileResolver][CACHE] failed to create cache dir %@: %@",
              dir.path, err.localizedDescription);
        return nil;
    }
    return dir;
}

/// Deletes *.partial leftovers from a previous process. Runs once from init,
/// before any claim exists in this process, so no live partial can be hit.
- (NSUInteger)_sweepStalePartialsInDirectory:(NSURL *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSURL *> *items =
        [fm contentsOfDirectoryAtURL:dir
          includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:nil];
    NSUInteger swept = 0;
    for (NSURL *item in items) {
        if (![item.pathExtension isEqualToString:kVGCAFCachePartialExtension]) {
            continue;
        }
        if ([fm removeItemAtURL:item error:nil]) swept++;
    }
    return swept;
}

- (NSString *)_locked_cafPathForKey:(NSString *)key {
    NSString *name = [NSString stringWithFormat:@"%@.%@", key,
                      kVGCAFCacheFileExtension];
    return [(NSURL *)_directoryURL URLByAppendingPathComponent:name
                                                  isDirectory:NO].path;
}

// ── Lookup ──────────────────────────────────────────────────────────────────

- (VGCAFCacheLookupState)lookupIdentity:(VGCAFSourceIdentity *)identity
                            resolvedPath:(NSString *_Nullable *_Nullable)outPath
                                cafBytes:(long long *_Nullable)outBytes
                       negativeRemaining:(NSTimeInterval *_Nullable)outRemaining {
    if (!_directoryURL) return VGCAFCacheLookupMiss;

    __block VGCAFCacheLookupState state = VGCAFCacheLookupMiss;
    __block NSString *path = nil;
    __block long long bytes = -1;
    __block NSTimeInterval remaining = 0.0;
    dispatch_sync(_stateQueue, ^{
        state = [self _locked_lookupKey:identity.cacheKey
                                   path:&path
                                  bytes:&bytes
                      negativeRemaining:&remaining];
    });
    if (outPath) *outPath = path;
    if (outBytes) *outBytes = bytes;
    if (outRemaining) *outRemaining = remaining;
    return state;
}

- (VGCAFCacheLookupState)_locked_lookupKey:(NSString *)key
                                      path:(NSString *__strong _Nullable *_Nonnull)outPath
                                     bytes:(long long *)outBytes
                         negativeRemaining:(NSTimeInterval *)outRemaining {
    NSDate *expiry = _negativeExpiry[key];
    if (expiry) {
        NSTimeInterval left = [expiry timeIntervalSinceNow];
        if (left > 0) {
            *outRemaining = left;
            return VGCAFCacheLookupNegative;
        }
        [_negativeExpiry removeObjectForKey:key];
    }

    NSString *cafPath = [self _locked_cafPathForKey:key];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary<NSFileAttributeKey, id> *attrs =
        [fm attributesOfItemAtPath:cafPath error:nil];
    if (!attrs) return VGCAFCacheLookupMiss;

    long long size = (long long)[attrs fileSize];
    if (size <= 0 || ![self _validateCAFAtPath:cafPath]) {
        NSLog(@"[VGAudioPreviewFileResolver][CACHE] discarding unreadable cache "
              @"entry key=%@ cafBytes=%lld",
              [key substringFromIndex:key.length - 12], size);
        [fm removeItemAtPath:cafPath error:nil];
        [_recentUse removeObjectForKey:cafPath];
        return VGCAFCacheLookupMiss;
    }

    // LRU touch: the file's mtime orders eviction; the in-memory map protects
    // very recent users from eviction by a concurrent publish.
    NSDate *now = [NSDate date];
    [fm setAttributes:@{NSFileModificationDate : now}
         ofItemAtPath:cafPath
                error:nil];
    _recentUse[cafPath] = now;

    *outPath = cafPath;
    *outBytes = size;
    return VGCAFCacheLookupHit;
}

/// Cheap header-level validation: AVAudioFile must open the CAF and report a
/// positive frame length. Guards against a corrupt or truncated entry being
/// served repeatedly.
- (BOOL)_validateCAFAtPath:(NSString *)path {
    NSError *err = nil;
    AVAudioFile *file =
        [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path]
                                      error:&err];
    return file != nil && err == nil && file.length > 0;
}

// ── Claims ──────────────────────────────────────────────────────────────────

- (VGCAFCacheClaim *)claimIdentity:(VGCAFSourceIdentity *)identity
                        ownerLabel:(NSString *)ownerLabel
                             owned:(BOOL *)outOwned {
    __block VGCAFCacheClaim *claim = nil;
    __block BOOL owned = NO;
    dispatch_sync(_stateQueue, ^{
        VGCAFCacheClaim *existing = self->_inflight[identity.cacheKey];
        if (existing) {
            claim = existing;
            owned = NO;
            return;
        }
        claim = [[VGCAFCacheClaim alloc] initWithKey:identity.cacheKey
                                          ownerLabel:ownerLabel];
        self->_inflight[identity.cacheKey] = claim;
        owned = YES;
    });
    *outOwned = owned;
    return claim;
}

- (void)releaseClaim:(VGCAFCacheClaim *)claim {
    dispatch_sync(_stateQueue, ^{
        if (claim.hasReleased) return;
        claim.hasReleased = YES;
        if (self->_inflight[claim.key] == claim) {
            [self->_inflight removeObjectForKey:claim.key];
        }
        dispatch_group_leave(claim.group);
    });
}

// ── Partial → published ─────────────────────────────────────────────────────

- (nullable NSURL *)newPartialURLForClaim:(VGCAFCacheClaim *)claim {
    NSURL *dir = _directoryURL;
    if (!dir) return nil;
    // Re-create if the system purged the directory while the app was running.
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSString *name = [NSString stringWithFormat:@"%@.%@.%@", claim.key,
                      [NSUUID UUID].UUIDString, kVGCAFCachePartialExtension];
    return [dir URLByAppendingPathComponent:name isDirectory:NO];
}

- (nullable NSString *)publishPartialURL:(NSURL *)partialURL
                                forClaim:(VGCAFCacheClaim *)claim
                          protectedPaths:(NSSet<NSString *> *)protectedPaths
                                cafBytes:(long long *_Nullable)outBytes
                                   error:(NSError *_Nullable *_Nullable)error {
    if (!_directoryURL) return nil;

    __block NSString *finalPath = nil;
    __block long long bytes = -1;
    __block NSError *err = nil;
    dispatch_sync(_stateQueue, ^{
        NSString *target = [self _locked_cafPathForKey:claim.key];
        // rename(2) is atomic on the same volume and replaces any existing
        // destination, so a lookup sees either the old complete file, or the
        // new complete file — never a partial.
        if (rename(partialURL.fileSystemRepresentation,
                   target.fileSystemRepresentation) != 0) {
            int savedErrno = errno;
            NSString *msg =
                [NSString stringWithUTF8String:strerror(savedErrno)] ?: @"rename failed";
            err = [NSError errorWithDomain:NSPOSIXErrorDomain
                                      code:savedErrno
                                  userInfo:@{NSLocalizedDescriptionKey : msg}];
            return;
        }
        bytes = VGFileSizeAtPath(target);
        self->_recentUse[target] = [NSDate date];
        [self->_negativeExpiry removeObjectForKey:claim.key];
        finalPath = target;

        NSMutableSet<NSString *> *protect = [NSMutableSet setWithSet:protectedPaths];
        [protect addObject:target];
        [self _locked_evictIfNeededProtecting:protect];
    });
    if (outBytes) *outBytes = bytes;
    if (error) *error = err;
    return finalPath;
}

// ── Eviction ────────────────────────────────────────────────────────────────

/// Byte-budget LRU eviction over completed *.caf files, oldest mtime first.
/// Never deletes |protectedPaths| (current plan + just-published file) or
/// files used within kVGCAFCacheRecentUseProtectionSeconds in this process.
/// Partial files are not candidates (different extension). An evicted file
/// still open in an older runtime remains readable through its descriptor.
- (void)_locked_evictIfNeededProtecting:(NSSet<NSString *> *)protectedPaths {
    NSURL *dir = _directoryURL;
    if (!dir) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *listErr = nil;
    NSArray<NSURL *> *items =
        [fm contentsOfDirectoryAtURL:dir
          includingPropertiesForKeys:@[
              NSURLFileSizeKey, NSURLContentModificationDateKey,
              NSURLIsRegularFileKey
          ]
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:&listErr];
    if (!items) {
        NSLog(@"[VGAudioPreviewFileResolver][CACHE] eviction scan failed: %@",
              listErr.localizedDescription);
        return;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSURL *item in items) {
        if (![item.pathExtension isEqualToString:kVGCAFCacheFileExtension]) continue;
        NSNumber *isRegular = nil;
        NSNumber *size = nil;
        NSDate *mtime = nil;
        [item getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
        if (!isRegular.boolValue) continue;
        [item getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [item getResourceValue:&mtime forKey:NSURLContentModificationDateKey error:nil];
        unsigned long long bytes = size.unsignedLongLongValue;
        total += bytes;
        // Rebuild the path from the directory URL so it compares equal to the
        // strings produced by _locked_cafPathForKey: (same base, same form).
        NSString *path = [dir URLByAppendingPathComponent:item.lastPathComponent
                                              isDirectory:NO].path;
        [entries addObject:@{
            @"path" : path,
            @"bytes" : @(bytes),
            @"mtime" : mtime ?: [NSDate distantPast],
        }];
    }

    if (total <= kVGCAFCacheByteBudget) {
        [self _locked_pruneRecentUse];
        return;
    }

    [entries sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *a,
                                                     NSDictionary<NSString *, id> *b) {
        return [(NSDate *)a[@"mtime"] compare:(NSDate *)b[@"mtime"]];
    }];

    NSDate *protectCutoff =
        [NSDate dateWithTimeIntervalSinceNow:-kVGCAFCacheRecentUseProtectionSeconds];
    unsigned long long before = total;
    NSUInteger evicted = 0;
    NSUInteger skippedProtected = 0;
    for (NSDictionary<NSString *, id> *entry in entries) {
        if (total <= kVGCAFCacheByteBudget) break;
        NSString *path = entry[@"path"];
        NSDate *lastUse = _recentUse[path];
        BOOL isProtected =
            [protectedPaths containsObject:path] ||
            (lastUse && [lastUse compare:protectCutoff] == NSOrderedDescending);
        if (isProtected) {
            skippedProtected++;
            continue;
        }
        NSError *rmErr = nil;
        if ([fm removeItemAtPath:path error:&rmErr]) {
            total -= [entry[@"bytes"] unsignedLongLongValue];
            evicted++;
            [_recentUse removeObjectForKey:path];
        } else {
            NSLog(@"[VGAudioPreviewFileResolver][CACHE] eviction remove failed %@: %@",
                  path.lastPathComponent, rmErr.localizedDescription);
        }
    }
    NSLog(@"[VGAudioPreviewFileResolver][CACHE] eviction evicted=%lu "
          @"skippedProtected=%lu bytesBefore=%llu bytesAfter=%llu budgetBytes=%llu",
          (unsigned long)evicted, (unsigned long)skippedProtected, before, total,
          kVGCAFCacheByteBudget);
    [self _locked_pruneRecentUse];
}

/// Keeps the recent-use protection map bounded.
- (void)_locked_pruneRecentUse {
    NSDate *cutoff =
        [NSDate dateWithTimeIntervalSinceNow:-kVGCAFCacheRecentUseProtectionSeconds];
    NSMutableArray<NSString *> *stale = [NSMutableArray array];
    [_recentUse enumerateKeysAndObjectsUsingBlock:^(NSString *path, NSDate *used,
                                                    BOOL *stop) {
        if ([used compare:cutoff] != NSOrderedDescending) [stale addObject:path];
    }];
    [_recentUse removeObjectsForKeys:stale];
}

// ── Negative cache ──────────────────────────────────────────────────────────

- (void)recordNegativeForClaim:(VGCAFCacheClaim *)claim reason:(NSString *)reason {
    dispatch_sync(_stateQueue, ^{
        NSDate *now = [NSDate date];

        // Drop expired entries first.
        NSMutableArray<NSString *> *expired = [NSMutableArray array];
        [self->_negativeExpiry enumerateKeysAndObjectsUsingBlock:^(
            NSString *key, NSDate *expiry, BOOL *stop) {
            if ([expiry compare:now] != NSOrderedDescending) [expired addObject:key];
        }];
        [self->_negativeExpiry removeObjectsForKeys:expired];

        // Bound the table: evict the soonest-to-expire entry when full.
        if (self->_negativeExpiry.count >= kVGCAFCacheNegativeMaxEntries) {
            NSArray<NSString *> *ordered = [self->_negativeExpiry
                keysSortedByValueUsingComparator:^NSComparisonResult(NSDate *a, NSDate *b) {
                    return [a compare:b];
                }];
            if (ordered.firstObject) {
                [self->_negativeExpiry removeObjectForKey:ordered.firstObject];
            }
        }

        self->_negativeExpiry[claim.key] =
            [now dateByAddingTimeInterval:kVGCAFCacheNegativeTTLSeconds];
        NSLog(@"[VGAudioPreviewFileResolver][CACHE] negative cached key=%@ owner=%@ "
              @"reason=%@ ttlSeconds=%.0f entries=%lu",
              [claim.key substringFromIndex:claim.key.length - 12],
              claim.ownerLabel, reason, kVGCAFCacheNegativeTTLSeconds,
              (unsigned long)self->_negativeExpiry.count);
    });
}

@end

// ─── Per-source log line ─────────────────────────────────────────────────────

static void VGLogSourceResolution(NSString *trackId,
                                  NSString *sourcePath,
                                  VGCAFSourceIdentity *_Nullable identity,
                                  BOOL cacheHit,
                                  NSString *state,
                                  long long cafBytes,
                                  CFAbsoluteTime start) {
    NSLog(@"[VGAudioPreviewFileResolver][CACHE] track=%@ source=%@ key=%@ "
          @"cacheHit=%@ state=%@ sourceBytes=%lld cafBytes=%lld elapsedMs=%d",
          trackId,
          sourcePath.lastPathComponent,
          identity ? identity.keySuffix : @"-",
          cacheHit ? @"YES" : @"NO",
          state,
          identity ? identity.fileSize : -1LL,
          cafBytes,
          VGElapsedMs(start));
}

// ─── VGAudioPreviewFileResolver ──────────────────────────────────────────────

@implementation VGAudioPreviewFileResolver {
    // Private serial queue for extraction work.
    dispatch_queue_t _resolverQueue;

    // Resolver-owned temporary directory for uncached (fallback) extraction.
    // Created lazily on first fallback; deleted in _removeTempDirectoryIfNeeded.
    NSURL *_Nullable _tempDirURL;

    // Resolver-owned in-progress partial CAF paths inside the shared cache
    // directory. Accessed on _resolverQueue only (and in dealloc, when no
    // work can be in flight). Completed cache entries are never listed here.
    NSMutableSet<NSString *> *_ownedPartialPaths;

    // Atomic cancellation flag. Set in cancelAndCleanupWithCompletion:.
    // The extraction loop checks this per-sample-buffer; in-flight waits
    // check it per slice.
    _Atomic(BOOL) _cancelled;

    // Guards _cleanupComplete and _cleanupWaiters.
    dispatch_semaphore_t _cleanupSemaphore;

    // YES after cancelAndCleanupWithCompletion: has finished cleanup.
    BOOL _cleanupComplete;

    // Waiters queued while cleanup is in progress (race with
    // a second cancelAndCleanupWithCompletion: call from another thread).
    NSMutableArray<dispatch_block_t> *_cleanupWaiters;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _resolverQueue = dispatch_queue_create(
            "com.vanguard.audio.preview.fileResolver",
            DISPATCH_QUEUE_SERIAL);

        atomic_init(&_cancelled, NO);
        _cleanupComplete = NO;
        _cleanupWaiters = [NSMutableArray new];
        _ownedPartialPaths = [NSMutableSet new];
        _tempDirURL = nil; // lazily created only for uncached fallback
        // Use a binary semaphore to synchronise cleanup state inspection
        // from different queues. Initialised to 1 (unlocked).
        _cleanupSemaphore = dispatch_semaphore_create(1);
    }
    return self;
}

- (void)dealloc {
    // Safety net: ensure resolver-owned cleanup on dealloc even without an
    // explicit call. Completed cache entries are never touched here.
    [self _removeOwnedPartialFiles];
    [self _removeTempDirectoryIfNeeded];
}

// ─── Public: resolvePlan:completion: ─────────────────────────────────────────

- (void)resolvePlan:(nullable VGAudioSidecarPlan *)plan
         completion:(void (^)(VGAudioSidecarPlan *_Nullable resolvedPlan))completion {
    NSParameterAssert(completion != nil);

    // No plan → silent passthrough.
    if (!plan || plan.tracks.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
        return;
    }

    dispatch_async(_resolverQueue, ^{
        [self _resolveTracksInPlan:plan completion:completion];
    });
}

// ─── Public: cancelAndCleanupWithCompletion: ─────────────────────────────────

- (void)cancelAndCleanupWithCompletion:(dispatch_block_t)completion {
    NSParameterAssert(completion != nil);

    // Set cancel flag atomically. The extraction loop will see this on its
    // next iteration and terminate; an in-flight wait exits within one slice.
    atomic_store(&_cancelled, YES);

    // Check whether cleanup is already done or in progress.
    dispatch_semaphore_wait(_cleanupSemaphore, DISPATCH_TIME_FOREVER);
    if (_cleanupComplete) {
        dispatch_semaphore_signal(_cleanupSemaphore);
        dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    [_cleanupWaiters addObject:[completion copy]];
    dispatch_semaphore_signal(_cleanupSemaphore);

    // Dispatch cleanup work to the resolver queue. Because the queue is
    // serial, this block will only run after any in-flight extraction has
    // exited (or yields immediately if the queue is idle).
    dispatch_async(_resolverQueue, ^{
        // Remove resolver-owned files only: in-progress partials in the cache
        // directory and the fallback temp directory. Completed CAFs belong to
        // the shared cache and survive this resolver.
        [self _removeOwnedPartialFiles];
        [self _removeTempDirectoryIfNeeded];

        // Transition to complete and drain waiters on main.
        dispatch_semaphore_wait(self->_cleanupSemaphore, DISPATCH_TIME_FOREVER);
        self->_cleanupComplete = YES;
        NSArray<dispatch_block_t> *waiters = [self->_cleanupWaiters copy];
        [self->_cleanupWaiters removeAllObjects];
        dispatch_semaphore_signal(self->_cleanupSemaphore);

        dispatch_async(dispatch_get_main_queue(), ^{
            for (dispatch_block_t w in waiters) {
                w();
            }
        });
    });
}

// ─── Private: track resolution loop ──────────────────────────────────────────

/// Called on _resolverQueue.
- (void)_resolveTracksInPlan:(VGAudioSidecarPlan *)plan
                  completion:(void (^)(VGAudioSidecarPlan *_Nullable))completion {
    CFAbsoluteTime planStart = CFAbsoluteTimeGetCurrent();

    NSMutableArray<NSDictionary<NSString *, id> *> *resolvedTracks =
        [NSMutableArray arrayWithCapacity:plan.tracks.count];

    // In-plan dedupe: normalized source path → url to use for that source
    // (a CAF path, or the original url string for pure-audio passthrough).
    NSMutableDictionary<NSString *, NSString *> *urlByNormalizedPath =
        [NSMutableDictionary dictionary];
    // Normalized source paths already dropped in this pass.
    NSMutableSet<NSString *> *droppedNormalizedPaths = [NSMutableSet set];
    // CAF paths handed out by this pass — protected from eviction while the
    // pass publishes further entries.
    NSMutableSet<NSString *> *planCafPaths = [NSMutableSet set];

    NSUInteger cacheHits = 0, cacheMisses = 0, passthroughs = 0, deduped = 0,
               dropped = 0;

    for (NSDictionary<NSString *, id> *trackDict in plan.tracks) {
        // Cancellation check between tracks.
        if (atomic_load(&_cancelled)) {
            NSLog(@"[VGAudioPreviewFileResolver][TIMING] cancelled between tracks — "
                  @"aborting elapsedMs=%d", VGElapsedMs(planStart));
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        NSString *urlString = trackDict[@"url"];
        if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
            NSLog(@"[VGAudioPreviewFileResolver] track missing url — dropping");
            dropped++;
            continue;
        }

        id trackIdRaw = trackDict[@"trackId"];
        NSString *trackId = [trackIdRaw isKindOfClass:[NSString class]]
            ? (NSString *)trackIdRaw : @"unknown"; // logs only — never keyed
        NSString *normalizedPath = VGNormalizedSourcePath(urlString);

        // ── In-plan dedupe: same source already handled in this pass ──────
        if ([droppedNormalizedPaths containsObject:normalizedPath]) {
            NSLog(@"[VGAudioPreviewFileResolver][CACHE] track=%@ source=%@ "
                  @"dedupedInPlan=YES state=droppedDuplicate",
                  trackId, urlString.lastPathComponent);
            dropped++;
            continue;
        }
        NSString *dedupedURL = urlByNormalizedPath[normalizedPath];
        if (dedupedURL) {
            deduped++;
            NSLog(@"[VGAudioPreviewFileResolver][CACHE] track=%@ source=%@ "
                  @"dedupedInPlan=YES state=reused url=%@",
                  trackId, urlString.lastPathComponent,
                  dedupedURL.lastPathComponent);
            if ([dedupedURL isEqualToString:urlString]) {
                [resolvedTracks addObject:trackDict];
            } else {
                NSMutableDictionary<NSString *, id> *rewritten = [trackDict mutableCopy];
                rewritten[@"url"] = dedupedURL;
                [resolvedTracks addObject:[rewritten copy]];
            }
            continue;
        }

        // ── First occurrence of this source in the pass ───────────────────
        NSString *rewrittenURL = nil;
        BOOL cacheHit = NO;
        VGSourceResolution resolution =
            [self _resolveSourcePath:urlString
                      normalizedPath:normalizedPath
                             trackId:trackId
                      protectedPaths:planCafPaths
                        rewrittenURL:&rewrittenURL
                            cacheHit:&cacheHit];

        switch (resolution) {
            case VGSourceResolutionCancelled: {
                NSLog(@"[VGAudioPreviewFileResolver][TIMING] cancelled during source "
                      @"resolution — aborting elapsedMs=%d", VGElapsedMs(planStart));
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }

            case VGSourceResolutionPassthrough:
                passthroughs++;
                urlByNormalizedPath[normalizedPath] = urlString;
                [resolvedTracks addObject:trackDict];
                break;

            case VGSourceResolutionRewritten: {
                if (cacheHit) cacheHits++; else cacheMisses++;
                NSString *finalURL = (NSString *)rewrittenURL;
                urlByNormalizedPath[normalizedPath] = finalURL;
                [planCafPaths addObject:finalURL];
                // Build rewritten track dict: copy all fields, replace only "url".
                NSMutableDictionary<NSString *, id> *rewritten = [trackDict mutableCopy];
                rewritten[@"url"] = finalURL;
                [resolvedTracks addObject:[rewritten copy]];
                break;
            }

            case VGSourceResolutionDropped:
                dropped++;
                [droppedNormalizedPaths addObject:normalizedPath];
                break;
        }
    }

    // Post-loop cancellation check.
    if (atomic_load(&_cancelled)) {
        NSLog(@"[VGAudioPreviewFileResolver][TIMING] cancelled after track loop — "
              @"aborting elapsedMs=%d", VGElapsedMs(planStart));
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    if (resolvedTracks.count == 0) {
        NSLog(@"[VGAudioPreviewFileResolver][TIMING] all tracks dropped — returning "
              @"nil plan tracks=%lu elapsedMs=%d",
              (unsigned long)plan.tracks.count, VGElapsedMs(planStart));
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    // Construct new immutable plan: preserve volumeKeyframes, waveformCache,
    // timeRemapAudioPolicy verbatim; only "url" keys differ in tracks.
    VGAudioSidecarPlan *resolvedPlan =
        [[VGAudioSidecarPlan alloc]
            initWithTracks:[resolvedTracks copy]
           volumeKeyframes:plan.volumeKeyframes
             waveformCache:plan.waveformCache
     timeRemapAudioPolicy:plan.timeRemapAudioPolicy];

    NSLog(@"[VGAudioPreviewFileResolver][TIMING] resolvePlan done tracks=%lu "
          @"resolved=%lu passthrough=%lu cacheHits=%lu cacheMisses=%lu "
          @"dedupedTracks=%lu dropped=%lu elapsedMs=%d",
          (unsigned long)plan.tracks.count,
          (unsigned long)resolvedTracks.count,
          (unsigned long)passthroughs,
          (unsigned long)cacheHits,
          (unsigned long)cacheMisses,
          (unsigned long)deduped,
          (unsigned long)dropped,
          VGElapsedMs(planStart));

    dispatch_async(dispatch_get_main_queue(), ^{
        completion(resolvedPlan);
    });
}

// ─── Private: per-source resolution ──────────────────────────────────────────

/// Resolves one distinct source. Runs on _resolverQueue.
///
/// Order of operations:
///   1. Cache lookup by source identity (no AVAsset work on a hit).
///   2. Container classification; pure audio passes through.
///   3. Uncacheable source (no readable size/mtime, cache unavailable) →
///      resolver-owned temporary extraction.
///   4. Cache miss → claim the key and extract to a partial, or wait for the
///      in-flight owner and re-check the cache.
- (VGSourceResolution)_resolveSourcePath:(NSString *)sourcePath
                          normalizedPath:(NSString *)normalizedPath
                                 trackId:(NSString *)trackId
                          protectedPaths:(NSSet<NSString *> *)protectedPaths
                            rewrittenURL:(NSString *__strong _Nullable *_Nonnull)outURL
                                cacheHit:(BOOL *)outCacheHit {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    *outCacheHit = NO;

    NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
    VGAudioPreviewCAFCache *cache = [VGAudioPreviewCAFCache sharedCache];
    VGCAFSourceIdentity *identity = cache.isAvailable
        ? [VGCAFSourceIdentity identityForNormalizedPath:normalizedPath]
        : nil;

    // ── 1. Cache lookup before any AVAsset work ──────────────────────────
    if (identity) {
        NSString *hitPath = nil;
        long long cafBytes = -1;
        NSTimeInterval remaining = 0.0;
        VGCAFCacheLookupState state = [cache lookupIdentity:identity
                                               resolvedPath:&hitPath
                                                   cafBytes:&cafBytes
                                          negativeRemaining:&remaining];
        if (state == VGCAFCacheLookupHit) {
            *outURL = hitPath;
            *outCacheHit = YES;
            VGLogSourceResolution(trackId, sourcePath, identity, YES, @"hit",
                                  cafBytes, start);
            return VGSourceResolutionRewritten;
        }
        if (state == VGCAFCacheLookupNegative) {
            NSString *stateLabel = [NSString stringWithFormat:
                @"negativeCached(ttlRemainingMs=%d)", (int)(remaining * 1000.0)];
            VGLogSourceResolution(trackId, sourcePath, identity, NO, stateLabel,
                                  -1, start);
            return VGSourceResolutionDropped;
        }
    }

    // ── 2. Container classification ─────────────────────────────────────
    if (!VGURLIsAudiovisualContainer(sourceURL)) {
        VGLogSourceResolution(trackId, sourcePath, identity, NO, @"passthrough",
                              -1, start);
        return VGSourceResolutionPassthrough;
    }

    if (atomic_load(&_cancelled)) {
        VGLogSourceResolution(trackId, sourcePath, identity, NO, @"cancelled",
                              -1, start);
        return VGSourceResolutionCancelled;
    }

    // ── 3. Uncacheable → resolver-owned temporary extraction ─────────────
    if (!identity) {
        return [self _extractUncachedFromURL:sourceURL
                                  sourcePath:sourcePath
                                     trackId:trackId
                                    identity:nil
                                rewrittenURL:outURL
                                       start:start];
    }

    // ── 4. Cache miss: claim or wait for the in-flight owner ─────────────
    CFAbsoluteTime waitDeadline = start + kVGCAFCacheInflightWaitTimeoutSeconds;
    while (YES) {
        BOOL owned = NO;
        VGCAFCacheClaim *claim = [cache claimIdentity:identity
                                           ownerLabel:trackId
                                                owned:&owned];
        if (owned) {
            return [self _extractWithClaim:claim
                                  identity:identity
                                 sourceURL:sourceURL
                                sourcePath:sourcePath
                                   trackId:trackId
                            protectedPaths:protectedPaths
                              rewrittenURL:outURL
                                     start:start];
        }

        // Another resolver is extracting this source. Wait in slices so
        // cancellation stays responsive; never publish or read its partial.
        NSLog(@"[VGAudioPreviewFileResolver][CACHE] track=%@ source=%@ key=%@ "
              @"waiting for in-flight extraction owner=%@",
              trackId, sourcePath.lastPathComponent, identity.keySuffix,
              claim.ownerLabel);
        BOOL ownerFinished = [self _waitForInflightGroup:claim.group
                                                deadline:waitDeadline];
        if (atomic_load(&_cancelled)) {
            VGLogSourceResolution(trackId, sourcePath, identity, NO,
                                  @"cancelledWhileWaiting", -1, start);
            return VGSourceResolutionCancelled;
        }
        if (!ownerFinished) {
            VGLogSourceResolution(trackId, sourcePath, identity, NO,
                                  @"inflightWaitTimeout", -1, start);
            return [self _extractUncachedFromURL:sourceURL
                                      sourcePath:sourcePath
                                         trackId:trackId
                                        identity:identity
                                    rewrittenURL:outURL
                                           start:start];
        }

        // Owner finished: it published, negative-cached, or abandoned the key.
        NSString *hitPath = nil;
        long long cafBytes = -1;
        NSTimeInterval remaining = 0.0;
        VGCAFCacheLookupState state = [cache lookupIdentity:identity
                                               resolvedPath:&hitPath
                                                   cafBytes:&cafBytes
                                          negativeRemaining:&remaining];
        if (state == VGCAFCacheLookupHit) {
            *outURL = hitPath;
            *outCacheHit = YES;
            VGLogSourceResolution(trackId, sourcePath, identity, YES,
                                  @"joinedInflight", cafBytes, start);
            return VGSourceResolutionRewritten;
        }
        if (state == VGCAFCacheLookupNegative) {
            NSString *stateLabel = [NSString stringWithFormat:
                @"negativeCached(ttlRemainingMs=%d)", (int)(remaining * 1000.0)];
            VGLogSourceResolution(trackId, sourcePath, identity, NO, stateLabel,
                                  -1, start);
            return VGSourceResolutionDropped;
        }
        // Miss (owner was cancelled): loop and try to claim it ourselves.
    }
}

/// Blocks the resolver queue until |group| empties (owner released), the
/// resolver is cancelled, or |deadline| passes. Returns YES only when the
/// owner released the claim.
- (BOOL)_waitForInflightGroup:(dispatch_group_t)group
                     deadline:(CFAbsoluteTime)deadline {
    while (!atomic_load(&_cancelled) && CFAbsoluteTimeGetCurrent() < deadline) {
        long rc = dispatch_group_wait(
            group, dispatch_time(DISPATCH_TIME_NOW, kVGCAFCacheInflightWaitSliceNanos));
        if (rc == 0) return YES;
    }
    return NO;
}

/// Owner path: extract to a resolver-owned partial inside the cache
/// directory, then publish atomically (or negative-cache on failure), then
/// release the claim so waiters observe the outcome on re-lookup.
- (VGSourceResolution)_extractWithClaim:(VGCAFCacheClaim *)claim
                               identity:(VGCAFSourceIdentity *)identity
                              sourceURL:(NSURL *)sourceURL
                             sourcePath:(NSString *)sourcePath
                                trackId:(NSString *)trackId
                         protectedPaths:(NSSet<NSString *> *)protectedPaths
                           rewrittenURL:(NSString *__strong _Nullable *_Nonnull)outURL
                                  start:(CFAbsoluteTime)start {
    VGAudioPreviewCAFCache *cache = [VGAudioPreviewCAFCache sharedCache];

    NSURL *partialURL = [cache newPartialURLForClaim:claim];
    if (!partialURL) {
        [cache releaseClaim:claim];
        return [self _extractUncachedFromURL:sourceURL
                                  sourcePath:sourcePath
                                     trackId:trackId
                                    identity:identity
                                rewrittenURL:outURL
                                       start:start];
    }

    // The partial is resolver-owned until published.
    [_ownedPartialPaths addObject:partialURL.path];

    VGCAFExtractOutcome outcome = [self _extractAudioFromURL:sourceURL
                                                    toCAFURL:partialURL
                                                     trackId:trackId];

    VGSourceResolution resolution = VGSourceResolutionDropped;
    BOOL keepPartialAsResolverOwned = NO;

    switch (outcome) {
        case VGCAFExtractOutcomeSuccess: {
            long long cafBytes = -1;
            NSError *publishErr = nil;
            NSString *finalPath = [cache publishPartialURL:partialURL
                                                  forClaim:claim
                                            protectedPaths:protectedPaths
                                                  cafBytes:&cafBytes
                                                     error:&publishErr];
            if (finalPath) {
                *outURL = finalPath;
                resolution = VGSourceResolutionRewritten;
                VGLogSourceResolution(trackId, sourcePath, identity, NO,
                                      @"extracted", cafBytes, start);
            } else {
                // Rename failed: the fully written file still sits at the
                // partial path. Serve it as a resolver-owned temporary so
                // audio still plays; cleanup deletes it with this resolver.
                *outURL = partialURL.path;
                resolution = VGSourceResolutionRewritten;
                keepPartialAsResolverOwned = YES;
                NSString *stateLabel = [NSString stringWithFormat:
                    @"publishFailed(%@)", publishErr.localizedDescription ?: @"unknown"];
                VGLogSourceResolution(trackId, sourcePath, identity, NO, stateLabel,
                                      VGFileSizeAtPath(partialURL.path), start);
            }
            break;
        }
        case VGCAFExtractOutcomeCancelled:
            resolution = VGSourceResolutionCancelled;
            VGLogSourceResolution(trackId, sourcePath, identity, NO, @"cancelled",
                                  -1, start);
            break;
        case VGCAFExtractOutcomeNoAudioTrack:
            [cache recordNegativeForClaim:claim reason:@"noAudioTrack"];
            resolution = VGSourceResolutionDropped;
            VGLogSourceResolution(trackId, sourcePath, identity, NO, @"noAudioTrack",
                                  -1, start);
            break;
        case VGCAFExtractOutcomeFailed:
            [cache recordNegativeForClaim:claim reason:@"extractionFailed"];
            resolution = VGSourceResolutionDropped;
            VGLogSourceResolution(trackId, sourcePath, identity, NO,
                                  @"extractionFailed", -1, start);
            break;
    }

    if (!keepPartialAsResolverOwned) {
        // Published (rename already moved it) or aborted (delete the partial).
        if (outcome != VGCAFExtractOutcomeSuccess) {
            [[NSFileManager defaultManager] removeItemAtURL:partialURL error:nil];
        }
        [_ownedPartialPaths removeObject:partialURL.path];
    }

    // Release AFTER publish/negative so waiters see the outcome on re-lookup.
    [cache releaseClaim:claim];
    return resolution;
}

/// Fallback path (cache unavailable, uncacheable identity, publish failure
/// upstream, or in-flight wait timeout): extract into the resolver-owned
/// temporary directory exactly as the pre-cache implementation did. Nothing
/// here is published to the shared cache.
- (VGSourceResolution)_extractUncachedFromURL:(NSURL *)sourceURL
                                   sourcePath:(NSString *)sourcePath
                                      trackId:(NSString *)trackId
                                     identity:(nullable VGCAFSourceIdentity *)identity
                                 rewrittenURL:(NSString *__strong _Nullable *_Nonnull)outURL
                                        start:(CFAbsoluteTime)start {
    NSURL *cafURL = [self _tempCafURLForTrackId:trackId];
    if (!cafURL) {
        VGLogSourceResolution(trackId, sourcePath, identity, NO, @"noTempDir",
                              -1, start);
        return VGSourceResolutionDropped;
    }

    VGCAFExtractOutcome outcome = [self _extractAudioFromURL:sourceURL
                                                    toCAFURL:cafURL
                                                     trackId:trackId];
    switch (outcome) {
        case VGCAFExtractOutcomeSuccess:
            *outURL = cafURL.path;
            VGLogSourceResolution(trackId, sourcePath, identity, NO,
                                  @"extractedUncached",
                                  VGFileSizeAtPath(cafURL.path), start);
            return VGSourceResolutionRewritten;
        case VGCAFExtractOutcomeCancelled:
            VGLogSourceResolution(trackId, sourcePath, identity, NO, @"cancelled",
                                  -1, start);
            return VGSourceResolutionCancelled;
        case VGCAFExtractOutcomeNoAudioTrack:
            VGLogSourceResolution(trackId, sourcePath, identity, NO, @"noAudioTrack",
                                  -1, start);
            return VGSourceResolutionDropped;
        case VGCAFExtractOutcomeFailed:
            VGLogSourceResolution(trackId, sourcePath, identity, NO,
                                  @"extractionFailed", -1, start);
            return VGSourceResolutionDropped;
    }
    return VGSourceResolutionDropped;
}

// ─── Private: extraction ──────────────────────────────────────────────────────

/// Extracts the first audio track of |sourceURL| — the FULL source duration,
/// never range-bounded — to a float32 interleaved PCM CAF file at |cafURL|.
/// Runs on _resolverQueue. Checks _cancelled per sample buffer. On any
/// non-success outcome the (partial) output file is removed.
- (VGCAFExtractOutcome)_extractAudioFromURL:(NSURL *)sourceURL
                                   toCAFURL:(NSURL *)cafURL
                                    trackId:(NSString *)trackId {
    CFAbsoluteTime extractStart = CFAbsoluteTimeGetCurrent();
    AVURLAsset *asset = [AVURLAsset assetWithURL:sourceURL];

    // Find first audio track.
    NSArray<AVAssetTrack *> *audioTracks =
        [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — no audio track in container %@",
              trackId, sourceURL.lastPathComponent);
        return VGCAFExtractOutcomeNoAudioTrack;
    }
    AVAssetTrack *audioTrack = audioTracks.firstObject;

    // ── Step 1: Read source audio format ─────────────────────────────────────
    //
    // We need the source sample rate and channel count to build ASBDs.
    // Obtain from the track's first format description.

    Float64 sourceSampleRate = 44100.0; // safe default; overridden below
    UInt32 sourceChannels    = 1;

    NSArray *fmtDescs = audioTrack.formatDescriptions;
    if (fmtDescs.count > 0) {
        CMFormatDescriptionRef fmtDesc =
            (__bridge CMFormatDescriptionRef)fmtDescs.firstObject;
        const AudioStreamBasicDescription *srcASBD =
            CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc);
        if (srcASBD) {
            if (srcASBD->mSampleRate > 0) sourceSampleRate = srcASBD->mSampleRate;
            if (srcASBD->mChannelsPerFrame > 0) sourceChannels = srcASBD->mChannelsPerFrame;
        }
    }

    // ── Step 2: Create AVAssetReader with PCM output ──────────────────────────
    //
    // Request float32 interleaved PCM from the reader. We use interleaved
    // here to keep the reader output simple; ExtAudioFile handles the
    // client-format conversion from interleaved to non-interleaved when
    // kExtAudioFileProperty_ClientDataFormat is set.

    NSDictionary *readerSettings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey:      @32,
        AVLinearPCMIsFloatKey:       @YES,
        AVLinearPCMIsBigEndianKey:   @NO,
        AVLinearPCMIsNonInterleaved: @NO,   // interleaved from reader
    };

    NSError *readerErr = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerErr];
    if (!reader) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — AVAssetReader init failed: %@",
              trackId, readerErr.localizedDescription);
        return VGCAFExtractOutcomeFailed;
    }

    AVAssetReaderTrackOutput *trackOutput =
        [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:audioTrack
                            outputSettings:readerSettings];
    trackOutput.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:trackOutput]) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — cannot add reader output",
              trackId);
        return VGCAFExtractOutcomeFailed;
    }
    [reader addOutput:trackOutput];

    // ── Step 3: Create ExtAudioFile with file ASBD ────────────────────────────
    //
    // File ASBD: CAF container, float32 interleaved PCM.
    // This is what gets written to disk.

    AudioStreamBasicDescription fileASBD = {
        .mSampleRate       = sourceSampleRate,
        .mFormatID         = kAudioFormatLinearPCM,
        .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket   = 4 * sourceChannels,
        .mFramesPerPacket  = 1,
        .mBytesPerFrame    = 4 * sourceChannels,
        .mChannelsPerFrame = sourceChannels,
        .mBitsPerChannel   = 32,
    };

    // Remove pre-existing file (ExtAudioFileCreateWithURL with
    // kAudioFileFlags_EraseFile requires the file to not exist or will
    // overwrite; the erase flag handles it on most paths, but explicit
    // removal guards against stale partial files from a prior run).
    [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];

    ExtAudioFileRef cafFile = NULL;
    OSStatus osErr = ExtAudioFileCreateWithURL(
        (__bridge CFURLRef)cafURL,
        kAudioFileCAFType,
        &fileASBD,
        NULL,                        // channel layout: let CoreAudio infer
        kAudioFileFlags_EraseFile,
        &cafFile);
    if (osErr != noErr) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — ExtAudioFileCreateWithURL "
              @"failed: %d", trackId, (int)osErr);
        return VGCAFExtractOutcomeFailed;
    }

    // ── Step 4: Set client data format (interleaved float32) ────────────────
    //
    // The client ASBD defines the format in which we hand data to
    // ExtAudioFileWrite. Both reader output and client format are interleaved
    // float32 PCM; no conversion is needed. The property is set explicitly
    // as required by the ExtAudioFile contract.

    AudioStreamBasicDescription clientASBD = {
        .mSampleRate       = sourceSampleRate,
        .mFormatID         = kAudioFormatLinearPCM,
        .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket   = 4 * sourceChannels,
        .mFramesPerPacket  = 1,
        .mBytesPerFrame    = 4 * sourceChannels,
        .mChannelsPerFrame = sourceChannels,
        .mBitsPerChannel   = 32,
    };

    osErr = ExtAudioFileSetProperty(
        cafFile,
        kExtAudioFileProperty_ClientDataFormat,
        sizeof(clientASBD),
        &clientASBD);
    if (osErr != noErr) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — "
              @"kExtAudioFileProperty_ClientDataFormat failed: %d",
              trackId, (int)osErr);
        ExtAudioFileDispose(cafFile);
        [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];
        return VGCAFExtractOutcomeFailed;
    }

    // ── Step 5: Start reader and pump samples ─────────────────────────────────

    if (![reader startReading]) {
        NSLog(@"[VGAudioPreviewFileResolver] track %@ — AVAssetReader startReading "
              @"failed: %@", trackId, reader.error.localizedDescription);
        ExtAudioFileDispose(cafFile);
        [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];
        return VGCAFExtractOutcomeFailed;
    }

    BOOL success = YES;
    long long framesWritten = 0;

    while (YES) {
        // Per-buffer cancellation check.
        if (atomic_load(&_cancelled)) {
            NSLog(@"[VGAudioPreviewFileResolver] track %@ — cancelled during extraction "
                  @"framesWritten=%lld elapsedMs=%d",
                  trackId, framesWritten, VGElapsedMs(extractStart));
            [reader cancelReading];
            ExtAudioFileDispose(cafFile);
            // Remove partial output.
            [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];
            return VGCAFExtractOutcomeCancelled;
        }

        CMSampleBufferRef sampleBuffer = [trackOutput copyNextSampleBuffer];
        if (!sampleBuffer) {
            // copyNextSampleBuffer returns nil at EOF or on error.
            // Only AVAssetReaderStatusCompleted is a success.
            if (reader.status != AVAssetReaderStatusCompleted) {
                NSLog(@"[VGAudioPreviewFileResolver] track %@ — reader ended with "
                      @"non-completed status %ld: %@",
                      trackId, (long)reader.status,
                      reader.error.localizedDescription);
                success = NO;
            }
            break;
        }

        // Extract AudioBufferList from sample buffer.
        CMBlockBufferRef blockBuffer = NULL;
        AudioBufferList abl;
        CMItemCount frameCount = CMSampleBufferGetNumSamples(sampleBuffer);
        OSStatus ablErr = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            NULL,           // bufferListSizeNeededOut
            &abl,
            sizeof(abl),
            NULL,           // blockBufferAllocator
            NULL,           // blockBufferMemoryAllocator
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &blockBuffer);

        if (ablErr != noErr) {
            NSLog(@"[VGAudioPreviewFileResolver] track %@ — "
                  @"CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer "
                  @"failed: %d", trackId, (int)ablErr);
            CFRelease(sampleBuffer);
            success = NO;
            break;
        }

        // Write frames to CAF.
        osErr = ExtAudioFileWrite(cafFile, (UInt32)frameCount, &abl);
        if (osErr != noErr) {
            NSLog(@"[VGAudioPreviewFileResolver] track %@ — ExtAudioFileWrite "
                  @"failed: %d", trackId, (int)osErr);
            if (blockBuffer) CFRelease(blockBuffer);
            CFRelease(sampleBuffer);
            success = NO;
            break;
        }
        framesWritten += (long long)frameCount;

        if (blockBuffer) CFRelease(blockBuffer);
        CFRelease(sampleBuffer);
    }

    // ── Step 6: Finalise or clean up ─────────────────────────────────────────

    ExtAudioFileDispose(cafFile);   // Flushes and closes. Always called.

    if (!success) {
        [[NSFileManager defaultManager] removeItemAtURL:cafURL error:nil];
        return VGCAFExtractOutcomeFailed;
    }

    NSLog(@"[VGAudioPreviewFileResolver][TIMING] extraction complete track=%@ "
          @"source=%@ framesWritten=%lld sampleRate=%.0f channels=%u elapsedMs=%d",
          trackId, sourceURL.lastPathComponent, framesWritten, sourceSampleRate,
          (unsigned int)sourceChannels, VGElapsedMs(extractStart));
    return VGCAFExtractOutcomeSuccess;
}

// ─── Private: resolver-owned temporary files ─────────────────────────────────

/// Lazily creates the resolver-owned temporary directory used only by the
/// uncached fallback path. Returns NO if it cannot be created.
- (BOOL)_ensureTempDirectory {
    if (_tempDirURL) return YES;
    NSURL *tmpBase = [NSURL fileURLWithPath:NSTemporaryDirectory()
                                isDirectory:YES];
    NSString *uuid = [NSUUID UUID].UUIDString;
    NSURL *dir = [tmpBase URLByAppendingPathComponent:
                      [NSString stringWithFormat:@"vg_apr_%@", uuid]
                                         isDirectory:YES];
    NSError *mkdirErr = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&mkdirErr]) {
        NSLog(@"[VGAudioPreviewFileResolver] failed to create temp dir: %@",
              mkdirErr.localizedDescription);
        return NO;
    }
    _tempDirURL = dir;
    return YES;
}

- (nullable NSURL *)_tempCafURLForTrackId:(NSString *)trackId {
    if (![self _ensureTempDirectory]) return nil;
    // Sanitise trackId for use in a filename: replace non-alphanumeric chars.
    NSString *safe = [[trackId componentsSeparatedByCharactersInSet:
                          [NSCharacterSet alphanumericCharacterSet].invertedSet]
                         componentsJoinedByString:@"_"];
    NSString *filename = [NSString stringWithFormat:@"%@.caf", safe];
    return [(NSURL *)_tempDirURL URLByAppendingPathComponent:filename];
}

/// Deletes any in-progress partial files this resolver still owns inside
/// the shared cache directory. Completed (published) entries were removed
/// from the set at publish time and are never touched.
- (void)_removeOwnedPartialFiles {
    NSSet<NSString *> *partials = [_ownedPartialPaths copy];
    [_ownedPartialPaths removeAllObjects];
    for (NSString *path in partials) {
        NSError *err = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:path error:&err] &&
            !([err.domain isEqualToString:NSCocoaErrorDomain] &&
              err.code == NSFileNoSuchFileError)) {
            NSLog(@"[VGAudioPreviewFileResolver] partial removal error %@: %@",
                  path.lastPathComponent, err.localizedDescription);
        }
    }
}

- (void)_removeTempDirectoryIfNeeded {
    NSURL *dir = _tempDirURL;
    if (!dir) return;
    _tempDirURL = nil;
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtURL:dir error:&err];
    if (err) {
        NSLog(@"[VGAudioPreviewFileResolver] temp dir removal error: %@",
              err.localizedDescription);
    }
}

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
