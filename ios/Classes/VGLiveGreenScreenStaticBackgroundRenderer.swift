// VGLiveGreenScreenStaticBackgroundRenderer.swift
// Generic live green-screen: static background buffer builder (solid color or
// still image). Caller-agnostic — usable by live meeting/calling, going live,
// camera, or any other surface; never scoped to a specific caller.
//
// Responsibilities:
//   - Builds one BGRA, Metal-compatible, IOSurface-backed CVPixelBuffer at the
//     canvas size for a solid color or a local image file.
//   - Solid: fills the full canvas. Alpha is ignored (the background lane is
//     opaque), matching the offline green-screen export renderer.
//   - Image: decodes via ImageIO bounded to the canvas (never upscaled), then
//     places it into the full canvas with `aspectFill` (center crop) or
//     `aspectFit` (centered, black letterbox/pillarbox). EXIF orientation is
//     deliberately NOT applied, matching VGGreenScreenExportSession so the same
//     image path renders identically in live preview and export.
//   - Video backgrounds are not a spec case; the method handler rejects them.
//
// Threading: build(...) is synchronous and is called on the main thread by the
// coordinator lifecycle. The CIContext is shared and thread-safe.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Metal

// MARK: - Spec types

/// How a still image is placed into the full canvas.
enum VGLiveGreenScreenBackgroundScaleMode {
    /// Scale to cover the canvas, center-crop the overflow.
    case aspectFill
    /// Scale to fit inside the canvas, center, black letterbox/pillarbox.
    case aspectFit
}

/// Validated static background description built by the method handler.
enum VGLiveGreenScreenBackgroundSpec {
    case solidColor(argb: Int32)
    case image(filePath: String, scaleMode: VGLiveGreenScreenBackgroundScaleMode)
}

/// Failure raised by the renderer. `invalidArgument` maps to `INVALID_ARG`
/// (bad canvas, missing/undecodable image file); `compositionFailed` maps to
/// `composition_failed` (buffer allocation).
struct VGLiveGreenScreenBackgroundError: Error {
    enum Kind {
        case invalidArgument
        case compositionFailed
    }

    let kind: Kind
    let message: String
}

// MARK: - Renderer

final class VGLiveGreenScreenStaticBackgroundRenderer {

    // MARK: Rendering resources

    /// Process-wide CIContext (thread-safe, expensive to create). Metal-backed
    /// when a device exists; CPU fallback otherwise.
    private static let sharedContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        NSLog("[VGLiveGreenScreenStaticBackgroundRenderer] MTLCreateSystemDefaultDevice nil — CPU CIContext fallback")
        return CIContext(options: options)
    }()

    /// Decode bound: the image's longest side is decoded to at most this factor
    /// times the canvas's longest side (never upscaled by ImageIO).
    private static let imageDecodeMaxDimensionFactor = 2

    private let ciContext: CIContext

    // MARK: Init

    init() {
        ciContext = VGLiveGreenScreenStaticBackgroundRenderer.sharedContext
    }

    // MARK: Build

    /// Renders `spec` into a new full-canvas BGRA buffer.
    ///
    /// Throws `VGLiveGreenScreenBackgroundError` when the canvas is degenerate,
    /// the image file is missing or undecodable, or the buffer cannot be
    /// allocated. Never returns a partially filled buffer.
    func build(spec: VGLiveGreenScreenBackgroundSpec,
               canvasWidth: Int,
               canvasHeight: Int) throws -> CVPixelBuffer {
        guard canvasWidth > 0, canvasHeight > 0 else {
            throw VGLiveGreenScreenBackgroundError(
                kind: .invalidArgument,
                message: "canvas size must be > 0 (got \(canvasWidth)x\(canvasHeight))")
        }

        let canvasRect = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: canvasRect)
        let composed: CIImage

        switch spec {
        case .solidColor(let argb):
            composed = CIImage(color: VGLiveGreenScreenStaticBackgroundRenderer.ciColor(argb: argb))
                .cropped(to: canvasRect)

        case .image(let filePath, let scaleMode):
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw VGLiveGreenScreenBackgroundError(
                    kind: .invalidArgument,
                    message: "background image file not found: \(filePath)")
            }
            let maxPixelSize = max(canvasWidth, canvasHeight)
                * VGLiveGreenScreenStaticBackgroundRenderer.imageDecodeMaxDimensionFactor
            guard let cgImage = VGLiveGreenScreenStaticBackgroundRenderer.loadImage(
                path: filePath, maxPixelSize: maxPixelSize) else {
                throw VGLiveGreenScreenBackgroundError(
                    kind: .invalidArgument,
                    message: "background image could not be decoded: \(filePath)")
            }
            let image = CIImage(cgImage: cgImage)
            guard image.extent.width > 0, image.extent.height > 0, !image.extent.isInfinite else {
                throw VGLiveGreenScreenBackgroundError(
                    kind: .invalidArgument,
                    message: "background image is empty: \(filePath)")
            }
            let placed = VGLiveGreenScreenStaticBackgroundRenderer.place(image, into: canvasRect, mode: scaleMode)
            composed = placed.composited(over: black)
        }

        let buffer = try VGLiveGreenScreenStaticBackgroundRenderer.makePixelBuffer(
            width: canvasWidth, height: canvasHeight)
        ciContext.render(composed.cropped(to: canvasRect), to: buffer, bounds: canvasRect, colorSpace: nil)
        return buffer
    }

    // MARK: - Helpers

    /// Opaque CIColor from a packed ARGB value; alpha is ignored.
    private static func ciColor(argb: Int32) -> CIColor {
        let value = UInt32(bitPattern: argb)
        let red   = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8)  & 0xFF) / 255
        let blue  = CGFloat(value & 0xFF) / 255
        return CIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    /// Scale `image` into `rect` (aspectFill center-crops; aspectFit centers
    /// and lets the black canvas show through), then crop to `rect`.
    private static func place(_ image: CIImage,
                              into rect: CGRect,
                              mode: VGLiveGreenScreenBackgroundScaleMode) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return CIImage.empty() }
        let scaleX = rect.width / extent.width
        let scaleY = rect.height / extent.height
        let scale: CGFloat
        switch mode {
        case .aspectFill: scale = max(scaleX, scaleY)
        case .aspectFit:  scale = min(scaleX, scaleY)
        }
        let scaledWidth  = extent.width  * scale
        let scaledHeight = extent.height * scale
        let tx = rect.minX + (rect.width  - scaledWidth)  / 2 - extent.minX * scale
        let ty = rect.minY + (rect.height - scaledHeight) / 2 - extent.minY * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        return image.transformed(by: transform).cropped(to: rect)
    }

    /// Decodes the image bounded to `maxPixelSize` on its longer side (never
    /// upscaled). EXIF orientation is applied so the returned CGImage is in
    /// visual (display) orientation.
    private static func loadImage(path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let bounded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return bounded
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// BGRA + Metal-compatible + IOSurface-backed so both CoreImage and the
    /// Flutter texture path can consume the buffer directly.
    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String:  true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw VGLiveGreenScreenBackgroundError(
                kind: .compositionFailed,
                message: "background buffer allocation failed: status=\(status) (\(width)x\(height))")
        }
        return buffer
    }
}
