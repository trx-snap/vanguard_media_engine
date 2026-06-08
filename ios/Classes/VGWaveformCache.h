// VGWaveformCache.h
// vanguard_media_engine — Phase 8.17
//
// Local disk-backed cache for VGWaveformResult data produced by VGWaveformExtractor.
//
// Design:
//   - Stateless utility class. All methods are class-level (no instance required).
//   - Stores one file per cacheKey under iOS NSCachesDirectory/vanguard_waveforms/.
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
//   Save/load calls are synchronous I/O. The caller is responsible for
//   dispatching off the main thread if needed. These methods do not internally
//   dispatch; they execute on the calling thread.
//
// Eviction:
//   No eviction in this MVP. Old files persist until the OS evicts the Caches
//   directory under disk pressure or the user clears app data.
//
// Forbidden:
//   No waveform extraction, no AVAssetReader, no AVAudioEngine, no graph nodes.

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

/// Saves a VGWaveformResult to disk keyed by [cacheKey].
///
/// [cacheKey] must be non-empty (typically a file URL, track id, or hash).
/// [result] must contain at least one sample.
///
/// Returns YES on success, NO on failure (e.g. disk full, bad result).
/// [error] is populated on failure.
+ (BOOL)saveResult:(VGWaveformResult *)result
      forCacheKey:(NSString *)cacheKey
             error:(NSError * _Nullable * _Nullable)error;

/// Loads a previously saved VGWaveformResult from disk.
///
/// Returns the cached result on success, or nil on cache miss or any error.
/// Corrupt or mismatched cache files return nil without raising an exception.
+ (nullable VGWaveformResult *)loadResultForCacheKey:(NSString *)cacheKey;

@end

NS_ASSUME_NONNULL_END
