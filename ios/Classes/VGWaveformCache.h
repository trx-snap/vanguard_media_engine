// VGWaveformCache.h
// vanguard_media_engine — Phase 8.17 / Slice Q
//
// Local disk-backed cache for VGWaveformResult data produced by VGWaveformExtractor.
//
// ## Instance API (Slice Q)
//
// VGWaveformCache is now an instance class supporting dependency injection.
//
//   [VGWaveformCache defaultCache]          — shared instance backed by
//                                              NSCachesDirectory/vanguard_waveforms/
//   -initWithRootDirectoryURL:              — injected root for test isolation.
//
// Instance methods own legacy and namespaced I/O. Legacy class methods delegate
// to the default instance so existing callers are unaffected.
//
// ## Legacy API (flat storage, class delegates to default instance)
//
// Design:
//   - Stores one file per cacheKey under <root>/
//   - cacheKey is SHA-256 hashed before use as a filename to prevent path traversal.
//   - Cache files use atomic writes (NSData writeToFile:options:error: with atomic flag).
//   - Simple binary format with a versioned header (see implementation notes).
//
// Cache file layout (little-endian):
//   [0..3]   uint32  schema version  (currently 1)
//   [4..11]  double  durationSeconds
//   [12..15] uint32  samplesPerSecond
//   [16..19] uint32  pointCount
//   [20..]   float   samples[pointCount]
//
// Thread safety:
//   All instance methods are synchronous I/O. The caller is responsible for
//   dispatching off the main thread if needed.
//
// Eviction:
//   No eviction in this MVP. Old files persist until the OS evicts the Caches
//   directory under disk pressure or the user clears app data.
//
// Forbidden:
//   No waveform extraction, no AVAssetReader, no AVAudioEngine, no graph nodes.
//
// ## Namespaced API (Slice Q)
//
// Adds project-scoped waveform cache storage with filesystem isolation.
//
// Storage topology (relative to root):
//   n_<SHA256(namespace)>/         ← project namespace directory
//     k_<SHA256(assetKey)>/        ← asset key directory
//       <samplesPerSecond>.vgwc    ← density file
//
// Raw namespace/key values are hashed only in ObjC. Swift and Dart never
// construct paths or hash values.
//
// Invalidation:
//   - invalidateAssetForNamespace:assetKey: removes k_<hash>/ directory.
//   - invalidateNamespace: removes n_<hash>/ directory.
//   - Both are idempotent (absent path = success).
//
// Symlink safety (no-follow via lstat, ObjC-owned):
//   - Resolved canonical path components are compared, not plain string prefixes.
//   - lstat is used on every component before write or delete.
//   - S_IFLNK or unexpected filesystem type rejects the operation with an error.
//   - Root, namespace and asset levels are created separately with validation after each.
//   - Before recursive invalidation, the expected shallow subtree is validated.
//     Unexpected siblings block that recursive invalidation.
//   - Missing invalidation target is success (idempotent).
//   - Accepted residual TOCTOU boundary: the app-private iOS sandbox.
//
// Load behavior:
//   - Missing or corrupt entry: nil with no NSError.
//   - Unsafe tree or unexpected I/O: nil with NSError.
//   - Cached samplesPerSecond must exactly equal the requested SPS.
//
// Save behavior:
//   - result.samplesPerSecond must exactly equal samplesPerSecond arg.
//   - Mismatch returns an error.

#pragma once

#import <Foundation/Foundation.h>
#import "VGWaveformExtractor.h"

NS_ASSUME_NONNULL_BEGIN

// ─── VGWaveformCache ──────────────────────────────────────────────────────────

/// Disk-backed waveform result cache.
///
/// All methods are synchronous and must be called from a background thread
/// to avoid blocking the main thread during I/O.
@interface VGWaveformCache : NSObject

// ── Lifecycle ─────────────────────────────────────────────────────────────────

/// Returns the default shared instance backed by
/// NSCachesDirectory/vanguard_waveforms/.
+ (instancetype)defaultCache;

/// Designated initializer. [rootDirectoryURL] is the cache root directory
/// (must be a file URL). Use [defaultCache] for production; use this
/// initializer to inject a temporary directory for test isolation.
- (instancetype)initWithRootDirectoryURL:(NSURL *)rootDirectoryURL NS_DESIGNATED_INITIALIZER;

/// Convenience initializer using the default NSCachesDirectory/vanguard_waveforms/ root.
- (instancetype)init;

// ── Instance legacy flat-storage API ──────────────────────────────────────────

/// Saves [result] to disk keyed by [cacheKey].
///
/// [cacheKey] must be non-empty. [result] must contain at least one sample.
/// Returns YES on success, NO on failure ([error] populated).
- (BOOL)saveResult:(VGWaveformResult *)result
       forCacheKey:(NSString *)cacheKey
             error:(NSError * _Nullable * _Nullable)error;

/// Loads a previously saved result. Returns nil on miss or any error.
- (nullable VGWaveformResult *)loadResultForCacheKey:(NSString *)cacheKey;

// ── Instance namespaced API (Slice Q) ─────────────────────────────────────────

/// Loads a namespaced waveform.
///
/// Returns nil + no error on cache miss (including SPS mismatch).
/// Returns nil + error on unexpected I/O failure or unsafe tree.
/// Cached samplesPerSecond must exactly equal [samplesPerSecond]; otherwise nil (miss).
- (nullable VGWaveformResult *)loadNamespacedResultForNamespace:(NSString *)ns
                                                       assetKey:(NSString *)assetKey
                                              samplesPerSecond:(NSInteger)samplesPerSecond
                                                         error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NOTHROW;

/// Saves a namespaced waveform.
///
/// [result.samplesPerSecond] must exactly equal [samplesPerSecond]; mismatch returns NO + error.
/// [ns] and [assetKey] must be non-empty. [samplesPerSecond] must be > 0.
/// Performs lstat no-follow validation with component-level resolved-path comparison.
/// Returns YES on success, NO on failure ([error] populated).
- (BOOL)saveNamespacedResult:(VGWaveformResult *)result
                   namespace:(NSString *)ns
                    assetKey:(NSString *)assetKey
            samplesPerSecond:(NSInteger)samplesPerSecond
                       error:(NSError * _Nullable * _Nullable)error;

/// Removes every cached density for one asset (k_<hash>/ directory).
///
/// Idempotent: absent directory is treated as success.
/// Validates the expected shallow subtree before recursive removal.
/// Unexpected siblings block this invalidation.
/// Returns YES on success, NO on failure ([error] populated).
- (BOOL)invalidateAssetForNamespace:(NSString *)ns
                           assetKey:(NSString *)assetKey
                              error:(NSError * _Nullable * _Nullable)error;

/// Removes the entire project namespace cache directory (n_<hash>/).
///
/// Idempotent: absent directory is treated as success.
/// Validates the expected shallow subtree before recursive removal.
/// Unexpected siblings block this invalidation.
/// Returns YES on success, NO on failure ([error] populated).
- (BOOL)invalidateNamespace:(NSString *)ns
                      error:(NSError * _Nullable * _Nullable)error;

// ── Legacy class-method shims (delegate to defaultCache) ──────────────────────

/// Delegates to [[VGWaveformCache defaultCache] saveResult:forCacheKey:error:].
+ (BOOL)saveResult:(VGWaveformResult *)result
       forCacheKey:(NSString *)cacheKey
             error:(NSError * _Nullable * _Nullable)error;

/// Delegates to [[VGWaveformCache defaultCache] loadResultForCacheKey:].
+ (nullable VGWaveformResult *)loadResultForCacheKey:(NSString *)cacheKey;

@end

NS_ASSUME_NONNULL_END
