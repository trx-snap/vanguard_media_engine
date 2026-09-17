// VGDuetPreviewCompositor.swift
// VG-DUET-SLICE-4B-B: CoreImage compositor for the Duet preview texture.
//
// Responsibilities:
//   - Owns a Metal-backed CIContext (CPU fallback when no Metal device exists).
//   - Owns a BGRA, Metal-compatible, IOSurface-backed CVPixelBufferPool at a
//     fixed canvas size.
//   - composite(): dark canvas + aspect-filled source frame in sourceRect +
//     deterministic camera placeholder in cameraRect.
//
// Explicitly NOT in this slice: camera capture, green-screen keying, audio,
// export.  The camera placeholder is a static visual so that layout geometry
// can be verified on-device before camera capture lands.
//
// Coordinate systems:
//   Layout rects (VGDuetLayoutGeometry) are canvas-pixel rects with a TOP-LEFT
//   origin.  CoreImage renders with a BOTTOM-LEFT origin.  ciRect(fromTopLeft:)
//   flips Y and snaps edges to whole pixels, so geometry intent is preserved to
//   within 1 px.
//
// Production green-screen mask refinement pipeline:
// The aspect-filled L8 mask is refined at output (canvas) scale before CIBlendWithMask:
//   morphology close -> feather -> trimap -> guided edge preserve -> CIBlendWithMask
//
// Refinement stages:
//   1. applyGreenScreenMorphologyClose — morphological close (CIMorphologyMaximum dilate,
//      then CIMorphologyMinimum erode, radius 1.0; r1b). Clamped to extent before dilate,
//      cropped to a finite radius-padded rect before erode to ensure bounded input and
//      prevent EXC_BAD_ACCESS, filling pinholes and stair-step bites before blur.
//   2. featherGreenScreenMask — CIGaussianBlur at feather radius 3.0 px softens the mask.
//   3. applyGreenScreenTrimap — remaps blurred mask luminance via smoothstep(0.14, 0.86, m)
//      to establish definite foreground/background regions with a widened transition band.
//   4. applyGreenScreenGuidedEdgePreserve — restores the pre-trimap feathered mask wherever
//      the camera frame has strong edges (CIEdges intensity 2.0, blur 1.5, smoothstep
//      0.08/0.34), preserving fine detail (hair, fingers) while keeping flat regions clean.
//   5. CIBlendWithMask — composites aspect-filled camera frame over canvas background using
//      the refined mask.
//
// Fail-open behavior:
// Each refinement stage is fail-open to its input: if a required CoreImage filter is
// unavailable or inputs are degenerate, the stage is skipped and the previous stage's
// output is used unchanged, so the worst case is the raw unmodified mask. CIBlendWithMask
// is never skipped due to refinement failure; only if CIBlendWithMask itself is unavailable
// does composition fall back to opaque camera overlay.
//
// Production stack & physical proof summary:
// iOS live green-screen edge smoothness A/B S1: Vision Fast default + compositor refinement
// (morphology close r1b radius 1.0, feather 3.0, trimap 0.14/0.86, guided edge
// constants 2.0/1.5/0.08/0.34).
// Rationale: S1 widens output-scale anti-aliased alpha transition to reduce visible edge pixelation
// while preserving the already-proved Vision Fast backend, 512 matte publish geometry,
// camera aspect/orientation, and morphology r1b crash fix.
// Physical proof baseline: clean-copy Vision Fast avgTotalMs ≈ 13.9 ms, degradedEventCount 0.
//
// Deterministic pixel proof note:
// The in-file deterministic pixel proof (runDeterministicPixelProof, reached via
// VGDuetMethodHandler) was authored for linear blending. Because mask refinement is
// nonlinear (specifically, trimap smoothstep remaps mask byte 64 [~0.251] to ~0.034,
// which trips fractionalBlendMathOk), deterministic pixel proof must be rebaselined
// separately if used with the production refinement pipeline active.
//
// Threading: composite() is expected to be called from a single serial queue
// (the render loop's render queue).  The CIContext and pool are immutable
// after init and are themselves thread-safe.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

final class VGDuetPreviewCompositor {

    // MARK: - Canvas

    let canvasWidth: Int
    let canvasHeight: Int

    var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }
    private var canvasBounds: CGRect { CGRect(origin: .zero, size: canvasSize) }

    // MARK: - Rendering resources

    /// Compositor-owned CIContext.  Backed by a single process-wide context
    /// (CIContext is thread-safe and expensive to create), so repeated
    /// attach/detach cycles do not pay the Metal pipeline warm-up cost again.
    private let ciContext: CIContext

    /// Output pool.  BGRA + Metal compatible + IOSurface backed so Flutter's
    /// texture path can consume buffers directly.  nil when creation failed;
    /// composite() then returns nil and the render loop simply skips presenting.
    private let pool: CVPixelBufferPool?

    /// Bounds outstanding pool allocations (texture-held + Flutter-held +
    /// in-render).  Exceeding it yields a dropped frame, never unbounded growth.
    private static let allocationThreshold = 6

    private let poolAuxAttributes: [String: Any] = [
        kCVPixelBufferPoolAllocationThresholdKey as String: VGDuetPreviewCompositor.allocationThreshold,
    ]

    // MARK: - Palette (deterministic)

    private static let canvasColor      = CIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)
    private static let placeholderFill  = CIColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1.0)
    private static let placeholderEdge  = CIColor(red: 0.34, green: 0.37, blue: 0.44, alpha: 1.0)
    private static let placeholderGlow  = CIColor(red: 0.30, green: 0.33, blue: 0.40, alpha: 1.0)
    private static let placeholderEdgePx: CGFloat = 2.0

    /// Alpha used when the camera rect fully covers the source rect (green
    /// screen / degenerate layouts).  Keeps the source visible instead of
    /// occluding it with an opaque placeholder.
    private static let overlayAlpha: CGFloat = 0.28

    /// Production mask refinement: morphological close (CIMorphologyMaximum dilate then
    /// CIMorphologyMinimum erode, radius 1.0; r1b) applied before feathering to fill tiny
    /// stair-step bites and pinholes in the raw matte.
    /// The IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST log prints
    /// maskMorphologyCloseEnabled / maskMorphologyCloseApplied /
    /// maskMorphologyCloseRadius.
    private static let greenScreenMaskMorphologyCloseEnabled: Bool = true
    private static let greenScreenMaskMorphologyCloseRadius: CGFloat = 1.0

    /// Production mask refinement: feather radius, in canvas pixels, applied as a
    /// CIGaussianBlur `inputRadius` to soften the closed mask at output scale before
    /// CIBlendWithMask (production constant: 3.0 px, S1 edge smoothness A/B).
    /// The IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST log prints this value as
    /// maskFeatherRadius.
    private static let greenScreenMaskFeatherRadius: CGFloat = 3.0

    /// Production mask refinement: trimap / alpha-curve pass remapping mask luminance m
    /// through smoothstep(greenScreenTrimapLow, greenScreenTrimapHigh, m) to produce
    /// solid foreground/background bands with a widened soft edge (production constants: 0.14 / 0.86, S1).
    /// The IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST log prints
    /// maskTrimapEnabled / maskTrimapApplied / maskTrimapLow / maskTrimapHigh.
    private static let greenScreenTrimapEnabled: Bool = true
    private static let greenScreenTrimapLow:  CGFloat = 0.14
    private static let greenScreenTrimapHigh: CGFloat = 0.86

    /// Production mask refinement: guided-edge-preservation pass restoring the
    /// pre-trimap feathered mask wherever the camera frame has strong edges
    /// (production constants: intensity 2.0, blur radius 1.5, smoothstep 0.08/0.34, S1),
    /// preserving thin detail (hair, fingers) while keeping flat regions cleanly keyed.
    /// The IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST log prints maskGuidedEdgeEnabled /
    /// maskGuidedEdgeApplied / maskGuidedEdgeIntensity / maskGuidedEdgeBlurRadius /
    /// maskGuidedEdgeLow / maskGuidedEdgeHigh.
    private static let greenScreenGuidedEdgeEnabled: Bool = true
    private static let greenScreenGuidedEdgeIntensity: CGFloat = 2.0
    private static let greenScreenGuidedEdgeBlurRadius: CGFloat = 1.5
    private static let greenScreenGuidedEdgeLow: CGFloat = 0.08
    private static let greenScreenGuidedEdgeHigh: CGFloat = 0.34

    /// One-time diagnostic marker: set to true after the first successful
    /// CIBlendWithMask composite.  Guards against log spam on every frame.
    private var _hasLoggedFirstMaskBlend = false

    private static let sharedContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        NSLog("[VGDuetPreviewCompositor] MTLCreateSystemDefaultDevice nil — CPU CIContext fallback")
        return CIContext(options: options)
    }()

    // MARK: - Init

    init(canvasWidth: Double, canvasHeight: Double) {
        let width  = max(2, Int(canvasWidth.rounded()))
        let height = max(2, Int(canvasHeight.rounded()))
        self.canvasWidth  = width
        self.canvasHeight = height
        self.ciContext    = VGDuetPreviewCompositor.sharedContext
        self.pool         = VGDuetPreviewCompositor.makePool(width: width, height: height)
    }

    // MARK: - Composite

    /// Renders one preview frame.
    ///
    /// - Parameters:
    ///   - sourceFrame:     decoded source frame (BGRA).  nil draws canvas + placeholder only.
    ///   - sourceRect:      top-left-origin canvas rect for the source (aspect-fill).
    ///   - cameraRect:      top-left-origin canvas rect for the camera slot.
    ///   - cameraFrame:     live camera frame (BGRA).  When non-nil, aspect-filled into cameraRect.
    ///                      When nil, the deterministic camera placeholder is drawn instead.
    ///   - isGreenScreen:   when true, attempt CIBlendWithMask keying instead of opaque overlay.
    ///   - greenScreenMask: single-channel (L8) mask buffer; 255 = subject (foreground).
    ///                      Nil or unavailable falls back to the camera-over-source preview.
    /// - Returns: a pool-backed BGRA buffer, or nil when the pool is exhausted / unavailable.
    func composite(sourceFrame: CVPixelBuffer?,
                   sourceRect: CGRect,
                   cameraRect: CGRect,
                   cameraFrame: CVPixelBuffer? = nil,
                   isGreenScreen: Bool = false,
                   greenScreenMask: CVPixelBuffer? = nil) -> CVPixelBuffer? {
        guard let pool = pool else { return nil }

        var outBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, poolAuxAttributes as CFDictionary, &outBuffer)
        guard status == kCVReturnSuccess, let output = outBuffer else {
            return nil
        }

        let bounds = canvasBounds
        var image = CIImage(color: VGDuetPreviewCompositor.canvasColor).cropped(to: bounds)

        let ciSource = ciRect(fromTopLeft: sourceRect)
        if let frame = sourceFrame, !ciSource.isEmpty {
            let sourceImage = CIImage(cvPixelBuffer: frame)
            image = aspectFill(sourceImage, into: ciSource).composited(over: image)
        }

        let ciCamera = ciRect(fromTopLeft: cameraRect)
        if !ciCamera.isEmpty {
            if isGreenScreen, let camFrame = cameraFrame, let maskBuffer = greenScreenMask {
                // Green-screen path: CIBlendWithMask.
                //   foreground = aspect-filled camera into cameraRect
                //   background = current composed source canvas (image)
                //   mask       = aspect-filled segmentation mask into cameraRect
                // The filter replaces pixels where mask ~= 255 (subject) with the foreground.
                // The mapped mask is refined at output scale first (see
                // refineGreenScreenMask: morphology close, then 3.0 px feather,
                // then trimap smoothstep, then camera-guided edge preservation);
                // a failed morphology close falls back to the raw mask, a failed
                // feather falls back to the (possibly closed) unblurred mask, a
                // failed trimap falls back to the blurred mask, and a failed
                // guided-edge pass falls back to the trimapped mask — never to
                // the camera overlay.
                // Falls through to the opaque-overlay path if the blend filter is unavailable.
                let camFilled  = aspectFill(CIImage(cvPixelBuffer: camFrame),   into: ciCamera)
                let maskFilled = aspectFill(CIImage(cvPixelBuffer: maskBuffer), into: ciCamera)
                let refined    = refineGreenScreenMask(maskFilled, in: ciCamera, guidedBy: camFilled)
                let params: [String: Any] = [
                    "inputBackgroundImage": image,
                    "inputImage":           camFilled,
                    "inputMaskImage":       refined.mask,
                ]
                if let blended = CIFilter(name: "CIBlendWithMask", parameters: params)?.outputImage {
                    image = blended.cropped(to: bounds)
                    // One-time diagnostic: log the first frame where a mask was actually blended.
                    // Grep marker: IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST
                    if !_hasLoggedFirstMaskBlend {
                        _hasLoggedFirstMaskBlend = true
                        NSLog("[VGDuetPreviewCompositor] IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST — CIBlendWithMask reached CoreImage blend for first masked frame maskFeatherRadius=\(VGDuetPreviewCompositor.greenScreenMaskFeatherRadius) maskFeatherApplied=\(refined.featherApplied) maskTrimapEnabled=\(VGDuetPreviewCompositor.greenScreenTrimapEnabled) maskTrimapApplied=\(refined.trimapApplied) maskTrimapLow=\(VGDuetPreviewCompositor.greenScreenTrimapLow) maskTrimapHigh=\(VGDuetPreviewCompositor.greenScreenTrimapHigh) maskGuidedEdgeEnabled=\(VGDuetPreviewCompositor.greenScreenGuidedEdgeEnabled) maskGuidedEdgeApplied=\(refined.guidedApplied) maskGuidedEdgeIntensity=\(VGDuetPreviewCompositor.greenScreenGuidedEdgeIntensity) maskGuidedEdgeBlurRadius=\(VGDuetPreviewCompositor.greenScreenGuidedEdgeBlurRadius) maskGuidedEdgeLow=\(VGDuetPreviewCompositor.greenScreenGuidedEdgeLow) maskGuidedEdgeHigh=\(VGDuetPreviewCompositor.greenScreenGuidedEdgeHigh) maskMorphologyCloseEnabled=\(VGDuetPreviewCompositor.greenScreenMaskMorphologyCloseEnabled) maskMorphologyCloseApplied=\(refined.morphologyCloseApplied) maskMorphologyCloseRadius=\(VGDuetPreviewCompositor.greenScreenMaskMorphologyCloseRadius)")
                    }
                } else {
                    // Filter unavailable (should not happen on supported iOS): fall back to
                    // opaque camera overlay so green-screen does not silently show only source.
                    NSLog("[VGDuetPreviewCompositor] CIBlendWithMask unavailable — camera overlay fallback")
                    image = camFilled.composited(over: image)
                }
            } else if let camFrame = cameraFrame {
                // Live camera frame (non-green-screen, or mask missing): aspect-fill into the slot.
                let camImage = CIImage(cvPixelBuffer: camFrame)
                image = aspectFill(camImage, into: ciCamera).composited(over: image)
            } else {
                // No live frame yet: show deterministic placeholder.
                let coversSource = !ciSource.isEmpty && ciCamera.contains(ciSource)
                image = cameraPlaceholder(in: ciCamera, translucent: coversSource).composited(over: image)
            }
        }

        ciContext.render(image, to: output, bounds: bounds, colorSpace: nil)
        return output
    }

    // MARK: - Geometry helpers

    /// Converts a top-left-origin canvas rect to CoreImage bottom-left space,
    /// snapping edges to whole pixels and clipping to the canvas.
    private func ciRect(fromTopLeft rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x0 = rect.minX.rounded()
        let x1 = rect.maxX.rounded()
        let y0 = rect.minY.rounded()
        let y1 = rect.maxY.rounded()
        guard x1 > x0, y1 > y0 else { return .zero }
        let flipped = CGRect(x: x0,
                             y: CGFloat(canvasHeight) - y1,
                             width: x1 - x0,
                             height: y1 - y0)
        let clipped = flipped.intersection(canvasBounds)
        return clipped.isNull ? .zero : clipped
    }

    /// Scale-to-fill + center-crop `image` into `rect` (CI coordinates).
    private func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return CIImage.empty() }
        let scale  = max(rect.width / extent.width, rect.height / extent.height)
        let scaledW = extent.width  * scale
        let scaledH = extent.height * scale
        let tx = rect.minX + (rect.width  - scaledW) / 2 - extent.minX * scale
        let ty = rect.minY + (rect.height - scaledH) / 2 - extent.minY * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        return image.transformed(by: transform).cropped(to: rect)
    }

    /// Refines an already aspect-filled green-screen mask at output scale in four
    /// fail-open stages:
    ///   1. applyGreenScreenMorphologyClose — morphology close r1b fills pinholes / bites.
    ///   2. featherGreenScreenMask — gaussian blur softens edges.
    ///   3. applyGreenScreenTrimap — smoothstep curve separates foreground/background.
    ///   4. applyGreenScreenGuidedEdgePreserve — restores fine edges from camera guide.
    ///
    /// - Parameter guide: aspect-filled camera frame used as an edge guide for stage 4;
    ///   never composited into the returned mask directly.
    /// - Returns: refined mask plus per-stage applied flags. Each stage fails open to
    ///   its input if filter creation fails or inputs are degenerate.
    private func refineGreenScreenMask(_ mask: CIImage, in rect: CGRect, guidedBy guide: CIImage)
        -> (mask: CIImage, morphologyCloseApplied: Bool, featherApplied: Bool, trimapApplied: Bool, guidedApplied: Bool) {
        let closed = applyGreenScreenMorphologyClose(mask, in: rect)
        let feathered = featherGreenScreenMask(closed.mask, in: rect)
        let trimapped = applyGreenScreenTrimap(feathered.mask, in: rect)
        let guided = applyGreenScreenGuidedEdgePreserve(trimapped: trimapped.mask,
                                                          feathered: feathered.mask,
                                                          guide: guide,
                                                          in: rect)
        return (guided.mask, closed.applied, feathered.applied, trimapped.applied, guided.applied)
    }

    /// Morphological close: CIMorphologyMaximum (dilate) then CIMorphologyMinimum (erode),
    /// each with inputRadius = greenScreenMaskMorphologyCloseRadius (1.0 px; r1b).
    /// Clamped to extent before dilate, then cropped to a finite radius-padded rect before
    /// erode to ensure bounded input and prevent EXC_BAD_ACCESS, then cropped back to `rect`.
    /// Fails open to input mask if disabled, empty, or filters are unavailable.
    ///
    /// - Returns: the closed mask and `applied == true`, or the input mask
    ///   unchanged and `applied == false`.
    private func applyGreenScreenMorphologyClose(_ mask: CIImage, in rect: CGRect) -> (mask: CIImage, applied: Bool) {
        guard VGDuetPreviewCompositor.greenScreenMaskMorphologyCloseEnabled else { return (mask, false) }
        let radius = VGDuetPreviewCompositor.greenScreenMaskMorphologyCloseRadius
        guard radius > 0, !rect.isEmpty, !mask.extent.isEmpty else { return (mask, false) }

        let clamped = mask.clampedToExtent()

        let maxParams: [String: Any] = [
            "inputImage":  clamped,
            "inputRadius": radius,
        ]
        guard let dilated = CIFilter(name: "CIMorphologyMaximum", parameters: maxParams)?.outputImage else {
            return (mask, false)
        }

        // r1b: `dilated` still carries the infinite extent inherited from
        // `clamped`. Feeding that straight into a second morphology filter
        // crashed with EXC_BAD_ACCESS on-device, so crop to a finite rect —
        // padded by the radius on each side so the erode below still has
        // valid samples out to its own reach — before the erode pass.
        // `boundedDilated` is used as-is (not re-clamped) since
        // clampedToExtent() would reintroduce an infinite-extent image and
        // recreate the exact crash condition this works around.
        let pad = max(radius * 2, 2)
        let workingRect = rect.insetBy(dx: -pad, dy: -pad)
        let boundedDilated = dilated.cropped(to: workingRect)

        let minParams: [String: Any] = [
            "inputImage":  boundedDilated,
            "inputRadius": radius,
        ]
        guard let eroded = CIFilter(name: "CIMorphologyMinimum", parameters: minParams)?.outputImage else {
            return (mask, false)
        }

        return (eroded.cropped(to: rect), true)
    }

    /// Softens the mask with CIGaussianBlur at greenScreenMaskFeatherRadius (3.0 px).
    /// Clamped to extent before blur and cropped back to `rect` to prevent edge darkening.
    /// Fails open to input mask if radius <= 0, empty, or blur filter is unavailable.
    ///
    /// - Returns: the feathered mask and `applied == true`, or the input mask
    ///   unchanged and `applied == false`.
    private func featherGreenScreenMask(_ mask: CIImage, in rect: CGRect) -> (mask: CIImage, applied: Bool) {
        let radius = VGDuetPreviewCompositor.greenScreenMaskFeatherRadius
        guard radius > 0, !rect.isEmpty, !mask.extent.isEmpty else { return (mask, false) }
        let params: [String: Any] = [
            "inputImage":  mask.clampedToExtent(),
            "inputRadius": radius,
        ]
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: params)?.outputImage else {
            return (mask, false)
        }
        return (blurred.cropped(to: rect), true)
    }

    /// Remaps mask luminance m through smoothstep(low, high, m) with constants [0.14, 0.86].
    /// Values <= low become solid background, values >= high become solid foreground,
    /// and the narrow band in between stays soft.
    ///
    /// Implemented as a CoreImage GPU pipeline fusing CIColorMatrix, CIColorClamp,
    /// and CIColorPolynomial into a per-pixel program, cropped back to `rect`.
    /// Fails open to input mask if disabled, degenerate, empty, or filters are unavailable.
    ///
    /// - Returns: the remapped mask and `applied == true`, or the input mask
    ///   unchanged and `applied == false`.
    private func applyGreenScreenTrimap(_ mask: CIImage, in rect: CGRect) -> (mask: CIImage, applied: Bool) {
        guard VGDuetPreviewCompositor.greenScreenTrimapEnabled else { return (mask, false) }
        let low  = VGDuetPreviewCompositor.greenScreenTrimapLow
        let high = VGDuetPreviewCompositor.greenScreenTrimapHigh
        guard high > low, !rect.isEmpty, !mask.extent.isEmpty else { return (mask, false) }

        // 1. Linear ramp: t = (m - low) / (high - low), applied to R, G, B; alpha untouched.
        let scale = 1 / (high - low)
        let bias  = -low * scale
        let rampParams: [String: Any] = [
            "inputImage":      mask,
            "inputRVector":    CIVector(x: scale, y: 0,     z: 0,     w: 0),
            "inputGVector":    CIVector(x: 0,     y: scale, z: 0,     w: 0),
            "inputBVector":    CIVector(x: 0,     y: 0,     z: scale, w: 0),
            "inputAVector":    CIVector(x: 0,     y: 0,     z: 0,     w: 1),
            "inputBiasVector": CIVector(x: bias,  y: bias,  z: bias,  w: 0),
        ]
        guard let ramped = CIFilter(name: "CIColorMatrix", parameters: rampParams)?.outputImage else {
            return (mask, false)
        }

        // 2. Clamp t to [0, 1] so the polynomial below only ever sees the smoothstep domain.
        let clampParams: [String: Any] = [
            "inputImage":         ramped,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
        guard let clamped = CIFilter(name: "CIColorClamp", parameters: clampParams)?.outputImage else {
            return (mask, false)
        }

        // 3. Smoothstep curve: s = 0 + 0·t + 3·t² − 2·t³ (per R, G, B); alpha = identity.
        let smoothstep = CIVector(x: 0, y: 0, z: 3, w: -2)
        let curveParams: [String: Any] = [
            "inputImage":             clamped,
            "inputRedCoefficients":   smoothstep,
            "inputGreenCoefficients": smoothstep,
            "inputBlueCoefficients":  smoothstep,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
        ]
        guard let curved = CIFilter(name: "CIColorPolynomial", parameters: curveParams)?.outputImage else {
            return (mask, false)
        }
        return (curved.cropped(to: rect), true)
    }

    /// Restores the pre-trimap `feathered` mask over the `trimapped` mask wherever
    /// the camera frame (`guide`) has a strong edge, preserving thin subject detail
    /// (hair, fingers) while flat regions keep the trimapped mask.
    ///
    /// Guided edge constants: intensity 2.0, blur radius 1.5, smoothstep [0.08, 0.34].
    /// Edge confidence is derived from `guide` alone via CIEdges -> CIGaussianBlur ->
    /// smoothstep normalized confidence mask -> CIBlendWithMask.
    /// Fails open to `trimapped` mask if disabled, degenerate, empty, or filters are unavailable.
    ///
    /// - Returns: the guided-edge-preserved mask and `applied == true`, or
    ///   `trimapped` unchanged and `applied == false`.
    private func applyGreenScreenGuidedEdgePreserve(trimapped: CIImage,
                                                      feathered: CIImage,
                                                      guide: CIImage,
                                                      in rect: CGRect) -> (mask: CIImage, applied: Bool) {
        guard VGDuetPreviewCompositor.greenScreenGuidedEdgeEnabled else { return (trimapped, false) }
        let low  = VGDuetPreviewCompositor.greenScreenGuidedEdgeLow
        let high = VGDuetPreviewCompositor.greenScreenGuidedEdgeHigh
        guard high > low, !rect.isEmpty, !trimapped.extent.isEmpty,
              !feathered.extent.isEmpty, !guide.extent.isEmpty else {
            return (trimapped, false)
        }

        // 1. Crop the guide (camera frame) to the foreground rect.
        let croppedGuide = guide.cropped(to: rect)

        // 2. Edge detection on the camera frame itself.
        let edgesParams: [String: Any] = [
            "inputImage":     croppedGuide,
            "inputIntensity": VGDuetPreviewCompositor.greenScreenGuidedEdgeIntensity,
        ]
        guard let edges = CIFilter(name: "CIEdges", parameters: edgesParams)?.outputImage else {
            return (trimapped, false)
        }

        // 3. Small blur so isolated edge pixels become a soft confidence band
        //    instead of a 1-pixel-wide mask.
        let blurParams: [String: Any] = [
            "inputImage":  edges.clampedToExtent(),
            "inputRadius": VGDuetPreviewCompositor.greenScreenGuidedEdgeBlurRadius,
        ]
        guard let blurredEdges = CIFilter(name: "CIGaussianBlur", parameters: blurParams)?.outputImage else {
            return (trimapped, false)
        }

        // 4a. Linear ramp: t = (m - low) / (high - low), applied to R, G, B; alpha untouched.
        let scale = 1 / (high - low)
        let bias  = -low * scale
        let rampParams: [String: Any] = [
            "inputImage":      blurredEdges,
            "inputRVector":    CIVector(x: scale, y: 0,     z: 0,     w: 0),
            "inputGVector":    CIVector(x: 0,     y: scale, z: 0,     w: 0),
            "inputBVector":    CIVector(x: 0,     y: 0,     z: scale, w: 0),
            "inputAVector":    CIVector(x: 0,     y: 0,     z: 0,     w: 1),
            "inputBiasVector": CIVector(x: bias,  y: bias,  z: bias,  w: 0),
        ]
        guard let ramped = CIFilter(name: "CIColorMatrix", parameters: rampParams)?.outputImage else {
            return (trimapped, false)
        }

        // 4b. Clamp t to [0, 1] so the polynomial below only ever sees the smoothstep domain.
        let clampParams: [String: Any] = [
            "inputImage":         ramped,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
        guard let clamped = CIFilter(name: "CIColorClamp", parameters: clampParams)?.outputImage else {
            return (trimapped, false)
        }

        // 4c. Smoothstep curve: s = 0 + 0·t + 3·t² − 2·t³ (per R, G, B); alpha = identity.
        let smoothstep = CIVector(x: 0, y: 0, z: 3, w: -2)
        let curveParams: [String: Any] = [
            "inputImage":             clamped,
            "inputRedCoefficients":   smoothstep,
            "inputGreenCoefficients": smoothstep,
            "inputBlueCoefficients":  smoothstep,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0),
        ]
        guard let curved = CIFilter(name: "CIColorPolynomial", parameters: curveParams)?.outputImage else {
            return (trimapped, false)
        }
        // 5. Crop back to `rect`.
        let edgeConfidence = curved.cropped(to: rect)

        // Composite: feathered where the camera has a strong edge, trimapped elsewhere.
        let blendParams: [String: Any] = [
            "inputImage":           feathered,
            "inputBackgroundImage": trimapped,
            "inputMaskImage":       edgeConfidence,
        ]
        guard let blended = CIFilter(name: "CIBlendWithMask", parameters: blendParams)?.outputImage else {
            return (trimapped, false)
        }
        return (blended.cropped(to: rect), true)
    }

    /// Deterministic camera placeholder: slate fill, 2 px lighter edge, soft
    /// centred glow.  `translucent` lowers alpha so an underlying source stays
    /// visible when the camera rect covers it.
    private func cameraPlaceholder(in rect: CGRect, translucent: Bool) -> CIImage {
        let alpha = translucent ? VGDuetPreviewCompositor.overlayAlpha : 1.0

        let edge = CIImage(color: withAlpha(VGDuetPreviewCompositor.placeholderEdge, alpha)).cropped(to: rect)

        let inset = VGDuetPreviewCompositor.placeholderEdgePx
        let innerRect = rect.insetBy(dx: inset, dy: inset)
        var placeholder: CIImage = edge
        if innerRect.width > 0, innerRect.height > 0 {
            let fill = CIImage(color: withAlpha(VGDuetPreviewCompositor.placeholderFill, alpha)).cropped(to: innerRect)
            placeholder = fill.composited(over: edge)
        }

        let radius = max(1.0, min(rect.width, rect.height) * 0.45)
        let glowParams: [String: Any] = [
            "inputCenter":  CIVector(x: rect.midX, y: rect.midY),
            "inputRadius0": 0.0,
            "inputRadius1": radius,
            "inputColor0":  withAlpha(VGDuetPreviewCompositor.placeholderGlow, alpha * 0.9),
            "inputColor1":  withAlpha(VGDuetPreviewCompositor.placeholderGlow, 0.0),
        ]
        if let glow = CIFilter(name: "CIRadialGradient", parameters: glowParams)?.outputImage?.cropped(to: rect) {
            placeholder = glow.composited(over: placeholder)
        }
        return placeholder
    }

    private func withAlpha(_ color: CIColor, _ alpha: CGFloat) -> CIColor {
        return CIColor(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }

    // MARK: - Pool

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:     Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String:               width,
            kCVPixelBufferHeightKey as String:              height,
            kCVPixelBufferMetalCompatibilityKey as String:  true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes as CFDictionary,
                                             pixelBufferAttributes as CFDictionary,
                                             &pool)
        guard status == kCVReturnSuccess, let created = pool else {
            NSLog("[VGDuetPreviewCompositor] CVPixelBufferPoolCreate failed: %d (%dx%d)", status, width, height)
            return nil
        }
        return created
    }
}

// MARK: - Diagnostic: deterministic CoreImage pixel proof (simulator-safe)
//
// Proof boundary: ios_duet_coreimage_pixel_proof_synthetic_mask_blend_only
//
// Proves that composite()'s CIBlendWithMask green-screen path (lines above, "Green-screen
// path" block) blends a synthetic camera foreground over a synthetic source/background
// through a single-channel L8 mask with the expected linear-interpolation math, using only
// synthetic CVPixelBuffers built in-process. Diagnostic only.
//
// Non-claims: no real camera hardware or AVCaptureSession lifecycle, no Vision/ML
// segmentation quality, no video decoder, no MP4 export, no audio, no ConnectsApp /
// Universal Editor / upload wiring.
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
    /// in `composite(...)`. Renders synthetic BGRA source/camera buffers and an L8 mask
    /// through a real `VGDuetPreviewCompositor(canvasWidth: 64, canvasHeight: 64)` instance
    /// and asserts pixel values in the resulting output buffer. Never throws; every failure
    /// mode is captured in the returned map's `failureReason`/`mismatches` instead.
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

        // 3. Composite through the real green-screen path.
        let compositor = VGDuetPreviewCompositor(canvasWidth: 64, canvasHeight: 64)
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
            "output = round(foreground * (maskByte/255) + background * (1 - maskByte/255)) per channel"

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

        // Fractional blend math: alpha=128 and alpha=64 linear mixes.
        sample("mask_alpha128_quadrant", x: 20, y: 40, expected: expectedMix(alpha: 128), group: "fraction")
        sample("mask_alpha64_quadrant",  x: 40, y: 40, expected: expectedMix(alpha: 64),  group: "fraction")

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
