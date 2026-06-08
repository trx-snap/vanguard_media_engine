// VGAudioExportMuxer.h
// vanguard_media_engine — Phase 8.14A Audio Sidecar Export Muxer MVP
//
// Post-pass sidecar audio muxer using AVMutableComposition + AVAssetExportSession.
//
// ═══════════════════════════════════════════════════════════════════════════════
// ARCHITECTURE: POST-PASS ONLY (Opus approval 2026-06-08)
// ═══════════════════════════════════════════════════════════════════════════════
//
// This muxer is invoked AFTER VGVideoEncoderSinkNode has produced a video-only
// MP4 at a temporary path. It reads that video + one sidecar audio track and
// produces the final muxed MP4 at the caller's requested output path.
//
// Approved by Opus:
//   - Do NOT modify VGVideoEncoderSinkNode, VGTimelineExportHelper (graph).
//   - Do NOT interleave audio into the inline AVAssetWriter lifecycle.
//   - Use AVAssetExportPresetPassthrough (no re-encode).
//   - Use timescale 600 for all CMTime construction.
//   - Clamp audio so final output duration == video duration.
//   - Delete existing output file before AVAssetExportSession starts.
//   - Delete temp video file on success; delete both on failure.
//
// Phase 8.14A MVP scope:
//   - Single sidecar audio track only.
//   - Supports: trackId, url (absolute device path), startTime, duration, volume.
//   - timeRemapAudioPolicy: "mute" → skip audio. Anything else → preserve/include.
//   - No ducking, no keyframed volume, no waveform, no Phase 15 work.
//   - Original clip audio is NOT included (deferred to Phase 8.15+).
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
/// first audio track from the supplied VGAudioSidecarPlan.
///
/// @param videoTempPath   Absolute path to the video-only MP4 produced by the
///                        export graph. This file is deleted on success.
/// @param audioSidecar    VGAudioSidecarPlan containing the audio track(s).
///                        Phase 8.14A: only the first track is used.
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
