// VanguardCameraPlatformView.swift
// Phase 3: MTKView-based camera preview PlatformView.
//
// Rendering path:
//   VanguardCameraMediaSource (_captureQueue) -> onFrame:pts: -> _latestBuffer swap
//   CADisplayLink (main thread, 60fps) -> draw(in:) -> CVMetalTextureCacheCreateTextureFromImage
//   -> MTLRenderCommandEncoder (vanguard_vertex + vanguard_blit_rotated) -> MTKView.currentDrawable -> display
//
// Zero copies: CVPixelBuffer IOSurface is GPU-mapped directly -- no memcpy in render path.
//
// -- POC 0 fixes (Phase 6B-POC0) -----------------------------------------------
// Bug 1 fixed: vanguard_fragment (non-existent) -> vanguard_blit_rotated
// Bug 2 fixed: added MTLVertexDescriptor + quad vertex buffer (vanguard_vertex uses [[stage_in]])
// Bug 3 fixed: synthetic CVPixelBuffer feeds latestBuffer for render-path validation
// Bug 4 fixed: makeDefaultLibrary() (app bundle, no shaders) ->
//              Bundle(for: Self.self) (framework bundle, has VanguardCompositor.metallib)
// -------------------------------------------------------------------------------
//
// -- Phase 6C Option B ----------------------------------------------------------
// Capture buffers remain stable (always 1080x1920, orientation-locked to portrait
// by VanguardCameraMediaSource). VGNativeCameraViewController owns orientation
// decisions and pushes displayRotationIndex to this view.
// draw(in:) computes aspect-fill crop + applies rotation + mirror correction
// in a single Metal pass using vanguard_blit_rotated_ex.
// -------------------------------------------------------------------------------

import Flutter
import MetalKit
import AVFoundation
import os.lock

// -----------------------------------------------------------------------------
// MARK: - Frame receiver protocol bridging (Swift <-> ObjC)

// Declared in VanguardCameraMediaSource.h as @protocol VanguardCameraFrameReceiver.
// Swift conformance below.

// -----------------------------------------------------------------------------
// MARK: - VanguardCameraPlatformView

final class VanguardCameraPlatformView: NSObject, FlutterPlatformView, MTKViewDelegate, VanguardCameraFrameReceiver {

    // -- Metal resources (created in init -- never lazily) -----------------------
    private let mtkView:        MTKView
    private let device:         MTLDevice
    private var commandQueue:   MTLCommandQueue!
    private var pipelineState:  MTLRenderPipelineState?  // nil = setup failed (logged)
    private var poc6cPipelineState: MTLRenderPipelineState?
    private var textureCache:   CVMetalTextureCache!
    private var quadVertexBuf:  MTLBuffer!               // full-screen quad -- created once

    // -- Phase 4: Filter Chain --------------------------------------------------
    @objc public var filterChain: [VanguardFilterNode] = []

    // -- Latest frame (capture queue -> main thread) -----------------------------
    // os_unfair_lock: ~2ns, priority-aware. One pointer swap per frame.
    private var latestBuffer:  CVPixelBuffer?
    private var bufferLock     = os_unfair_lock_s()

    // -- POC 0/1: one-shot log flags (never spam per-frame) ----------------------
    private var _poc0DrawLogged    = false
    // -- Phase 6C: one-shot log on first draw to confirm active render path ------
    private var _poc6cRenderPathLogged = false
    // -- POC 1: first live frame received (replaces synthetic teal) ---------------
    private var _poc1FrameLogged   = false

    // -- Phase 6C Option B: Presentation rotation state -------------------------
    // Set by VGNativeCameraViewController via viewWillTransition(to:with:).
    // VanguardCameraPlatformView is a renderer ONLY -- it does NOT observe
    // UIDeviceOrientation.  The VC owns all orientation decisions.
    //
    //   displayRotationIndex:
    //     0 = portrait (identity)
    //     1 = landscapeLeft  (home right, +90 CW)
    //     2 = landscapeRight (home left, -90 CCW)
    //     3 = 180 (not used -- PortraitUpsideDown excluded from supported orientations)
    //
    //   mirrorCorrectionEnabled:
    //     YES = front camera in a rotated orientation (rotationIndex != 0).
    //     Flips tex.x after rotation to correct for portrait-space mirror
    //     being applied as a display-space wrong axis.
    //     Easy to disable per smoke test: set to NO if mirror is correct without it.
    //
    //   isFrontCamera:
    //     YES = current camera position is front-facing. Used for mirror correction.
    @objc public var displayRotationIndex: UInt32 = 0
    @objc public var mirrorCorrectionEnabled: Bool = false
    @objc public var isFrontCamera: Bool = false

    // Last logged crop/rotation values -- only log when something changes.
    private var _lastLoggedSrcW: Int = 0
    private var _lastLoggedSrcH: Int = 0
    private var _lastLoggedDstW: Int = 0
    private var _lastLoggedDstH: Int = 0
    private var _lastLoggedRotation: UInt32 = 999 // force first log

    // -------------------------------------------------------------------------
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

        // -- POC 0: install synthetic test frame ---------------------------------
        // Feeds a 64x64 solid blue-green BGRA CVPixelBuffer so draw(in:) has
        // something to render without needing a live camera.
        // Remove or guard with #if DEBUG before Phase 7 production migration.
        _poc0_installSyntheticFrame()
    }

    func view() -> UIView { mtkView }

    // -------------------------------------------------------------------------
    // MARK: - Metal setup (called once in init)

    private func _setupMetal() {
        commandQueue       = device.makeCommandQueue()!
        commandQueue.label = "com.vanguard.camera.render"

        // Texture cache: reuses CVMetalTexture objects per CVPixelBuffer IOSurface.
        // First call per new IOSurface: ~0.5ms. Cache hits: ~0.1ms.
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache!

        // -- Bug 4 fix: load Metal library from the framework bundle -------------
        // device.makeDefaultLibrary() loads from the MAIN app bundle, which has
        // no compiled .metal shaders. VanguardCompositor.metal is compiled into
        // default.metallib inside vanguard_media_engine.framework.
        // Bundle(for: Self.self) resolves to that framework bundle on all
        // deployment configurations (CocoaPods use_frameworks!, static xcframework).
        let bundle = Bundle(for: Self.self)
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            NSLog("[Vanguard] POC0 ERROR: Metal library not found in bundle %@ -- pipelineState will be nil",
                  bundle.bundleURL.lastPathComponent)
            return
        }
        NSLog("[Vanguard] POC0: Metal library loaded from bundle %@",
              bundle.bundleURL.lastPathComponent)

        guard let vertexFn   = library.makeFunction(name: "vanguard_vertex"),
              let fragmentFn = library.makeFunction(name: "vanguard_blit_rotated") else {
            NSLog("[Vanguard] POC0 ERROR: required shader functions not found in library")
            return
        }

        // Phase 6C: load extended fragment function for rotation+crop+mirror.
        // Falls back gracefully if not available (POC0/1/2 path unaffected).
        let fragmentFnEx = library.makeFunction(name: "vanguard_blit_rotated_ex")

        // -- Bug 2 fix: MTLVertexDescriptor matching vanguard_vertex VertexIn ----
        let vtxDesc = MTLVertexDescriptor()
        vtxDesc.attributes[0].format      = .float2   // position
        vtxDesc.attributes[0].offset      = 0
        vtxDesc.attributes[0].bufferIndex = 0
        vtxDesc.attributes[1].format      = .float2   // texCoord
        vtxDesc.attributes[1].offset      = 8
        vtxDesc.attributes[1].bufferIndex = 0
        vtxDesc.layouts[0].stride         = 16
        vtxDesc.layouts[0].stepFunction   = .perVertex

        let desc = MTLRenderPipelineDescriptor()
        desc.label                           = "VanguardCameraRender-POC0"
        desc.vertexFunction                  = vertexFn
        desc.fragmentFunction                = fragmentFn
        desc.vertexDescriptor                = vtxDesc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            NSLog("[Vanguard] POC0: pipelineState created successfully")
        } catch {
            NSLog("[Vanguard] POC0 ERROR: pipelineState creation failed: %@", error.localizedDescription)
            pipelineState = nil
            return
        }

        // Phase 6C: build poc6cPipelineState using vanguard_blit_rotated_ex.
        if let fragmentFnEx = fragmentFnEx {
            let descEx = MTLRenderPipelineDescriptor()
            descEx.label                           = "VanguardCameraRender-6C"
            descEx.vertexFunction                  = vertexFn
            descEx.fragmentFunction                = fragmentFnEx
            descEx.vertexDescriptor                = vtxDesc
            descEx.colorAttachments[0].pixelFormat = .bgra8Unorm
            do {
                poc6cPipelineState = try device.makeRenderPipelineState(descriptor: descEx)
                NSLog("[Vanguard] POC6C: poc6cPipelineState created successfully")
            } catch {
                NSLog("[Vanguard] POC6C WARNING: poc6cPipelineState creation failed: %@ -- falling back",
                      error.localizedDescription)
                poc6cPipelineState = nil
            }
        } else {
            NSLog("[Vanguard] POC6C WARNING: vanguard_blit_rotated_ex not found in library -- falling back")
        }

        // Pre-allocate the full-screen quad vertex buffer.
        let quad: [Float] = [
            0.0, 0.0,  0.0, 0.0,
            1.0, 0.0,  1.0, 0.0,
            0.0, 1.0,  0.0, 1.0,
            1.0, 1.0,  1.0, 1.0,
        ]
        quadVertexBuf = device.makeBuffer(bytes: quad,
                                          length: quad.count * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        quadVertexBuf.label = "com.vanguard.camera.quad"
        NSLog("[Vanguard] POC0: quad vertex buffer created")
    }

    // -------------------------------------------------------------------------
    // MARK: - POC 0: Synthetic test frame

    private func _poc0_installSyntheticFrame() {
        let width  = 64
        let height = 64
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pixelBuffer)
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
                    rowPtr[px + 0] = 180  // B
                    rowPtr[px + 1] = 140  // G
                    rowPtr[px + 2] = 60   // R
                    rowPtr[px + 3] = 255  // A
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        os_unfair_lock_lock(&bufferLock)
        latestBuffer = pb
        os_unfair_lock_unlock(&bufferLock)
        NSLog("[Vanguard] POC0: synthetic 64x64 teal frame installed in latestBuffer")
    }

    // -------------------------------------------------------------------------
    // MARK: - Frame receiver (called on _captureQueue -- must be fast)

    @objc func onFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if !_poc1FrameLogged {
            _poc1FrameLogged = true
            NSLog("[Vanguard] POC1: first live camera frame received in VanguardCameraPlatformView")
        }

        var currentBuffer = pixelBuffer
        for node in filterChain {
            if node.enabled {
                currentBuffer = node.processBuffer(currentBuffer, at: pts, device: device).takeUnretainedValue()
            }
        }

        let old: CVPixelBuffer?
        os_unfair_lock_lock(&bufferLock)
        old = latestBuffer
        latestBuffer = currentBuffer
        os_unfair_lock_unlock(&bufferLock)
        _ = old
    }

    @objc func setPreviewFPS(_ fps: Int) {
        mtkView.preferredFramesPerSecond = fps
    }

    // -------------------------------------------------------------------------
    // MARK: - MTKViewDelegate -- called on main thread at vsync

    func draw(in view: MTKView) {
        // Snapshot latestBuffer under lock.
        os_unfair_lock_lock(&bufferLock)
        guard let buffer = latestBuffer else {
            os_unfair_lock_unlock(&bufferLock)
            return
        }
        os_unfair_lock_unlock(&bufferLock)

        guard let drawable   = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let cmdBuffer  = commandQueue.makeCommandBuffer(),
              let qvb        = quadVertexBuf else { return }

        guard pipelineState != nil || poc6cPipelineState != nil else { return }

        if !_poc0DrawLogged {
            _poc0DrawLogged = true
            NSLog("[Vanguard] POC0: draw(in:) reached -- MTKView render path is live")
        }

        // Zero-copy: CVPixelBuffer -> MTLTexture via IOSurface-backed CVMetalTexture.
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let cvResult = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTexture
        )
        guard cvResult == kCVReturnSuccess,
              let cvTex   = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return
        }

        // -- Phase 6C Option B: use poc6cPipelineState + vanguard_blit_rotated_ex
        // when available. Falls back to original pipelineState for POC0/1/2.
        let usePoc6c  = poc6cPipelineState != nil
        let activePSO = usePoc6c ? poc6cPipelineState! : pipelineState!

        // One-shot: confirm which render path is active on first draw.
        // Used to distinguish Cause A (pipeline nil = fallback, no crop) from
        // Cause C (pipeline OK but rotationIndex wrong) in the landscape audit.
        if !_poc6cRenderPathLogged {
            _poc6cRenderPathLogged = true
            if usePoc6c {
                NSLog("[Vanguard][6C] RENDER PATH: vanguard_blit_rotated_ex active (crop+rotation+mirror)")
            } else {
                NSLog("[Vanguard][6C] RENDER PATH: FALLBACK vanguard_blit_rotated active (rotation only, no crop) -- poc6cPipelineState=nil")
            }
        }

        var rotationIndex: UInt32 = displayRotationIndex
        var isHLG: UInt32         = 0

        // -- Phase 6C: compute aspect-fill crop uniforms -------------------------
        // Source: CVPixelBuffer dims (stable at 1080x1920 while preview-locked).
        // Dest:   drawable dims (changes with UI orientation).
        let dstW      = Int(drawable.texture.width)
        let dstH      = Int(drawable.texture.height)
        let isRotated = (rotationIndex == 1 || rotationIndex == 2)
        let effSrcW   = isRotated ? h : w
        let effSrcH   = isRotated ? w : h

        let scaleX = Double(dstW) / Double(effSrcW)
        let scaleY = Double(dstH) / Double(effSrcH)
        let scale  = max(scaleX, scaleY)

        let visU = Double(dstW) / (Double(effSrcW) * scale)  // <= 1.0
        let visV = Double(dstH) / (Double(effSrcH) * scale)  // <= 1.0

        // Crop uniforms are in display/screen UV space because the shader applies
        // crop BEFORE rotation (Step 1 before Step 2 in vanguard_blit_rotated_ex).
        // visU/visV are computed against effSrcW/H which already reflects the
        // post-rotation effective dimensions. No axis transposition needed.
        let cropScaleU = Float(visU)
        let cropScaleV = Float(visV)
        let cropOffsetU = (1.0 - cropScaleU) / 2.0
        let cropOffsetV = (1.0 - cropScaleV) / 2.0
        var cropUniforms = SIMD4<Float>(cropOffsetU, cropOffsetV, cropScaleU, cropScaleV)

        // Mirror correction: front camera in rotated orientation.
        // Easy to disable: set mirrorCorrectionEnabled = false from the native VC.
        var mirrorCorrection: UInt32 = (mirrorCorrectionEnabled && isFrontCamera
                                        && rotationIndex != 0) ? 1 : 0

        // Log only when layout changes (not per-frame).
        if w != _lastLoggedSrcW || h != _lastLoggedSrcH ||
           dstW != _lastLoggedDstW || dstH != _lastLoggedDstH ||
           rotationIndex != _lastLoggedRotation {
            NSLog("[Vanguard][6C] src=%dx%d dst=%dx%d rotation=%d crop=(%.3f,%.3f,%.3f,%.3f) mirror=%d",
                  w, h, dstW, dstH, rotationIndex,
                  cropOffsetU, cropOffsetV, cropScaleU, cropScaleV, mirrorCorrection)
            _lastLoggedSrcW = w; _lastLoggedSrcH = h
            _lastLoggedDstW = dstW; _lastLoggedDstH = dstH
            _lastLoggedRotation = rotationIndex
        }

        guard let rotBuf = device.makeBuffer(bytes: &rotationIndex,
                                             length: MemoryLayout<UInt32>.size,
                                             options: .storageModeShared),
              let hlgBuf = device.makeBuffer(bytes: &isHLG,
                                             length: MemoryLayout<UInt32>.size,
                                             options: .storageModeShared) else { return }

        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPass)!
        encoder.label = usePoc6c ? "VanguardCameraFrame-6C" : "VanguardCameraFrame-POC0"
        encoder.setRenderPipelineState(activePSO)
        encoder.setVertexBuffer(qvb, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBuffer(rotBuf, offset: 0, index: 0)
        encoder.setFragmentBuffer(hlgBuf, offset: 0, index: 1)

        if usePoc6c {
            guard let cropBuf = device.makeBuffer(bytes: &cropUniforms,
                                                  length: MemoryLayout<SIMD4<Float>>.size,
                                                  options: .storageModeShared),
                  let mirrorBuf = device.makeBuffer(bytes: &mirrorCorrection,
                                                    length: MemoryLayout<UInt32>.size,
                                                    options: .storageModeShared) else {
                encoder.endEncoding()
                return
            }
            encoder.setFragmentBuffer(cropBuf,   offset: 0, index: 2)
            encoder.setFragmentBuffer(mirrorBuf, offset: 0, index: 3)
        }

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // autoResizeDrawable = true handles resize automatically.
    }

    // -------------------------------------------------------------------------
    // MARK: - Dealloc

    deinit {
        os_unfair_lock_lock(&bufferLock)
        latestBuffer = nil
        os_unfair_lock_unlock(&bufferLock)
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}

// -----------------------------------------------------------------------------
// MARK: - VanguardCameraViewFactory
//
// POC 1: latestInstance tracks the most recently created VanguardCameraPlatformView
// via a weak reference so the plugin can set cameraSource.frameReceiver without
// creating a retain cycle.  Only one PlatformView should be mounted at a time;
// this is POC-only and documented as such.  Remove or replace with a proper
// registration mechanism before production (Phase 7).

final class VanguardCameraViewFactory: NSObject, FlutterPlatformViewFactory {

    // -- POC 1: weak ref to last created view -- plugin reads this after mount --
    // POC-only. Do NOT use in production.
    // REMOVE before Phase 7 / production.
    weak var latestInstance: VanguardCameraPlatformView?

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        let view = VanguardCameraPlatformView(frame: frame)
        latestInstance = view
        NSLog("[Vanguard] POC1: VanguardCameraPlatformView created (viewId=%lld)", viewId)
        return view
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
