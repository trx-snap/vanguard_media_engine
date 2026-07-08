// VGOrientationEvidence.swift
// ROI-5A.1 — Imported Media Orientation Evidence
//
// Pure-math orientation evidence extractor. No AVFoundation dependency.
// Feed naturalSize + preferredTransform from AVAssetTrack to extract().
//
// Classification rules (Opus-validated):
//   epsilon       = 1e-4
//   determinant   = a*d - b*c
//   det ≈ +1.0 → pure rotation; det ≈ -1.0 → rotation + mirror
//   Orthogonality: |a²+b²−1| ≤ ε, |c²+d²−1| ≤ ε, |a·c+b·d| ≤ ε
//
// orientationStatus values:
//   "valid"        — Supported cardinal rotation (0/90/180/270), no mirroring.
//   "validMirrored"— Cardinal rotation with horizontal mirror. ROI blocked until
//                    a mirror coordinate policy is defined.
//   "ambiguous"    — Non-orthogonal, shear, non-unit scale, or degenerate matrix.
//                    ROI must not be generated for ambiguous videos.
//   "noVideoTrack" — No video track exists.
//
// IMPORTANT — display dimensions:
//   displayWidth/Height are computed by applying the full affine transform to the
//   naturalSize CGRect and taking the absolute bounding-box dimensions. This
//   correctly handles rotation + translation in a single step.
//   A landscape imported video stays landscape; this does NOT force portrait.
//
// IMPORTANT — camera-produced clips (DEC-132):
//   App-recorded camera clips carry identity preferredTransform. They will
//   classify as valid/0°. Never double-apply rotation to them.

import CoreGraphics
import Foundation

// MARK: - VGOrientationEvidence

struct VGOrientationEvidence {

    // MARK: Properties

    /// Raw encoded dimensions (naturalSize before any rotation). Never swapped.
    let encodedWidth:  Int
    let encodedHeight: Int

    /// Display dimensions: bounding-box of naturalSize after applying
    /// preferredTransform. For a 90°/270°-rotated landscape source (e.g.
    /// 1920×1080 + 90° transform), displayWidth=1080, displayHeight=1920.
    let displayWidth:  Int
    let displayHeight: Int

    /// Cardinal rotation in degrees (0, 90, 180, 270) for non-mirrored valid
    /// transforms. nil for mirrored, non-cardinal, ambiguous, or noVideoTrack.
    let rotationDegrees: Int?

    /// Raw matrix components from preferredTransform.
    let transformA:  Double
    let transformB:  Double
    let transformC:  Double
    let transformD:  Double
    let transformTx: Double
    let transformTy: Double

    /// Orientation classification. One of:
    /// "valid" | "validMirrored" | "ambiguous" | "noVideoTrack"
    let orientationStatus: String

    // MARK: - Derived convenience

    var isPortraitDisplay:  Bool { displayHeight > displayWidth }
    var isLandscapeDisplay: Bool { displayWidth >= displayHeight }

    // MARK: - Extraction

    /// Extract orientation evidence from a video track's naturalSize and
    /// preferredTransform. This is the sole public entry point.
    ///
    /// - Parameters:
    ///   - naturalSize:        AVAssetTrack.naturalSize
    ///   - preferredTransform: AVAssetTrack.preferredTransform
    static func extract(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> VGOrientationEvidence {

        let a  = Double(preferredTransform.a)
        let b  = Double(preferredTransform.b)
        let c  = Double(preferredTransform.c)
        let d  = Double(preferredTransform.d)
        let tx = Double(preferredTransform.tx)
        let ty = Double(preferredTransform.ty)

        // Guard: degenerate / zero naturalSize → noVideoTrack.
        guard naturalSize.width > 0,
              naturalSize.height > 0,
              naturalSize.width.isFinite,
              naturalSize.height.isFinite else {
            return VGOrientationEvidence(
                encodedWidth:     0,
                encodedHeight:    0,
                displayWidth:     0,
                displayHeight:    0,
                rotationDegrees:  nil,
                transformA:       a,
                transformB:       b,
                transformC:       c,
                transformD:       d,
                transformTx:      tx,
                transformTy:      ty,
                orientationStatus: "noVideoTrack"
            )
        }

        // Encoded dimensions (raw, never swapped).
        let encW = Int(abs(naturalSize.width).rounded())
        let encH = Int(abs(naturalSize.height).rounded())

        // Display dimensions — bounding box of naturalSize rect after transform.
        // abs() handles sign-flips from rotations. CGRect.applying() returns a
        // standardized (always-positive-size) rect, but we apply abs() for safety.
        let encodedRect  = CGRect(origin: .zero, size: naturalSize)
        let displayRect  = encodedRect.applying(preferredTransform)
        let dispW = Int(abs(displayRect.width).rounded())
        let dispH = Int(abs(displayRect.height).rounded())

        // ── Matrix classification ─────────────────────────────────────────────
        let eps = 1e-4

        // Orthogonality / unit-length checks.
        let rowAB_sq   = a * a + b * b
        let rowCD_sq   = c * c + d * d
        let dotProduct = a * c + b * d

        let isOrthogonalUnit = abs(rowAB_sq - 1.0) <= eps
                            && abs(rowCD_sq - 1.0) <= eps
                            && abs(dotProduct)      <= eps

        let det = a * d - b * c

        // Ambiguous — non-unit or non-orthogonal (shear, scale, degenerate).
        guard isOrthogonalUnit else {
            return VGOrientationEvidence(
                encodedWidth:     encW,
                encodedHeight:    encH,
                displayWidth:     dispW,
                displayHeight:    dispH,
                rotationDegrees:  nil,
                transformA:  a, transformB:  b, transformC:  c, transformD:  d,
                transformTx: tx, transformTy: ty,
                orientationStatus: "ambiguous"
            )
        }

        // ── Pure rotation (det ≈ +1.0) ────────────────────────────────────────
        if abs(det - 1.0) <= eps {
            let (degrees, matched) = _matchCardinal(a: a, b: b, c: c, d: d, eps: eps)
            if matched {
                return VGOrientationEvidence(
                    encodedWidth:     encW,
                    encodedHeight:    encH,
                    displayWidth:     dispW,
                    displayHeight:    dispH,
                    rotationDegrees:  degrees,
                    transformA:  a, transformB:  b, transformC:  c, transformD:  d,
                    transformTx: tx, transformTy: ty,
                    orientationStatus: "valid"
                )
            }
            // Orthogonal and unit but not a standard cardinal — ambiguous.
            return VGOrientationEvidence(
                encodedWidth:     encW,
                encodedHeight:    encH,
                displayWidth:     dispW,
                displayHeight:    dispH,
                rotationDegrees:  nil,
                transformA:  a, transformB:  b, transformC:  c, transformD:  d,
                transformTx: tx, transformTy: ty,
                orientationStatus: "ambiguous"
            )
        }

        // ── Mirror + rotation (det ≈ -1.0) ───────────────────────────────────
        if abs(det + 1.0) <= eps {
            let matched = _matchMirroredCardinal(a: a, b: b, c: c, d: d, eps: eps)
            if matched {
                return VGOrientationEvidence(
                    encodedWidth:     encW,
                    encodedHeight:    encH,
                    displayWidth:     dispW,
                    displayHeight:    dispH,
                    rotationDegrees:  nil, // ROI blocked until mirror policy defined.
                    transformA:  a, transformB:  b, transformC:  c, transformD:  d,
                    transformTx: tx, transformTy: ty,
                    orientationStatus: "validMirrored"
                )
            }
            return VGOrientationEvidence(
                encodedWidth:     encW,
                encodedHeight:    encH,
                displayWidth:     dispW,
                displayHeight:    dispH,
                rotationDegrees:  nil,
                transformA:  a, transformB:  b, transformC:  c, transformD:  d,
                transformTx: tx, transformTy: ty,
                orientationStatus: "ambiguous"
            )
        }

        // Determinant is neither ≈+1 nor ≈-1 (scale/degenerate).
        return VGOrientationEvidence(
            encodedWidth:     encW,
            encodedHeight:    encH,
            displayWidth:     dispW,
            displayHeight:    dispH,
            rotationDegrees:  nil,
            transformA:  a, transformB:  b, transformC:  c, transformD:  d,
            transformTx: tx, transformTy: ty,
            orientationStatus: "ambiguous"
        )
    }

    // MARK: - Flutter method channel serialization

    /// Returns a dictionary suitable for merging into a Flutter method-channel
    /// result map. Uses `NSNull` for nil `rotationDegrees` so the Dart side
    /// receives a proper null rather than a missing key.
    func toFlutterMap() -> [String: Any] {
        var map: [String: Any] = [
            "encodedWidth":      encodedWidth,
            "encodedHeight":     encodedHeight,
            "displayWidth":      displayWidth,
            "displayHeight":     displayHeight,
            "transformA":        transformA,
            "transformB":        transformB,
            "transformC":        transformC,
            "transformD":        transformD,
            "transformTx":       transformTx,
            "transformTy":       transformTy,
            "orientationStatus": orientationStatus,
        ]
        // Only include rotationDegrees when non-nil so Dart receives null for
        // mirrored/ambiguous cases via the ?? nil fallback in _fromRaw.
        if let deg = rotationDegrees {
            map["rotationDegrees"] = deg
        }
        return map
    }

    // MARK: - Private helpers

    /// Matches the four standard cardinal rotation matrices with epsilon tolerance.
    /// Returns (degrees, true) on match, (nil, false) otherwise.
    private static func _matchCardinal(
        a: Double, b: Double, c: Double, d: Double, eps: Double
    ) -> (Int?, Bool) {
        // 0°:   a≈ 1, b≈ 0, c≈  0, d≈ 1
        if abs(a -  1.0) <= eps && abs(b)       <= eps &&
           abs(c)        <= eps && abs(d -  1.0) <= eps { return (0,   true) }
        // 90°:  a≈ 0, b≈ 1, c≈ -1, d≈ 0
        if abs(a)        <= eps && abs(b -  1.0) <= eps &&
           abs(c +  1.0) <= eps && abs(d)        <= eps { return (90,  true) }
        // 180°: a≈-1, b≈ 0, c≈  0, d≈-1
        if abs(a +  1.0) <= eps && abs(b)        <= eps &&
           abs(c)        <= eps && abs(d +  1.0) <= eps { return (180, true) }
        // 270°: a≈ 0, b≈-1, c≈  1, d≈ 0
        if abs(a)        <= eps && abs(b +  1.0) <= eps &&
           abs(c -  1.0) <= eps && abs(d)        <= eps { return (270, true) }
        return (nil, false)
    }

    /// Matches the four mirrored cardinal variants (det ≈ -1).
    private static func _matchMirroredCardinal(
        a: Double, b: Double, c: Double, d: Double, eps: Double
    ) -> Bool {
        // mirror+0°:   a≈-1, b≈ 0, c≈ 0, d≈ 1
        if abs(a +  1.0) <= eps && abs(b) <= eps &&
           abs(c) <= eps && abs(d - 1.0)  <= eps { return true }
        // mirror+90°:  a≈ 0, b≈ 1, c≈ 1, d≈ 0
        if abs(a) <= eps && abs(b - 1.0) <= eps &&
           abs(c - 1.0) <= eps && abs(d) <= eps { return true }
        // mirror+180°: a≈ 1, b≈ 0, c≈ 0, d≈-1
        if abs(a - 1.0) <= eps && abs(b) <= eps &&
           abs(c) <= eps && abs(d + 1.0) <= eps { return true }
        // mirror+270°: a≈ 0, b≈-1, c≈-1, d≈ 0
        if abs(a) <= eps && abs(b + 1.0) <= eps &&
           abs(c + 1.0) <= eps && abs(d) <= eps { return true }
        return false
    }
}
