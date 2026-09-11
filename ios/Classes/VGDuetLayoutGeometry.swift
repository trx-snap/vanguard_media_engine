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
    /// When `transform` is nil, returns the full-canvas identity (backwards compatible
    /// with existing green-screen sessions without a transform).
    ///
    /// Transform semantics (v1 — shrink/reposition only):
    /// - `scale` is clamped to [0.25, 1.0] before rect math.
    /// - `offset` is a normalized canvas-center translation, clamped to [-1.0, 1.0].
    /// - `anchor` maps a point within the scaled rect to canvas-center + offset,
    ///   clamped to [0.0, 1.0].
    ///
    /// Rect math (mirrors AndroidDuetLayoutGeometry exactly):
    ///   scaledW  = canvasWidth  * clampedScale
    ///   scaledH  = canvasHeight * clampedScale
    ///   canvasCx = canvasWidth  / 2
    ///   canvasCy = canvasHeight / 2
    ///   targetX  = canvasCx + clampedOffsetX * canvasCx
    ///   targetY  = canvasCy + clampedOffsetY * canvasCy
    ///   left     = targetX - clampedAnchorX * scaledW  (then clamp to canvas)
    ///   top      = targetY - clampedAnchorY * scaledH  (then clamp to canvas)
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

        // Clamp inputs.
        let scale   = min(max(t.scale,   0.25), 1.0)
        let offsetX = min(max(t.offsetX, -1.0), 1.0)
        let offsetY = min(max(t.offsetY, -1.0), 1.0)
        let anchorX = min(max(t.anchorX, 0.0), 1.0)
        let anchorY = min(max(t.anchorY, 0.0), 1.0)

        // Identity short-circuit: scale 1.0 with no offset → full canvas.
        if scale >= 1.0 && offsetX == 0.0 && offsetY == 0.0 {
            return (source: source, camera: full)
        }

        let scaledW = canvasWidth  * scale
        let scaledH = canvasHeight * scale

        // Canvas center and target point.
        let canvasCx = canvasWidth  / 2.0
        let canvasCy = canvasHeight / 2.0
        let targetX  = canvasCx + offsetX * canvasCx
        let targetY  = canvasCy + offsetY * canvasCy

        // Unclamped rect with anchor mapping to target.
        var left = targetX - anchorX * scaledW
        var top  = targetY - anchorY * scaledH

        // Clamp rect fully inside canvas; size is fixed by scale.
        left = min(max(left, 0.0), canvasWidth  - scaledW)
        top  = min(max(top,  0.0), canvasHeight - scaledH)

        let camera = CGRect(x: left, y: top, width: scaledW, height: scaledH)
        return (source: source, camera: camera)
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

// MARK: - NativeForegroundTransform

/// Parsed foreground camera-layer transform for native geometry computation.
///
/// All fields are raw (pre-clamp) values from the layout config map;
/// clamping is performed inside `VGDuetLayoutGeometry.greenScreen(canvasWidth:canvasHeight:transform:)`.
struct NativeForegroundTransform {
    let scale:   CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let anchorX: CGFloat
    let anchorY: CGFloat
}
