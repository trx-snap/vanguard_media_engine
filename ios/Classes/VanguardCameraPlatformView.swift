// VanguardCameraPlatformView.swift
// Phase 3: MTKView-based camera preview PlatformView.
//
// Rendering path:
//   VanguardCameraMediaSource (_captureQueue) → onFrame:pts: → _latestBuffer swap
//   CADisplayLink (main thread, 60fps) → draw(in:) → CVMetalTextureCacheCreateTextureFromImage
//   → MTLRenderCommandEncoder (VanguardCompositor.metal) → MTKView.currentDrawable → display
//
// Zero copies: CVPixelBuffer IOSurface is GPU-mapped directly — no memcpy in render path.
// Phase 4: insert filterChain[] between _latestBuffer and MTLTexture upload — zero change here.

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
    private let mtkView:       MTKView
    private let device:        MTLDevice
    private var commandQueue:  MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var textureCache:  CVMetalTextureCache! // swiftlint:disable:this implicitly_unwrapped_optional

    // ── Phase 4: Filter Chain ────────────────────────────────────────────────
    @objc public var filterChain: [VanguardFilterNode] = []

    // ── Latest frame (capture queue → main thread) ────────────────────────────
    // os_unfair_lock: ~2ns, priority-aware. One pointer swap per frame.
    private var latestBuffer:  CVPixelBuffer?
    private var bufferLock     = os_unfair_lock_s()

    // ─────────────────────────────────────────────────────────────────────────
    init(frame: CGRect) {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("[Vanguard] Metal not available on this device")
        }
        device  = metalDevice
        mtkView = MTKView(frame: frame, device: metalDevice)

        // Continuous mode: CADisplayLink fires draw(in:) at preferredFramesPerSecond.
        // We do NOT call setNeedsDisplay — MTKView pulls at vsync rate.
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
    }

    func view() -> UIView { mtkView }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Metal setup (called once in init)

    private func _setupMetal() {
        commandQueue = device.makeCommandQueue()!
        commandQueue.label = "com.vanguard.camera.render"

        // Texture cache: reuses CVMetalTexture objects per CVPixelBuffer IOSurface.
        // First call per new IOSurface: ~0.5ms. Cache hits: ~0.1ms.
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache!

        // Pipeline state from VanguardCompositor.metal (pre-compiled .metallib at build time).
        // No runtime compilation cost.
        guard let library = device.makeDefaultLibrary() else {
            NSLog("[Vanguard] Metal library not found")
            return
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label                           = "VanguardCameraRender"
        descriptor.vertexFunction                  = library.makeFunction(name: "vanguard_vertex")
        descriptor.fragmentFunction                = library.makeFunction(name: "vanguard_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Frame receiver (called on _captureQueue — must be fast)

    // @objc to bridge with VanguardCameraFrameReceiver ObjC protocol
    @objc func onFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
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
        // 'buffer' is a strong Swift local — ARC retains it until end of scope.
        // No manual CVPixelBufferRetain needed.
        os_unfair_lock_unlock(&bufferLock)

        guard let drawable    = view.currentDrawable,
              let renderPass  = view.currentRenderPassDescriptor,
              let cmdBuffer   = commandQueue.makeCommandBuffer(),
              let pso         = pipelineState else { return }

        // ── Zero-copy: CVPixelBuffer → MTLTexture via IOSurface-backed CVMetalTexture ──
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            buffer,
            nil,                    // pixelFormatType: inferred from buffer (BGRA)
            .bgra8Unorm,
            w, h,
            0,                      // planeIndex: 0 (full buffer — not planar)
            &cvTexture
        )
        guard result == kCVReturnSuccess,
              let cvTex   = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            // CVMetalTextureCache miss — skip this frame, no crash
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }

        // ── Metal render: texture → drawable (VanguardCompositor.metal) ───────
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
        encoder.label = "VanguardCameraFrame"
        encoder.setRenderPipelineState(pso)
        encoder.setFragmentTexture(texture, index: 0)
        // Full-screen quad: 4 vertices driven by vertex shader index [0..3]
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()

        // Flush stale cache entries (IOSurfaces whose CVPixelBuffer was released)
        CVMetalTextureCacheFlush(textureCache, 0)

        // Phase 4 insertion point — between buffer and texture creation:
        // let filtered = filterChain.reduce(buffer) { buf, node in
        //     node.processBuffer(buf, at: pts, device: device)
        // }
        // Then pass filtered to CVMetalTextureCacheCreateTextureFromImage
        // PlatformView contract unchanged.
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // autoResizeDrawable = true handles this automatically
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

final class VanguardCameraViewFactory: NSObject, FlutterPlatformViewFactory {

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        VanguardCameraPlatformView(frame: frame)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
