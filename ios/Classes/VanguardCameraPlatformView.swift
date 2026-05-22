// VanguardCameraPlatformView.swift
// Phase 3: MTKView-based camera preview PlatformView.
//
// Rendering path:
//   VanguardCameraMediaSource (_captureQueue) → onFrame:pts: → _latestBuffer swap
//   CADisplayLink (main thread, 60fps) → draw(in:) → CVMetalTextureCacheCreateTextureFromImage
//   → MTLRenderCommandEncoder (vanguard_vertex + vanguard_blit_rotated) → MTKView.currentDrawable → display
//
// Zero copies: CVPixelBuffer IOSurface is GPU-mapped directly — no memcpy in render path.
//
// ── POC 0 fixes (Phase 6B-POC0) ────────────────────────────────────────────
// Bug 1 fixed: vanguard_fragment (non-existent) → vanguard_blit_rotated
// Bug 2 fixed: added MTLVertexDescriptor + quad vertex buffer (vanguard_vertex uses [[stage_in]])
// Bug 3 fixed: synthetic CVPixelBuffer feeds latestBuffer for render-path validation
// Bug 4 fixed: makeDefaultLibrary() (app bundle, no shaders) →
//              Bundle(for: Self.self) (framework bundle, has VanguardCompositor.metallib)
// ────────────────────────────────────────────────────────────────────────────

import Flutter
import MetalKit
import AVFoundation
import os.lock

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Frame receiver protocol bridging (Swift ↔ ObjC)

// Declared in VanguardCameraMediaSource.h as @protocol VanguardCameraFrameReceiver.
// Swift conformance below.

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - VanguardCameraPlatformView

final class VanguardCameraPlatformView: NSObject, FlutterPlatformView, MTKViewDelegate, VanguardCameraFrameReceiver {

    // ── Metal resources (created in init — never lazily) ─────────────────────
    private let mtkView:        MTKView
    private let device:         MTLDevice
    private var commandQueue:   MTLCommandQueue!
    private var pipelineState:  MTLRenderPipelineState?  // nil = setup failed (logged)
    private var textureCache:   CVMetalTextureCache!
    private var quadVertexBuf:  MTLBuffer!               // full-screen quad — created once

    // ── Phase 4: Filter Chain ────────────────────────────────────────────────
    @objc public var filterChain: [VanguardFilterNode] = []

    // ── Latest frame (capture queue → main thread) ────────────────────────────
    // os_unfair_lock: ~2ns, priority-aware. One pointer swap per frame.
    private var latestBuffer:  CVPixelBuffer?
    private var bufferLock     = os_unfair_lock_s()

    // ── POC 0/1: one-shot log flags (never spam per-frame) ──────────────────────
    private var _poc0DrawLogged    = false
    // ── POC 1: first live frame received (replaces synthetic teal) ───────────────
    private var _poc1FrameLogged   = false

    // ─────────────────────────────────────────────────────────────────────────
    init(frame: CGRect) {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("[Vanguard] Metal not available on this device")
        }
        device  = metalDevice
        mtkView = MTKView(frame: frame, device: metalDevice)

        // Continuous mode: CADisplayLink fires draw(in:) at preferredFramesPerSecond.
        mtkView.isPaused                 = false
        mtkView.enableSetNeedsDisplay    = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.framebufferOnly          = false  // allow texture reads (Phase 4 filters)
        mtkView.colorPixelFormat         = .bgra8Unorm
        mtkView.autoResizeDrawable       = true
        mtkView.contentScaleFactor       = UIScreen.main.scale

        super.init()

        mtkView.delegate = self
        _setupMetal()

        // ── POC 0: install synthetic test frame ───────────────────────────────
        // Feeds a 64×64 solid blue-green BGRA CVPixelBuffer so draw(in:) has
        // something to render without needing a live camera.
        // Remove or guard with #if DEBUG before Phase 7 production migration.
        _poc0_installSyntheticFrame()
    }

    func view() -> UIView { mtkView }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Metal setup (called once in init)

    private func _setupMetal() {
        commandQueue       = device.makeCommandQueue()!
        commandQueue.label = "com.vanguard.camera.render"

        // Texture cache: reuses CVMetalTexture objects per CVPixelBuffer IOSurface.
        // First call per new IOSurface: ~0.5ms. Cache hits: ~0.1ms.
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache!

        // ── Bug 4 fix: load Metal library from the framework bundle ───────────
        // device.makeDefaultLibrary() loads from the MAIN app bundle, which has
        // no compiled .metal shaders. VanguardCompositor.metal is compiled into
        // default.metallib inside vanguard_media_engine.framework.
        // Bundle(for: Self.self) resolves to that framework bundle on all
        // deployment configurations (CocoaPods use_frameworks!, static xcframework).
        // Pattern is identical to VanguardMetalRenderer._setupMetal (line 286–289).
        let bundle = Bundle(for: Self.self)
        var libraryError: NSError?
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            NSLog("[Vanguard] POC0 ERROR: Metal library not found in bundle %@ — pipelineState will be nil",
                  bundle.bundleURL.lastPathComponent)
            return
        }
        NSLog("[Vanguard] POC0: Metal library loaded from bundle %@",
              bundle.bundleURL.lastPathComponent)

        // ── Bug 1 fix: vanguard_blit_rotated (was: non-existent vanguard_fragment) ──
        // vanguard_blit_rotated accepts a single BGRA texture and two uint32
        // fragment uniforms: rotationIndex [buffer(0)] and isHLG [buffer(1)].
        // It reuses vanguard_vertex (position + texCoord full-screen quad geometry).
        guard let vertexFn   = library.makeFunction(name: "vanguard_vertex"),
              let fragmentFn = library.makeFunction(name: "vanguard_blit_rotated") else {
            NSLog("[Vanguard] POC0 ERROR: required shader functions not found in library")
            return
        }

        // ── Bug 2 fix: MTLVertexDescriptor matching vanguard_vertex VertexIn ──
        // struct VertexIn { float2 position [[attribute(0)]]; float2 texCoord [[attribute(1)]]; }
        // Identical layout to VanguardMetalRenderer._setupBlitPipeline (line 369–377).
        let vtxDesc = MTLVertexDescriptor()
        vtxDesc.attributes[0].format      = .float2   // position
        vtxDesc.attributes[0].offset      = 0
        vtxDesc.attributes[0].bufferIndex = 0
        vtxDesc.attributes[1].format      = .float2   // texCoord
        vtxDesc.attributes[1].offset      = 8         // sizeof(float2) = 8 bytes
        vtxDesc.attributes[1].bufferIndex = 0
        vtxDesc.layouts[0].stride         = 16        // sizeof(float4) = 16 bytes
        vtxDesc.layouts[0].stepFunction   = .perVertex

        let desc = MTLRenderPipelineDescriptor()
        desc.label                           = "VanguardCameraRender-POC0"
        desc.vertexFunction                  = vertexFn
        desc.fragmentFunction                = fragmentFn
        desc.vertexDescriptor                = vtxDesc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            NSLog("[Vanguard] POC0: pipelineState created successfully ✓")
        } catch {
            NSLog("[Vanguard] POC0 ERROR: pipelineState creation failed: %@", error.localizedDescription)
            pipelineState = nil
            return
        }

        // ── Bug 2 fix continued: pre-allocate the full-screen quad vertex buffer ──
        // NDC-pre-transform positions [0,1] (vanguard_vertex applies: x*2-1, -(y*2-1))
        // 4 vertices × 4 floats = 64 bytes. Identical to kQuad in VanguardMetalRenderer (line 452–455).
        let quad: [Float] = [
            // position (x,y)   texCoord (u,v)
            0.0, 0.0,            0.0, 0.0,
            1.0, 0.0,            1.0, 0.0,
            0.0, 1.0,            0.0, 1.0,
            1.0, 1.0,            1.0, 1.0,
        ]
        quadVertexBuf = device.makeBuffer(bytes: quad,
                                          length: quad.count * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        quadVertexBuf.label = "com.vanguard.camera.quad"
        NSLog("[Vanguard] POC0: quad vertex buffer created ✓")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - POC 0: Synthetic test frame
    // Creates a 64×64 solid colour BGRA CVPixelBuffer and feeds it as if it
    // were a real camera frame. Proves the entire draw path without camera.
    // Remove or guard with #if DEBUG before Phase 7 production migration.

    private func _poc0_installSyntheticFrame() {
        let width  = 64
        let height = 64
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            NSLog("[Vanguard] POC0 WARNING: synthetic pixel buffer creation failed (%d)", status)
            return
        }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            for row in 0..<height {
                let rowPtr = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for col in 0..<width {
                    let px = col * 4
                    // BGRA: solid teal (B=180, G=140, R=60, A=255)
                    rowPtr[px + 0] = 180  // B
                    rowPtr[px + 1] = 140  // G
                    rowPtr[px + 2] = 60   // R
                    rowPtr[px + 3] = 255  // A
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        // Install via the same lock path as onFrame:pts: so draw(in:) picks it up.
        os_unfair_lock_lock(&bufferLock)
        latestBuffer = pb
        os_unfair_lock_unlock(&bufferLock)
        NSLog("[Vanguard] POC0: synthetic 64×64 teal frame installed in latestBuffer ✓")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Frame receiver (called on _captureQueue — must be fast)

    // @objc to bridge with VanguardCameraFrameReceiver ObjC protocol
    @objc func onFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        // ── POC 1: log first live frame arrival (one-shot, not per-frame) ────────
        if !_poc1FrameLogged {
            _poc1FrameLogged = true
            NSLog("[Vanguard] POC1: first live camera frame received in VanguardCameraPlatformView ✓")
        }

        var currentBuffer = pixelBuffer
        for node in filterChain {
            if node.enabled {
                currentBuffer = node.processBuffer(currentBuffer, at: pts, device: device).takeUnretainedValue()
            }
        }

        // Swap _latestBuffer under lock.
        // Swift ARC retains pixelBuffer on assignment and releases the old value
        // when it goes out of scope — no manual CVPixelBufferRetain/Release needed.
        let old: CVPixelBuffer?
        os_unfair_lock_lock(&bufferLock)
        old = latestBuffer
        latestBuffer = currentBuffer  // +1 ARC retain on currentBuffer
        os_unfair_lock_unlock(&bufferLock)
        _ = old  // ARC releases old when this goes out of scope (outside lock)
        // MTKView draws at vsync — no setNeedsDisplay dispatch needed.
    }

    /// Called by plugin to adjust preview FPS (jitter-triggered throttle).
    @objc func setPreviewFPS(_ fps: Int) {
        mtkView.preferredFramesPerSecond = fps
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - MTKViewDelegate — called on main thread at vsync

    func draw(in view: MTKView) {
        // Snapshot latestBuffer under lock — ARC keeps it alive for this scope.
        os_unfair_lock_lock(&bufferLock)
        guard let buffer = latestBuffer else {
            os_unfair_lock_unlock(&bufferLock)
            return
        }
        os_unfair_lock_unlock(&bufferLock)

        guard let drawable   = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let cmdBuffer  = commandQueue.makeCommandBuffer(),
              let pso        = pipelineState,
              let qvb        = quadVertexBuf else { return }

        // ── POC 0: log once when draw path is reached ─────────────────────────
        if !_poc0DrawLogged {
            _poc0DrawLogged = true
            NSLog("[Vanguard] POC0: draw(in:) reached — MTKView render path is live ✓")
        }

        // ── Zero-copy: CVPixelBuffer → MTLTexture via IOSurface-backed CVMetalTexture ──
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let cvResult = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            buffer,
            nil,            // attributes: inferred from buffer (BGRA)
            .bgra8Unorm,
            w, h,
            0,              // planeIndex: 0 (packed — not planar)
            &cvTexture
        )
        guard cvResult == kCVReturnSuccess,
              let cvTex   = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }

        // ── Metal render: blit texture → drawable ────────────────────────────
        // vanguard_blit_rotated uniforms:
        //   buffer(0) → rotationIndex: uint32  (0 = identity, 1 = +90°, 2 = -90°, 3 = 180°)
        //   buffer(1) → isHLG:         uint32  (0 = SDR/sRGB, 1 = HLG colour correction)
        // POC 0: identity rotation (0), SDR (0). Both are zero-copy stack values.
        var rotationIndex: UInt32 = 0
        var isHLG: UInt32         = 0

        guard let rotBuf = device.makeBuffer(bytes: &rotationIndex,
                                             length: MemoryLayout<UInt32>.size,
                                             options: .storageModeShared),
              let hlgBuf = device.makeBuffer(bytes: &isHLG,
                                             length: MemoryLayout<UInt32>.size,
                                             options: .storageModeShared) else { return }

        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
        encoder.label = "VanguardCameraFrame-POC0"
        encoder.setRenderPipelineState(pso)

        // ── Bug 2 fix: bind quad vertex buffer to slot 0 (required by vanguard_vertex) ──
        encoder.setVertexBuffer(qvb, offset: 0, index: 0)

        // Fragment: texture + two uint32 uniforms
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBuffer(rotBuf, offset: 0, index: 0)
        encoder.setFragmentBuffer(hlgBuf, offset: 0, index: 1)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()

        // Flush stale cache entries (IOSurfaces whose CVPixelBuffer was released)
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // autoResizeDrawable = true handles resize automatically.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Dealloc

    deinit {
        os_unfair_lock_lock(&bufferLock)
        latestBuffer = nil          // ARC releases the buffer
        os_unfair_lock_unlock(&bufferLock)
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - VanguardCameraViewFactory
//
// POC 1: latestInstance tracks the most recently created VanguardCameraPlatformView
// via a weak reference so the plugin can set cameraSource.frameReceiver without
// creating a retain cycle.  Only one PlatformView should be mounted at a time;
// this is POC-only and documented as such.  Remove or replace with a proper
// registration mechanism before production (Phase 7).

final class VanguardCameraViewFactory: NSObject, FlutterPlatformViewFactory {

    // ── POC 1: weak ref to last created view — plugin reads this after mount ──
    // POC-only. Do NOT use in production (no support for multiple simultaneous views).
    // REMOVE before Phase 7 / production.
    weak var latestInstance: VanguardCameraPlatformView?

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        let view = VanguardCameraPlatformView(frame: frame)
        latestInstance = view  // weak — no retain cycle
        NSLog("[Vanguard] POC1: VanguardCameraPlatformView created (viewId=%lld)", viewId)
        return view
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
