// VGDualCameraCompositorNode.h
// vanguard_media_engine — Phase 7.x-B / Phase 7.x-F / Phase 7.x-G
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 7.x-B / 7.x-F / 7.x-G — DUAL-CAMERA EDITOR CONSUMPTION
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGDualCameraCompositorNode is the native skeleton for dual-camera timeline
// composition in the UMF editor pipeline.  It consumes two existing
// VGClipDescriptors (primary + secondary) produced by the Dart descriptor
// foundation from Phase 7.x-A (VGDualCameraDescriptor.toMap()).
//
// ── SCOPE (Phase 7.x-B) ─────────────────────────────────────────────────────
//
//   IN SCOPE (7.x-B):
//     • Objective-C class skeleton conforming to <VGSourceNode>.
//     • Designated initializer that parses and validates the primary clip,
//       secondary clip, layoutMode, and pipLayout from the parameters dict.
//     • Readonly property exposure of parsed clip descriptors and layout config.
//     • Idempotent invalidate / no-op startProducing / stopProducing.
//     • VGNode protocol stubs (prepareWithContext:completion:,
//       negotiateFormatForPort:inputFormats:, declaredPorts).
//
//   ADDED (Phase 7.x-F):
//     • Lazy AVAssetReader + AVAssetReaderVideoCompositionOutput for primaryClip.
//     • pullFrame: now decodes and returns primary clip BGRA frames.
//     • seekTo:generation: cancels the reader and rebuilds on next pull.
//     • Phase 7.9-identical preferredTransform orientation normalization.
//     • primaryRenderSize: display-correct output dimensions (preferredTransform applied).
//     • Secondary clip remains parsed/stored but unused (no PiP yet).
//
//   ADDED (Phase 7.x-G):
//     • Secondary clip AVAssetReader lifecycle mirroring the primary reader.
//     • Secondary requested-PTS/sample-window pacing (RR-146 equivalent).
//     • Combined seek/invalidate/dispose clearing both readers atomically.
//     • Secondary EOS: if secondary exhausts before primary, primary continues.
//       Primary EOS still dictates overall DEV texture EOS.
//     • secondaryRenderSize DEV diagnostic property.
//     • Rendered output remains primary-only pass-through (no PiP/CoreImage).
//
//   OUT OF SCOPE (DEFERRED TO 7.x-H AND LATER):
//     • PiP geometry computation or CoreImage compositing.
//     • Export parity with VanguardDualCameraFlattener.
//     • Live camera capture or AVCaptureMultiCamSession usage.
//     • Still/freeze/reverse primary clip support.
//     • Canvas aspect-fit normalization.
//
// ── DO NOT MODIFY ────────────────────────────────────────────────────────────
//
//   VanguardMediaEnginePlugin.swift     VGTimelineCompositorNode.h/.m
//   VGEditorGraphFactory.*              VanguardDualCameraCompositor.swift
//   VanguardCompositor.metal            camera/session/capture files
//   connectsapp_*/**                    UMF docs
//
// ── IMPORTS ──────────────────────────────────────────────────────────────────
//
//   <UMF/VGSourceNode.h>  — pull-mode VGNode + VGSourceNode protocol.
//   <UMF/VGClipDescriptor.h> — existing clip descriptor model.
//   No AVFoundation. No CoreMedia. No Flutter. No camera.
//
// Phase 7.x-B skeleton only. Not integrated into the live runtime.

#pragma once

#import <Foundation/Foundation.h>
#import <UMF/VGSourceNode.h>
#import <UMF/VGClipDescriptor.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGDualCameraLayoutMode ───────────────────────────────────────────────────
/// The spatial layout mode for dual-camera composition.
///
/// Wire value mirrors the Dart `VGDualCameraLayoutMode` enum.
/// Only `VGDualCameraLayoutModePiP` is supported in Phase 7.x-B.
typedef NS_ENUM(NSInteger, VGDualCameraLayoutMode) {
    /// Picture-in-Picture: secondary clip is rendered as a smaller inset over the primary.
    VGDualCameraLayoutModePiP = 0,
    /// Split-Screen: primary on top half, secondary on bottom half (portrait split).
    /// Phase 7.x-K.
    VGDualCameraLayoutModeSplitScreen = 1,
};

// ─── VGPiPAnchor ─────────────────────────────────────────────────────────────
/// The corner anchor for the PiP inset.
///
/// Wire values mirror the Dart `VGPiPAnchor` enum.
typedef NS_ENUM(NSInteger, VGPiPAnchor) {
    VGPiPAnchorTopLeft     = 0,
    VGPiPAnchorTopRight    = 1,
    VGPiPAnchorBottomLeft  = 2,
    VGPiPAnchorBottomRight = 3,  ///< Default.
};

// ─── VGPiPLayoutConfig ───────────────────────────────────────────────────────
/// Parsed PiP layout configuration. Mirrors Dart VGPiPLayoutDescriptor fields.
/// Stored by VGDualCameraCompositorNode for use by Phase 7.x-C compositor.
typedef struct {
    VGPiPAnchor anchor;         ///< Corner anchor for PiP inset.
    double      widthFraction;  ///< PiP width as fraction of primary canvas (0.05–0.75).
    double      marginFraction; ///< Margin from edge as fraction of primary canvas (>= 0.0).
    double      cornerRadius;   ///< Corner radius in points (>= 0.0).
    double      opacity;        ///< PiP opacity (0.0–1.0).
} VGPiPLayoutConfig;

// ─── VGSplitScreenLayoutConfig ───────────────────────────────────────────────
/// Parsed split-screen layout configuration. Phase 7.x-K.
/// splitRatio: fraction of canvas height for primary (top). Range 0.2–0.8.
typedef struct {
    double splitRatio; ///< Primary (top) height fraction. Default 0.5.
} VGSplitScreenLayoutConfig;

// ─── Error domain ────────────────────────────────────────────────────────────
/// NSError domain for VGDualCameraCompositorNode initialization failures.
FOUNDATION_EXPORT NSString * const VGDualCameraCompositorNodeErrorDomain;

// ─── VGDualCameraCompositorNodeErrorCode ─────────────────────────────────────
/// Stable error codes for VGDualCameraCompositorNode initialization failures.
typedef NS_ENUM(NSInteger, VGDualCameraCompositorNodeErrorCode) {

    /// The `parameters` dictionary is missing the `primaryClip` key or
    /// the value is not a valid VGClipDescriptor dictionary.
    VGDualCameraCompositorNodeErrorMissingPrimaryClip    = 2000,

    /// The `parameters` dictionary is missing the `secondaryClip` key or
    /// the value is not a valid VGClipDescriptor dictionary.
    VGDualCameraCompositorNodeErrorMissingSecondaryClip  = 2001,

    /// The primary clip descriptor failed -isValid or -fromDictionary: returned nil.
    VGDualCameraCompositorNodeErrorInvalidPrimaryClip    = 2002,

    /// The secondary clip descriptor failed -isValid or -fromDictionary: returned nil.
    VGDualCameraCompositorNodeErrorInvalidSecondaryClip  = 2003,

    /// Primary and secondary clips share the same clipId.
    VGDualCameraCompositorNodeErrorDuplicateClipId       = 2004,

    /// The `layoutMode` value is not a recognized or supported mode.
    /// Phase 7.x-K now supports both "pip" and "splitScreen".
    VGDualCameraCompositorNodeErrorUnsupportedLayoutMode = 2005,
};

// ─── VGDualCameraCompositorNode ───────────────────────────────────────────────
/// Phase 7.x-B / 7.x-F / 7.x-G dual-camera compositor node.
///
/// Conforms to <VGSourceNode> for pull-mode integration with the generic
/// VanguardGraphRuntime source node interface (Phase 7.x-D).
///
/// Phase 7.x-F: `pullFrame:` lazily initializes an AVAssetReader for
/// `primaryClip` and returns decoded BGRA frames. Orientation normalization
/// uses `AVAssetReaderVideoCompositionOutput` with an `AVMutableVideoComposition`
/// (Phase 7.9-identical convention). Secondary clip is stored but not rendered.
///
/// Phase 7.x-G: `pullFrame:` now also drives a secondary `AVAssetReader`
/// for `secondaryClip`, applying identical requested-PTS/sample-window pacing
/// (RR-146 equivalent). The secondary buffer is decoded and tracked internally;
/// the rendered output remains primary-only pass-through. Secondary EOS does
/// not terminate the stream; primary EOS still governs. Both readers are torn
/// down together on seek, invalidate, and dispose.
/// No PiP, no CoreImage compositing, no export in this phase.
///
/// Initialized from a `parameters` dictionary that mirrors the Dart
/// `VGDualCameraDescriptor.toMap()` serialization:
///   parameters[@"primaryClip"]   — NSDictionary (VGClipDescriptor wire format)
///   parameters[@"secondaryClip"] — NSDictionary (VGClipDescriptor wire format)
///   parameters[@"layoutMode"]    — NSString ("pip")
///   parameters[@"pipLayout"]     — NSDictionary (optional PiP geometry)
///
/// Phase 7.x-F supported primary clip shapes: VGClipMediaKindVideo,
/// freezePTS == nil, isReversed == NO, valid sourceURL.
/// All other shapes return skippedWithGeneration: with a DEV log warning.
/// Does NOT touch any camera/session code or AVCaptureMultiCamSession.
@interface VGDualCameraCompositorNode : NSObject <VGSourceNode>

// ─── Parsed descriptor properties ────────────────────────────────────────────

/// The primary (background / full-screen) clip descriptor.
///
/// Validated on init: non-nil and passes -isValid.
/// Stored for inspection, logging, and eventual 7.x-C compositor wiring.
@property (nonatomic, strong, readonly) VGClipDescriptor *primaryClip;

/// The secondary (PiP / overlay) clip descriptor.
///
/// Validated on init: non-nil, passes -isValid, and clipId != primaryClip.clipId.
/// Stored for inspection, logging, and eventual 7.x-C compositor wiring.
@property (nonatomic, strong, readonly) VGClipDescriptor *secondaryClip;

/// The spatial layout mode for dual-camera composition.
///
/// Phase 7.x-B: only VGDualCameraLayoutModePiP is accepted.
/// Other values cause initialization to return nil with
/// VGDualCameraCompositorNodeErrorUnsupportedLayoutMode.
@property (nonatomic, readonly) VGDualCameraLayoutMode layoutMode;

/// PiP layout geometry configuration, parsed from parameters[@"pipLayout"].
///
/// Defaults to { anchor=BottomRight, widthFraction=0.35, marginFraction=0.018,
/// cornerRadius=24.0, opacity=1.0 } when the key is absent or invalid.
/// Stored for consumption by the Phase 7.x-C compositor.
@property (nonatomic, readonly) VGPiPLayoutConfig pipLayout;

/// Phase 7.x-K: Split-screen layout configuration, parsed from parameters[@"splitLayout"].
///
/// Defaults to { splitRatio=0.5 } when the key is absent or invalid.
@property (nonatomic, readonly) VGSplitScreenLayoutConfig splitLayout;

/// Phase 7.x-F: Display-correct output dimensions of the primary clip.
///
/// Computed synchronously during `initWithNodeId:parameters:ports:error:` by
/// probing `videoTrack.naturalSize` + `preferredTransform` on the primary asset.
/// This is pure metadata access (no decoding, < 1 ms for local assets) and is
/// guaranteed to be accurate before `dev_createDualCameraTexture` returns its
/// MethodChannel result to Dart.
///
/// The value reflects the display-correct pixel dimensions after transform.
/// For a portrait .mov recorded at 1080x1920 sensor, this returns {1080, 1920}.
/// For a landscape clip it returns landscape dimensions.
///
/// Returns `{1280, 720}` (DEV fallback) only if `sourceURL` is empty or the
/// asset has no video track.
///
/// Not related to `VanguardGraphRuntime.renderSize` (which is the V1 push-mode
/// output size). This property is DEV-only and read by the plugin route only.
@property (nonatomic, readonly) CGSize primaryRenderSize;

/// Phase 7.x-G: Display-correct output dimensions of the secondary clip.
///
/// Probed synchronously during `initWithNodeId:parameters:ports:error:` using
/// the same `naturalSize` + `preferredTransform` logic as `primaryRenderSize`.
/// Returns `{1280, 720}` (DEV fallback) if `secondaryClip.sourceURL` is empty
/// or the secondary asset has no video track.
///
/// DEV-only. Not exposed to production runtime.
@property (nonatomic, readonly) CGSize secondaryRenderSize;

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize from a Dart-side VGDualCameraDescriptor.toMap() parameters dict.
///
/// @param nodeId      The nodeId for this node, matching the VGGraphNodeDescriptor.
/// @param parameters  Dictionary containing primaryClip, secondaryClip,
///                    layoutMode ("pip" or "splitScreen"), optional pipLayout,
///                    and optional splitLayout keys.
/// @param ports       Ports array from VGGraphNodeDescriptor (stored for
///                    declaredPorts; currently unused in 7.x-B skeleton).
/// @param outError    On failure, set to a VGDualCameraCompositorNodeErrorDomain
///                    NSError. On success, set to nil. May be NULL.
///
/// Returns nil if:
///   - primaryClip is missing or fails VGClipDescriptor +fromDictionary:.
///   - secondaryClip is missing or fails VGClipDescriptor +fromDictionary:.
///   - primaryClip or secondaryClip fails -isValid.
///   - primaryClip.clipId equals secondaryClip.clipId.
///   - layoutMode is not "pip" or "splitScreen".
- (nullable instancetype)initWithNodeId:(NSString *)nodeId
                             parameters:(NSDictionary<NSString *, id> *)parameters
                                  ports:(NSArray<id> *)ports
                                  error:(NSError * _Nullable * _Nullable)outError
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// ─── Phase 7.x-N: DEV telemetry ──────────────────────────────────────────────

/// Returns a snapshot of DEV-only frame telemetry counters.
///
/// All values are NSNumber. Integer counters are non-negative. Timing values are
/// NSNumber doubleValue (milliseconds, ≥0). Read atomically — safe from any thread.
///
/// Core pull counters:
///   @"pullFrameCallCount"          — total pullFrame: calls since last reset (incl. cache hits).
///   @"primaryPullCount"            — alias for pullFrameCallCount (backward compat).
///   @"primaryDecodeCount"          — total AVAssetReader decode (copyNextSampleBuffer) calls.
///   @"successfulFrameCount"        — frames delivered (not skipped/EOS).
///
/// Composition counters:
///   @"compositedFrameCount"        — total successful CoreImage composites (all modes).
///   @"pipCompositionCount"         — successful PiP composites.
///   @"splitScreenCompositionCount" — successful split-screen composites.
///   @"compositionFailureCount"     — composites attempted but _compositeWith* returned NULL.
///   @"fallbackToPrimaryCount"      — primary-only deliveries (secondary/composite unavailable).
///
/// Image / output buffer counters:
///   @"imageBufferBuildCount"       — successful _buildImageBufferForClip calls (primary + secondary).
///   @"outputBufferCreateCount"     — successful CVPixelBufferCreate calls in composite methods.
///
/// Buffer byte estimates (atomic, updated from pull queue):
///   @"primaryBufferEstBytes"       — bytesPerRow×height of current primary CVPixelBuffer.
///   @"secondaryBufferEstBytes"     — bytesPerRow×height of current secondary CVPixelBuffer.
///   @"estimatedRetainedBufferBytes"— sum of primary + secondary byte estimates.
///
/// Timing (NSNumber doubleValue, milliseconds; 0 = not yet measured):
///   @"firstFrameMs"                — monotonic timestamp (CACurrentMediaTime * 1e3) of first delivered frame.
///   @"lastPullFrameMs"             — duration of the most recent pullFrame: call that delivered a frame.
///   @"maxPullFrameMs"              — peak pullFrame: delivery duration since last reset.
///   @"averagePullFrameMs"          — mean pullFrame: delivery duration since last reset.
///   @"estimatedRetainedBufferMB"   — estimatedRetainedBufferBytes / (1024*1024) as double.
///
/// DEV-only. Not exposed to production runtime.
- (NSDictionary<NSString *, NSNumber *> *)devGetTelemetry;

/// Resets all DEV telemetry counters to zero.
///
/// Thread-safe: writes atomic counters without locking.
/// DEV-only.
- (void)devResetTelemetry;

@end

NS_ASSUME_NONNULL_END
