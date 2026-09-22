// VGLiveGreenScreenCompositor.swift
// Generic live green-screen: CoreImage compositor for the standalone Live GreenScreen
// preview (adapter path) and the offline replay / matte-stage diagnostics lab.
// Caller-agnostic — not scoped to Duet.
//
// Responsibilities:
//   - Owns a Metal-backed CIContext (CPU fallback when no Metal device exists).
//   - Owns a BGRA, Metal-compatible, IOSurface-backed CVPixelBufferPool at a
//     fixed canvas size.
//   - composite(): dark canvas + aspect-filled source frame in sourceRect, then either
//     a CIBlendWithMask-keyed camera foreground, an opaque camera overlay, or (no live
//     frame yet) a deterministic camera placeholder in cameraRect.
//   - Owns exactly one `VGMatteRefinementPipeline` instance (created in init with
//     `liveMatteRefinementMode`) and delegates every mask refinement decision to it.
//
// This type was split out of VGDuetPreviewCompositor (VG-DUET-SLICE architecture
// boundary cleanup): Duet is a 2-input spatial compositor (source media + a foreground
// camera/effects frame that is either opaque or already keyed upstream as
// straight-alpha) and must never own mask refinement, CIBlendWithMask, raw masks, or
// live GreenScreen camera ingress. Every live/static GreenScreen compositing
// responsibility — CIContext/pool, the CIBlendWithMask green-screen path, and the
// VGMatteRefinementPipeline-owning mask refinement — lives here instead.
//
// Default mode: unlike the generic Duet compositor (whose own `init` default is the
// neutral `.s1` so it never inherits GreenScreen tuning), this type IS GreenScreen-scoped,
// so its `init` defaults `liveMatteRefinementMode` to
// `VGMatteRefinementPipeline.defaultLiveMatteRefinementMode` (the production Soft R2
// live default) — the same default every other GreenScreen-owned entry point uses.
//
// Coordinate systems:
//   Layout rects (VGDuetLayoutGeometry) are canvas-pixel rects with a TOP-LEFT
//   origin.  CoreImage renders with a BOTTOM-LEFT origin.  ciRect(fromTopLeft:)
//   flips Y and snaps edges to whole pixels, so geometry intent is preserved to
//   within 1 px.
//
// Production green-screen mask refinement pipeline:
// The aspect-filled L8 mask is refined at output (canvas) scale, then composited via
// CIBlendWithMask. The refinement policy and CoreImage filter graph are owned by
// VGMatteRefinementPipeline (VGMatteRefinementPipeline.swift), not by this compositor —
// see that file for the full stage-by-stage algorithm description. composite() calls
// `mattePipeline.refineLiveGreenScreenMask(...)` before CIBlendWithMask.
//
// ciRect(fromTopLeft:), aspectFill(_:into:), and ciContext are internal (not private) so
// VGLiveGreenScreenReplayDiagnostics can reproduce composite()'s exact geometry and render
// the pipeline's stage taps through the same context. The compositor itself never writes
// files.
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
// (morphology close r1b radius 1.0, feather 4.0, trimap 0.10/0.90, guided edge
// constants 2.0/1.5/0.08/0.34).
// Physical proof baseline: clean-copy Vision Fast avgTotalMs ≈ 13.9 ms, degradedEventCount 0.
//
// Threading: composite() is expected to be called from a single serial queue
// (the render loop's render queue).  The CIContext and pool are immutable
// after init and are themselves thread-safe.

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import simd

final class VGLiveGreenScreenCompositor {

    // MARK: - Canvas

    let canvasWidth: Int
    let canvasHeight: Int

    /// Live-selectable matte refinement mode for this compositor instance (see
    /// `VGMatteRefinementPipeline.LiveMatteRefinementMode`). Defaults to
    /// `VGMatteRefinementPipeline.defaultLiveMatteRefinementMode` (the production Soft R2
    /// live default) when no argument is passed to `init`. Never mutated for the lifetime
    /// of the instance.
    let liveMatteRefinementMode: VGMatteRefinementPipeline.LiveMatteRefinementMode

    /// Owns the actual matte refinement filter graph (S1/S4/S5/tightAlphaR1); this
    /// compositor delegates `greenScreenMatteStages(...)` to it instead of implementing
    /// refinement itself. See VGMatteRefinementPipeline.swift.
    private let mattePipeline: VGMatteRefinementPipeline

    /// Pure GPU Zero Metal compute pipeline for <12.5ms latency and sub-pixel edge sharpness.
    private let gpuZeroPipeline: VGGPUZeroMetalPipeline?

    var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }
    private var canvasBounds: CGRect { CGRect(origin: .zero, size: canvasSize) }

    // MARK: - Rendering resources

    /// Compositor-owned CIContext.  Backed by a single process-wide context
    /// (CIContext is thread-safe and expensive to create), so repeated
    /// attach/detach cycles do not pay the Metal pipeline warm-up cost again.
    /// Internal (not private) so the offline replay lab can render matte stage
    /// taps through the same context composite() uses.
    let ciContext: CIContext

    /// Output pool.  BGRA + Metal compatible + IOSurface backed so Flutter's
    /// texture path can consume buffers directly.  nil when creation failed;
    /// composite() then returns nil and the render loop simply skips presenting.
    private let pool: CVPixelBufferPool?

    /// Bounds outstanding pool allocations (texture-held + Flutter-held +
    /// in-render).  Exceeding it yields a dropped frame, never unbounded growth.
    private static let allocationThreshold = 6

    private let poolAuxAttributes: [String: Any] = [
        kCVPixelBufferPoolAllocationThresholdKey as String: VGLiveGreenScreenCompositor.allocationThreshold,
    ]

    // MARK: - Palette (deterministic)

    /// Internal (not private) so the offline replay lab can rebuild composite()'s canvas
    /// when composing a diagnostic-only (non-S1) final mask; composite() itself is unchanged.
    static let canvasColor              = CIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)
    private static let placeholderFill  = CIColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1.0)
    private static let placeholderEdge  = CIColor(red: 0.34, green: 0.37, blue: 0.44, alpha: 1.0)
    private static let placeholderGlow  = CIColor(red: 0.30, green: 0.33, blue: 0.40, alpha: 1.0)
    private static let placeholderEdgePx: CGFloat = 2.0

    /// Alpha used when the camera rect fully covers the source rect (green
    /// screen / degenerate layouts).  Keeps the source visible instead of
    /// occluding it with an opaque placeholder.
    private static let overlayAlpha: CGFloat = 0.28

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
        NSLog("[VGLiveGreenScreenCompositor] MTLCreateSystemDefaultDevice nil — CPU CIContext fallback")
        return CIContext(options: options)
    }()

    // MARK: - Init

    init(canvasWidth: Double, canvasHeight: Double,
         liveMatteRefinementMode: VGMatteRefinementPipeline.LiveMatteRefinementMode
             = VGMatteRefinementPipeline.defaultLiveMatteRefinementMode) {
        let width  = max(2, Int(canvasWidth.rounded()))
        let height = max(2, Int(canvasHeight.rounded()))
        self.canvasWidth  = width
        self.canvasHeight = height
        self.ciContext    = VGLiveGreenScreenCompositor.sharedContext
        self.pool         = VGLiveGreenScreenCompositor.makePool(width: width, height: height)
        self.liveMatteRefinementMode = liveMatteRefinementMode
        self.mattePipeline = VGMatteRefinementPipeline(liveMatteRefinementMode: liveMatteRefinementMode)
        if liveMatteRefinementMode == .gpuZeroMetal {
            self.gpuZeroPipeline = VGGPUZeroMetalPipeline()
            if self.gpuZeroPipeline != nil {
                NSLog("[VGLiveGreenScreenCompositor] VGGPUZeroMetalPipeline active for canvas %dx%d", width, height)
            } else {
                NSLog("[VGLiveGreenScreenCompositor] Warning: VGGPUZeroMetalPipeline init failed — will fail open to Core Image")
            }
        } else {
            self.gpuZeroPipeline = nil
        }
    }

    // MARK: - Composite

    /// Renders one preview frame.
    ///
    /// - Parameters:
    ///   - sourceFrame:     decoded/static background frame (BGRA).  nil draws canvas + placeholder only.
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
        var image = CIImage(color: VGLiveGreenScreenCompositor.canvasColor).cropped(to: bounds)

        let ciSource = ciRect(fromTopLeft: sourceRect)
        if let frame = sourceFrame, !ciSource.isEmpty {
            let sourceImage = CIImage(cvPixelBuffer: frame)
            image = aspectFill(sourceImage, into: ciSource).composited(over: image)
        }

        let ciCamera = ciRect(fromTopLeft: cameraRect)
        if !ciCamera.isEmpty {
            if isGreenScreen, let camFrame = cameraFrame, let maskBuffer = greenScreenMask {
                if liveMatteRefinementMode == .gpuZeroMetal,
                   let gpuZero = gpuZeroPipeline {
                    let solidCol = SIMD4<Float>(
                        Float(VGLiveGreenScreenCompositor.canvasColor.red),
                        Float(VGLiveGreenScreenCompositor.canvasColor.green),
                        Float(VGLiveGreenScreenCompositor.canvasColor.blue),
                        Float(VGLiveGreenScreenCompositor.canvasColor.alpha)
                    )
                    if gpuZero.render(cameraBuffer: camFrame,
                                      maskBuffer: maskBuffer,
                                      backgroundBuffer: sourceFrame,
                                      outputBuffer: output,
                                      canvasWidth: canvasWidth,
                                      canvasHeight: canvasHeight,
                                      solidColor: solidCol) {
                        if !_hasLoggedFirstMaskBlend {
                            _hasLoggedFirstMaskBlend = true
                            NSLog("[VGLiveGreenScreenCompositor] IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST — GPUZeroMetal compute pipeline rendered first frame directly to output buffer")
                        }
                        return output
                    }
                }
                // Green-screen path: CIBlendWithMask.
                //   foreground = aspect-filled camera into cameraRect
                //   background = current composed source canvas (image)
                //   mask       = aspect-filled segmentation mask into cameraRect
                // The filter replaces pixels where mask ~= 255 (subject) with the foreground.
                // The mapped mask is refined at output scale first (see
                // VGMatteRefinementPipeline.refineLiveGreenScreenMask: morphology close,
                // then 4.0 px feather, then trimap smoothstep, then camera-guided edge
                // preservation);
                // a failed morphology close falls back to the raw mask, a failed
                // feather falls back to the (possibly closed) unblurred mask, a
                // failed trimap falls back to the blurred mask, and a failed
                // guided-edge pass falls back to the trimapped mask — never to
                // the camera overlay.
                // Falls through to the opaque-overlay path if the blend filter is unavailable.
                let camFilled  = aspectFill(CIImage(cvPixelBuffer: camFrame),   into: ciCamera)
                let maskFilled = aspectFill(CIImage(cvPixelBuffer: maskBuffer), into: ciCamera)
                let refined    = mattePipeline.refineLiveGreenScreenMask(aspectFilledMask: maskFilled, in: ciCamera, guidedBy: camFilled)
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
                        NSLog("[VGLiveGreenScreenCompositor] IOS_DUET_GREENSCREEN_MASK_BLEND_FIRST — CIBlendWithMask reached CoreImage blend for first masked frame maskFeatherRadius=\(VGMatteRefinementPipeline.greenScreenMaskFeatherRadius) maskFeatherApplied=\(refined.featherApplied) maskTrimapEnabled=\(VGMatteRefinementPipeline.greenScreenTrimapEnabled) maskTrimapApplied=\(refined.trimapApplied) maskTrimapLow=\(VGMatteRefinementPipeline.greenScreenTrimapLow) maskTrimapHigh=\(VGMatteRefinementPipeline.greenScreenTrimapHigh) maskGuidedEdgeEnabled=\(VGMatteRefinementPipeline.greenScreenGuidedEdgeEnabled) maskGuidedEdgeApplied=\(refined.guidedEdgeApplied) maskGuidedEdgeIntensity=\(VGMatteRefinementPipeline.greenScreenGuidedEdgeIntensity) maskGuidedEdgeBlurRadius=\(VGMatteRefinementPipeline.greenScreenGuidedEdgeBlurRadius) maskGuidedEdgeLow=\(VGMatteRefinementPipeline.greenScreenGuidedEdgeLow) maskGuidedEdgeHigh=\(VGMatteRefinementPipeline.greenScreenGuidedEdgeHigh) maskMorphologyCloseEnabled=\(VGMatteRefinementPipeline.greenScreenMaskMorphologyCloseEnabled) maskMorphologyCloseApplied=\(refined.morphologyCloseApplied) maskMorphologyCloseRadius=\(VGMatteRefinementPipeline.greenScreenMaskMorphologyCloseRadius) liveMatteRefinementMode=\(liveMatteRefinementMode.rawValue) liveTightAlphaR1Applied=\(refined.tightAlphaR1Applied) liveS4GuidedAlphaR1Applied=\(refined.s4GuidedAlphaR1Applied) liveS4GuidedAlphaApplied=\(refined.s4GuidedAlphaApplied)")
                    }
                } else {
                    // Filter unavailable (should not happen on supported iOS): fall back to
                    // opaque camera overlay so green-screen does not silently show only source.
                    NSLog("[VGLiveGreenScreenCompositor] CIBlendWithMask unavailable — camera overlay fallback")
                    image = camFilled.composited(over: image)
                }
            } else if let camFrame = cameraFrame {
                // Opaque live camera frame (unkeyed presentation, or keying requested with the
                // mask missing): aspect-fill into the slot.
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
    /// Internal so the offline replay lab maps cameraRect exactly as composite() does.
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
    /// Internal so the offline replay lab fills camera/mask exactly as composite() does.
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

    // MARK: - Matte refinement stage tap

    /// Thin wrapper over `VGMatteRefinementPipeline.greenScreenMatteStages(...)`. Kept on
    /// the compositor so `VGLiveGreenScreenReplayDiagnostics` (offline matte-stage lab)
    /// keeps calling `compositor.greenScreenMatteStages(...)` unchanged.
    func greenScreenMatteStages(aspectFilledMask mask: CIImage,
                                in rect: CGRect,
                                guidedBy guide: CIImage,
                                refinementMode: VGMatteRefinementPipeline.GreenScreenRefinementMode = .s1
    ) -> VGMatteRefinementPipeline.GreenScreenMatteStages {
        return mattePipeline.greenScreenMatteStages(aspectFilledMask: mask, in: rect, guidedBy: guide, refinementMode: refinementMode)
    }

    /// Deterministic camera placeholder: slate fill, 2 px lighter edge, soft
    /// centred glow.  `translucent` lowers alpha so an underlying source stays
    /// visible when the camera rect covers it.
    private func cameraPlaceholder(in rect: CGRect, translucent: Bool) -> CIImage {
        let alpha = translucent ? VGLiveGreenScreenCompositor.overlayAlpha : 1.0

        let edge = CIImage(color: withAlpha(VGLiveGreenScreenCompositor.placeholderEdge, alpha)).cropped(to: rect)

        let inset = VGLiveGreenScreenCompositor.placeholderEdgePx
        let innerRect = rect.insetBy(dx: inset, dy: inset)
        var placeholder: CIImage = edge
        if innerRect.width > 0, innerRect.height > 0 {
            let fill = CIImage(color: withAlpha(VGLiveGreenScreenCompositor.placeholderFill, alpha)).cropped(to: innerRect)
            placeholder = fill.composited(over: edge)
        }

        let radius = max(1.0, min(rect.width, rect.height) * 0.45)
        let glowParams: [String: Any] = [
            "inputCenter":  CIVector(x: rect.midX, y: rect.midY),
            "inputRadius0": 0.0,
            "inputRadius1": radius,
            "inputColor0":  withAlpha(VGLiveGreenScreenCompositor.placeholderGlow, alpha * 0.9),
            "inputColor1":  withAlpha(VGLiveGreenScreenCompositor.placeholderGlow, 0.0),
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

    static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
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
            NSLog("[VGLiveGreenScreenCompositor] CVPixelBufferPoolCreate failed: %d (%dx%d)", status, width, height)
            return nil
        }
        return created
    }
}

// MARK: - GPU Zero Uniforms

struct GPUZeroGuidedUniforms {
    var resolution: SIMD2<Float>
    var eps: Float
    var filterEnabled: UInt32
    var cropUniforms: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1)
    var rotationIndex: UInt32 = 0
    var mirrorCorrection: UInt32 = 0
    var isBiPlanar: UInt32 = 0
    var _pad: UInt32 = 0
}

struct GPUZeroTemporalUniforms {
    var resolution: SIMD2<Float>
    var stabilizerEnabled: UInt32
    var _pad: UInt32 = 0
}

struct GPUZeroCompositeUniforms {
    var resolution: SIMD2<Float>
    var _pad0: SIMD2<Float> = .zero
    var solidColor: SIMD4<Float>
    var outputMode: UInt32
    var despillEnabled: UInt32
    var _pad1: SIMD2<UInt32> = .zero
    var cropUniforms: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1)
    var rotationIndex: UInt32 = 0
    var mirrorCorrection: UInt32 = 0
    var isBiPlanar: UInt32 = 0
    var _pad2: UInt32 = 0
}

// MARK: - GPU Zero Metal Compute Pipeline
//
// Pure Metal compute implementation of green-screen matting:
// - Zero-copy CVPixelBuffer -> MTLTexture via CVMetalTextureCache
// - Direct biplanar YCbCr hardware luminance sampling
// - 25-point isotropic guided filter with fast-path interior/exterior skip
// - Zero-lag temporal motion snap
// - Hermite cubic composite with inward-normal ambient despill
// Total execution time: ~0.8ms on GPU, ~0.2ms CPU dispatch.

final class VGGPUZeroMetalPipeline {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache

    private let pipelineGuided: MTLComputePipelineState
    private let pipelineTemporal: MTLComputePipelineState
    private let pipelineComposite: MTLComputePipelineState

    private var refinedAlphaTexture: MTLTexture?
    private var stabilizedAlphaTexture: MTLTexture?
    private var prevAlphaTexture: MTLTexture?
    private var dummyBgTexture: MTLTexture?
    private var dummyCamCbCrTexture: MTLTexture?
    private var hasPreviousFrame = false

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.device = dev
        guard let queue = dev.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let c = cache else { return nil }
        self.textureCache = c

        var library: MTLLibrary?
        let bundle = Bundle(for: VGLiveGreenScreenCompositor.self)
        if let defaultLib = try? dev.makeDefaultLibrary(bundle: bundle) {
            library = defaultLib
        } else if let metalBundleURL = bundle.url(forResource: "VanguardMetal", withExtension: "bundle"),
                  let metalBundle = Bundle(url: metalBundleURL),
                  let metalLibURL = metalBundle.url(forResource: "default", withExtension: "metallib") {
            library = try? dev.makeLibrary(filepath: metalLibURL.path)
        } else if let mainMetalBundleURL = Bundle.main.url(forResource: "VanguardMetal", withExtension: "bundle"),
                  let metalBundle = Bundle(url: mainMetalBundleURL),
                  let metalLibURL = metalBundle.url(forResource: "default", withExtension: "metallib") {
            library = try? dev.makeLibrary(filepath: metalLibURL.path)
        } else {
            library = dev.makeDefaultLibrary()
        }

        guard let lib = library,
              let fnGuided = lib.makeFunction(name: "kernel_greenscreen_guided_filter"),
              let fnTemporal = lib.makeFunction(name: "kernel_greenscreen_temporal_stabilize"),
              let fnComposite = lib.makeFunction(name: "kernel_greenscreen_composite_despill") else {
            NSLog("[VGGPUZeroMetalPipeline] Required Metal compute functions not found in library")
            return nil
        }

        do {
            self.pipelineGuided = try dev.makeComputePipelineState(function: fnGuided)
            self.pipelineTemporal = try dev.makeComputePipelineState(function: fnTemporal)
            self.pipelineComposite = try dev.makeComputePipelineState(function: fnComposite)
        } catch {
            NSLog("[VGGPUZeroMetalPipeline] Failed to create compute pipeline state: %@", error.localizedDescription)
            return nil
        }
    }

    private func ensureIntermediateTextures(width: Int, height: Int) {
        if refinedAlphaTexture == nil || refinedAlphaTexture?.width != width || refinedAlphaTexture?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            refinedAlphaTexture = device.makeTexture(descriptor: desc)
            stabilizedAlphaTexture = device.makeTexture(descriptor: desc)
            prevAlphaTexture = device.makeTexture(descriptor: desc)
            hasPreviousFrame = false
        }
        if dummyBgTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            if let tex = device.makeTexture(descriptor: desc) {
                var black: UInt32 = 0xFF0A0A0A
                tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)
                dummyBgTexture = tex
            }
        }
        if dummyCamCbCrTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            if let tex = device.makeTexture(descriptor: desc) {
                var neutral: UInt16 = 0x8080
                tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &neutral, bytesPerRow: 2)
                dummyCamCbCrTexture = tex
            }
        }
    }

    func makeTexture(from buffer: CVPixelBuffer, planeIndex: Int = 0, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
        let isPlanar = CVPixelBufferIsPlanar(buffer)
        let w = isPlanar ? CVPixelBufferGetWidthOfPlane(buffer, planeIndex) : CVPixelBufferGetWidth(buffer)
        let h = isPlanar ? CVPixelBufferGetHeightOfPlane(buffer, planeIndex) : CVPixelBufferGetHeight(buffer)
        let attrs: [CFString: Any] = [
            kCVMetalTextureUsage: usage.rawValue
        ]
        var cvTexOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            attrs as CFDictionary,
            pixelFormat,
            w,
            h,
            planeIndex,
            &cvTexOut
        )
        guard status == kCVReturnSuccess, let cvTex = cvTexOut else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    func encode(
        commandBuffer cmdBuf: MTLCommandBuffer,
        cameraBuffer: CVPixelBuffer,
        matteTexture: MTLTexture,
        backgroundBuffer: CVPixelBuffer?,
        outputBuffer: CVPixelBuffer,
        canvasWidth: Int,
        canvasHeight: Int,
        solidColor: SIMD4<Float>,
        cropUniforms: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
        rotationIndex: UInt32 = 0,
        mirrorCorrection: UInt32 = 0,
        outputMode: UInt32? = nil
    ) -> Bool {
        ensureIntermediateTextures(width: canvasWidth, height: canvasHeight)
        guard let refinedAlpha = refinedAlphaTexture,
              let stabilizedAlpha = stabilizedAlphaTexture,
              let prevAlpha = prevAlphaTexture else {
            return false
        }

        let camFmt = CVPixelBufferGetPixelFormatType(cameraBuffer)
        let isBiPlanar = (camFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                          camFmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        var camYTex: MTLTexture?
        var camCbCrTex: MTLTexture?
        if isBiPlanar {
            camYTex = makeTexture(from: cameraBuffer, planeIndex: 0, pixelFormat: .r8Unorm, usage: .shaderRead)
            camCbCrTex = makeTexture(from: cameraBuffer, planeIndex: 1, pixelFormat: .rg8Unorm, usage: .shaderRead)
        } else {
            camYTex = makeTexture(from: cameraBuffer, planeIndex: 0, pixelFormat: .bgra8Unorm, usage: .shaderRead)
            camCbCrTex = dummyCamCbCrTexture
        }
        guard let camY = camYTex else { return false }
        let camCbCr = camCbCrTex ?? dummyCamCbCrTexture!

        guard let outTex = makeTexture(from: outputBuffer, planeIndex: 0, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .shaderWrite]) else {
            return false
        }

        var bgTex: MTLTexture? = nil
        if let bgBuffer = backgroundBuffer {
            bgTex = makeTexture(from: bgBuffer, planeIndex: 0, pixelFormat: .bgra8Unorm, usage: .shaderRead)
        }
        if bgTex == nil {
            bgTex = dummyBgTexture
        }

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let numGroups = MTLSize(
            width: (canvasWidth + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (canvasHeight + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )

        // Pass 1: 25-Point Isotropic Guided Filter
        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.label = "GPUZero_GuidedFilter"
            enc.setComputePipelineState(pipelineGuided)
            enc.setTexture(camY, index: 0)
            enc.setTexture(matteTexture, index: 1)
            enc.setTexture(refinedAlpha, index: 2)
            var uniforms = GPUZeroGuidedUniforms(
                resolution: SIMD2<Float>(Float(canvasWidth), Float(canvasHeight)),
                eps: 0.0001,
                filterEnabled: 1,
                cropUniforms: cropUniforms,
                rotationIndex: rotationIndex,
                mirrorCorrection: mirrorCorrection,
                isBiPlanar: isBiPlanar ? 1 : 0
            )
            enc.setBytes(&uniforms, length: MemoryLayout<GPUZeroGuidedUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
            enc.endEncoding()
        }

        // Pass 2: Temporal Stabilize
        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.label = "GPUZero_TemporalStabilize"
            enc.setComputePipelineState(pipelineTemporal)
            enc.setTexture(refinedAlpha, index: 0)
            enc.setTexture(hasPreviousFrame ? prevAlpha : refinedAlpha, index: 1)
            enc.setTexture(stabilizedAlpha, index: 2)
            var uniforms = GPUZeroTemporalUniforms(
                resolution: SIMD2<Float>(Float(canvasWidth), Float(canvasHeight)),
                stabilizerEnabled: hasPreviousFrame ? 1 : 0
            )
            enc.setBytes(&uniforms, length: MemoryLayout<GPUZeroTemporalUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
            enc.endEncoding()
        }

        // Pass 3: Composite + Despill
        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.label = "GPUZero_CompositeDespill"
            enc.setComputePipelineState(pipelineComposite)
            enc.setTexture(camY, index: 0)
            enc.setTexture(camCbCr, index: 1)
            enc.setTexture(stabilizedAlpha, index: 2)
            enc.setTexture(bgTex, index: 3)
            enc.setTexture(outTex, index: 4)
            var uniforms = GPUZeroCompositeUniforms(
                resolution: SIMD2<Float>(Float(canvasWidth), Float(canvasHeight)),
                solidColor: solidColor,
                outputMode: outputMode ?? ((backgroundBuffer != nil) ? 2 : 1),
                despillEnabled: 1,
                cropUniforms: cropUniforms,
                rotationIndex: rotationIndex,
                mirrorCorrection: mirrorCorrection,
                isBiPlanar: isBiPlanar ? 1 : 0
            )
            enc.setBytes(&uniforms, length: MemoryLayout<GPUZeroCompositeUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
            enc.endEncoding()
        }

        // Zero-copy pointer swap for temporal stability
        let tmp = prevAlphaTexture
        prevAlphaTexture = stabilizedAlphaTexture
        stabilizedAlphaTexture = tmp
        hasPreviousFrame = true

        return true
    }

    func render(
        cameraBuffer: CVPixelBuffer,
        maskBuffer: CVPixelBuffer,
        backgroundBuffer: CVPixelBuffer?,
        outputBuffer: CVPixelBuffer,
        canvasWidth: Int,
        canvasHeight: Int,
        solidColor: SIMD4<Float>,
        cropUniforms: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
        rotationIndex: UInt32 = 0,
        mirrorCorrection: UInt32 = 0
    ) -> Bool {
        let maskFmt = CVPixelBufferGetPixelFormatType(maskBuffer)
        let maskPixelFormat: MTLPixelFormat = (maskFmt == kCVPixelFormatType_32BGRA) ? .bgra8Unorm : .r8Unorm
        guard let maskTex = makeTexture(from: maskBuffer, planeIndex: 0, pixelFormat: maskPixelFormat, usage: .shaderRead) else {
            return false
        }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return false }
        cmdBuf.label = "GPUZeroGreenScreen"
        let ok = encode(
            commandBuffer: cmdBuf,
            cameraBuffer: cameraBuffer,
            matteTexture: maskTex,
            backgroundBuffer: backgroundBuffer,
            outputBuffer: outputBuffer,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            solidColor: solidColor,
            cropUniforms: cropUniforms,
            rotationIndex: rotationIndex,
            mirrorCorrection: mirrorCorrection
        )
        if ok {
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
        }
        return ok
    }

    func renderStraightAlpha(
        commandBuffer cmdBuf: MTLCommandBuffer? = nil,
        cameraBuffer: CVPixelBuffer,
        matteTexture: MTLTexture,
        outputBuffer: CVPixelBuffer,
        canvasWidth: Int,
        canvasHeight: Int,
        cropUniforms: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
        rotationIndex: UInt32 = 0,
        mirrorCorrection: UInt32 = 0
    ) -> Bool {
        let cb = cmdBuf ?? commandQueue.makeCommandBuffer()
        guard let commandBuffer = cb else { return false }
        commandBuffer.label = "GPUZeroStraightAlpha"
        let ok = encode(
            commandBuffer: commandBuffer,
            cameraBuffer: cameraBuffer,
            matteTexture: matteTexture,
            backgroundBuffer: nil,
            outputBuffer: outputBuffer,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            solidColor: SIMD4<Float>(0, 0, 0, 0),
            cropUniforms: cropUniforms,
            rotationIndex: rotationIndex,
            mirrorCorrection: mirrorCorrection,
            outputMode: 0
        )
        if ok && cmdBuf == nil {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        return ok
    }
}
