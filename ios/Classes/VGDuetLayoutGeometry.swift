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
