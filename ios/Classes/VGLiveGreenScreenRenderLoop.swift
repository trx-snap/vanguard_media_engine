// VGLiveGreenScreenRenderLoop.swift
// Generic live green-screen: display-link driven live render loop. Caller-agnostic.
//
// Why a separate loop instead of VGDuetPreviewRenderLoop: that loop is keyed to
// a source-video PTS and goes passive whenever the target PTS does not move, so
// it would stop presenting fresh camera frames over a static background. This
// loop renders on every display tick (coalesced to one in-flight composite)
// regardless of whether the background or foreground rect changed.
//
// Each render:
//   1. snapshots background / foreground rect / keying flag on main,
//   2. takes a +1 retained snapshot of the freshest mask FIRST (with the camera
//      PTS it was computed from), then asks the camera provider for the frame
//      nearest that PTS so mask and foreground describe the same instant; with
//      no mask, or no frame inside the pairing window, the latest camera frame
//      is used instead (never a dropped render),
//   3. composites on renderQueue via VGDuetPreviewCompositor.composite with
//      sourceFrame = static background (full canvas), cameraRect = foreground
//      rect, isGreenScreen = keying flag (CIBlendWithMask when a fresh mask
//      exists; unkeyed camera-over-background otherwise),
//   4. releases the snapshots and presents on main through presentHandler.
//
// Threading:
//   - start / stop / updateBackground / updateForegroundRect / setKeyingEnabled
//     and displayLinkFired run on the main thread. Main-thread confinement makes
//     every state change atomic with respect to the next render, because each
//     render snapshots all loop state on main before crossing to renderQueue.
//   - Compositing runs on a private serial renderQueue; the compositor is
//     immutable after init. Presenting hops back to main.
//
// Explicitly NOT here: Flutter imports, camera/segmenter ownership, session
// state, MethodChannel parsing.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

// MARK: - CADisplayLink weak proxy

/// CADisplayLink retains its target. The proxy holds the loop weakly so the
/// link can never keep a stopped loop (and its captured closures) alive.
private final class VGLiveGreenScreenDisplayLinkProxy: NSObject {
    weak var loop: VGLiveGreenScreenRenderLoop?

    init(loop: VGLiveGreenScreenRenderLoop) {
        self.loop = loop
    }

    @objc func displayLinkFired(_ sender: CADisplayLink) {
        loop?.displayLinkFired(sender)
    }
}

// MARK: - Render loop

final class VGLiveGreenScreenRenderLoop {

    // MARK: Injected seams

    /// A *retained* (+1) fresh segmentation mask plus the camera presentation
    /// timestamp of the frame it was computed from (non-numeric when unknown).
    /// The loop releases `buffer` after compositing.
    struct MaskSnapshot {
        let buffer: Unmanaged<CVPixelBuffer>
        let sourcePTS: CMTime
    }

    /// Returns a *retained* (+1) camera frame snapshot, or nil when no frame is
    /// available. `preferredPTS` (numeric) asks for the frame nearest that
    /// timestamp (the current mask's source PTS); nil asks for the latest
    /// frame. The provider may fall back to the latest frame itself when no
    /// frame is near `preferredPTS`. The loop releases the result after
    /// compositing.
    typealias CameraFrameProvider = (_ preferredPTS: CMTime?) -> Unmanaged<CVPixelBuffer>?

    /// Returns the latest fresh segmentation mask with its source PTS, or nil
    /// when none is available or it is stale. Released by the loop after
    /// compositing.
    typealias MaskProvider = () -> MaskSnapshot?

    /// Invoked on main, only while not stopped, with a composited output buffer.
    typealias PresentHandler = (CVPixelBuffer) -> Void

    private let compositor: VGDuetPreviewCompositor
    private let cameraFrameProvider: CameraFrameProvider
    private let maskProvider: MaskProvider
    private let presentHandler: PresentHandler

    private let renderQueue = DispatchQueue(label: "com.connects.vanguard.livegreenscreen.render",
                                            qos: .userInteractive)

    // MARK: Main-thread state

    /// Static background presented as the full-canvas source layer.
    private var background: CVPixelBuffer
    /// Full-canvas rect for the background layer (top-left origin).
    private let fullCanvasRect: CGRect
    /// Current foreground (keyed camera) rect (top-left origin).
    private var foregroundRect: CGRect
    /// False after a terminal segmentation failure: the camera is presented
    /// unkeyed over the same background.
    private var isKeyingEnabled = true

    private var isStopped = false
    private var isActive = false
    private var displayLink: CADisplayLink?

    /// True from render dispatch until its result is presented (or dropped) on
    /// main. Guarantees a single composite in flight.
    private var inFlight = false
    /// Set when a tick or state change arrives while a render is in flight;
    /// the next render starts as soon as the in-flight one completes.
    private var renderPending = false

    // MARK: - Init

    init(compositor: VGDuetPreviewCompositor,
         background: CVPixelBuffer,
         foregroundRect: CGRect,
         cameraFrameProvider: @escaping CameraFrameProvider,
         maskProvider: @escaping MaskProvider,
         presentHandler: @escaping PresentHandler) {
        self.compositor          = compositor
        self.background          = background
        self.fullCanvasRect      = CGRect(x: 0, y: 0,
                                          width: compositor.canvasWidth,
                                          height: compositor.canvasHeight)
        self.foregroundRect      = foregroundRect
        self.cameraFrameProvider = cameraFrameProvider
        self.maskProvider        = maskProvider
        self.presentHandler      = presentHandler
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Public API (main thread)

    /// Installs the display link and renders immediately. Idempotent while active.
    func start() {
        assert(Thread.isMainThread)
        guard !isStopped, !isActive else { return }
        isActive = true
        installDisplayLink()
        requestRender()
    }

    /// Terminal. Invalidates the display link and drops pending work. Every
    /// later call (and every in-flight completion) is a no-op.
    func stop() {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        isStopped = true
        isActive  = false
        tearDownDisplayLink()
        renderPending = false
    }

    /// Atomically swaps the static background and forces the next render.
    /// The camera, segmenter, and texture are untouched.
    func updateBackground(_ buffer: CVPixelBuffer) {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        background = buffer
        requestRender()
    }

    /// Applies a new foreground (keyed camera) rect and forces the next render.
    func updateForegroundRect(_ rect: CGRect) {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        foregroundRect = rect
        requestRender()
    }

    /// Enables/disables mask keying. When disabled the camera is composited
    /// opaque (aspect-filled) into the foreground rect over the background.
    func setKeyingEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        guard !isStopped else { return }
        isKeyingEnabled = enabled
        requestRender()
    }

    // MARK: - Display link

    private func installDisplayLink() {
        if let existing = displayLink {
            existing.isPaused = false
            return
        }
        let proxy = VGLiveGreenScreenDisplayLinkProxy(loop: self)
        let link = CADisplayLink(target: proxy,
                                 selector: #selector(VGLiveGreenScreenDisplayLinkProxy.displayLinkFired(_:)))
        // The camera ingress runs at 30 fps; prefer 30 so each tick has a good
        // chance of carrying a new camera frame without doubling GPU work.
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
        } else {
            link.preferredFramesPerSecond = 30
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func displayLinkFired(_ sender: CADisplayLink) {
        guard !isStopped, isActive else { return }
        // Render every tick: the background is static but the camera is live.
        requestRender()
    }

    // MARK: - Render pipeline (main thread)

    private func requestRender() {
        guard !isStopped else { return }
        if inFlight {
            renderPending = true
            return
        }
        render()
    }

    private func render() {
        inFlight      = true
        renderPending = false

        let sourceFrame = background
        let sourceRect  = fullCanvasRect
        let cameraRect  = foregroundRect
        let keyed       = isKeyingEnabled
        let compositor  = self.compositor

        // Snapshot the mask and the live camera frame *before* crossing the
        // queue boundary. Mask first: its source PTS selects the camera frame
        // it was computed from, so the keyed foreground never shows a newer
        // pose than the matte (motion voids). Both are +1 retains released
        // after compositing.
        let maskSnap: MaskSnapshot? = keyed ? maskProvider() : nil
        let maskBuffer: CVPixelBuffer? = maskSnap.map { $0.buffer.takeUnretainedValue() }
        let preferredPTS: CMTime? = maskSnap.flatMap { $0.sourcePTS.isNumeric ? $0.sourcePTS : nil }

        var cameraSnap: Unmanaged<CVPixelBuffer>? = cameraFrameProvider(preferredPTS)
        if cameraSnap == nil, preferredPTS != nil {
            // No camera frame inside the pairing window: present the latest
            // frame rather than dropping the render.
            cameraSnap = cameraFrameProvider(nil)
        }
        let cameraBuffer: CVPixelBuffer? = cameraSnap.map { $0.takeUnretainedValue() }

        renderQueue.async { [weak self] in
            let output = compositor.composite(sourceFrame: sourceFrame,
                                              sourceRect: sourceRect,
                                              cameraRect: cameraRect,
                                              cameraFrame: cameraBuffer,
                                              isGreenScreen: keyed,
                                              greenScreenMask: maskBuffer)
            cameraSnap?.release()
            maskSnap?.buffer.release()
            DispatchQueue.main.async {
                self?.didRender(output)
            }
        }
    }

    private func didRender(_ output: CVPixelBuffer?) {
        inFlight = false
        guard !isStopped else { return }
        if let output = output {
            presentHandler(output)
        }
        // A tick or state change arrived while compositing: render again now so
        // background/transform updates are never dropped.
        if renderPending {
            render()
        }
    }
}
