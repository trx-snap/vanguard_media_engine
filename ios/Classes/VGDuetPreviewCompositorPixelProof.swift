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
    /// Never throws; every failure mode is captured in the returned map's
    /// `failureReason`/`mismatches` instead.
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
