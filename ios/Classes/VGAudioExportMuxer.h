// VGAudioExportMuxer.h
// vanguard_media_engine — Phase 8.14B Multi-Track Audio Mixdown
//
// 2-pass post-pass sidecar audio muxer using AVMutableComposition + AVAssetExportSession.
//
// ═══════════════════════════════════════════════════════════════════════════════
// ARCHITECTURE: 2-PASS POST-PASS (Opus approval 2026-06-08)
// ═══════════════════════════════════════════════════════════════════════════════
//
// PHASE 8.14A had a latent bug: it set audioMix on an AVAssetExportPresetPassthrough
// session. Apple ignores audioMix in passthrough mode — volume was silently dropped.
// Phase 8.14B fixes this with a 2-pass design.
//
// Pass 1 — Audio Mixdown:
//   Builds an audio-only AVMutableComposition from all active sidecar tracks.
//   Applies AVMutableAudioMix (per-track volume, fade ramps) during export.
//   Uses AVAssetExportPresetAppleM4A (compatible with AVMutableAudioMix).
//   Output: {finalOutputPath}.audio_mix_tmp.m4a
//
// Pass 2 — Final Passthrough:
//   Builds a composition of the video-only MP4 + mixed M4A from Pass 1.
//   Uses AVAssetExportPresetPassthrough (no re-encode of H.264 video).
//   Output: finalOutputPath
//
// Per-track features (Phase 8.14B):
//   - role: metadata-only ("music"|"voiceover"|"sfx"|"original"). No behavior branch.
//   - volume: 0.0–1.0. Applied via AVMutableAudioMixInputParameters.setVolume:atTime:
//   - fadeInSeconds: linear ramp 0 → volume at insertion point.
//   - fadeOutSeconds: linear ramp volume → 0 at track end.
//   - timeRemapAudioPolicy "mute": track is skipped entirely.
//
// Cleanup:
//   - All temp files (video, audio mix) deleted on success.
//   - All temp files + partial output deleted on any failure.
//   - Includes Pass 1 success + Pass 2 failure case.
//
// Approved by Opus:
//   - Do NOT modify VGVideoEncoderSinkNode, VGTimelineExportHelper (graph).
//   - Do NOT interleave audio into the inline AVAssetWriter lifecycle.
//   - Do NOT set audioMix on AVAssetExportPresetPassthrough (Apple ignores it).
//   - Use timescale 600 for all CMTime construction.
//   - Clamp audio so final output duration == video duration.
//   - Delete existing output file before AVAssetExportSession starts.
//   - Use one AVMutableCompositionTrack + one AVMutableAudioMixInputParameters per track.
//   - Fade ramps computed relative to track insertion point, not source file time.
//
// Forbidden imports:
//   VGVideoEncoderSinkNode, VGVideoExportSession, VGAudioOnlyExporter,
//   VGExportScheduler, VGGraphDescriptor, VGGraphValidator, VGGraphPlanner,
//   VanguardGraphRuntime, any MultiCam classes, Connects app code.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGAudioSidecarPlan.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGAudioExportMuxer ──────────────────────────────────────────────────────
/// Post-pass audio muxer: combines a video-only MP4 with a sidecar audio track.
///
/// This is a one-shot, use-once object. Instantiate, call muxWithCompletion:,
/// and discard. Do not reuse an instance.
///
/// Thread safety: startMuxWithCompletion: dispatches internally and is safe to
/// call from any thread. The completion block fires on a background queue.
@interface VGAudioExportMuxer : NSObject

/// Creates a muxer configured to combine a video-only temporary file with the
/// sidecar audio tracks from the supplied VGAudioSidecarPlan.
///
/// Phase 8.14B: supports multiple audio tracks with per-track volume, role,
/// and fade-in/fade-out. Uses a 2-pass export:
///   Pass 1: audio-only mixdown → {finalOutputPath}.audio_mix_tmp.m4a
///   Pass 2: video + mixed audio → finalOutputPath (passthrough, no re-encode).
///
/// @param videoTempPath   Absolute path to the video-only MP4 produced by the
///                        export graph. This file is deleted on success.
/// @param audioSidecar    VGAudioSidecarPlan containing the audio tracks.
///                        All tracks with timeRemapAudioPolicy="mute" are skipped.
/// @param finalOutputPath Absolute path where the muxed MP4 will be written.
///                        An existing file at this path is deleted before
///                        AVAssetExportSession starts.
- (instancetype)initWithVideoTempPath:(NSString *)videoTempPath
                         audioSidecar:(VGAudioSidecarPlan *)audioSidecar
                      finalOutputPath:(NSString *)finalOutputPath
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Starts the post-pass mux operation asynchronously.
///
/// Must be called at most once per instance. Additional calls are no-ops.
///
/// @param completion Invoked exactly once on a background queue.
///   - success=YES, durationSeconds=final duration, error=nil on success.
///   - success=NO, durationSeconds=0, error=describes failure on error.
///   - On any failure the temp video file is deleted (if it exists).
///   - On any failure a partially written output file is deleted (if it exists).
- (void)startMuxWithCompletion:(void (^)(BOOL success,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
