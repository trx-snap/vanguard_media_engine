// VGAudioPreviewFileResolver.h
// Vanguard Media Engine — S-P2 MOV original-audio repair
//
// One-shot resolver: converts audiovisual-container URLs (MOV/MP4) in a
// VGAudioSidecarPlan to temporary CAF files that AVAudioFile can open.
// Pure audio sources pass through unchanged.
//
// Lifecycle:
//   - Each VanguardGraphRuntime audio-plan request creates one resolver.
//   - resolvePlan:completion: starts async extraction; completion fires
//     exactly once on the main queue.
//   - cancelAndCleanupWithCompletion: cancels in-flight extraction,
//     disposes ExtAudioFile, removes all temporary files, then fires
//     completion exactly once on the main queue.
//   - Never reuse or reset a cancelled resolver.
//
// Threading: all public API may be called from the main queue.
//   Extraction runs on a private serial queue owned by the resolver.
//
// Package-internal. Do not import from public headers.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGAudioSidecarPlan.h>

#if VG_USE_V2_GRAPH

NS_ASSUME_NONNULL_BEGIN

/// One-shot audiovisual-to-CAF URL resolver for VGAudioSidecarPlan.
///
/// Attach one instance per setAudioSidecarPlan: request via associated object.
/// Cancel and clean up before starting a replacement request.
@interface VGAudioPreviewFileResolver : NSObject

/// Designated initialiser. Creates the resolver's private serial queue and
/// temporary working directory. Does not start any work.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// Resolves all tracks in |plan| asynchronously.
///
/// Audiovisual sources (containing a video track) are decoded to float32
/// interleaved PCM and written to a temporary CAF file. Pure audio
/// sources pass through with their original URL unchanged. A track is
/// dropped (not silenced) only when its audiovisual source has no audio
/// track or when extraction fails after attempting recovery; the failure
/// is logged with the concrete AVFoundation/AudioToolbox error.
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
/// all temporary files (partial and completed), then fires |completion|
/// exactly once on the main queue.
///
/// Idempotent if called more than once; completion fires immediately if
/// already cleaned up. Safe to call from any thread.
- (void)cancelAndCleanupWithCompletion:(dispatch_block_t)completion;

@end

NS_ASSUME_NONNULL_END

#endif // VG_USE_V2_GRAPH
