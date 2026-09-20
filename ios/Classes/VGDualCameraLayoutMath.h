// VGDualCameraLayoutMath.h
// vanguard_media_engine — MC-1A: Layout geometry extraction
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-1A — DUAL-CAMERA LAYOUT GEOMETRY HELPER
// ═══════════════════════════════════════════════════════════════════════════════
//
// Pure geometry / layout math for dual-camera PiP and split-screen composition.
//
// This header is intentionally free of:
//   - AVFoundation, CoreMedia, CoreVideo, CoreImage
//   - UMF protocol types (VGSourceNode, VGNode, VGClipDescriptor, …)
//   - Flutter / camera session types
//
// That keeps it importable by:
//   - VGDualCameraCompositorNode   (existing pull-mode playback compositor)
//   - Future VanguardMultiCamMediaSource  (live preview compositor, MC-4+)
//   - Any native diagnostic or test harness
//
// ── TYPES (moved here from VGDualCameraCompositorNode.h) ────────────────────
//
//   VGDualCameraLayoutMode    — pip / splitScreen selection
//   VGPiPAnchor               — four-corner anchor for the PiP inset
//   VGPiPLayoutConfig         — PiP geometry parameters (widthFraction, etc.)
//   VGSplitScreenLayoutConfig — split-screen geometry parameters (splitRatio)
//
// ── RESULT TYPES ─────────────────────────────────────────────────────────────
//
//   VGDCPiPGeometry           — output of VGDCLayoutComputePiPGeometry(…)
//   VGDCSplitRects            — output of VGDCLayoutComputeSplitRects(…)
//   VGDCAspectFillResult      — output of VGDCLayoutComputeAspectFill(…)
//
// ── FUNCTIONS ────────────────────────────────────────────────────────────────
//
//   VGDCLayoutComputePiPGeometry(…)  — PiP rect + clamped corner radius
//   VGDCLayoutComputeSplitRects(…)   — primary (top) and secondary (bottom) rects
//   VGDCLayoutComputeAspectFill(…)   — uniform scale + center offsets for fill-crop
//
// All three functions are pure C (no side effects, no allocations, no logging).
// They preserve the exact arithmetic that was proven in VGDualCameraCompositorNode.
//
// ── CONSTRAINTS ──────────────────────────────────────────────────────────────
//
//   DO NOT add AVFoundation / CoreImage / UMF imports to this header.
//   DO NOT add live-capture logic here.
//   DO NOT add session or mode management here.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ─── VGDualCameraLayoutMode ───────────────────────────────────────────────────
/// The spatial layout mode for dual-camera composition.
///
/// Wire value mirrors the Dart `VGDualCameraLayoutMode` enum.
/// Applies to both offline (playback / export) and live preview paths.
typedef NS_ENUM(NSInteger, VGDualCameraLayoutMode) {
    /// Picture-in-Picture: secondary is rendered as a smaller inset over the primary.
    VGDualCameraLayoutModePiP = 0,
    /// Split-Screen: primary on top half, secondary on bottom half (portrait split).
    VGDualCameraLayoutModeSplitScreen = 1,
};

// ─── VGPiPAnchor ─────────────────────────────────────────────────────────────
/// The corner anchor for the PiP inset.
///
/// Wire values mirror the Dart `VGPiPAnchor` enum.
typedef NS_ENUM(NSInteger, VGPiPAnchor) {
    VGPiPAnchorTopLeft       = 0,
    VGPiPAnchorTopRight      = 1,
    VGPiPAnchorBottomLeft    = 2,
    VGPiPAnchorBottomRight   = 3,  ///< Default.
    VGPiPAnchorFreeFloating  = 4,  ///< Position via centerX/centerY (Dart Y-down, normalized 0–1).
};

// ─── VGPiPLayoutConfig ───────────────────────────────────────────────────────
/// PiP layout geometry configuration. Mirrors Dart VGPiPLayoutDescriptor fields.
///
/// Defaults (matching Dart VGPiPLayoutDescriptor() defaults):
///   anchor         = VGPiPAnchorBottomRight
///   widthFraction  = 0.35
///   marginFraction = 0.018
///   cornerRadius   = 24.0
///   opacity        = 1.0
///   centerX        = 0.5
///   centerY        = 0.5
typedef struct {
    VGPiPAnchor anchor;         ///< Corner anchor for PiP inset.
    double      widthFraction;  ///< PiP width as fraction of primary canvas (0.05–0.75).
    double      marginFraction; ///< Margin from edge as fraction of primary canvas (>= 0.0).
    double      cornerRadius;   ///< Corner radius in points (>= 0.0).
    double      opacity;        ///< PiP opacity (0.0–1.0).
    double      centerX;        ///< Normalized PiP center X (0.0–1.0). Used only when anchor == freeFloating.
    double      centerY;        ///< Normalized PiP center Y (0.0–1.0, Dart Y-down). Used only when anchor == freeFloating.
} VGPiPLayoutConfig;

// ─── VGSplitScreenDirection ──────────────────────────────────────────────────
/// The directional mode for split-screen composition.
///
/// Wire values mirror the Dart `VGSplitScreenDirection` enum.
typedef NS_ENUM(NSInteger, VGSplitScreenDirection) {
    /// Top/Bottom: primary on top, secondary on bottom. splitRatio is active.
    VGSplitScreenDirectionTopBottom = 0,
    /// Left/Right: primary on left, secondary on right. Always 50/50 locked.
    VGSplitScreenDirectionLeftRight = 1,
};

// ─── VGSplitScreenLayoutConfig ───────────────────────────────────────────────
/// Parsed split-screen layout configuration.
///
/// splitRatio: fraction of canvas height for primary (top). Range 0.2–0.8.
/// Default: 0.5. Ignored when direction == leftRight (always 50/50).
/// direction: topBottom or leftRight. Default: topBottom.
typedef struct {
    double                  splitRatio; ///< Primary (top) height fraction. Default 0.5. Ignored for leftRight.
    VGSplitScreenDirection  direction;  ///< Split direction. Default: topBottom.
} VGSplitScreenLayoutConfig;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Result types
// ─────────────────────────────────────────────────────────────────────────────

// ─── VGDCPiPGeometry ─────────────────────────────────────────────────────────
/// Output of VGDCLayoutComputePiPGeometry(…).
///
/// All dimensions are in pixels in CoreImage Y-up coordinate space.
/// (Y = 0 at bottom-left of the primary canvas.)
///
/// The caller uses pipOriginX/Y + pipW/H to scale and translate the secondary
/// source image, and clampedCornerRadius to build the CIRoundedRectangleGenerator
/// mask. The clampedOpacity is the validated (0–1) opacity for CIColorMatrix.
typedef struct {
    double pipOriginX;          ///< X position of PiP inset (CIImage Y-up space).
    double pipOriginY;          ///< Y position of PiP inset (CIImage Y-up space).
    double pipW;                ///< Width of PiP inset in pixels.
    double pipH;                ///< Height of PiP inset in pixels.
    double clampedCornerRadius; ///< Corner radius clamped to [0, MIN(pipW,pipH)/2].
    double clampedOpacity;      ///< Opacity clamped to [0.0, 1.0].
} VGDCPiPGeometry;

// ─── VGDCSplitRects ──────────────────────────────────────────────────────────
/// Output of VGDCLayoutComputeSplitRects(…).
///
/// Both rects are in CoreImage Y-up coordinate space on a canvas of
/// {canvasW, canvasH} pixels.
///
///   topRect.origin.y    = bottomH  (primary occupies the upper band)
///   bottomRect.origin.y = 0        (secondary occupies the lower band)
///
/// If the split geometry is degenerate (either band < 1 pixel), isValid = NO
/// and both rects are CGRectZero.
typedef struct {
    CGRect topRect;    ///< Primary (top) band rect in CIImage Y-up space.
    CGRect bottomRect; ///< Secondary (bottom) band rect in CIImage Y-up space.
    BOOL   isValid;    ///< YES when both bands are at least 1 pixel tall.
} VGDCSplitRects;

// ─── VGDCSplitRectsLR ────────────────────────────────────────────────────────
/// Output of VGDCLayoutComputeSplitRectsLeftRight(…).
///
/// Both rects are in CoreImage Y-up coordinate space. Left/right split is
/// always 50/50 locked — splitRatio is ignored.
typedef struct {
    CGRect leftRect;   ///< Primary (left) band rect in CIImage Y-up space.
    CGRect rightRect;  ///< Secondary (right) band rect in CIImage Y-up space.
    BOOL   isValid;    ///< YES when both bands are at least 1 pixel wide.
} VGDCSplitRectsLR;

// ─── VGDCAspectFillResult ────────────────────────────────────────────────────
/// Output of VGDCLayoutComputeAspectFill(…).
///
/// Apply to source CIImage (after normalizing its origin to (0,0)):
///   1. Scale uniformly by `scale`.
///   2. Translate by (offsetX, offsetY).
///   3. Crop to targetRect.
///
/// The caller is responsible for origin normalization and the crop.
typedef struct {
    double scale;   ///< Uniform scale factor to fill the target rect.
    double offsetX; ///< X translation to center the scaled source in the target.
    double offsetY; ///< Y translation to center the scaled source in the target.
} VGDCAspectFillResult;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Pure geometry functions
// ─────────────────────────────────────────────────────────────────────────────

/// Compute PiP geometry for a secondary source placed over a primary canvas.
///
/// Arithmetic is identical to the Phase 7.x-H / 7.x-J compositor in
/// VGDualCameraCompositorNode._compositeWithPrimary:secondary:, steps 2–3.
///
/// @param primW   Width of the primary canvas in pixels (must be > 0).
/// @param primH   Height of the primary canvas in pixels (must be > 0).
/// @param secW    Width of the secondary source in pixels (must be > 0).
/// @param secH    Height of the secondary source in pixels (must be > 0).
/// @param config  PiP layout configuration.
/// @return        Computed PiP geometry. All values are clamped and safe to use.
///                If either canvas or source dimension is zero the result has
///                pipW = pipH = 1 (degenerate-safe minimum).
VGDCPiPGeometry VGDCLayoutComputePiPGeometry(size_t primW,
                                              size_t primH,
                                              size_t secW,
                                              size_t secH,
                                              VGPiPLayoutConfig config);

/// Compute primary (top) and secondary (bottom) band rects for split-screen layout.
///
/// Arithmetic is identical to the Phase 7.x-K compositor in
/// VGDualCameraCompositorNode._compositeWithSplitScreen:secondary:, step 2.
///
/// @param canvasW  Canvas width in pixels.
/// @param canvasH  Canvas height in pixels.
/// @param config   Split-screen layout configuration.
/// @return         Primary and secondary band rects. Check isValid before using.
VGDCSplitRects VGDCLayoutComputeSplitRects(size_t canvasW,
                                            size_t canvasH,
                                            VGSplitScreenLayoutConfig config);

/// Compute primary (left) and secondary (right) band rects for left/right split.
///
/// Always 50/50 locked — splitRatio in config is intentionally ignored.
///
/// @param canvasW  Canvas width in pixels.
/// @param canvasH  Canvas height in pixels.
/// @param config   Split-screen layout configuration (direction/splitRatio — ratio is ignored).
/// @return         Primary (left) and secondary (right) band rects. Check isValid before using.
VGDCSplitRectsLR VGDCLayoutComputeSplitRectsLeftRight(size_t canvasW,
                                                       size_t canvasH,
                                                       VGSplitScreenLayoutConfig config);

/// Compute the uniform scale and center offsets to aspect-fill a source into
/// a target rect (scale-to-fill + center crop).
///
/// Arithmetic is identical to the Phase 7.x-K `aspectFillIntoRect` block in
/// VGDualCameraCompositorNode._compositeWithSplitScreen:secondary:.
///
/// The caller applies the result to the source CIImage (after normalizing its
/// origin to (0,0)) as:
///   1. Scale by `scale` uniformly.
///   2. Translate by (offsetX, offsetY).
///   3. Crop to `targetRect`.
///
/// @param srcW        Source image width in pixels (must be > 0).
/// @param srcH        Source image height in pixels (must be > 0).
/// @param targetRect  Target CGRect (in the CIImage coordinate space of the caller).
/// @return            Scale and offsets. If srcW or srcH is 0, scale = 1 and
///                    offsets = 0 (safe no-op).
VGDCAspectFillResult VGDCLayoutComputeAspectFill(size_t srcW,
                                                   size_t srcH,
                                                   CGRect targetRect);

NS_ASSUME_NONNULL_END
