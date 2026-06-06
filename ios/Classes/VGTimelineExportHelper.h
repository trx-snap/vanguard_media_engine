// VGTimelineExportHelper.h
// vanguard_media_engine — Phase 7 Stage 7.5E / Phase 7.12
//
// Offline timeline export helper for the Phase 7 pipeline.
//
// ═══════════════════════════════════════════════════════════════════════════════
// ALL-CONFIGURATIONS FUNCTIONALITY (Phase 7.12, DEC-145)
// ═══════════════════════════════════════════════════════════════════════════════
//
// The header is unconditional so Swift can always see the @interface.
// Phase 7.12: the #if DEBUG guard on the .m implementation was removed.
// The real export pipeline now compiles in all configurations (debug, profile,
// release). Required for profile-mode device validation (flutter run --profile)
//
// Architecture:
//   - Creates a completely independent VGTimelineCompositorNode (does NOT reuse
//     the playback runtime or _timelineRuntime from the plugin).
//   - Wires compositor → VGVideoEncoderSinkNode via VGClockPolicyPull export graph.
//   - Drives the pull loop via VGExportScheduler on a private serial queue.
//   - VGExportProfile is constructed internally — not exposed to Swift.
//   - Follows the VGVideoExportSession failure-cleanup pattern for sink/scheduler
//     invalidation on all error paths.
//
// Forbidden:
//   - No VanguardGraphRuntime, VanguardMetalRenderer, VGGraphSchedulerV2.
//   - No Flutter textures, no CADisplayLink, no camera path.
//   - No ConnectsApp, no UMF contract changes.
//   - No audio tracks.
//
// Phase 7 Stage 7.5E: dev export proof only. No production API surface.
// PLATFORM: AVFoundation, VideoToolbox (via VGVideoEncoderSinkNode).
//
// ── Phase 8.6 Overlay Wiring ─────────────────────────────────────────────────
//
// Phase 8.6 adds a new 9-parameter method that accepts optional canvas and
// overlays dictionaries.
//
// When overlays is non-empty, VGOverlayNode is inserted between the compositor
// and sink, changing the export topology from:
//   VGTimelineCompositorNode → VGVideoEncoderSinkNode
// to:
//   VGTimelineCompositorNode → VGOverlayNode → VGVideoEncoderSinkNode
//
// When overlays is nil or empty, the existing 2-node topology is preserved
// exactly. No behavior change for the no-overlay case.
//
// The original 7-parameter method is kept for backward compatibility and
// forwards to the new method with canvas:nil overlays:nil.
//
// Phase 8.6: Pass-through only. No rendering. No Metal. No CoreImage.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGTimelineExportHelper ───────────────────────────────────────────────────
/// Dev-only offline timeline export helper.
///
/// Builds a pull-mode export graph from VGTimelineCompositorNode → VGVideoEncoderSinkNode,
/// runs the VGExportScheduler pump, and writes a video-only H.264 MP4.
///
/// All methods are class methods. This class must not be instantiated.
@interface VGTimelineExportHelper : NSObject

/// Perform offline pull-mode video-only timeline export.
///
/// Constructs an independent VGTimelineCompositorNode from the supplied clip
/// dictionaries, wires it to a VGVideoEncoderSinkNode targeting the output path,
/// and executes the full pull-mode export pipeline.
///
/// VGExportProfile is constructed internally from the supplied primitive parameters
/// (H.264 High AutoLevel, VGEncoderUsageOffline). Swift callers must NOT build
/// VGExportProfile — pass primitive values only.
///
/// @param clips        NSArray of clip descriptor dictionaries (same wire contract
///                     as dev_createTimelineTexture: id, sourcePath, mediaKind, etc.)
/// @param transitions  NSArray of transition descriptor dictionaries (may be empty).
///                     Passed directly to VGTimelineCompositorNode so that dissolve
///                     and fade transitions are executed during export (Phase 7.10).
/// @param outputPath   Absolute path for the output MP4 file.
///                     An existing file at this path will be deleted by the sink
///                     during preparation (AVAssetWriter cannot overwrite).
/// @param width        Video width in pixels (must be > 0).
/// @param height       Video height in pixels (must be > 0).
/// @param fps          Frame rate (must be > 0).
/// @param bitrateBps   Target bitrate in bits per second (must be > 0).
/// @param completion   Invoked exactly once on a background queue upon completion.
///                     On success: success=YES, outputPath=absolute path, durationSeconds≈10.0.
///                     On failure: success=NO, error describes the failure.
///
/// Forwards to exportTimelineWithClips:transitions:outputPath:width:height:fps:bitrateBps:
/// canvas:overlays:completion: with canvas:nil overlays:nil.
+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                    transitions:(NSArray<NSDictionary *> *)transitions
                     outputPath:(NSString *)outputPath
                          width:(NSInteger)width
                         height:(NSInteger)height
                            fps:(NSInteger)fps
                     bitrateBps:(NSInteger)bitrateBps
                     completion:(void (^)(BOOL success,
                                         NSString * _Nullable outputPath,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion;

/// Perform offline pull-mode video-only timeline export with optional overlay support.
///
/// Phase 8.6 variant. Accepts optional canvas and overlays dictionaries from the
/// Dart VGEditorDraft serialization.
///
/// When overlays is non-nil and non-empty:
///   Inserts VGOverlayNode between compositor and sink:
///   VGTimelineCompositorNode → VGOverlayNode → VGVideoEncoderSinkNode
///
/// When overlays is nil or empty:
///   Preserves existing 2-node topology:
///   VGTimelineCompositorNode → VGVideoEncoderSinkNode
///
/// @param clips        NSArray of clip descriptor dictionaries.
/// @param transitions  NSArray of transition descriptor dictionaries (may be empty).
/// @param outputPath   Absolute path for the output MP4 file.
/// @param width        Video width in pixels (must be > 0).
/// @param height       Video height in pixels (must be > 0).
/// @param fps          Frame rate (must be > 0).
/// @param bitrateBps   Target bitrate in bits per second (must be > 0).
/// @param canvas       Optional canvas descriptor dictionary (NSDictionary).
///                     Passed to VGOverlayNode as parameters[@"canvas"].
///                     If nil, VGOverlayNode uses its default canvas.
/// @param overlays     Optional array of overlay descriptor dictionaries.
///                     If nil or empty, no VGOverlayNode is inserted.
/// @param completion   Invoked exactly once on a background queue upon completion.
+ (void)exportTimelineWithClips:(NSArray<NSDictionary *> *)clips
                    transitions:(NSArray<NSDictionary *> *)transitions
                     outputPath:(NSString *)outputPath
                          width:(NSInteger)width
                         height:(NSInteger)height
                            fps:(NSInteger)fps
                     bitrateBps:(NSInteger)bitrateBps
                         canvas:(nullable NSDictionary *)canvas
                       overlays:(nullable NSArray<NSDictionary *> *)overlays
                     completion:(void (^)(BOOL success,
                                         NSString * _Nullable outputPath,
                                         NSTimeInterval durationSeconds,
                                         NSError * _Nullable error))completion;

/// init is unavailable. Use class methods only.
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
