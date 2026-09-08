// VGAudioPreviewFileResolver.h
// Vanguard Media Engine — S-P2 MOV original-audio repair / Phase 10F Slice 1
//
// One-shot resolver: converts audiovisual-container URLs (MOV/MP4) in a
// VGAudioSidecarPlan to CAF files that AVAudioFile can open.
// Pure audio sources pass through unchanged.
//
// Phase 10F Slice 1 — full-source preview CAF cache:
//   - Extraction always covers the FULL source audio (never range-bounded),
//     so the sidecar sourceTrimStart/duration semantics are unchanged. The
//     resolver rewrites only the track "url" field.
//   - Completed CAFs live in a shared, durable cache under
//     Library/Caches/com.vanguard.audiopreview/, keyed by normalized source
//     path + byte size + mtime + audio schema tag (never by trackId). They
//     are owned by the cache, survive resolver cleanup and dealloc, and are
//     reclaimed only by byte-budget LRU eviction (which never removes files
//     handed out for the plan being resolved).
//   - In-progress (partial) files are owned by the requesting resolver and
//     are deleted on cancel, failure, or cleanup. Publication is an atomic
//     rename, so a lookup never observes a half-written CAF.
//   - Tracks within one plan that reference the same source are resolved
//     once (in-plan dedupe) and rewritten to the same CAF path.
//   - Concurrent resolvers requesting the same source serialize behind one
//     extraction; failed / no-audio sources are negative-cached for a
//     bounded TTL to avoid immediate repeated expensive failures.
//
// Lifecycle:
//   - Each VanguardGraphRuntime audio-plan request creates one resolver.
//   - resolvePlan:completion: starts async resolution; completion fires
//     exactly once on the main queue.
//   - cancelAndCleanupWithCompletion: cancels in-flight extraction,
//     disposes ExtAudioFile, removes resolver-owned temporary and partial
//     files (never completed cache entries), then fires completion exactly
//     once on the main queue.
//   - Never reuse or reset a cancelled resolver.
//
// Threading: all public API may be called from the main queue.
//   Extraction runs on a private serial queue owned by the resolver. Cache
//   bookkeeping is serialized on a shared queue owned by the file-private
//   cache in the implementation file; the cache never calls back into
//   resolver queues.
//
// Package-internal. Do not import from public headers.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGAudioSidecarPlan.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

/// One-shot audiovisual-to-CAF URL resolver for VGAudioSidecarPlan, backed by
/// the shared full-source preview CAF cache.
///
/// Attach one instance per setAudioSidecarPlan: request via associated object.
/// Cancel and clean up before starting a replacement request.
@interface VGAudioPreviewFileResolver : NSObject

/// Designated initialiser. Creates the resolver's private serial queue. The
/// resolver-owned temporary directory (used only for uncached fallback
/// extraction) is created lazily. Does not start any work.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// Resolves all tracks in |plan| asynchronously.
///
/// Audiovisual sources (containing a video track) are served from the shared
/// CAF cache when a valid entry exists; otherwise their full audio is decoded
/// to float32 interleaved PCM, written to a CAF file, and published to the
/// cache. Pure audio sources pass through with their original URL unchanged.
/// A track is dropped (not silenced) only when its audiovisual source has no
/// audio track, when extraction fails, or when the source is inside its
/// bounded negative-cache window; the failure is logged with the concrete
/// AVFoundation/AudioToolbox error and timing.
///
/// On success: completion receives a new immutable VGAudioSidecarPlan with
///   only the "url" field changed per track; all other fields, keyframes,
///   waveformCache, and timeRemapAudioPolicy are preserved verbatim.
/// On cancel: completion receives nil.
/// On total failure (all tracks dropped): completion receives nil.
///
/// completion fires exactly once on the main queue.
/// Must not be called after cancelAndCleanupWithCompletion:.
- (void)resolvePlan:(nullable VGAudioSidecarPlan *)plan
         completion:(void (^)(VGAudioSidecarPlan *_Nullable resolvedPlan))completion;

/// Cancels any in-flight extraction, disposes ExtAudioFile handles, removes
/// resolver-owned temporary files (in-progress partial CAFs and any uncached
/// fallback CAFs), then fires |completion| exactly once on the main queue.
/// Completed CAFs published to the shared cache are never removed here.
///
/// Idempotent if called more than once; completion fires immediately if
/// already cleaned up. Safe to call from any thread.
- (void)cancelAndCleanupWithCompletion:(dispatch_block_t)completion;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
