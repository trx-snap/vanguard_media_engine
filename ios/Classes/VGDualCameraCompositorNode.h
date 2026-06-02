// VGDualCameraCompositorNode.h
// vanguard_media_engine — Phase 7.x-B
//
// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 7.x-B — DUAL-CAMERA EDITOR CONSUMPTION SKELETON
// ═══════════════════════════════════════════════════════════════════════════════
//
// VGDualCameraCompositorNode is the native skeleton for dual-camera timeline
// composition in the UMF editor pipeline.  It consumes two existing
// VGClipDescriptors (primary + secondary) produced by the Dart descriptor
// foundation from Phase 7.x-A (VGDualCameraDescriptor.toMap()).
//
// ── SCOPE (Phase 7.x-B) ─────────────────────────────────────────────────────
//
//   IN SCOPE:
//     • Objective-C class skeleton conforming to <VGSourceNode>.
//     • Designated initializer that parses and validates the primary clip,
//       secondary clip, layoutMode, and pipLayout from the parameters dict.
//     • Readonly property exposure of parsed clip descriptors and layout config.
//     • pullFrame: stub that returns VGFrameStatusSkipped unconditionally.
//     • Idempotent invalidate / no-op startProducing / stopProducing.
//     • VGNode protocol stubs (prepareWithContext:completion:,
//       negotiateFormatForPort:inputFormats:, declaredPorts).
//
//   OUT OF SCOPE (DEFERRED TO 7.x-C AND LATER):
//     • AVAssetReader instantiation or video decoding.
//     • PiP geometry computation or CoreImage compositing.
//     • MethodChannel routing in VanguardMediaEnginePlugin.
//     • Integration with VanguardGraphRuntime or VGExportScheduler.
//     • Export parity with VanguardDualCameraFlattener.
//     • Live camera capture or AVCaptureMultiCamSession usage.
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
    /// Phase 7.x-B only supports `VGDualCameraLayoutModePiP` ("pip").
    VGDualCameraCompositorNodeErrorUnsupportedLayoutMode = 2005,
};

// ─── VGDualCameraCompositorNode ───────────────────────────────────────────────
/// Phase 7.x-B native skeleton for dual-camera timeline consumption.
///
/// Conforms to <VGSourceNode> for structural compatibility with the UMF
/// graph topology. `pullFrame:` is a stub that returns VGFrameStatusSkipped
/// unconditionally; actual video decoding and PiP compositing are deferred
/// to Phase 7.x-C.
///
/// Initialized from a `parameters` dictionary that mirrors the Dart
/// `VGDualCameraDescriptor.toMap()` serialization:
///   parameters[@"primaryClip"]   — NSDictionary (VGClipDescriptor wire format)
///   parameters[@"secondaryClip"] — NSDictionary (VGClipDescriptor wire format)
///   parameters[@"layoutMode"]    — NSString ("pip")
///   parameters[@"pipLayout"]     — NSDictionary (optional PiP geometry)
///
/// Phase 7.x-B: does NOT allocate pixel buffers, does NOT open files,
/// does NOT instantiate AVAssetReader, does NOT touch any camera/session code.
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

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize from a Dart-side VGDualCameraDescriptor.toMap() parameters dict.
///
/// @param nodeId      The nodeId for this node, matching the VGGraphNodeDescriptor.
/// @param parameters  Dictionary containing primaryClip, secondaryClip,
///                    layoutMode, and optional pipLayout keys.
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
///   - layoutMode is not "pip".
- (nullable instancetype)initWithNodeId:(NSString *)nodeId
                             parameters:(NSDictionary<NSString *, id> *)parameters
                                  ports:(NSArray<id> *)ports
                                  error:(NSError * _Nullable * _Nullable)outError
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
