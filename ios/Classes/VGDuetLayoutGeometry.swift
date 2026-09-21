// VGDuetLayoutGeometry.swift
// VG-DUET-SLICE-4A: Native geometry helpers mirroring VGDuetLayoutMath.dart.
//
// Pure, stateless, renderer-independent.  Mirrors the Dart layout math for:
//   - splitLeftRight (50/50 horizontal)
//   - splitTopBottom (50/50 vertical)
//   - pip (anchor + normalizedRect → pixel rects)
//   - greenScreen (full-background source, camera overlay, full-canvas placeholder)
//
// All inputs/outputs use plain CGFloat arithmetic and CGRect.
// No UIKit, AVFoundation, Metal, or Flutter dependencies.

import CoreGraphics
import Foundation

// MARK: - VGDuetLayoutGeometry

/// Pure static helpers for Duet spatial layout geometry.
///
/// Matches the semantics of `VGDuetLayoutMath` in Dart:
///   - All returned rects are in canvas-pixel coordinates.
///   - Return order is `[sourceRect, cameraRect]` unless noted.
enum VGDuetLayoutGeometry {

    // MARK: - Split Left/Right

    /// Returns `[sourceRect, cameraRect]` for a 50/50 horizontal split.
    ///
    /// Default (not swapped): source occupies the left half, camera the right.
    /// Swapped: camera on left, source on right.
    static func splitLeftRight(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        isSwapped: Bool
    ) -> (source: CGRect, camera: CGRect) {
        let halfW = canvasWidth / 2.0
        let left  = CGRect(x: 0,     y: 0, width: halfW, height: canvasHeight)
        let right = CGRect(x: halfW, y: 0, width: halfW, height: canvasHeight)
        return isSwapped ? (source: right, camera: left)
                         : (source: left,  camera: right)
    }

    // MARK: - Split Top/Bottom

    /// Returns `[sourceRect, cameraRect]` for a 50/50 vertical split.
    ///
    /// Default (not swapped): source on top, camera on bottom.
    /// Swapped: camera on top, source on bottom.
    static func splitTopBottom(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        isSwapped: Bool
    ) -> (source: CGRect, camera: CGRect) {
        let halfH = canvasHeight / 2.0
        let top    = CGRect(x: 0, y: 0,     width: canvasWidth, height: halfH)
        let bottom = CGRect(x: 0, y: halfH, width: canvasWidth, height: halfH)
        return isSwapped ? (source: bottom, camera: top)
                         : (source: top,    camera: bottom)
    }

    // MARK: - PiP

    /// Converts a normalised PiP rect (0–1 fraction of canvas) to pixel rect.
    ///
    /// The normalised rect is anchored relative to the canvas origin (top-left).
    static func pipCameraRect(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        normalizedLeft: CGFloat,
        normalizedTop: CGFloat,
        normalizedWidth: CGFloat,
        normalizedHeight: CGFloat
    ) -> CGRect {
        return CGRect(
            x:      normalizedLeft   * canvasWidth,
            y:      normalizedTop    * canvasHeight,
            width:  normalizedWidth  * canvasWidth,
            height: normalizedHeight * canvasHeight
        )
    }

    /// Returns the full-canvas source rect used in PiP mode.
    static func pipSourceRect(canvasWidth: CGFloat, canvasHeight: CGFloat) -> CGRect {
        return CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
    }

    // MARK: - Green Screen

    /// Returns rects for the Green Screen layout.
    ///
    /// - `source` fills the full canvas (background video).
    /// - `camera` is a placeholder equal to the full canvas; the compositor
    ///   slice that performs keying will crop/overlay as needed.
    static func greenScreen(
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> (source: CGRect, camera: CGRect) {
        let full = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        return (source: full, camera: full)
    }

    /// Returns rects for the Green Screen layout with an optional foreground transform.
    ///
    /// When `transform` is nil or has non-finite/non-positive scale, returns the
    /// full-canvas identity (backwards compatible with existing green-screen sessions
    /// without a transform).
    ///
    /// Transform semantics (v2 — free transform: scale, drag, rotate):
    /// - `scale` is clamped to [0.10, 4.0] before rect math; malformed scale degrades
    ///   to the full-canvas identity. Unlike v1, scale above 1.0 is not clamped down
    ///   to the full-canvas rect — the camera layer can be larger than the canvas.
    /// - `offset` is a normalized canvas-center translation, defaulting non-finite
    ///   values to 0.0 before clamping to [-2.0, 2.0].
    /// - `anchor` maps a point within the scaled rect to canvas-center + offset,
    ///   defaulting non-finite values to 0.5 before clamping to [0.0, 1.0].
    /// - `transform.rotationDegrees` is not applied here: this function always
    ///   returns the unrotated, axis-aligned camera rect. Rotation is serialized
    ///   separately for native preview/export to apply.
    ///
    /// Rect math (mirrors AndroidGreenScreenLayoutGeometry exactly):
    ///   scaledW  = canvasWidth  * clampedScale
    ///   scaledH  = canvasHeight * clampedScale
    ///   canvasCx = canvasWidth  / 2
    ///   canvasCy = canvasHeight / 2
    ///   targetX  = canvasCx + clampedOffsetX * canvasCx
    ///   targetY  = canvasCy + clampedOffsetY * canvasCy
    ///   left     = targetX - clampedAnchorX * scaledW
    ///   top      = targetY - clampedAnchorY * scaledH
    ///
    /// Free placement (drag) is intentionally not clamped fully inside the canvas —
    /// the resulting rect may extend beyond canvas edges, matching TikTok-style Duet
    /// foreground placement. Scale exactly 1.0 with zero offset and centered anchor
    /// still yields the full-canvas identity rect.
    static func greenScreen(
        canvasWidth:  CGFloat,
        canvasHeight: CGFloat,
        transform:    NativeForegroundTransform?
    ) -> (source: CGRect, camera: CGRect) {
        let full = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let source = full

        guard let t = transform else {
            return (source: source, camera: full)
        }

        let rawScale = t.scale
        if !rawScale.isFinite || rawScale <= 0.0 {
            return (source: source, camera: full)
        }

        // Normalize and clamp inputs.
        let scale = min(max(rawScale, 0.10), 4.0)
        let rawOffsetX = t.offsetX
        let rawOffsetY = t.offsetY
        let offsetX = min(max(rawOffsetX.isFinite ? rawOffsetX : 0.0, -2.0), 2.0)
        let offsetY = min(max(rawOffsetY.isFinite ? rawOffsetY : 0.0, -2.0), 2.0)
        let rawAnchorX = t.anchorX
        let rawAnchorY = t.anchorY
        let anchorX = min(max(rawAnchorX.isFinite ? rawAnchorX : 0.5, 0.0), 1.0)
        let anchorY = min(max(rawAnchorY.isFinite ? rawAnchorY : 0.5, 0.0), 1.0)

        // Identity short-circuit: only exactly scale 1.0, zero offset, and
        // centered anchor returns the full canvas without any rect math.
        if scale == 1.0 && offsetX == 0.0 && offsetY == 0.0 && anchorX == 0.5 && anchorY == 0.5 {
            return (source: source, camera: full)
        }

        let scaledW = canvasWidth  * scale
        let scaledH = canvasHeight * scale

        // Canvas center and target point.
        let canvasCx = canvasWidth  / 2.0
        let canvasCy = canvasHeight / 2.0
        let targetX  = canvasCx + offsetX * canvasCx
        let targetY  = canvasCy + offsetY * canvasCy

        // Rect with anchor mapping to target. Free placement (drag) is
        // intentionally not clamped fully inside the canvas — the resulting
        // rect may extend beyond canvas edges, matching TikTok-style Duet
        // foreground placement.
        let left = targetX - anchorX * scaledW
        let top  = targetY - anchorY * scaledH

        let camera = CGRect(x: left, y: top, width: scaledW, height: scaledH)
        return (source: source, camera: camera)
    }

    // MARK: - Foreground rotation (preview-only)

    /// Derives preview-only rotation metadata from a foreground transform.
    ///
    /// Mirrors the same finiteness/clamping rules as
    /// `greenScreen(canvasWidth:canvasHeight:transform:)`: a nil transform, or an
    /// invalid (non-finite or non-positive) scale — which forces that function to
    /// fall back to the full-canvas identity rect — also forces identity rotation
    /// here (0 degrees, centered anchor). A valid transform's `rotationDegrees` and
    /// anchor are carried through even when the unrotated rect happens to equal the
    /// full canvas (scale 1.0, zero offset, centered anchor), since rotation can
    /// still be visually meaningful in that case.
    static func foregroundRotation(transform: NativeForegroundTransform?) -> VGDuetForegroundRotation {
        guard let t = transform else { return .identity }

        let rawScale = t.scale
        guard rawScale.isFinite && rawScale > 0.0 else { return .identity }

        let rawAnchorX = t.anchorX
        let rawAnchorY = t.anchorY
        let anchorX = min(max(rawAnchorX.isFinite ? rawAnchorX : 0.5, 0.0), 1.0)
        let anchorY = min(max(rawAnchorY.isFinite ? rawAnchorY : 0.5, 0.0), 1.0)

        let rawRotation = t.rotationDegrees
        let rotationDegrees = rawRotation.isFinite ? rawRotation : 0.0

        return VGDuetForegroundRotation(rotationDegrees: rotationDegrees, anchorX: anchorX, anchorY: anchorY)
    }

    // MARK: - Map serialization helpers

    /// Serializes a CGRect to a flat dictionary for MethodChannel transport.
    static func rectToMap(_ rect: CGRect) -> [String: Double] {
        return [
            "left":   Double(rect.origin.x),
            "top":    Double(rect.origin.y),
            "width":  Double(rect.width),
            "height": Double(rect.height),
        ]
    }
}

// MARK: - VGDuetForegroundRotation

/// Preview-only rotation metadata for the green-screen foreground/camera layer.
///
/// Carries `rotationDegrees` plus the pivot anchor (normalized, Dart/top-left
/// space) that `VGDuetPreviewCompositor` rotates the camera layer around. This
/// is never serialized to Dart: `VGDuetLayoutGeometry.rectToMap` and
/// `VGDuetNativeSessionCoordinator.serializeLayoutRects` continue to emit only
/// source/camera rect maps.
struct VGDuetForegroundRotation {
    let rotationDegrees: CGFloat
    let anchorX: CGFloat
    let anchorY: CGFloat

    static let identity = VGDuetForegroundRotation(rotationDegrees: 0.0, anchorX: 0.5, anchorY: 0.5)
}

// MARK: - NativeForegroundTransform

/// Parsed foreground camera-layer transform for native geometry computation.
///
/// All fields are raw (pre-clamp) values from the layout config map;
/// clamping is performed inside `VGDuetLayoutGeometry.greenScreen(canvasWidth:canvasHeight:transform:)`.
/// `rotationDegrees` is contract data only in this slice: it defaults to `0.0`
/// and is not applied to the axis-aligned rect returned by that function.
struct NativeForegroundTransform {
    let scale:           CGFloat
    let offsetX:         CGFloat
    let offsetY:         CGFloat
    let anchorX:         CGFloat
    let anchorY:         CGFloat
    let rotationDegrees: CGFloat

    init(
        scale:           CGFloat,
        offsetX:         CGFloat,
        offsetY:         CGFloat,
        anchorX:         CGFloat,
        anchorY:         CGFloat,
        rotationDegrees: CGFloat = 0.0
    ) {
        self.scale           = scale
        self.offsetX         = offsetX
        self.offsetY         = offsetY
        self.anchorX         = anchorX
        self.anchorY         = anchorY
        self.rotationDegrees = rotationDegrees
    }
}
