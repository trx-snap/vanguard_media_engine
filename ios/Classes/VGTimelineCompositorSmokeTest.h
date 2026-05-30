// VGTimelineCompositorSmokeTest.h
// vanguard_media_engine — Phase 7 Stage 7.5B
//
// Headless native smoke test runner for VGTimelineCompositorNode.
//
// ═══════════════════════════════════════════════════════════════════════════════
// DEBUG-ONLY FUNCTIONALITY
// ═══════════════════════════════════════════════════════════════════════════════
//
// The header is unconditional so Swift can always see the @interface.
// The implementation (.m) is guarded by #if DEBUG. In release builds, the
// +runWithClipAPath:clipBPath: method returns a static error result.
//
// This exists solely to prove the Stage 7.5A VGTimelineCompositorNode
// execution pipeline in the example app.
//
// What this test proves:
//   1. VGEditorGraphFactory builds a valid descriptor from clip paths.
//   2. VGGraphValidator accepts the self-sourcing compositor topology.
//   3. VGTimelineCompositorNode initializes from the descriptor.
//   4. prepareWithContext: establishes initial generation.
//   5. pullFrame: returns .delivered with valid CVPixelBufferRef payloads.
//   6. Clip sequencing: frame at clip B's range pulls from clip B.
//   7. EOS detection: pulling past timeline end returns .endOfStream.
//   8. seekTo:generation: + stale generation → .skipped.
//   9. seekTo:generation: + matching generation → .delivered.
//  10. invalidate cleans up all resources.
//
// What this test does NOT do:
//   - No Metal rendering, no GPU blending, no UI display.
//   - No audio decoding.
//   - No ConnectsApp integration.
//
// PLATFORM: AVFoundation (AVAssetWriter for synthetic test video generation).
//           iOS 14.0+ (matches VGTimelineCompositorNode requirement).

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase 7 Stage 7.5B: Headless execution proof for VGTimelineCompositorNode.
///
/// @note The actual test logic only runs in DEBUG builds. In release builds,
/// this returns a static error result.
@interface VGTimelineCompositorSmokeTest : NSObject

/// Run the headless execution proof for VGTimelineCompositorNode.
///
/// This method synchronously:
///   1. Generates two short synthetic test videos (if clipAPath/clipBPath are
///      nil or empty, it writes synthetic MP4 files to NSTemporaryDirectory).
///   2. Constructs VGClipDescriptor + VGEditorGraphFactory topology.
///   3. Validates via VGGraphValidator.
///   4. Instantiates VGTimelineCompositorNode.
///   5. Runs the headless pull/seek/EOS verification pipeline.
///   6. Returns structured results.
///
/// @param clipAPath Absolute path to the first video asset. Pass nil to use
///                  a generated synthetic video.
/// @param clipBPath Absolute path to the second video asset. Pass nil to use
///                  a generated synthetic video.
/// @return A dictionary containing:
///   - @"success": @YES/@NO  — overall pass/fail.
///   - @"steps": NSArray<NSDictionary *>  — step-by-step results.
///   - @"logs": NSArray<NSString *>  — human-readable log lines.
///   - @"error": NSString (optional)  — first error message if failed.
+ (NSDictionary<NSString *, id> *)runWithClipAPath:(nullable NSString *)clipAPath
                                         clipBPath:(nullable NSString *)clipBPath;

/// Phase 7 Stage 7.5C: Generate and return paths to persistent synthetic MP4 clips.
///
/// Creates two solid-color synthetic MP4 clips in NSTemporaryDirectory:
///   - @"clipAPath": red 5-second 320×240 video at vg_playback_clip_A.mp4
///   - @"clipBPath": blue 5-second 320×240 video at vg_playback_clip_B.mp4
///
/// Files are regenerated if they do not exist; otherwise the existing files are reused.
/// Unlike runWithClipAPath:clipBPath:, this method does NOT run the headless smoke test
/// and does NOT clean up the generated files — they persist for use by the playback proof.
///
/// In RELEASE builds: returns nil (the synthetic generation uses #if DEBUG AVAssetWriter code).
///
/// @return NSDictionary with @"clipAPath" and @"clipBPath" (both NSString) on success,
///         or nil if clip generation failed.
+ (nullable NSDictionary<NSString *, NSString *> *)generateSyntheticClipPaths;

/// Phase 7 Stage 7.5D: Generate and return paths to real moving-pattern H.264 MP4 clips.
///
/// Creates two 5-second H.264 MP4 clips in NSTemporaryDirectory, each containing
/// a moving white vertical stripe on a solid color background. The per-frame
/// motion guarantees genuine inter-frame encoding, proving that AVAssetReader
/// is decompressing real H.264 content in the timeline pull loop.
///
///   - @"clipAPath": red base + moving stripe, 640×360 at vg_playback_real_clip_A.mp4
///   - @"clipBPath": blue base + moving stripe, 640×360 at vg_playback_real_clip_B.mp4
///
/// These are distinct from the 7.5C solid-color synthetic clips. The generation
/// logic lives in _generateMovingPatternVideo, which is entirely separate from
/// _generateSyntheticVideo. The 7.5C path is untouched.
///
/// Files are cached (not regenerated if already present). Regenerate by deleting
/// the files from NSTemporaryDirectory.
///
/// In RELEASE builds: returns nil (generation uses #if DEBUG AVAssetWriter code).
///
/// @return NSDictionary with @"clipAPath" and @"clipBPath" (both NSString) on success,
///         or nil if clip generation failed.
+ (nullable NSDictionary<NSString *, NSString *> *)generateRealVideoClipPaths;

@end

NS_ASSUME_NONNULL_END
