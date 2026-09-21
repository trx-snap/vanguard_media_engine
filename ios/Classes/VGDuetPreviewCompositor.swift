// VGDuetPreviewCompositor.swift
// VG-DUET-SLICE-4B-B: CoreImage compositor for the Duet preview texture.
//
// Duet is a 2-input spatial compositor: source media + a foreground camera/effects
// frame. It must NOT own mask refinement, CIBlendWithMask, raw masks, or standalone
// live GreenScreen camera ingress — that live/static GreenScreen compositing
// responsibility lives in VGLiveGreenScreenCompositor.swift instead (see that file for
// the CIBlendWithMask green-screen path and VGMatteRefinementPipeline ownership).
//
// Responsibilities:
//   - Owns a Metal-backed CIContext (CPU fallback when no Metal device exists).
//   - Owns a BGRA, Metal-compatible, IOSurface-backed CVPixelBufferPool at a
//     fixed canvas size.
//   - composite(): dark canvas + aspect-filled source frame in sourceRect +
//     either a foreground camera frame (opaque, or already keyed upstream as
//     straight-alpha) in cameraRect, or a deterministic camera placeholder.
//
// Explicitly NOT in this slice: camera capture, green-screen keying/mask refinement,
// audio, export.  The camera placeholder is a static visual so that layout geometry
// can be verified on-device before camera capture lands.
//
// Coordinate systems:
//   Layout rects (VGDuetLayoutGeometry) are canvas-pixel rects with a TOP-LEFT
//   origin.  CoreImage renders with a BOTTOM-LEFT origin.  ciRect(fromTopLeft:)
//   flips Y and snaps edges to whole pixels, so geometry intent is preserved to
//   within 1 px.
//
// Straight-alpha foreground ingest (Phase 4B-A; the proven Duet production path):
// composite(cameraFrameUsesStraightAlpha: true) treats `cameraFrame` as a foreground that
// was ALREADY keyed upstream: BGRA with STRAIGHT (non-premultiplied) alpha, RGB = 0 where
// alpha = 0 (the VGGreenScreenFilterNode alpha output convention).  The frame is
// premultiplied (CIImage.premultiplyingAlpha), aspect-filled into cameraRect and
// source-over composited onto the composed source canvas.  No matte is required, no matte
// refinement runs.  The default (`false`) composites `cameraFrame` as an opaque overlay
// instead.  Straight-alpha frames may come from VGGreenScreenFilterNode alpha mode via the
// graph-backed foreground provider (VGDuetGraphGreenScreenForegroundProvider); this
// compositor remains unaware of ML/matte policy — it only composites whatever it is handed.
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
    let ciContext: CIContext

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

    /// Alpha used when the camera rect fully covers the source rect (degenerate
    /// layouts).  Keeps the source visible instead of occluding it with an
    /// opaque placeholder.
    private static let overlayAlpha: CGFloat = 0.28

    /// One-time diagnostic marker for the straight-alpha foreground path
    /// (`cameraFrameUsesStraightAlpha: true`).  Guards against log spam on every frame.
    private var _hasLoggedFirstStraightAlphaComposite = false

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
    ///   - cameraFrameUsesStraightAlpha:
    ///                      Phase 4B-A.  When true, `cameraFrame` is a foreground already
    ///                      keyed upstream (BGRA, STRAIGHT alpha): it is premultiplied,
    ///                      aspect-filled into cameraRect and source-over composited onto
    ///                      the composed canvas.  Default false composites `cameraFrame`
    ///                      as an opaque overlay instead.
    ///   - cameraRotationDegrees, cameraAnchorX, cameraAnchorY:
    ///                      Preview-only Duet foreground free-transform rotation (DEC_V2_123C).
    ///                      The camera/foreground layer (live frame or placeholder) is rotated
    ///                      `cameraRotationDegrees` clockwise (Dart/top-left visual convention)
    ///                      around the normalized pivot `(cameraAnchorX, cameraAnchorY)` inside
    ///                      cameraRect. Defaults (0.0, 0.5, 0.5) are a no-op identity rotation
    ///                      so existing callers stay source-compatible. The source/background
    ///                      layer is never rotated.
    /// - Returns: a pool-backed BGRA buffer, or nil when the pool is exhausted / unavailable.
    func composite(sourceFrame: CVPixelBuffer?,
                   sourceRect: CGRect,
                   cameraRect: CGRect,
                   cameraFrame: CVPixelBuffer? = nil,
                   cameraFrameUsesStraightAlpha: Bool = false,
                   cameraRotationDegrees: CGFloat = 0.0,
                   cameraAnchorX: CGFloat = 0.5,
                   cameraAnchorY: CGFloat = 0.5) -> CVPixelBuffer? {
        guard let pool = pool else { return nil }

        // Final guard: sanitize non-finite rotation/anchor inputs regardless of
        // caller (VGDuetLayoutGeometry.foregroundRotation already clamps these,
        // but the compositor must not trust callers blindly).
        let sanitizedRotationDegrees = cameraRotationDegrees.isFinite ? cameraRotationDegrees : 0.0
        let sanitizedAnchorX = cameraAnchorX.isFinite ? cameraAnchorX : 0.5
        let sanitizedAnchorY = cameraAnchorY.isFinite ? cameraAnchorY : 0.5

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
            if cameraFrameUsesStraightAlpha, let camFrame = cameraFrame {
                // Straight-alpha foreground path (pre-keyed upstream).
                //   The frame's bytes are STRAIGHT alpha (fg.rgb, a).  CoreImage treats a
                //   BGRA pixel buffer as premultiplied, so premultiply first, giving
                //   (fg.rgb*a, a), and do it BEFORE resampling so transparent texels never
                //   bleed colour into edges; then aspect-fill into the unrotated cameraRect,
                //   rotate the resulting layer, then source-over onto the canvas
                //   (C = C_fg*a + C_bg*(1-a)).
                let camPremultiplied = CIImage(cvPixelBuffer: camFrame).premultiplyingAlpha()
                let filled = aspectFill(camPremultiplied, into: ciCamera)
                let rotated = rotateCameraLayer(filled, in: ciCamera,
                                                rotationDegrees: sanitizedRotationDegrees,
                                                anchorX: sanitizedAnchorX,
                                                anchorY: sanitizedAnchorY)
                image = rotated.composited(over: image)
                // One-time diagnostic: first frame composited through the straight-alpha path.
                // Grep marker: IOS_DUET_FOREGROUND_STRAIGHT_ALPHA_COMPOSITE_FIRST
                if !_hasLoggedFirstStraightAlphaComposite {
                    _hasLoggedFirstStraightAlphaComposite = true
                    NSLog("[VGDuetPreviewCompositor] IOS_DUET_FOREGROUND_STRAIGHT_ALPHA_COMPOSITE_FIRST pre-keyed straight-alpha foreground premultiplied and source-over composited into cameraRect; no matte, no refinement")
                }
            } else if let camFrame = cameraFrame {
                // Opaque live camera frame: aspect-fill into the unrotated slot, then rotate.
                let camImage = CIImage(cvPixelBuffer: camFrame)
                let filled = aspectFill(camImage, into: ciCamera)
                let rotated = rotateCameraLayer(filled, in: ciCamera,
                                                rotationDegrees: sanitizedRotationDegrees,
                                                anchorX: sanitizedAnchorX,
                                                anchorY: sanitizedAnchorY)
                image = rotated.composited(over: image)
            } else {
                // No live frame yet: show deterministic placeholder, rotated to match.
                let coversSource = !ciSource.isEmpty && ciCamera.contains(ciSource)
                let placeholder = cameraPlaceholder(in: ciCamera, translucent: coversSource)
                let rotated = rotateCameraLayer(placeholder, in: ciCamera,
                                                rotationDegrees: sanitizedRotationDegrees,
                                                anchorX: sanitizedAnchorX,
                                                anchorY: sanitizedAnchorY)
                image = rotated.composited(over: image)
            }
        }

        ciContext.render(image, to: output, bounds: bounds, colorSpace: nil)
        return output
    }

    // MARK: - Geometry helpers

    /// Converts a top-left-origin canvas rect to CoreImage bottom-left space,
    /// snapping edges to whole pixels and clipping to the canvas.
    func ciRect(fromTopLeft rect: CGRect) -> CGRect {
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
    func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
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

    /// Rotates `image` (already aspect-filled/cropped into `rect`) around the
    /// normalized pivot `(anchorX, anchorY)` by `rotationDegrees`.  Returns
    /// `image` unchanged for zero, non-finite, or effectively-zero rotation.
    ///
    /// - `anchorX` is left-to-right inside `rect`: `rect.minX + anchorX * rect.width`.
    /// - `anchorY` is Dart/top-left-normalized; it is flipped into CoreImage
    ///   bottom-left space here: `rect.minY + (1.0 - anchorY) * rect.height`.
    /// - `rotationDegrees` is the visual clockwise angle in Dart/top-left space;
    ///   negating the radians before building the CoreImage affine rotation
    ///   makes it rotate visually clockwise in CoreImage's bottom-left space too.
    ///
    /// The caller must not crop the result back to `rect`: the canvas-bounded
    /// `ciContext.render` call is the only clip applied downstream, so rotated
    /// corners extending past `rect` are preserved instead of cut off.
    private func rotateCameraLayer(_ image: CIImage,
                                   in rect: CGRect,
                                   rotationDegrees: CGFloat,
                                   anchorX: CGFloat,
                                   anchorY: CGFloat) -> CIImage {
        guard rotationDegrees.isFinite, abs(rotationDegrees) > 0.0001 else { return image }

        let pivotX = rect.minX + anchorX * rect.width
        let pivotY = rect.minY + (1.0 - anchorY) * rect.height
        let radians = -rotationDegrees * CGFloat.pi / 180.0

        let transform = CGAffineTransform(translationX: -pivotX, y: -pivotY)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: pivotX, y: pivotY))

        return image.transformed(by: transform)
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
