// VGDuetPreviewCompositorPixelProof.swift
// Diagnostic: deterministic CoreImage pixel proof (simulator-safe), reachable via
// VGDuetPreviewCompositor.runDeterministicPixelProof().
//
// Proof boundary: ios_duet_coreimage_pixel_proof_synthetic_mask_blend_only
//
// This proof predates the Duet/GreenScreen architecture boundary cleanup (VG-DUET-SLICE
// architecture boundary cleanup) that moved CIBlendWithMask green-screen compositing out
// of VGDuetPreviewCompositor and into VGLiveGreenScreenCompositor (see that file). The
// entry point stays on VGDuetPreviewCompositor — and the proof boundary string, gate
// names (including `blendFilterOk`), and PASS/FAIL markers stay byte-for-byte unchanged —
// because the Dart-side smoke harness (example/lib/ios_duet_pixel_proof_smoke.dart) and
// the `runIosDuetPixelProof` method channel route (VGDuetMethodHandler.swift) hardcode
// that exact contract and are out of scope for this slice. Internally the proof now
// builds a VGLiveGreenScreenCompositor — the type that actually owns the CIBlendWithMask
// green-screen path being proved — instead of VGDuetPreviewCompositor; every gate and
// sample point is unchanged, but the fractional-blend expected values are not (see below).
//
// Fractional expected-value correction: `VGLiveGreenScreenCompositor.composite()` never
// feeds the raw authored mask byte to CIBlendWithMask — it always runs
// `VGMatteRefinementPipeline.refineLiveGreenScreenMask(...)` on the aspect-filled mask
// first (morphology close, feather, trimap, then the production live default
// `.s4SoftAlphaR2` camera-guided alpha refinement), and only the refined mask reaches
// CIBlendWithMask. Interior 0/255 quadrant values survive that pipeline unchanged (no
// stage moves a flat interior region far from any mask edge), which is why the
// boundary-keying and viewport-exterior assertions below still compare against literal
// background/foreground colors. Interior fractional values (the 128/64 quadrant sample
// points) do not survive unchanged — they sit close enough to multiple quadrant
// boundaries that feather/trimap/S4 refinement measurably shifts them. So the fractional
// assertions below render the exact same `.s4SoftAlphaR2` refined mask
// `VGLiveGreenScreenCompositor.composite()` used internally (via
// `greenScreenMatteStages(..., refinementMode: .s4SoftAlphaR2).finalMask`), sample its
// actual byte value at each fraction sample coordinate, and assert the composited output
// against the linear foreground/background mix of *that* sampled value — a real
// after-the-fact check of CIBlendWithMask's own linear-interpolation math against
// whatever mask value the production refinement pipeline actually produced, rather than
// a stale assumption that the raw quadrant byte reaches the filter unchanged.
//
// Proves that VGLiveGreenScreenCompositor's CIBlendWithMask green-screen path blends a
// synthetic camera foreground over a synthetic source/background through a single-channel
// L8 mask with the expected linear-interpolation math, using only synthetic
// CVPixelBuffers built in-process. Diagnostic only.
//
// DEC-V2-123C follow-up: this file also proves deterministic Duet straight-alpha
// foreground free-transform rotation/off-canvas pixel behavior — a SEPARATE lane
// appended near the end of runDeterministicPixelProof() that instantiates a real
// VGDuetPreviewCompositor directly (not VGLiveGreenScreenCompositor) and exercises its
// cameraFrameUsesStraightAlpha: true composite() path with cameraRotationDegrees /
// cameraAnchorX / cameraAnchorY, using only synthetic CVPixelBuffers built in-process.
// See that lane's own header comment for the exact test pattern, sample geometry, and
// rotation-direction derivation. The proof boundary string, PASS/FAIL markers, and every
// gate/sample point in the CIBlendWithMask lane above stay byte-for-byte unchanged.
//
// Non-claims: no real camera hardware or AVCaptureSession lifecycle, no Vision/ML
// segmentation quality, no video decoder, no MP4 export, no audio, no ConnectsApp /
// Universal Editor / upload wiring.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

extension VGDuetPreviewCompositor {

    static let iosDuetPixelProofBoundary = "ios_duet_coreimage_pixel_proof_synthetic_mask_blend_only"

    private static let pixelProofStartMarker = "IOS_DUET_PIXEL_PROOF_START"
    private static let pixelProofPassMarker  = "IOS_DUET_PIXEL_PROOF_PASS"
    private static let pixelProofFailMarker  = "IOS_DUET_PIXEL_PROOF_FAIL"

    /// Max per-channel 0-255 delta tolerated between an actual sampled pixel and the
    /// expected linear-mix pixel. CIBlendWithMask matched exact rounded math (delta 0)
    /// in an offline CoreImage probe against this same geometry; 2 leaves headroom for
    /// Metal-vs-CPU CIContext backend differences.
    private static let pixelProofTolerance = 2

    private static let pixelProofNonClaims: [String] = [
        "No real camera hardware or AVCaptureSession lifecycle claim.",
        "No Vision/ML segmentation quality claim; synthetic mask patterns only.",
        "No video decoder claim.",
        "No MP4/export pipeline claim.",
        "No audio pipeline claim.",
        "No ConnectsApp/Universal Editor/upload wiring claim.",
    ]

    /// Deterministic, simulator-safe pixel proof for the CIBlendWithMask green-screen path
    /// in `VGLiveGreenScreenCompositor.composite(...)`. Renders synthetic BGRA source/camera
    /// buffers and an L8 mask through a real `VGLiveGreenScreenCompositor(canvasWidth: 64,
    /// canvasHeight: 64)` instance and asserts pixel values in the resulting output buffer.
    /// Also runs a second, independent lane (DEC-V2-123C follow-up, appended near the end
    /// of this function) proving `VGDuetPreviewCompositor`'s own straight-alpha foreground
    /// free-transform rotation/off-canvas rendered pixel behavior via a real
    /// `VGDuetPreviewCompositor(canvasWidth: 64, canvasHeight: 64)` instance. Never throws;
    /// every failure mode is captured in the returned map's `failureReason`/`mismatches`
    /// instead.
    /// Markers: IOS_DUET_PIXEL_PROOF_START / IOS_DUET_PIXEL_PROOF_PASS / IOS_DUET_PIXEL_PROOF_FAIL.
    static func runDeterministicPixelProof() -> [String: Any] {
        NSLog("[VGDuetPreviewCompositor] \(pixelProofStartMarker)")

        var gates: [String: Bool] = [
            "compositorInitOk":      false,
            "syntheticBuffersOk":    false,
            "blendFilterOk":         false,
            "boundaryKeyingOk":      false,
            "fractionalBlendMathOk": false,
            "viewportExteriorOk":    false,
            "cleanupOk":             false,
            "canonical":             false,
            // DEC-V2-123C follow-up: Duet straight-alpha foreground
            // free-transform rotation / off-canvas rendered pixel proof (see
            // the dedicated lane appended below), exercising a real
            // VGDuetPreviewCompositor instance directly instead of
            // VGLiveGreenScreenCompositor above.
            "straightAlphaRotation0Ok":           false,
            "straightAlphaRotation90Ok":           false,
            "straightAlphaRgbAlphaCoTransformOk": false,
            "straightAlphaOffCanvasClipOk":        false,
            "rotationCanonicalOk":                 false,
        ]
        var failureReason = ""
        var mismatches: [String] = []
        var maxDelta = 0
        var sampleCount = 0
        var details: [String: Any] = [:]
        var viewportExteriorAllOk = true
        var boundaryKeyingAllOk = true
        var fractionalAllOk = true

        let backgroundColor: (r: Int, g: Int, b: Int) = (40, 160, 80)
        let foregroundColor: (r: Int, g: Int, b: Int) = (220, 60, 140)

        func fail(_ reason: String) {
            if failureReason.isEmpty { failureReason = reason }
        }

        func expectedMix(alpha: Int) -> (r: Int, g: Int, b: Int) {
            let m = Double(alpha) / 255.0
            let r = (Double(foregroundColor.r) * m + Double(backgroundColor.r) * (1 - m)).rounded()
            let g = (Double(foregroundColor.g) * m + Double(backgroundColor.g) * (1 - m)).rounded()
            let b = (Double(foregroundColor.b) * m + Double(backgroundColor.b) * (1 - m)).rounded()
            return (Int(r), Int(g), Int(b))
        }

        func finalize() -> [String: Any] {
            let allGatesPass = gates.values.allSatisfy { $0 }
            let overallPass = allGatesPass && maxDelta <= pixelProofTolerance && failureReason.isEmpty
            let marker = overallPass ? pixelProofPassMarker : pixelProofFailMarker
            NSLog("[VGDuetPreviewCompositor] \(marker) failureReason=\(failureReason) maxDelta=\(maxDelta) gates=\(gates)")
            var result: [String: Any] = [:]
            result["pass"] = overallPass
            result["status"] = overallPass ? "PASS" : "FAIL"
            result["marker"] = marker
            result["proofBoundary"] = iosDuetPixelProofBoundary
            result["gates"] = gates
            result["tolerance"] = pixelProofTolerance
            result["maxDelta"] = maxDelta
            result["sampleCount"] = sampleCount
            result["mismatches"] = mismatches
            result["details"] = details
            result["failureReason"] = failureReason
            result["nonClaims"] = pixelProofNonClaims
            return result
        }

        // 1. Blend filter availability.
        guard CIFilter(name: "CIBlendWithMask") != nil else {
            fail("blend_filter_unavailable")
            return finalize()
        }
        gates["blendFilterOk"] = true

        // 2. Synthetic buffers: 64x64 BGRA background, 32x32 BGRA foreground,
        //    32x32 L8 mask (quadrants: topLeft=0, topRight=255, bottomLeft=128, bottomRight=64).
        guard let sourceBuffer = makeConstantBGRABuffer(width: 64, height: 64,
                                                         r: backgroundColor.r, g: backgroundColor.g, b: backgroundColor.b),
              let cameraBuffer = makeConstantBGRABuffer(width: 32, height: 32,
                                                         r: foregroundColor.r, g: foregroundColor.g, b: foregroundColor.b),
              let maskBuffer = makeQuadrantMaskBuffer(width: 32, height: 32,
                                                       topLeft: 0, topRight: 255, bottomLeft: 128, bottomRight: 64)
        else {
            fail("synthetic_buffer_creation_failed")
            return finalize()
        }
        gates["syntheticBuffersOk"] = true
        details["syntheticBuffers"] = [
            "source": ["width": 64, "height": 64, "rgb": [backgroundColor.r, backgroundColor.g, backgroundColor.b]],
            "camera": ["width": 32, "height": 32, "rgb": [foregroundColor.r, foregroundColor.g, foregroundColor.b]],
            "mask": [
                "width": 32, "height": 32, "format": "OneComponent8",
                "quadrants": ["topLeft": 0, "topRight": 255, "bottomLeft": 128, "bottomRight": 64],
            ],
        ]

        // 3. Composite through the real green-screen path (owned by VGLiveGreenScreenCompositor
        //    since the architecture boundary cleanup; see this file's header).
        let compositor = VGLiveGreenScreenCompositor(canvasWidth: 64, canvasHeight: 64)
        let sourceRect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let cameraRect = CGRect(x: 16, y: 16, width: 32, height: 32)
        guard let output = compositor.composite(sourceFrame: sourceBuffer,
                                                 sourceRect: sourceRect,
                                                 cameraRect: cameraRect,
                                                 cameraFrame: cameraBuffer,
                                                 isGreenScreen: true,
                                                 greenScreenMask: maskBuffer)
        else {
            fail("composite_returned_nil_pool_exhausted_or_unavailable")
            return finalize()
        }
        // Only observable proof that the compositor + its pool initialized correctly:
        // a nil-returning composite() means the pool never came up (see makePool()).
        gates["compositorInitOk"] = true
        details["cameraRect"] = ["x": 16, "y": 16, "width": 32, "height": 32]
        details["sourceRect"] = ["x": 0, "y": 0, "width": 64, "height": 64]
        details["canvasSize"] = ["width": 64, "height": 64]

        // 3b. Reproduce the exact refined mask CIImage the composite() call above already
        // fed to CIBlendWithMask internally, so the fractional-blend assertions in step 4
        // can be checked against the real post-refinement mask value instead of the raw
        // authored quadrant byte (see this file's header). `compositor` above was built
        // with no explicit `liveMatteRefinementMode` override, so it already runs the
        // production default (`VGMatteRefinementPipeline.defaultLiveMatteRefinementMode`
        // == `.s4SoftAlphaR2`); this mirrors that exact mode for expected-mask sampling.
        let refinementModeUsedForExpected = "s4SoftAlphaR2"
        let ciCameraRect = compositor.ciRect(fromTopLeft: cameraRect)
        let maskFilledForExpected = compositor.aspectFill(CIImage(cvPixelBuffer: maskBuffer), into: ciCameraRect)
        let cameraFilledForExpected = compositor.aspectFill(CIImage(cvPixelBuffer: cameraBuffer), into: ciCameraRect)
        let expectedMaskStages = compositor.greenScreenMatteStages(aspectFilledMask: maskFilledForExpected,
                                                                    in: ciCameraRect,
                                                                    guidedBy: cameraFilledForExpected,
                                                                    refinementMode: .s4SoftAlphaR2)
        let refinedMaskDebugBuffer = renderMaskDebugBuffer(expectedMaskStages.finalMask,
                                                            using: compositor,
                                                            bounds: sourceRect,
                                                            width: 64, height: 64)

        var sampledRefinedMaskAlpha128: Int?
        var sampledRefinedMaskAlpha64: Int?
        if let maskDebugBuffer = refinedMaskDebugBuffer {
            CVPixelBufferLockBaseAddress(maskDebugBuffer, .readOnly)
            sampledRefinedMaskAlpha128 = readBGRAPixel(maskDebugBuffer, x: 20, y: 40)?.r
            sampledRefinedMaskAlpha64  = readBGRAPixel(maskDebugBuffer, x: 40, y: 40)?.r
            CVPixelBufferUnlockBaseAddress(maskDebugBuffer, .readOnly)
        } else {
            fail("refined_mask_debug_buffer_creation_failed")
        }
        // -1 sentinel (never a valid 0-255 mask byte) marks a sample that could not be
        // read, instead of bridging a Swift Optional through the Flutter method channel.
        details["refinedMaskForExpected"] = [
            "refinementMode": refinementModeUsedForExpected,
            "sampledAlphaAt_20_40": sampledRefinedMaskAlpha128 ?? -1,
            "sampledAlphaAt_40_40": sampledRefinedMaskAlpha64 ?? -1,
        ]

        // 4. Sample and assert.
        //
        // Orientation: an offline standalone CoreImage probe run against this exact
        // geometry (64x64 canvas, cameraRect x=16 y=16 width=32 height=32, mask quadrants
        // as above) confirmed that the mask buffer's memory row 0 (top, as authored) renders
        // to the TOP of the camera rect in the OUTPUT buffer's memory — i.e. no additional
        // vertical flip is introduced by ciRect(fromTopLeft:) + aspectFill + CIBlendWithMask
        // beyond the rect-position flip already documented at the top of this file. This
        // cameraRect is vertically symmetric in the 64-tall canvas (top offset 16 == bottom
        // offset 64-16-32=16), which is why the position flip is a no-op here. Sample
        // coordinates below are output-buffer (x,y) in top-left terms and match the probe's
        // observed quadrant layout exactly.
        details["orientationNote"] =
            "Mask memory row 0 (top) renders to the top of cameraRect in the output buffer " +
            "for this symmetric geometry; verified via an offline CoreImage probe, not assumed."
        details["blendFormula"] =
            "output = round(foreground * (refinedMaskByte/255) + background * (1 - refinedMaskByte/255)) " +
            "per channel, where refinedMaskByte is the actual VGMatteRefinementPipeline-refined " +
            "(s4SoftAlphaR2) mask value sampled at the same output coordinate, not the raw authored " +
            "quadrant byte fed into VGLiveGreenScreenCompositor.composite()'s greenScreenMask argument"

        CVPixelBufferLockBaseAddress(output, .readOnly)
        var lockedReadsOk = true

        func sample(_ label: String, x: Int, y: Int, expected: (r: Int, g: Int, b: Int), group: String) {
            guard let pixel = readBGRAPixel(output, x: x, y: y) else {
                lockedReadsOk = false
                fail("sample_read_failed_\(label)")
                return
            }
            let dR = abs(pixel.r - expected.r)
            let dG = abs(pixel.g - expected.g)
            let dB = abs(pixel.b - expected.b)
            let delta = max(dR, max(dG, dB))
            maxDelta = max(maxDelta, delta)
            sampleCount += 1
            if delta > pixelProofTolerance {
                mismatches.append(
                    "label=\(label) group=\(group) loc=(\(x),\(y)) " +
                    "actual=(\(pixel.r),\(pixel.g),\(pixel.b)) " +
                    "expected=(\(expected.r),\(expected.g),\(expected.b)) delta=\(delta)")
                switch group {
                case "exterior": viewportExteriorAllOk = false
                case "boundary": boundaryKeyingAllOk = false
                case "fraction": fractionalAllOk = false
                default: break
                }
            }
        }

        let bg = backgroundColor
        let fg = foregroundColor

        // Exterior: outside camera rect [16,48) x [16,48) — must remain untouched background.
        sample("ext_top_left_corner",     x: 2,  y: 2,  expected: bg, group: "exterior")
        sample("ext_bottom_right_corner", x: 61, y: 61, expected: bg, group: "exterior")
        sample("ext_above_camera",        x: 32, y: 2,  expected: bg, group: "exterior")
        sample("ext_left_of_camera",      x: 2,  y: 32, expected: bg, group: "exterior")

        // Boundary keying: alpha=0 keys out to pure background, alpha=255 keys in pure foreground.
        sample("mask_alpha0_quadrant",   x: 20, y: 20, expected: bg, group: "boundary")
        sample("mask_alpha255_quadrant", x: 40, y: 20, expected: fg, group: "boundary")

        // Fractional blend math: assert the composited pixel against the linear
        // foreground/background mix of the *actual* refined mask byte sampled at this
        // coordinate (see step 3b) rather than the raw authored quadrant byte (128/64),
        // since VGMatteRefinementPipeline measurably shifts these interior sample points.
        if let alpha128 = sampledRefinedMaskAlpha128 {
            sample("mask_alpha128_quadrant", x: 20, y: 40, expected: expectedMix(alpha: alpha128), group: "fraction")
        } else {
            fractionalAllOk = false
            fail("refined_mask_sample_failed_mask_alpha128_quadrant")
            mismatches.append("label=mask_alpha128_quadrant group=fraction refined_mask_sample_unavailable")
        }
        if let alpha64 = sampledRefinedMaskAlpha64 {
            sample("mask_alpha64_quadrant", x: 40, y: 40, expected: expectedMix(alpha: alpha64), group: "fraction")
        } else {
            fractionalAllOk = false
            fail("refined_mask_sample_failed_mask_alpha64_quadrant")
            mismatches.append("label=mask_alpha64_quadrant group=fraction refined_mask_sample_unavailable")
        }

        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        gates["cleanupOk"] = lockedReadsOk
        if !lockedReadsOk {
            fail("sample_readback_or_cleanup_failed")
        }

        gates["viewportExteriorOk"] = viewportExteriorAllOk
        gates["boundaryKeyingOk"] = boundaryKeyingAllOk
        gates["fractionalBlendMathOk"] = fractionalAllOk
        if !viewportExteriorAllOk { fail("viewport_exterior_mismatch") }
        if !boundaryKeyingAllOk { fail("boundary_keying_mismatch") }
        if !fractionalAllOk { fail("fractional_blend_math_mismatch") }

        // "canonical": this run actually exercised the primary CIBlendWithMask code path
        // (not the "filter unavailable" opaque-overlay fallback) and every gate agrees.
        gates["canonical"] = gates["blendFilterOk"] == true
            && gates["compositorInitOk"] == true
            && gates["syntheticBuffersOk"] == true
            && viewportExteriorAllOk && boundaryKeyingAllOk && fractionalAllOk

        // ─────────────────────────────────────────────────────────────────
        // 5. DEC-V2-123C follow-up: Duet straight-alpha foreground
        //    free-transform rotation / off-canvas rendered pixel proof.
        //
        //    Everything above proves VGLiveGreenScreenCompositor's
        //    CIBlendWithMask green-screen path only (see this file's header)
        //    and is completely untouched by this lane. This lane instead
        //    instantiates a REAL VGDuetPreviewCompositor(canvasWidth: 64,
        //    canvasHeight: 64) and drives its cameraFrameUsesStraightAlpha:
        //    true composite() path directly, proving the RENDERED pixel
        //    behavior of VGDuetPreviewCompositor.rotateCameraLayer -- which
        //    example/lib/ios_duet_green_screen_preview_physical_smoke.dart's
        //    VG_IOS_DUET_GREENSCREEN_PREVIEW_ROTATION_PROOF lane explicitly
        //    does NOT claim (it proves the preview stays alive across a
        //    rotation update, not any rendered pixel/visual-placement
        //    outcome). Synthetic CVPixelBuffers only; never touches a real
        //    camera, decoder, AVCaptureSession, or the GreenScreen
        //    compositor/buffers above.
        //
        //    Test pattern (32x32 straight-alpha BGRA "two-arm" cross, local
        //    coordinates, quarter = width/4 = height/4 = 8px):
        //      "right arm"  x:[24,32) y:[8,24)  -> opaque foreground colour.
        //      "lower arm"  x:[8,24)  y:[24,32) -> opaque foreground colour.
        //      every other pixel (both corners, the top arm, the left arm,
        //      the centre) -> fully transparent, RGB *and* alpha zeroed,
        //      matching the straight-alpha "transparent means rgb=0 too"
        //      convention VGGreenScreenFilterNode's production alpha output
        //      already guarantees. Every block is >=8px so a sample point at
        //      a block's centre is unaffected by bilinear-resampling
        //      interpolation at its edges (large-block-samples requirement).
        //
        //    cameraRect = (16,16,32,32) on the 64x64 canvas (fully on-canvas,
        //    so ciRect(fromTopLeft:) never clips it -- aspectFill's "cover"
        //    scale is exactly 1.0 and local (lx,ly) maps to canvas
        //    (16+lx,16+ly) with no recentring). Four fixed sample points,
        //    each at a block centre:
        //      "right sample" local (28,16) -> canvas (44,32) (right-arm centre)
        //      "lower sample" local (16,28) -> canvas (32,44) (lower-arm centre)
        //      "left sample"  local (4,16)  -> canvas (20,32) (left-arm-band centre, transparent)
        //      "top sample"   local (16,4)  -> canvas (32,20) (top-arm-band centre, transparent)
        //      "corner sample" local (4,4)  -> canvas (20,20) (corner, always transparent)
        //
        //    Rotation math independently re-derived from rotateCameraLayer's
        //    own transform (radians = -rotationDegrees * pi/180, applied via
        //    CGAffineTransform(rotationAngle:) in CoreImage's Y-up space,
        //    where positive angles are counter-clockwise): for
        //    cameraRotationDegrees: 90.0, a point to the right of the pivot
        //    in CI space maps to a point below the pivot (CI-Y decreases,
        //    i.e. toward the visual bottom of the canvas), and a point below
        //    the pivot maps to a point left of the pivot -- exactly the
        //    "right-side arm moves to lower sample; lower arm moves to left
        //    sample" rendered behavior already confirmed by the physical
        //    rotation smoke run referenced above. X is never flipped between
        //    top-left and CI space (only Y is, by ciRect(fromTopLeft:)), so
        //    this holds in the same top-left sample coordinates used
        //    throughout this proof.
        var straightAlphaRotation0AllOk = true
        var straightAlphaRotation90AllOk = true
        var straightAlphaRgbAlphaCoTransformAllOk = true
        var straightAlphaOffCanvasClipAllOk = true

        let saBackgroundColor: (r: Int, g: Int, b: Int) = (30, 90, 200)
        let saForegroundColor: (r: Int, g: Int, b: Int) = (240, 180, 20)

        // Shared mismatch/maxDelta/sampleCount accounting with the GreenScreen
        // lane above (same finalize() reads them), reading from an explicit
        // `buffer` parameter instead of `sample()`'s closure-captured
        // GreenScreen `output` above -- this lane renders three *different*
        // output buffers (rotation 0 / rotation 90 / off-canvas), never that one.
        func sampleInBuffer(_ buffer: CVPixelBuffer, _ label: String, x: Int, y: Int,
                            expected: (r: Int, g: Int, b: Int), group: String) {
            guard let pixel = readBGRAPixel(buffer, x: x, y: y) else {
                fail("straight_alpha_sample_read_failed_\(label)")
                switch group {
                case "straightAlphaRotation0": straightAlphaRotation0AllOk = false
                case "straightAlphaRotation90": straightAlphaRotation90AllOk = false
                case "straightAlphaRgbAlphaCoTransform": straightAlphaRgbAlphaCoTransformAllOk = false
                case "straightAlphaOffCanvasClip": straightAlphaOffCanvasClipAllOk = false
                default: break
                }
                return
            }
            let dR = abs(pixel.r - expected.r)
            let dG = abs(pixel.g - expected.g)
            let dB = abs(pixel.b - expected.b)
            let delta = max(dR, max(dG, dB))
            maxDelta = max(maxDelta, delta)
            sampleCount += 1
            if delta > pixelProofTolerance {
                mismatches.append(
                    "label=\(label) group=\(group) loc=(\(x),\(y)) " +
                    "actual=(\(pixel.r),\(pixel.g),\(pixel.b)) " +
                    "expected=(\(expected.r),\(expected.g),\(expected.b)) delta=\(delta)")
                switch group {
                case "straightAlphaRotation0": straightAlphaRotation0AllOk = false
                case "straightAlphaRotation90": straightAlphaRotation90AllOk = false
                case "straightAlphaRgbAlphaCoTransform": straightAlphaRgbAlphaCoTransformAllOk = false
                case "straightAlphaOffCanvasClip": straightAlphaOffCanvasClipAllOk = false
                default: break
                }
            }
        }

        guard let saSourceBuffer = makeConstantBGRABuffer(width: 64, height: 64,
                                                           r: saBackgroundColor.r, g: saBackgroundColor.g, b: saBackgroundColor.b),
              let saCameraBuffer = makeStraightAlphaArmPatternBuffer(width: 32, height: 32,
                                                                      r: saForegroundColor.r, g: saForegroundColor.g, b: saForegroundColor.b)
        else {
            fail("straight_alpha_synthetic_buffer_creation_failed")
            straightAlphaRotation0AllOk = false
            straightAlphaRotation90AllOk = false
            straightAlphaRgbAlphaCoTransformAllOk = false
            straightAlphaOffCanvasClipAllOk = false
            gates["straightAlphaRotation0Ok"] = false
            gates["straightAlphaRotation90Ok"] = false
            gates["straightAlphaRgbAlphaCoTransformOk"] = false
            gates["straightAlphaOffCanvasClipOk"] = false
            gates["rotationCanonicalOk"] = false
            return finalize()
        }

        let saCompositor = VGDuetPreviewCompositor(canvasWidth: 64, canvasHeight: 64)
        let saSourceRect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let saCameraRect = CGRect(x: 16, y: 16, width: 32, height: 32)

        details["straightAlpha"] = [
            "background": [saBackgroundColor.r, saBackgroundColor.g, saBackgroundColor.b],
            "foreground": [saForegroundColor.r, saForegroundColor.g, saForegroundColor.b],
            "cameraRect": ["x": 16, "y": 16, "width": 32, "height": 32],
            "pattern": "32x32 straight-alpha two-arm cross: right arm x:[24,32) y:[8,24) + " +
                       "lower arm x:[8,24) y:[24,32) opaque foreground; corners/top arm/left " +
                       "arm/centre transparent (alpha 0, rgb 0)",
        ]

        // 5a. Rotation 0 (identity): right arm at the right sample, lower arm at the
        //     lower sample, transparent regions reveal background.
        if let out0 = saCompositor.composite(sourceFrame: saSourceBuffer,
                                              sourceRect: saSourceRect,
                                              cameraRect: saCameraRect,
                                              cameraFrame: saCameraBuffer,
                                              cameraFrameUsesStraightAlpha: true,
                                              cameraRotationDegrees: 0.0,
                                              cameraAnchorX: 0.5,
                                              cameraAnchorY: 0.5) {
            CVPixelBufferLockBaseAddress(out0, .readOnly)
            sampleInBuffer(out0, "sa_rot0_right_arm", x: 44, y: 32,
                           expected: saForegroundColor, group: "straightAlphaRotation0")
            sampleInBuffer(out0, "sa_rot0_lower_arm", x: 32, y: 44,
                           expected: saForegroundColor, group: "straightAlphaRotation0")
            sampleInBuffer(out0, "sa_rot0_left_transparent", x: 20, y: 32,
                           expected: saBackgroundColor, group: "straightAlphaRotation0")
            sampleInBuffer(out0, "sa_rot0_top_transparent", x: 32, y: 20,
                           expected: saBackgroundColor, group: "straightAlphaRotation0")
            sampleInBuffer(out0, "sa_rot0_corner_transparent", x: 20, y: 20,
                           expected: saBackgroundColor, group: "straightAlphaRotation0")
            CVPixelBufferUnlockBaseAddress(out0, .readOnly)
        } else {
            straightAlphaRotation0AllOk = false
            fail("straight_alpha_rotation0_composite_returned_nil")
        }

        // 5b/5c. Rotation 90 clockwise around the rect centre anchor: the right arm's
        //     content moves to the lower sample and the lower arm's content moves to
        //     the left sample; the (now vacated) right/top positions read back as pure
        //     background. The two positions whose expected alpha state FLIPPED between
        //     rotation 0 and rotation 90 (right: opaque->transparent; left:
        //     transparent->opaque) are re-asserted as their own
        //     straightAlphaRgbAlphaCoTransform group: a bug that rotated alpha without
        //     RGB (or vice versa) would produce a wrong-hue partial pixel at one of
        //     these two positions instead of an exact background/foreground match,
        //     proving RGB and alpha moved together through the rotation.
        if let out90 = saCompositor.composite(sourceFrame: saSourceBuffer,
                                               sourceRect: saSourceRect,
                                               cameraRect: saCameraRect,
                                               cameraFrame: saCameraBuffer,
                                               cameraFrameUsesStraightAlpha: true,
                                               cameraRotationDegrees: 90.0,
                                               cameraAnchorX: 0.5,
                                               cameraAnchorY: 0.5) {
            CVPixelBufferLockBaseAddress(out90, .readOnly)
            sampleInBuffer(out90, "sa_rot90_right_now_transparent", x: 44, y: 32,
                           expected: saBackgroundColor, group: "straightAlphaRotation90")
            sampleInBuffer(out90, "sa_rot90_lower_now_colored", x: 32, y: 44,
                           expected: saForegroundColor, group: "straightAlphaRotation90")
            sampleInBuffer(out90, "sa_rot90_left_now_colored", x: 20, y: 32,
                           expected: saForegroundColor, group: "straightAlphaRotation90")
            sampleInBuffer(out90, "sa_rot90_top_now_transparent", x: 32, y: 20,
                           expected: saBackgroundColor, group: "straightAlphaRotation90")
            sampleInBuffer(out90, "sa_rot90_corner_still_transparent", x: 20, y: 20,
                           expected: saBackgroundColor, group: "straightAlphaRotation90")

            sampleInBuffer(out90, "sa_co_transform_right_pure_background", x: 44, y: 32,
                           expected: saBackgroundColor, group: "straightAlphaRgbAlphaCoTransform")
            sampleInBuffer(out90, "sa_co_transform_left_pure_foreground", x: 20, y: 32,
                           expected: saForegroundColor, group: "straightAlphaRgbAlphaCoTransform")
            CVPixelBufferUnlockBaseAddress(out90, .readOnly)
        } else {
            straightAlphaRotation90AllOk = false
            straightAlphaRgbAlphaCoTransformAllOk = false
            fail("straight_alpha_rotation90_composite_returned_nil")
        }

        // 5d. Off-canvas placement: cameraRect (48,16,32,32) extends 16px past the
        //     right edge of the 64x64 canvas (only canvas x:48-64 is on-canvas; x:64-80
        //     is clipped). Uses a SEPARATE, spatially-uniform fully-opaque straight-alpha
        //     foreground buffer (not the arm pattern above) specifically so this
        //     assertion is independent of exactly how aspectFill's "cover" scale
        //     re-centres content once ciRect(fromTopLeft:) has already clipped the
        //     destination rect -- with a uniform fill, any in-canvas point still
        //     geometrically inside the rendered camera layer reads the same foreground
        //     colour regardless of that recentring, so this proves the off-canvas
        //     placement renders and clips safely without depending on sub-pixel
        //     aspect-fill geometry this proof does not otherwise need to model.
        let saOffCanvasRect = CGRect(x: 48, y: 16, width: 32, height: 32)
        if let saOffCanvasCameraBuffer = makeConstantBGRABuffer(width: 32, height: 32,
                                                                  r: saForegroundColor.r, g: saForegroundColor.g, b: saForegroundColor.b),
           let outOffCanvas = saCompositor.composite(sourceFrame: saSourceBuffer,
                                                       sourceRect: saSourceRect,
                                                       cameraRect: saOffCanvasRect,
                                                       cameraFrame: saOffCanvasCameraBuffer,
                                                       cameraFrameUsesStraightAlpha: true,
                                                       cameraRotationDegrees: 0.0,
                                                       cameraAnchorX: 0.5,
                                                       cameraAnchorY: 0.5) {
            CVPixelBufferLockBaseAddress(outOffCanvas, .readOnly)
            // Well inside both cameraRect and the canvas (canvas x:48-64 visible span).
            sampleInBuffer(outOffCanvas, "sa_offcanvas_visible_foreground", x: 56, y: 32,
                           expected: saForegroundColor, group: "straightAlphaOffCanvasClip")
            // Well outside cameraRect (x:48-80) entirely: untouched pure background.
            sampleInBuffer(outOffCanvas, "sa_offcanvas_untouched_background", x: 4, y: 4,
                           expected: saBackgroundColor, group: "straightAlphaOffCanvasClip")
            CVPixelBufferUnlockBaseAddress(outOffCanvas, .readOnly)
            details["straightAlphaOffCanvas"] = [
                "cameraRect": ["x": 48, "y": 16, "width": 32, "height": 32],
                "canvasSize": ["width": 64, "height": 64],
                "clippedPastRightEdgePx": 16,
            ]
        } else {
            straightAlphaOffCanvasClipAllOk = false
            fail("straight_alpha_offcanvas_buffer_or_composite_failed")
        }

        gates["straightAlphaRotation0Ok"] = straightAlphaRotation0AllOk
        gates["straightAlphaRotation90Ok"] = straightAlphaRotation90AllOk
        gates["straightAlphaRgbAlphaCoTransformOk"] = straightAlphaRgbAlphaCoTransformAllOk
        gates["straightAlphaOffCanvasClipOk"] = straightAlphaOffCanvasClipAllOk
        gates["rotationCanonicalOk"] = straightAlphaRotation0AllOk
            && straightAlphaRotation90AllOk
            && straightAlphaRgbAlphaCoTransformAllOk
            && straightAlphaOffCanvasClipAllOk

        if !straightAlphaRotation0AllOk { fail("straight_alpha_rotation0_mismatch") }
        if !straightAlphaRotation90AllOk { fail("straight_alpha_rotation90_mismatch") }
        if !straightAlphaRgbAlphaCoTransformAllOk { fail("straight_alpha_rgb_alpha_co_transform_mismatch") }
        if !straightAlphaOffCanvasClipAllOk { fail("straight_alpha_offcanvas_clip_mismatch") }

        return finalize()
    }

    // MARK: - Diagnostic buffer helpers (synthetic inputs only; never touch live camera/decoder)

    private static func makeConstantBGRABuffer(width: Int, height: Int, r: Int, g: Int, b: Int, a: Int = 255) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let byteR = UInt8(clamping: r), byteG = UInt8(clamping: g), byteB = UInt8(clamping: b), byteA = UInt8(clamping: a)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4 + 0] = byteB
                row[x * 4 + 1] = byteG
                row[x * 4 + 2] = byteR
                row[x * 4 + 3] = byteA
            }
        }
        return buffer
    }

    private static func makeQuadrantMaskBuffer(width: Int, height: Int,
                                                topLeft: Int, topRight: Int,
                                                bottomLeft: Int, bottomRight: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_OneComponent8, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let halfW = width / 2
        let halfH = height / 2
        let tl = UInt8(clamping: topLeft), tr = UInt8(clamping: topRight)
        let bl = UInt8(clamping: bottomLeft), br = UInt8(clamping: bottomRight)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let isTop = y < halfH
            for x in 0..<width {
                let isLeft = x < halfW
                row[x] = isTop ? (isLeft ? tl : tr) : (isLeft ? bl : br)
            }
        }
        return buffer
    }

    /// DEC-V2-123C follow-up: synthetic `width` x `height` straight-alpha BGRA
    /// "two-arm cross" test pattern for `VGDuetPreviewCompositor`'s straight-alpha
    /// foreground path (`cameraFrameUsesStraightAlpha: true`): a "right arm" opaque
    /// block spanning local `x:[3/4 width, width), y:[1/4 height, 3/4 height)` and a
    /// "lower arm" opaque block spanning local `x:[1/4 width, 3/4 width), y:[3/4
    /// height, height)`, both in `(r, g, b, 255)`; every other pixel (both corners,
    /// the top arm, the left arm, the centre) is fully transparent with RGB also
    /// zeroed (`(0, 0, 0, 0)`), matching the straight-alpha "transparent means rgb=0
    /// too" convention `VGGreenScreenFilterNode`'s production alpha output already
    /// guarantees. Every block is a `width/4` x `height/4` (or larger) uniform region,
    /// so a sample point at a block's centre is never affected by bilinear-resampling
    /// interpolation at its edges.
    private static func makeStraightAlphaArmPatternBuffer(width: Int, height: Int,
                                                            r: Int, g: Int, b: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let byteR = UInt8(clamping: r), byteG = UInt8(clamping: g), byteB = UInt8(clamping: b)
        let quarterW = width / 4
        let quarterH = height / 4
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let inRightArmBand = y >= quarterH && y < (3 * quarterH)
            let inLowerArmBand = y >= (3 * quarterH)
            for x in 0..<width {
                let isRightArm = inRightArmBand && x >= (3 * quarterW)
                let isLowerArm = inLowerArmBand && x >= quarterW && x < (3 * quarterW)
                let opaque = isRightArm || isLowerArm
                row[x * 4 + 0] = opaque ? byteB : 0
                row[x * 4 + 1] = opaque ? byteG : 0
                row[x * 4 + 2] = opaque ? byteR : 0
                row[x * 4 + 3] = opaque ? 255 : 0
            }
        }
        return buffer
    }

    /// Renders a mask `CIImage` (e.g. a `VGMatteRefinementPipeline`-refined mask) into a
    /// scratch BGRA buffer using the same `compositor`-owned `CIContext` and the same
    /// `bounds` rect `VGLiveGreenScreenCompositor.composite()` renders its own output
    /// with, so a later `readBGRAPixel` call against this buffer maps to the same
    /// top-left (x,y) coordinates already verified for the real output buffer (see the
    /// orientation note above). Never touches the compositor's own pool; purely a local
    /// diagnostic scratch buffer for expected-value sampling. Grayscale-sourced images
    /// render with R == G == B == the mask byte, so any channel (here `.r`) reads it back.
    private static func renderMaskDebugBuffer(_ mask: CIImage,
                                               using compositor: VGLiveGreenScreenCompositor,
                                               bounds: CGRect,
                                               width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        compositor.ciContext.render(mask, to: buffer, bounds: bounds, colorSpace: nil)
        return buffer
    }

    /// Reads one BGRA pixel from a buffer already locked (`.readOnly`) by the caller.
    private static func readBGRAPixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        let b = Int(row[x * 4 + 0])
        let g = Int(row[x * 4 + 1])
        let r = Int(row[x * 4 + 2])
        let a = Int(row[x * 4 + 3])
        return (r, g, b, a)
    }
}
