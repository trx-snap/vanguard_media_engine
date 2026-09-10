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
    ///   - sourceFrame: decoded source frame (BGRA).  nil draws canvas + placeholder only.
    ///   - sourceRect:  top-left-origin canvas rect for the source (aspect-fill).
    ///   - cameraRect:  top-left-origin canvas rect for the camera slot.
    ///   - cameraFrame: live camera frame (BGRA).  When non-nil, aspect-filled into cameraRect.
    ///                  When nil, the deterministic camera placeholder is drawn instead.
    /// - Returns: a pool-backed BGRA buffer, or nil when the pool is exhausted / unavailable.
    func composite(sourceFrame: CVPixelBuffer?,
                   sourceRect: CGRect,
                   cameraRect: CGRect,
                   cameraFrame: CVPixelBuffer? = nil) -> CVPixelBuffer? {
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
            if let camFrame = cameraFrame {
                // Live camera frame: aspect-fill into the camera slot.
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
