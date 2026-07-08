// VGOrientationEvidenceTests.swift
// ROI-5A.1 — VGOrientationEvidence Native Swift XCTests
//
// Tests pure-math orientation extraction using synthetic CGAffineTransform
// values. NO video files, NO AVFoundation I/O.
//
// Covers:
//   - All 4 cardinal rotations (0°/90°/180°/270°)
//   - All 4 mirrored cardinal variants (validMirrored)
//   - Shear transform (ambiguous)
//   - Scale 2× (ambiguous)
//   - Zero matrix (ambiguous)
//   - noVideoTrack / zero naturalSize
//   - Display dimension bounding-box with translation offsets
//   - Landscape source stays landscape after 0° (not forced to portrait)

import XCTest
@testable import vanguard_media_engine

final class VGOrientationEvidenceTests: XCTestCase {

    // MARK: - Tolerance

    private let eps = 1e-9   // test assertion tolerance for display dimension checks

    // MARK: - Helper

    private func assertEvidence(
        _ ev: VGOrientationEvidence,
        encodedW: Int, encodedH: Int,
        displayW: Int, displayH: Int,
        rotDeg: Int?,
        status: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(ev.encodedWidth,  encodedW, "encodedWidth",  file: file, line: line)
        XCTAssertEqual(ev.encodedHeight, encodedH, "encodedHeight", file: file, line: line)
        XCTAssertEqual(ev.displayWidth,  displayW, "displayWidth",  file: file, line: line)
        XCTAssertEqual(ev.displayHeight, displayH, "displayHeight", file: file, line: line)
        XCTAssertEqual(ev.rotationDegrees, rotDeg, "rotationDegrees", file: file, line: line)
        XCTAssertEqual(ev.orientationStatus, status, "orientationStatus", file: file, line: line)
    }

    // MARK: - Cardinal Rotations

    func testIdentity_0degrees() {
        // 1080×1920 portrait source with identity transform (app-recorded camera clip, DEC-132).
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: .identity
        )
        assertEvidence(ev,
            encodedW: 1080, encodedH: 1920,
            displayW: 1080, displayH: 1920,
            rotDeg: 0, status: "valid"
        )
        XCTAssertTrue(ev.isPortraitDisplay)
        XCTAssertFalse(ev.isLandscapeDisplay)
    }

    func test90degrees_landscapeSourceBecomesPortraitDisplay() {
        // 1920×1080 landscape source + 90° → display 1080×1920 portrait.
        // This is the common case for portrait gallery videos stored as landscape.
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: t
        )
        assertEvidence(ev,
            encodedW: 1920, encodedH: 1080,
            displayW: 1080, displayH: 1920,
            rotDeg: 90, status: "valid"
        )
        XCTAssertTrue(ev.isPortraitDisplay, "Display is portrait after 90° rotation")
        XCTAssertFalse(ev.isLandscapeDisplay)
    }

    func test180degrees_displayDimensionsUnchanged() {
        // 1080×1920 portrait + 180° → still 1080×1920 (no size swap).
        let t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1080, ty: 1920)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: t
        )
        assertEvidence(ev,
            encodedW: 1080, encodedH: 1920,
            displayW: 1080, displayH: 1920,
            rotDeg: 180, status: "valid"
        )
        XCTAssertTrue(ev.isPortraitDisplay)
    }

    func test270degrees_landscapeSourceBecomesPortraitDisplay() {
        // 1920×1080 + 270° → display 1080×1920.
        let t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: t
        )
        assertEvidence(ev,
            encodedW: 1920, encodedH: 1080,
            displayW: 1080, displayH: 1920,
            rotDeg: 270, status: "valid"
        )
        XCTAssertTrue(ev.isPortraitDisplay)
    }

    // MARK: - Landscape source stays landscape

    func testLandscapeSourceStaysLandscape_identity() {
        // Landscape video (16:9, 1280×720) with identity transform.
        // Must classify as landscape display — NOT forced to portrait.
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1280, height: 720),
            preferredTransform: .identity
        )
        assertEvidence(ev,
            encodedW: 1280, encodedH: 720,
            displayW: 1280, displayH: 720,
            rotDeg: 0, status: "valid"
        )
        XCTAssertTrue(ev.isLandscapeDisplay, "Landscape video must remain landscape")
        XCTAssertFalse(ev.isPortraitDisplay)
    }

    // MARK: - Mirrored Cardinal Variants

    func testMirror_0degrees() {
        // Horizontal mirror: a=-1, b=0, c=0, d=1. Seen from some front cameras.
        let t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1080, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: t
        )
        XCTAssertEqual(ev.orientationStatus, "validMirrored")
        XCTAssertNil(ev.rotationDegrees, "rotationDegrees must be nil for mirrored transforms")
        XCTAssertEqual(ev.encodedWidth,  1080)
        XCTAssertEqual(ev.encodedHeight, 1920)
    }

    func testMirror_90degrees() {
        // Mirror + 90°: a=0, b=1, c=1, d=0.
        let t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: t
        )
        XCTAssertEqual(ev.orientationStatus, "validMirrored")
        XCTAssertNil(ev.rotationDegrees)
    }

    func testMirror_180degrees() {
        // Mirror + 180°: a=1, b=0, c=0, d=-1.
        let t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1920)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: t
        )
        XCTAssertEqual(ev.orientationStatus, "validMirrored")
        XCTAssertNil(ev.rotationDegrees)
    }

    func testMirror_270degrees() {
        // Mirror + 270°: a=0, b=-1, c=-1, d=0.
        let t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: t
        )
        XCTAssertEqual(ev.orientationStatus, "validMirrored")
        XCTAssertNil(ev.rotationDegrees)
    }

    // MARK: - Ambiguous Transforms

    func testShear_ambiguous() {
        // Shear: a=1, b=0.5, c=0, d=1. Non-orthogonal — ambiguous.
        let t = CGAffineTransform(a: 1, b: 0.5, c: 0, d: 1, tx: 0, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1280, height: 720),
            preferredTransform: t
        )
        XCTAssertEqual(ev.orientationStatus, "ambiguous")
        XCTAssertNil(ev.rotationDegrees)
        // Dimensions are still present even for ambiguous (evidence-only).
        XCTAssertEqual(ev.encodedWidth,  1280)
        XCTAssertEqual(ev.encodedHeight, 720)
        // Display bounding box is present (non-zero).
        XCTAssertGreaterThan(ev.displayWidth,  0)
        XCTAssertGreaterThan(ev.displayHeight, 0)
    }

    func testScale2x_ambiguous() {
        // Uniform scale 2×: a=2, b=0, c=0, d=2. Non-unit-length rows — ambiguous.
        let t = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 0, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: t
        )
        XCTAssertEqual(ev.orientationStatus, "ambiguous")
        XCTAssertNil(ev.rotationDegrees)
    }

    func testZeroMatrix_ambiguous() {
        // Fully degenerate zero matrix.
        let t = CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: t
        )
        XCTAssertEqual(ev.orientationStatus, "ambiguous")
        XCTAssertNil(ev.rotationDegrees)
    }

    // MARK: - noVideoTrack

    func testZeroNaturalSize_noVideoTrack() {
        // naturalSize of .zero means no video track.
        let ev = VGOrientationEvidence.extract(
            naturalSize: .zero,
            preferredTransform: .identity
        )
        XCTAssertEqual(ev.orientationStatus, "noVideoTrack")
        XCTAssertEqual(ev.encodedWidth,  0)
        XCTAssertEqual(ev.encodedHeight, 0)
        XCTAssertEqual(ev.displayWidth,  0)
        XCTAssertEqual(ev.displayHeight, 0)
        XCTAssertNil(ev.rotationDegrees)
    }

    func testNegativeNaturalSize_noVideoTrack() {
        // Defensive: negative size values must also classify as noVideoTrack.
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: -1080, height: -1920),
            preferredTransform: .identity
        )
        XCTAssertEqual(ev.orientationStatus, "noVideoTrack")
    }

    // MARK: - Display bounding box with translation

    func test90degrees_withTranslationOffset_displayDimensionsCorrect() {
        // iOS frequently includes tx/ty offsets after rotation.
        // The bounding-box approach (CGRect.applying) absorbs these correctly.
        // 1920×1080 + 90° + translation (1080, 0).
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: t
        )
        // Display dimensions must be 1080×1920 regardless of tx offset.
        XCTAssertEqual(ev.displayWidth,  1080, "tx offset must not distort displayWidth")
        XCTAssertEqual(ev.displayHeight, 1920, "tx offset must not distort displayHeight")
        XCTAssertEqual(ev.orientationStatus, "valid")
        XCTAssertEqual(ev.rotationDegrees, 90)
    }

    // MARK: - toFlutterMap keys

    func testToFlutterMap_containsExpectedKeys() {
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: .identity
        )
        let map = ev.toFlutterMap()
        let requiredKeys = [
            "encodedWidth", "encodedHeight",
            "displayWidth", "displayHeight",
            "transformA", "transformB", "transformC", "transformD",
            "transformTx", "transformTy",
            "orientationStatus",
        ]
        for key in requiredKeys {
            XCTAssertTrue(map.keys.contains(key), "Missing key: \(key)")
        }
        // rotationDegrees should be present for valid 0° (non-nil).
        XCTAssertTrue(map.keys.contains("rotationDegrees"))
    }

    func testToFlutterMap_rotationDegreesAbsentForMirrored() {
        // For validMirrored, rotationDegrees key must be absent (not nil-as-NSNull).
        let t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1080, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1080, height: 1920),
            preferredTransform: t
        )
        XCTAssertEqual(ev.orientationStatus, "validMirrored")
        let map = ev.toFlutterMap()
        XCTAssertFalse(map.keys.contains("rotationDegrees"),
                       "rotationDegrees must be absent for validMirrored to produce null on Dart side")
    }

    // MARK: - Matrix values in output

    func testTransformValues_90degrees() {
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        let ev = VGOrientationEvidence.extract(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: t
        )
        XCTAssertEqual(ev.transformA,  0.0, accuracy: 1e-9)
        XCTAssertEqual(ev.transformB,  1.0, accuracy: 1e-9)
        XCTAssertEqual(ev.transformC, -1.0, accuracy: 1e-9)
        XCTAssertEqual(ev.transformD,  0.0, accuracy: 1e-9)
    }
}
