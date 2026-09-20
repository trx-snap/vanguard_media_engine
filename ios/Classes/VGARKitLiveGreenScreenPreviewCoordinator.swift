// VGARKitLiveGreenScreenPreviewCoordinator.swift
// Generic live green-screen: ARKit ARMatteGenerator live person-matte engine.
// Caller-agnostic — live meeting/calling, going live, camera, or any other
// surface reaches it only through VGLiveGreenScreenSessionCoordinator's
// generic session; nothing here is scoped to Duet.
//
// Two callers, one engine:
//   1. Production (primary iOS live green-screen path): owned by
//      VGLiveGreenScreenSessionCoordinator for a session whose backend resolved
//      to ARKit. The session coordinator owns the Flutter texture (external
//      texture init), supplies the session's current static background buffer
//      and foreground rect at start, and swaps them live through
//      updateBackground / updateForegroundRect (the same public
//      updateLiveGreenScreenBackground / updateLiveGreenScreenTransform
//      contracts the Vision adapter path honours). A runtime failure is
//      reported once through `onTerminalFailure` so the owner can fall back.
//   2. RND diagnostic probe (proof boundary
//      ios_arkit_person_segmentation_matte_live_physical_smoke): the paired
//      startLiveGreenScreenARKitPreviewProbe / stopLiveGreenScreenARKitPreviewProbe
//      routes on VGLiveGreenScreenMethodHandler. The probe owns its own texture,
//      keeps the solid-teal background and the full-canvas foreground (no
//      background passed → teal), and its summary / capture-bundle behaviour is
//      unchanged.
//
// Starts from the verified still proof (VGARKitPersonSegmentationMatteStillProbe,
// 2026-09-18) and the live RND proof (avgMatteGenerationMs ≈ 2.7,
// avgCompositeMs ≈ 5.7, ≈25 effective fps, full-resolution 1080x1920 matte):
// front camera only, ARFaceTrackingConfiguration + .personSegmentation,
// ARMatteGenerator(device:matteResolution: .full) per frame (never the raw
// 256x192 ARFrame.segmentationBuffer for compositing), and the locked
// `leftMirrored` display orientation applied identically to the camera image
// and the matte before blending. Each accepted ARFrame is oriented, aspect-filled
// into the current foreground rect (full canvas by default) and composited over
// the current full-canvas background (session buffer, or solid teal #008080
// for the probe) through CIBlendWithMask into a pooled BGRA CVPixelBuffer,
// handed to the VGDuetPreviewTexture, and signalled via textureFrameAvailable
// on main.
//
// Mask refinement: the oriented / aspect-filled full-resolution matte is NOT
// blended raw. Before CIBlendWithMask it runs through the production live mask
// refinement owned by the caller-agnostic VGMatteRefinementPipeline
// (refineLiveGreenScreenMask: morphology close → feather → trimap →
// camera-guided edge preserve, plus the opt-in tightAlphaR1 post-pass
// when StartRequest.liveMatteRefinementMode is .tightAlphaR1, or the S4
// guided-alpha refinement when it is .s4SoftAlphaR2 (soft R2 set; the
// production default, VGMatteRefinementPipeline.defaultLiveMatteRefinementMode)
// or the opt-in .s4GuidedAlphaR1 (R1 set); explicit .s1 is the S1-only
// fallback), so
// the ARKit path and the Vision adapter path (which runs the same pipeline
// through its own VGDuetPreviewCompositor) share one refinement pipeline and
// one set of constants. The VGMatteRefinementPipeline instance held in
// RenderResources is used for mask refinement only: this engine still owns
// the camera (ARSession), ARMatteGenerator, CIContext, output pool,
// publishing, and lifecycle — it never instantiates a VGDuetPreviewCompositor
// — and the refinement never changes the camera / matte geometry or
// orientation (it is applied to the already oriented and aspect-filled mask
// over the same target rect, with the oriented camera image as the edge
// guide). Every stage fails open to its input, so the worst case is the raw
// matte. The first refined blend logs IOS_ARKIT_LIVE_MASK_REFINEMENT_FIRST
// with the mode and per-stage applied flags, and diagnosticsSnapshot / the
// stop summary carry liveMatteRefinement plus the same flags from the most
// recent blend.
//
// Threading: ARSession delegate callbacks arrive on a private serial delegate
// queue; matte generation + compositing run on a private serial render queue
// with exactly one render in flight (a frame arriving while a render is in
// flight is counted in droppedBusyFrames and dropped, never queued); a frame
// without a segmentationBuffer is counted in skippedNoMaskFrames; frames faster
// than targetFps are counted in throttledFrames. start() / stopFrameDelivery()
// / stop() / dispose() / updateBackground / updateForegroundRect run on the
// main thread. All counters, timing samples, and the live background /
// foreground rect are guarded by `lock`; each render snapshots the current
// background and rect under the lock before compositing.
//
// Fail-closed: unsupported face tracking / person segmentation, no Metal
// device, pool creation failure, an unexpected matte pixel format or storage
// mode, a matte/capturedImage dimension mismatch, or an ARSession failure all
// surface as `failureReason` with `pass: false`; rendering stops after the
// first terminal render failure and `onTerminalFailure` (when set) fires once
// on main. Pool exhaustion is transient (counted in droppedPoolExhaustedFrames,
// never a failure).
//
// Terminal order (stop): stopFrameDelivery (delegate nil → ARSession pause →
// bounded drain of the in-flight render) → texture invalidate + unregister
// (owned texture only; an external texture is torn down by its owner between
// stopFrameDelivery and stop) → ARSession + Metal/CoreImage resources released
// → summary cached. Every step is idempotent.
//
// Optional replay-bundle capture (StartRequest.captureBundleOutputDir): when a
// capture directory is supplied, exactly one deterministic replay input bundle
// is written once publishedFrames reaches `captureBundleAfterPublishedFrames`
// (default 1, from the first composited frame), inside that same render on the
// render queue (one render in flight is unchanged; frames that arrive during the
// capture are dropped as busy, never queued). The bundle holds the *same*
// oriented/aspect-filled camera CIImage the live composite just blended and the
// same oriented/aspect-filled RAW (pre-refinement) matte the live composite
// just refined — the replay lab re-runs the refinement stages itself, so the
// bundle stays a refinement *input* — each rendered through the same CIContext
// into a full-canvas buffer (background.bgra), with sourceRect == cameraRect
// == full canvas so VGLiveGreenScreenReplayDiagnostics / VGDuetPreviewCompositor
// apply no second crop or scale on replay. The write goes through
// VGLiveGreenScreenReplayDiagnostics.writeReplayInputBundle (refuses overwrite).
// A capture failure is terminal (failureReason set, pass: false); without a
// capture directory the live path and pass criteria are unchanged.
//
// Packaging: ios/vanguard_media_engine.podspec globs Classes/**/*.swift, so any
// regenerated Pods project picks this file up automatically. The checked-in
// example/ios Pods project was given this file's membership by hand (no pod
// install), mirroring VGARKitPersonSegmentationMatteStillProbe.swift.

import ARKit
import CoreGraphics
import CoreImage
import CoreVideo
import Flutter
import Foundation
import ImageIO
import Metal
import QuartzCore

final class VGARKitLiveGreenScreenPreviewCoordinator: NSObject, ARSessionDelegate {

    // MARK: - Constants

    static let proofBoundary = "ios_arkit_person_segmentation_matte_live_physical_smoke"
    /// Only supported tracking configuration: front-camera ARFaceTrackingConfiguration.
    static let trackingConfiguration = "face"
    /// Default display orientation from the still proof (`face` → `leftMirrored`).
    static let defaultOrientationMode = "leftMirrored"
    static let orientationMode = defaultOrientationMode
    /// `background` descriptor value when no session background was supplied
    /// (probe: solid teal).
    static let backgroundName = "teal"
    /// `background` descriptor value when the owner supplied (and may swap) the
    /// session's own full-canvas background buffer (production).
    static let sessionBackgroundName = "session"
    /// Accepted-frame cadence for the production session (matches the 30 fps
    /// camera ingress / display-link cadence of the adapter path).
    static let productionTargetFps = 30

    // Diagnostics identity reported by `diagnosticsSnapshot` so a reader can
    // never mistake this engine for a Vision / LiteRT adapter provider.
    static let diagnosticsProviderKind    = "arkit"
    static let diagnosticsProviderMode    = "arkit_face_matte_full"
    static let diagnosticsTimingSemantics = "arkit_matte_generator_spans"
    static let diagnosticsModelName       = "ARMatteGenerator"
    static let diagnosticsMattePath       = "arkit_matte_full_resolution"
    /// `maskRefinementPath` diagnostics value: the matte is refined through
    /// VGMatteRefinementPipeline's live pipeline before the blend (never raw).
    /// Value unchanged ("compositor_live_refinement") for wire compatibility.
    static let diagnosticsMaskRefinementPath = "compositor_live_refinement"
    /// Marker logged once on the first blend that used the refined mask.
    static let maskRefinementFirstMarker = "IOS_ARKIT_LIVE_MASK_REFINEMENT_FIRST"
    /// Bundle label used when StartRequest.captureBundleLabel is nil.
    static let defaultCaptureBundleLabel = "arkit_live_capture"
    /// Marker logged once when the optional replay bundle has been written.
    static let captureBundleCapturedMarker = "IOS_ARKIT_LIVE_CAPTURE_BUNDLE_CAPTURED"
    /// Marker logged once when the optional replay bundle capture failed.
    static let captureBundleFailMarker = "IOS_ARKIT_LIVE_CAPTURE_BUNDLE_FAIL"

    static let defaultDisplayOrientation: CGImagePropertyOrientation = .leftMirrored
    private static let displayOrientation = defaultDisplayOrientation

    /// RND-only allowlist: leftMirrored (selfie mirror) and right (upright non-mirrored).
    static let supportedOrientationModes: [String: CGImagePropertyOrientation] = [
        "leftMirrored": .leftMirrored,
        "right": .right,
    ]

    /// Solid teal (#008080), identical to the still proof's fixed background.
    private static let tealColor = CIColor(red: 0.0, green: 0.5019607843137255, blue: 0.5019607843137255, alpha: 1.0)

    /// Bounds outstanding output-pool allocations (texture-held + Flutter-held +
    /// in-render). Exceeding it drops the frame, never grows unbounded.
    private static let outputPoolAllocationThreshold = 6
    private static let mattePoolAllocationThreshold = 4

    /// Upper bound on retained per-frame timing samples (p95). Far above any
    /// harness hold; sums/counts keep accumulating past it.
    private static let maxTimingSamples = 20_000

    /// How long stop() waits for an in-flight render before tearing down.
    private static let stopRenderDrainTimeoutSeconds: Double = 2.0

    // MARK: - Request / outcome

    struct StartRequest {
        let canvasWidth: Int
        let canvasHeight: Int
        let targetFps: Int
        let displayOrientationMode: String
        let displayOrientation: CGImagePropertyOrientation
        /// When non-nil, one replay input bundle is captured into this directory
        /// once publishedFrames reaches `captureBundleAfterPublishedFrames` (see header).
        /// nil keeps the live preview behaviour and pass criteria unchanged.
        let captureBundleOutputDir: String?
        /// Bundle label; nil falls back to `defaultCaptureBundleLabel`. Only
        /// meaningful together with `captureBundleOutputDir`.
        let captureBundleLabel: String?
        /// Number of published frames to wait before attempting capture (warmup threshold).
        /// Defaults to 1 (capture from first successfully composited published frame).
        let captureBundleAfterPublishedFrames: Int
        /// Initial full-canvas static background (BGRA, canvas-sized; built by
        /// VGLiveGreenScreenStaticBackgroundRenderer). nil → solid teal (probe).
        /// Swappable live through `updateBackground`.
        let background: CVPixelBuffer?
        /// Initial foreground (keyed camera) rect, top-left origin in canvas
        /// pixels (VGDuetLayoutGeometry.greenScreen). nil → full canvas.
        /// Swappable live through `updateForegroundRect`.
        let foregroundRect: CGRect?
        /// Live mask refinement mode run by the VGMatteRefinementPipeline refiner
        /// before every blend (see header). `.s4SoftAlphaR2` (default,
        /// VGMatteRefinementPipeline.defaultLiveMatteRefinementMode) is the
        /// production pipeline (S1 stages plus the S4 soft R2 refinement);
        /// `.s1` is the explicit S1-only fallback; `.tightAlphaR1` adds the
        /// opt-in post-pass and `.s4GuidedAlphaR1` the opt-in S4 R1 RND
        /// candidate, exactly as on the adapter path.
        let liveMatteRefinementMode: VGMatteRefinementPipeline.LiveMatteRefinementMode

        init(canvasWidth: Int,
             canvasHeight: Int,
             targetFps: Int,
             displayOrientationMode: String = VGARKitLiveGreenScreenPreviewCoordinator.defaultOrientationMode,
             displayOrientation: CGImagePropertyOrientation = VGARKitLiveGreenScreenPreviewCoordinator.defaultDisplayOrientation,
             captureBundleOutputDir: String? = nil,
             captureBundleLabel: String? = nil,
             captureBundleAfterPublishedFrames: Int = 1,
             background: CVPixelBuffer? = nil,
             foregroundRect: CGRect? = nil,
             liveMatteRefinementMode: VGMatteRefinementPipeline.LiveMatteRefinementMode
                 = VGMatteRefinementPipeline.defaultLiveMatteRefinementMode) {
            self.canvasWidth = canvasWidth
            self.canvasHeight = canvasHeight
            self.targetFps = targetFps
            self.displayOrientationMode = displayOrientationMode
            self.displayOrientation = displayOrientation
            self.captureBundleOutputDir = captureBundleOutputDir
            self.captureBundleLabel = captureBundleLabel
            self.captureBundleAfterPublishedFrames = captureBundleAfterPublishedFrames
            self.background = background
            self.foregroundRect = foregroundRect
            self.liveMatteRefinementMode = liveMatteRefinementMode
        }
    }

    enum StartOutcome {
        /// Descriptor map: sessionId, textureId, width, height, targetFps, …
        case started([String: Any])
        /// Fail-closed map (`pass: false`, `failureReason`, no textureId);
        /// nothing was registered or started, so the instance may be discarded.
        case failed([String: Any])
    }

    // MARK: - State

    private enum State {
        case idle
        case running
        /// Terminal render / session failure: frames are ignored, texture stays
        /// registered until stop() so the summary can still be collected.
        case failed
        case stopping
        case stopped
    }

    /// Everything the render queue needs, bundled so stop() can drop the
    /// coordinator's reference while an in-flight render keeps its own.
    private final class RenderResources {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let matteGenerator: ARMatteGenerator
        let ciContext: CIContext
        let outputPool: CVPixelBufferPool
        let canvasRect: CGRect
        /// Solid-teal full-canvas fallback background (used when no session
        /// background buffer is set: the probe path).
        let backgroundImage: CIImage
        /// Production live mask refiner (VGMatteRefinementPipeline,
        /// StartRequest.liveMatteRefinementMode). Used ONLY for
        /// refineLiveGreenScreenMask; it never composites, renders, or
        /// publishes here, and this engine never instantiates a
        /// VGDuetPreviewCompositor.
        let maskRefiner: VGMatteRefinementPipeline
        /// Matte pool, created lazily for the first observed matte size.
        var mattePool: CVPixelBufferPool?
        var mattePoolWidth = 0
        var mattePoolHeight = 0
        /// Cached display transform (orientation normalisation + aspect-fill)
        /// for the last observed captured-image size and target rect.
        var cachedTransformWidth = 0
        var cachedTransformHeight = 0
        var cachedTransformRect = CGRect.null
        var cachedFillTransform = CGAffineTransform.identity

        init(device: MTLDevice, commandQueue: MTLCommandQueue, matteGenerator: ARMatteGenerator,
             ciContext: CIContext, outputPool: CVPixelBufferPool, canvasRect: CGRect, backgroundImage: CIImage,
             maskRefiner: VGMatteRefinementPipeline) {
            self.device = device
            self.commandQueue = commandQueue
            self.matteGenerator = matteGenerator
            self.ciContext = ciContext
            self.outputPool = outputPool
            self.canvasRect = canvasRect
            self.backgroundImage = backgroundImage
            self.maskRefiner = maskRefiner
        }
    }

    let sessionId: String
    private let request: StartRequest
    private let textureRegistry: FlutterTextureRegistry
    /// Output texture. Owned (registered on start, invalidated + unregistered on
    /// stop) for the probe; external (lifecycle owned by the caller, only
    /// updated and signalled here) for the production session.
    private let texture: VGDuetPreviewTexture
    private let ownsTexture: Bool
    private var textureId: Int64

    /// Fired at most once, on the main thread, when a terminal failure happens
    /// AFTER a successful start (render failure, ARSession failure, capture
    /// failure). Start-time failures are returned synchronously as `.failed`
    /// and never fire this. Set before start(); the owner should clear it
    /// before stopping. Not used by the probe.
    var onTerminalFailure: ((String) -> Void)?

    private var session: ARSession?
    private var resources: RenderResources?

    private let delegateQueue = DispatchQueue(label: "com.connects.vanguard.arkitlivepreview.delegate",
                                              qos: .userInteractive)
    private let renderQueue = DispatchQueue(label: "com.connects.vanguard.arkitlivepreview.render",
                                            qos: .userInteractive)

    private let lock = NSLock()
    private var state: State = .idle
    private var renderInFlight = false
    private var cachedSummary: [String: Any]?
    /// True once stopFrameDelivery() ran (delegate detached, session paused,
    /// in-flight render drained). Guarded by `lock`.
    private var frameDeliveryStopped = false

    // Live composite inputs (guarded by `lock`; snapshotted per render).
    /// Current full-canvas background buffer; nil → `RenderResources.backgroundImage` (teal).
    private var currentBackground: CVPixelBuffer?
    /// Current foreground rect, top-left origin in canvas pixels.
    private var currentForegroundRect: CGRect

    // Telemetry (all guarded by `lock`).
    private var startTime: CFTimeInterval = 0
    private var stopTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval?
    private var lastAcceptedFrameTime: CFTimeInterval?
    private var frameIntervalSumMs: Double = 0
    private var frameIntervalCount = 0
    private var frameCount = 0
    private var maskCount = 0
    private var publishedFrames = 0
    private var droppedBusyFrames = 0
    private var skippedNoMaskFrames = 0
    private var throttledFrames = 0
    private var droppedPoolExhaustedFrames = 0
    private var renderFailureCount = 0
    private var interruptionCount = 0
    private var firstMaskLatencyMs: Double?
    private var firstPublishTime: CFTimeInterval?
    private var lastPublishTime: CFTimeInterval?
    private var matteGenerationSamplesMs: [Double] = []
    private var matteGenerationSumMs: Double = 0
    private var matteGenerationMaxMs: Double = 0
    private var matteGenerationCount = 0
    /// Matte texture → OneComponent8 CVPixelBuffer copy span (a sub-span of
    /// compositeMs, reported separately as the "output access" span).
    private var matteCopySumMs: Double = 0
    private var matteCopyMaxMs: Double = 0
    private var compositeSamplesMs: [Double] = []
    private var compositeSumMs: Double = 0
    private var compositeMaxMs: Double = 0
    private var compositeCount = 0
    private var rawSegmentationBufferWidth = 0
    private var rawSegmentationBufferHeight = 0
    private var capturedImageWidth = 0
    private var capturedImageHeight = 0
    private var matteWidth = 0
    private var matteHeight = 0
    private var videoFormatWidth = 0
    private var videoFormatHeight = 0
    private var videoFormatFramesPerSecond = 0
    private var stopRenderDrainTimedOut = false
    private var failureReason: String?
    // Mask refinement telemetry (guarded by `lock`; written by the render
    // queue on every blended frame): the per-stage applied flags of the most
    // recent refined blend (all false until the first blend) and how many
    // blended frames went through the refiner.
    private var maskRefinementFrames = 0
    private var maskMorphologyCloseApplied = false
    private var maskFeatherApplied = false
    private var maskTrimapApplied = false
    private var maskGuidedEdgeApplied = false
    private var liveTightAlphaR1Applied = false
    private var liveS4GuidedAlphaR1Applied = false
    private var liveS4GuidedAlphaApplied = false
    private var hasLoggedFirstMaskRefinement = false

    // Optional one-shot replay-bundle capture (all guarded by `lock`; mutated
    // only by the render queue from the first successfully composited frame).
    private var captureBundleAttempted = false
    private var captureBundleCaptured = false
    private var captureBundleResult: [String: Any]?
    private var captureBundleFailureReason: String?
    private var captureBundleMs: Double?
    private var captureBundleFrameIndex: Int?

    private var captureRequested: Bool { request.captureBundleOutputDir != nil }
    private var captureLabel: String {
        request.captureBundleLabel ?? VGARKitLiveGreenScreenPreviewCoordinator.defaultCaptureBundleLabel
    }

    /// Minimum spacing between accepted frames derived from targetFps (0.9
    /// factor so capture jitter at exactly targetFps never halves the rate).
    private let minAcceptedFrameInterval: CFTimeInterval

    // MARK: - Init

    /// Probe init: the coordinator owns its texture (registered on start,
    /// invalidated and unregistered on stop).
    init(request: StartRequest, textureRegistry: FlutterTextureRegistry) {
        self.request = request
        self.textureRegistry = textureRegistry
        self.texture = VGDuetPreviewTexture()
        self.ownsTexture = true
        self.textureId = -1
        self.sessionId = "ios_arkit_live_gs_" + UUID().uuidString.lowercased()
        self.minAcceptedFrameInterval = 0.9 / Double(max(1, request.targetFps))
        self.currentBackground = request.background
        self.currentForegroundRect = request.foregroundRect
            ?? CGRect(x: 0, y: 0, width: request.canvasWidth, height: request.canvasHeight)
        super.init()
    }

    /// Production init: `texture` / `textureId` are owned by the caller
    /// (VGLiveGreenScreenSessionCoordinator), which registered the texture
    /// before start and invalidates / unregisters it between
    /// stopFrameDelivery() and stop(). This engine only updates the texture and
    /// signals textureFrameAvailable(textureId). `sessionId` is the owner's
    /// session id so every log marker correlates with the live session.
    init(request: StartRequest,
         textureRegistry: FlutterTextureRegistry,
         texture: VGDuetPreviewTexture,
         textureId: Int64,
         sessionId: String) {
        self.request = request
        self.textureRegistry = textureRegistry
        self.texture = texture
        self.ownsTexture = false
        self.textureId = textureId
        self.sessionId = sessionId
        self.minAcceptedFrameInterval = 0.9 / Double(max(1, request.targetFps))
        self.currentBackground = request.background
        self.currentForegroundRect = request.foregroundRect
            ?? CGRect(x: 0, y: 0, width: request.canvasWidth, height: request.canvasHeight)
        super.init()
    }

    /// Whether the engine currently has a session background buffer (vs. the
    /// probe's solid teal). Diagnostic read.
    private var backgroundName: String {
        lock.lock()
        let hasSessionBackground = currentBackground != nil
        lock.unlock()
        return hasSessionBackground
            ? VGARKitLiveGreenScreenPreviewCoordinator.sessionBackgroundName
            : VGARKitLiveGreenScreenPreviewCoordinator.backgroundName
    }

    // MARK: - Lifecycle (main thread)

    /// Registers the preview texture and starts the ARSession. Returns
    /// `.failed` (nothing retained, nothing registered) when the device does
    /// not support front-camera person segmentation or Metal/pool setup fails.
    func start() -> StartOutcome {
        assert(Thread.isMainThread)
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return .failed(makeFailedStartMap(reason: "already_started",
                                              faceTrackingSupported: ARFaceTrackingConfiguration.isSupported,
                                              facePersonSegmentationSupported: ARFaceTrackingConfiguration.supportsFrameSemantics(.personSegmentation)))
        }
        lock.unlock()

        let faceTrackingSupported = ARFaceTrackingConfiguration.isSupported
        let facePersonSegmentationSupported = ARFaceTrackingConfiguration.supportsFrameSemantics(.personSegmentation)
        NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_CAPABILITY sessionId=\(sessionId) faceTrackingSupported=\(faceTrackingSupported) facePersonSegmentationSupported=\(facePersonSegmentationSupported)")

        guard faceTrackingSupported else {
            return .failed(makeFailedStartMap(reason: "face_tracking_unsupported",
                                              faceTrackingSupported: faceTrackingSupported,
                                              facePersonSegmentationSupported: facePersonSegmentationSupported))
        }
        guard facePersonSegmentationSupported else {
            return .failed(makeFailedStartMap(reason: "face_person_segmentation_unsupported",
                                              faceTrackingSupported: faceTrackingSupported,
                                              facePersonSegmentationSupported: facePersonSegmentationSupported))
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .failed(makeFailedStartMap(reason: "no_metal_device",
                                              faceTrackingSupported: faceTrackingSupported,
                                              facePersonSegmentationSupported: facePersonSegmentationSupported))
        }
        guard let commandQueue = device.makeCommandQueue() else {
            return .failed(makeFailedStartMap(reason: "no_metal_command_queue",
                                              faceTrackingSupported: faceTrackingSupported,
                                              facePersonSegmentationSupported: facePersonSegmentationSupported))
        }
        let canvasWidth  = request.canvasWidth
        let canvasHeight = request.canvasHeight
        guard let outputPool = VGARKitLiveGreenScreenPreviewCoordinator.makePool(
            width: canvasWidth, height: canvasHeight,
            pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 3) else {
            return .failed(makeFailedStartMap(reason: "output_pool_create_failed",
                                              faceTrackingSupported: faceTrackingSupported,
                                              facePersonSegmentationSupported: facePersonSegmentationSupported))
        }

        let canvasRect = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false,
        ])
        let matteGenerator = ARMatteGenerator(device: device, matteResolution: .full)
        // Production mask refiner: the same VGMatteRefinementPipeline the adapter
        // path's VGDuetPreviewCompositor runs internally, at this session's live
        // mode. Mask refinement only (see RenderResources.maskRefiner); this
        // engine never instantiates a VGDuetPreviewCompositor.
        let maskRefiner = VGMatteRefinementPipeline(liveMatteRefinementMode: request.liveMatteRefinementMode)
        resources = RenderResources(
            device: device,
            commandQueue: commandQueue,
            matteGenerator: matteGenerator,
            ciContext: ciContext,
            outputPool: outputPool,
            canvasRect: canvasRect,
            backgroundImage: CIImage(color: VGARKitLiveGreenScreenPreviewCoordinator.tealColor).cropped(to: canvasRect),
            maskRefiner: maskRefiner)

        let configuration = ARFaceTrackingConfiguration()
        configuration.frameSemantics.insert(.personSegmentation)
        let videoFormat = configuration.videoFormat
        let formatWidth  = Int(videoFormat.imageResolution.width)
        let formatHeight = Int(videoFormat.imageResolution.height)
        let formatFps    = videoFormat.framesPerSecond

        // Texture registration (owned texture only) is the last fallible-free
        // step before run so every earlier failure leaves nothing to unwind. An
        // external texture was registered by its owner and is never touched here.
        if ownsTexture {
            textureId = textureRegistry.register(texture)
        }

        let arSession = ARSession()
        arSession.delegateQueue = delegateQueue
        arSession.delegate = self
        session = arSession

        lock.lock()
        state = .running
        startTime = CACurrentMediaTime()
        videoFormatWidth = formatWidth
        videoFormatHeight = formatHeight
        videoFormatFramesPerSecond = formatFps
        let initialForegroundRect = currentForegroundRect
        lock.unlock()

        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_START sessionId=\(sessionId) textureId=\(textureId) ownsTexture=\(ownsTexture) canvas=\(canvasWidth)x\(canvasHeight) targetFps=\(request.targetFps) trackingConfiguration=\(VGARKitLiveGreenScreenPreviewCoordinator.trackingConfiguration) orientationMode=\(request.displayOrientationMode) background=\(backgroundName) foregroundRect=\(VGARKitLiveGreenScreenPreviewCoordinator.describe(initialForegroundRect)) videoFormat=\(formatWidth)x\(formatHeight)@\(formatFps) liveMatteRefinement=\(request.liveMatteRefinementMode.rawValue) maskRefinementPath=\(VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsMaskRefinementPath) captureBundleRequested=\(captureRequested) captureBundleOutputDir=\(request.captureBundleOutputDir ?? "null") captureBundleLabel=\(captureRequested ? captureLabel : "null") captureBundleAfterPublishedFrames=\(request.captureBundleAfterPublishedFrames)")

        let descriptor: [String: Any] = [
            "proofBoundary": VGARKitLiveGreenScreenPreviewCoordinator.proofBoundary,
            "supported": true,
            "sessionId": sessionId,
            "textureId": textureId,
            "width": canvasWidth,
            "height": canvasHeight,
            "targetFps": request.targetFps,
            "trackingConfiguration": VGARKitLiveGreenScreenPreviewCoordinator.trackingConfiguration,
            "activeTrackingUsesFrontCamera": true,
            "orientationMode": request.displayOrientationMode,
            "background": backgroundName,
            "faceTrackingSupported": faceTrackingSupported,
            "facePersonSegmentationSupported": facePersonSegmentationSupported,
            "videoFormatWidth": formatWidth,
            "videoFormatHeight": formatHeight,
            "videoFormatFramesPerSecond": formatFps,
            "liveMatteRefinement": request.liveMatteRefinementMode.rawValue,
            "maskRefinementPath": VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsMaskRefinementPath,
            "captureBundleRequested": captureRequested,
            "captureBundleOutputDir": request.captureBundleOutputDir.map { $0 as Any } ?? NSNull(),
            "captureBundleLabel": captureRequested ? captureLabel as Any : NSNull(),
            "captureBundleAfterPublishedFrames": request.captureBundleAfterPublishedFrames,
        ]
        return .started(descriptor)
    }

    /// Stop phase 1 (idempotent): detaches the delegate, pauses the ARSession
    /// (no further frames), and drains the (at most one) in-flight render with
    /// a bounded wait so a wedged GPU can never hang the platform thread
    /// indefinitely. After this returns nothing touches the texture any more,
    /// so an external-texture owner may invalidate / unregister its texture
    /// before calling stop(). The ARSession object and render resources are
    /// released by stop(), never here.
    func stopFrameDelivery() {
        assert(Thread.isMainThread)

        lock.lock()
        if frameDeliveryStopped {
            lock.unlock()
            return
        }
        frameDeliveryStopped = true
        let wasStarted = state != .idle
        if state != .stopped {
            state = .stopping
        }
        stopTime = CACurrentMediaTime()
        if !wasStarted, failureReason == nil {
            failureReason = "not_started"
        }
        lock.unlock()

        // 1. Stop frame delivery.
        session?.delegate = nil
        session?.pause()

        // 2. Drain the in-flight render (bounded).
        if wasStarted {
            let drain = DispatchGroup()
            renderQueue.async(group: drain) { }
            let waitResult = drain.wait(timeout: .now() + VGARKitLiveGreenScreenPreviewCoordinator.stopRenderDrainTimeoutSeconds)
            if waitResult == .timedOut {
                lock.lock()
                stopRenderDrainTimedOut = true
                if failureReason == nil {
                    failureReason = "stop_render_drain_timed_out"
                }
                lock.unlock()
                NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_STOP_DRAIN_TIMEOUT sessionId=\(sessionId)")
            }
        }
    }

    /// Terminal and idempotent: runs stopFrameDelivery() when not yet done,
    /// invalidates and unregisters the texture (owned texture only), releases
    /// the ARSession and render resources, and returns the summary. Later calls
    /// return the same cached summary.
    @discardableResult
    func stop() -> [String: Any] {
        assert(Thread.isMainThread)

        lock.lock()
        if let cached = cachedSummary {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // 1 + 2. Stop frame delivery and drain the in-flight render.
        stopFrameDelivery()

        // 3. Owned texture: invalidate before unregister
        //    (VGLiveGreenScreenSessionCoordinator order). An external texture
        //    belongs to the owner, which tears it down between
        //    stopFrameDelivery() and stop().
        if ownsTexture {
            texture.invalidate()
            if textureId >= 0 {
                textureRegistry.unregisterTexture(textureId)
            }
        }

        // 4. Release the ARSession and render resources and finalise under the
        //    lock (an in-flight render past the drain timeout keeps its own
        //    strong reference to the resources until it returns).
        session = nil
        lock.lock()
        resources = nil
        state = .stopped
        let summary = makeSummaryLocked(endTime: stopTime, includeProofClaims: true)
        cachedSummary = summary
        // The owner's background buffer is no longer needed once the summary
        // has recorded which background was in use.
        currentBackground = nil
        lock.unlock()

        NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_STOP sessionId=\(sessionId) textureId=\(textureId) ownsTexture=\(ownsTexture) pass=\(summary["pass"] ?? false) frameCount=\(summary["frameCount"] ?? 0) maskCount=\(summary["maskCount"] ?? 0) publishedFrames=\(summary["publishedFrames"] ?? 0) droppedBusyFrames=\(summary["droppedBusyFrames"] ?? 0) skippedNoMaskFrames=\(summary["skippedNoMaskFrames"] ?? 0) throttledFrames=\(summary["throttledFrames"] ?? 0) droppedPoolExhaustedFrames=\(summary["droppedPoolExhaustedFrames"] ?? 0) effectiveFps=\(summary["effectiveFps"] ?? "null") avgMatteGenerationMs=\(summary["avgMatteGenerationMs"] ?? "null") p95MatteGenerationMs=\(summary["p95MatteGenerationMs"] ?? "null") avgCompositeMs=\(summary["avgCompositeMs"] ?? "null") p95CompositeMs=\(summary["p95CompositeMs"] ?? "null") failureReason=\(summary["failureReason"] ?? "null") liveMatteRefinement=\(summary["liveMatteRefinement"] ?? "null") maskRefinementFrames=\(summary["maskRefinementFrames"] ?? 0) maskMorphologyCloseApplied=\(summary["maskMorphologyCloseApplied"] ?? false) maskFeatherApplied=\(summary["maskFeatherApplied"] ?? false) maskTrimapApplied=\(summary["maskTrimapApplied"] ?? false) maskGuidedEdgeApplied=\(summary["maskGuidedEdgeApplied"] ?? false) liveTightAlphaR1Applied=\(summary["liveTightAlphaR1Applied"] ?? false) liveS4GuidedAlphaR1Applied=\(summary["liveS4GuidedAlphaR1Applied"] ?? false) liveS4GuidedAlphaApplied=\(summary["liveS4GuidedAlphaApplied"] ?? false) captureBundleRequested=\(summary["captureBundleRequested"] ?? false) captureBundleCaptured=\(summary["captureBundleCaptured"] ?? false) captureBundleAfterPublishedFrames=\(request.captureBundleAfterPublishedFrames)")
        return summary
    }

    /// Plugin-detach path: stops if not already stopped.
    func dispose() {
        assert(Thread.isMainThread)
        lock.lock()
        let needsStop = cachedSummary == nil
        lock.unlock()
        if needsStop {
            _ = stop()
        }
    }

    // MARK: - Live updates (main thread; production session)

    /// Swaps the full-canvas static background used by every later render.
    /// The ARSession, matte generation, and texture are untouched. No-op once
    /// frame delivery has stopped.
    func updateBackground(_ buffer: CVPixelBuffer) {
        assert(Thread.isMainThread)
        lock.lock()
        guard !frameDeliveryStopped, state != .stopped else {
            lock.unlock()
            return
        }
        currentBackground = buffer
        lock.unlock()
        NSLog("IOS_ARKIT_LIVE_GS_BACKGROUND_UPDATED sessionId=\(sessionId) background=\(VGARKitLiveGreenScreenPreviewCoordinator.sessionBackgroundName) size=\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))")
    }

    /// Applies a new foreground (keyed camera) rect, top-left origin in canvas
    /// pixels, used by every later render: camera and matte receive the same
    /// orientation + aspect-fill transform into this rect over the full-canvas
    /// background. No-op once frame delivery has stopped.
    func updateForegroundRect(_ rect: CGRect) {
        assert(Thread.isMainThread)
        lock.lock()
        guard !frameDeliveryStopped, state != .stopped else {
            lock.unlock()
            return
        }
        currentForegroundRect = rect
        lock.unlock()
        NSLog("IOS_ARKIT_LIVE_GS_FOREGROUND_RECT_UPDATED sessionId=\(sessionId) foregroundRect=\(VGARKitLiveGreenScreenPreviewCoordinator.describe(rect))")
    }

    /// Diagnostic-only live snapshot of the engine's counters / timing, safe
    /// from any thread and without any lifecycle change. While running, run
    /// duration and cadence are measured up to now; after stop() the cached
    /// terminal summary is returned. Proof claims (`claimsAllowed` /
    /// `nonClaims`) are probe-only and never part of this snapshot; the
    /// identity keys (`providerKind`, `providerMode`, `timingSemantics`,
    /// `engineState`) make ARKit unmistakable in a session diagnostics reply.
    func diagnosticsSnapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedSummary {
            var snapshot = cached
            snapshot.removeValue(forKey: "claimsAllowed")
            snapshot.removeValue(forKey: "nonClaims")
            return snapshot
        }
        let endTime = state == .running || state == .failed ? CACurrentMediaTime() : stopTime
        return makeSummaryLocked(endTime: endTime, includeProofClaims: false)
    }

    // MARK: - ARSessionDelegate (delegate queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return
        }
        let now = CACurrentMediaTime()
        if let last = lastFrameTime {
            frameIntervalSumMs += (now - last) * 1000.0
            frameIntervalCount += 1
        }
        lastFrameTime = now
        frameCount += 1
        capturedImageWidth  = CVPixelBufferGetWidth(frame.capturedImage)
        capturedImageHeight = CVPixelBufferGetHeight(frame.capturedImage)

        guard let rawMask = frame.segmentationBuffer else {
            skippedNoMaskFrames += 1
            lock.unlock()
            return
        }
        maskCount += 1
        rawSegmentationBufferWidth  = CVPixelBufferGetWidth(rawMask)
        rawSegmentationBufferHeight = CVPixelBufferGetHeight(rawMask)
        var firstMaskLatencyToLog: Double?
        if firstMaskLatencyMs == nil {
            let latencyMs = (now - startTime) * 1000.0
            firstMaskLatencyMs = latencyMs
            firstMaskLatencyToLog = latencyMs
        }
        if let lastAccepted = lastAcceptedFrameTime, now - lastAccepted < minAcceptedFrameInterval {
            throttledFrames += 1
            lock.unlock()
            if let latencyMs = firstMaskLatencyToLog { logFirstMask(latencyMs: latencyMs) }
            return
        }
        if renderInFlight {
            droppedBusyFrames += 1
            lock.unlock()
            if let latencyMs = firstMaskLatencyToLog { logFirstMask(latencyMs: latencyMs) }
            return
        }
        renderInFlight = true
        lastAcceptedFrameTime = now
        lock.unlock()
        if let latencyMs = firstMaskLatencyToLog { logFirstMask(latencyMs: latencyMs) }

        // Exactly one ARFrame is retained by the render queue at a time.
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            autoreleasepool {
                self.render(frame: frame)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        recordTerminalFailure("session_failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        lock.lock()
        interruptionCount += 1
        lock.unlock()
        NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_INTERRUPTED sessionId=\(sessionId)")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_INTERRUPTION_ENDED sessionId=\(sessionId)")
    }

    private func logFirstMask(latencyMs: Double) {
        lock.lock()
        let rawWidth = rawSegmentationBufferWidth
        let rawHeight = rawSegmentationBufferHeight
        lock.unlock()
        NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_FIRST_MASK sessionId=\(sessionId) latencyMs=\(latencyMs) rawSegmentationBuffer=\(rawWidth)x\(rawHeight)")
    }

    // MARK: - Render (render queue, one in flight)

    private enum RenderError: Error {
        case terminal(String)
        case poolExhausted
    }

    private func render(frame: ARFrame) {
        defer {
            lock.lock()
            renderInFlight = false
            lock.unlock()
        }

        lock.lock()
        let resources = self.resources
        let running = state == .running
        lock.unlock()
        guard running, let res = resources else { return }

        do {
            try renderFrame(frame, with: res)
        } catch RenderError.poolExhausted {
            lock.lock()
            droppedPoolExhaustedFrames += 1
            lock.unlock()
        } catch RenderError.terminal(let reason) {
            lock.lock()
            renderFailureCount += 1
            lock.unlock()
            recordTerminalFailure(reason)
        } catch {
            lock.lock()
            renderFailureCount += 1
            lock.unlock()
            recordTerminalFailure("render_failed: \(error.localizedDescription)")
        }
    }

    private func renderFrame(_ frame: ARFrame, with res: RenderResources) throws {
        guard let commandBuffer = res.commandQueue.makeCommandBuffer() else {
            throw RenderError.terminal("no_metal_command_buffer")
        }

        // 1. Full-resolution matte (same call as the still proof, once per frame).
        let matteStart = CACurrentMediaTime()
        let matteTexture = res.matteGenerator.generateMatte(from: frame, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let matteMs = (CACurrentMediaTime() - matteStart) * 1000.0
        if commandBuffer.status == .error {
            throw RenderError.terminal("matte_command_buffer_error: \(commandBuffer.error?.localizedDescription ?? "unknown")")
        }
        guard matteTexture.pixelFormat == .r8Unorm else {
            throw RenderError.terminal("unexpected_matte_pixel_format_\(matteTexture.pixelFormat.rawValue)")
        }
        guard matteTexture.storageMode != .private else {
            throw RenderError.terminal("unexpected_matte_storage_mode_private")
        }

        let capturedImage = frame.capturedImage
        let imageWidth  = CVPixelBufferGetWidth(capturedImage)
        let imageHeight = CVPixelBufferGetHeight(capturedImage)
        guard matteTexture.width == imageWidth, matteTexture.height == imageHeight else {
            throw RenderError.terminal("matte_dimension_mismatch_\(matteTexture.width)x\(matteTexture.height)_capturedImage_\(imageWidth)x\(imageHeight)")
        }

        // 2. Matte texture → pooled OneComponent8 CVPixelBuffer (same CPU copy
        //    path as the still proof, so camera and matte share the
        //    CVPixelBuffer-derived CoreImage coordinate space).
        let compositeStart = CACurrentMediaTime()
        let matteBuffer = try acquireMatteBuffer(width: imageWidth, height: imageHeight, from: res)
        try VGARKitLiveGreenScreenPreviewCoordinator.copy(matteTexture: matteTexture, into: matteBuffer)
        let matteCopyMs = (CACurrentMediaTime() - compositeStart) * 1000.0

        // 3. Snapshot the live composite inputs for this frame: the current
        //    full-canvas background (session buffer, or solid teal when none was
        //    supplied) and the current foreground rect (top-left origin), mapped
        //    to CoreImage bottom-left space exactly like
        //    VGDuetPreviewCompositor.ciRect(fromTopLeft:).
        lock.lock()
        let backgroundBuffer = currentBackground
        let foregroundRectTopLeft = currentForegroundRect
        lock.unlock()
        let backgroundImage: CIImage = backgroundBuffer
            .map { CIImage(cvPixelBuffer: $0).cropped(to: res.canvasRect) }
            ?? res.backgroundImage
        let targetRect = VGARKitLiveGreenScreenPreviewCoordinator.ciRect(fromTopLeft: foregroundRectTopLeft,
                                                                         canvas: res.canvasRect)

        // 4. Identical orientation + aspect-fill transform for camera and matte
        //    into the foreground rect; the aspect-filled matte is then refined
        //    through the production VGMatteRefinementPipeline live pipeline (same
        //    rect, camera as edge guide — geometry and orientation untouched)
        //    and the camera is blended over the background through the REFINED
        //    mask, never the raw matte. Outside the rect the cropped camera /
        //    matte are absent (mask 0), so the background shows there — the
        //    same CIBlendWithMask geometry the adapter path's compositor uses
        //    for a foreground rect. `maskImage` stays the raw aspect-filled
        //    matte (refinement input) for the optional replay bundle.
        let composited: CIImage
        let cameraImage: CIImage
        let maskImage: CIImage
        var refinement: VGMatteRefinementPipeline.LiveGreenScreenMaskRefinement?
        if targetRect.isEmpty {
            cameraImage = CIImage.empty()
            maskImage   = CIImage.empty()
            composited  = backgroundImage
        } else {
            let fill = fillTransform(forImageWidth: imageWidth, height: imageHeight, into: targetRect, in: res)
            cameraImage = VGARKitLiveGreenScreenPreviewCoordinator
                .orientedNormalizedCIImage(CIImage(cvPixelBuffer: capturedImage),
                                           orientation: request.displayOrientation)
                .transformed(by: fill)
                .cropped(to: targetRect)
            maskImage = VGARKitLiveGreenScreenPreviewCoordinator
                .orientedNormalizedCIImage(CIImage(cvPixelBuffer: matteBuffer),
                                           orientation: request.displayOrientation)
                .transformed(by: fill)
                .cropped(to: targetRect)
            let refined = res.maskRefiner.refineLiveGreenScreenMask(
                aspectFilledMask: maskImage, in: targetRect, guidedBy: cameraImage)
            refinement = refined
            let params: [String: Any] = [
                "inputImage":           cameraImage,
                "inputBackgroundImage": backgroundImage,
                "inputMaskImage":       refined.mask,
            ]
            guard let blended = CIFilter(name: "CIBlendWithMask", parameters: params)?.outputImage else {
                throw RenderError.terminal("blend_filter_unavailable")
            }
            composited = blended.cropped(to: res.canvasRect)
        }

        // 5. Render into a pooled BGRA buffer and publish.
        var outBuffer: CVPixelBuffer?
        let aux: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: VGARKitLiveGreenScreenPreviewCoordinator.outputPoolAllocationThreshold,
        ]
        let outStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, res.outputPool, aux as CFDictionary, &outBuffer)
        if outStatus == kCVReturnWouldExceedAllocationThreshold {
            throw RenderError.poolExhausted
        }
        guard outStatus == kCVReturnSuccess, let output = outBuffer else {
            throw RenderError.terminal("output_pool_pixel_buffer_create_failed_\(outStatus)")
        }
        res.ciContext.render(composited, to: output, bounds: res.canvasRect, colorSpace: nil)
        let compositeMs = (CACurrentMediaTime() - compositeStart) * 1000.0

        texture.update(pixelBuffer: output)
        let publishTime = CACurrentMediaTime()

        lock.lock()
        publishedFrames += 1
        if firstPublishTime == nil { firstPublishTime = publishTime }
        lastPublishTime = publishTime
        matteWidth  = matteTexture.width
        matteHeight = matteTexture.height
        matteGenerationSumMs += matteMs
        matteGenerationMaxMs = max(matteGenerationMaxMs, matteMs)
        matteGenerationCount += 1
        if matteGenerationSamplesMs.count < VGARKitLiveGreenScreenPreviewCoordinator.maxTimingSamples {
            matteGenerationSamplesMs.append(matteMs)
        }
        matteCopySumMs += matteCopyMs
        matteCopyMaxMs = max(matteCopyMaxMs, matteCopyMs)
        compositeSumMs += compositeMs
        compositeMaxMs = max(compositeMaxMs, compositeMs)
        compositeCount += 1
        if compositeSamplesMs.count < VGARKitLiveGreenScreenPreviewCoordinator.maxTimingSamples {
            compositeSamplesMs.append(compositeMs)
        }
        let isFirstPublish = publishedFrames == 1
        var logFirstRefinement = false
        if let refined = refinement {
            maskRefinementFrames += 1
            maskMorphologyCloseApplied = refined.morphologyCloseApplied
            maskFeatherApplied         = refined.featherApplied
            maskTrimapApplied          = refined.trimapApplied
            maskGuidedEdgeApplied      = refined.guidedEdgeApplied
            liveTightAlphaR1Applied    = refined.tightAlphaR1Applied
            liveS4GuidedAlphaR1Applied = refined.s4GuidedAlphaR1Applied
            liveS4GuidedAlphaApplied   = refined.s4GuidedAlphaApplied
            if !hasLoggedFirstMaskRefinement {
                hasLoggedFirstMaskRefinement = true
                logFirstRefinement = true
            }
        }
        lock.unlock()

        if isFirstPublish {
            NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_FIRST_PUBLISH sessionId=\(sessionId) textureId=\(textureId) capturedImage=\(imageWidth)x\(imageHeight) matte=\(matteTexture.width)x\(matteTexture.height) matteGenerationMs=\(matteMs) compositeMs=\(compositeMs)")
        }
        if logFirstRefinement, let refined = refinement {
            // One-time proof that the active ARKit path blended a REFINED mask
            // (grep marker: IOS_ARKIT_LIVE_MASK_REFINEMENT_FIRST).
            NSLog("\(VGARKitLiveGreenScreenPreviewCoordinator.maskRefinementFirstMarker) sessionId=\(sessionId) textureId=\(textureId) maskRefinementPath=\(VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsMaskRefinementPath) liveMatteRefinement=\(refined.liveMatteRefinementMode.rawValue) maskMorphologyCloseApplied=\(refined.morphologyCloseApplied) maskFeatherApplied=\(refined.featherApplied) maskTrimapApplied=\(refined.trimapApplied) maskGuidedEdgeApplied=\(refined.guidedEdgeApplied) liveTightAlphaR1Applied=\(refined.tightAlphaR1Applied) liveS4GuidedAlphaR1Applied=\(refined.s4GuidedAlphaR1Applied) liveS4GuidedAlphaApplied=\(refined.s4GuidedAlphaApplied) targetRect=\(VGARKitLiveGreenScreenPreviewCoordinator.describe(targetRect)) matte=\(matteTexture.width)x\(matteTexture.height) compositeMs=\(compositeMs)")
        }

        let registry = textureRegistry
        let id = textureId
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let publishable = self.state == .running
            self.lock.unlock()
            guard publishable else { return }
            registry.textureFrameAvailable(id)
        }

        // 6. Optional one-shot replay-bundle capture from this frame (once
        //    publishedFrames reaches captureBundleAfterPublishedFrames), after the
        //    publish above so the live path is untouched. Runs inside this render,
        //    so the one-in-flight backpressure is unchanged: frames arriving meanwhile
        //    are dropped as busy, never queued for capture.
        if let captureDir = request.captureBundleOutputDir {
            lock.lock()
            let shouldCapture = !captureBundleAttempted && publishedFrames >= request.captureBundleAfterPublishedFrames
            if shouldCapture { captureBundleAttempted = true }
            let frameIndex = publishedFrames
            lock.unlock()
            if shouldCapture {
                autoreleasepool {
                    runReplayBundleCapture(outputDir: captureDir,
                                           frameIndex: frameIndex,
                                           backgroundImage: backgroundImage,
                                           cameraImage: cameraImage,
                                           maskImage: maskImage,
                                           with: res)
                }
            }
        }
    }

    // MARK: - Replay-bundle capture (render queue, one-shot)

    /// Captures the bundle, records the outcome under `lock`, and logs the
    /// capture markers. A failure is terminal for the preview (fail-closed:
    /// failureReason set, pass: false) so a broken baseline never looks live.
    private func runReplayBundleCapture(outputDir: String,
                                        frameIndex: Int,
                                        backgroundImage: CIImage,
                                        cameraImage: CIImage,
                                        maskImage: CIImage,
                                        with res: RenderResources) {
        let label = captureLabel
        let captureStart = CACurrentMediaTime()
        do {
            let result = try captureReplayBundle(outputDir: outputDir,
                                                 label: label,
                                                 backgroundImage: backgroundImage,
                                                 cameraImage: cameraImage,
                                                 maskImage: maskImage,
                                                 with: res)
            let captureMs = (CACurrentMediaTime() - captureStart) * 1000.0
            lock.lock()
            captureBundleCaptured = true
            captureBundleResult = result
            captureBundleMs = captureMs
            captureBundleFrameIndex = frameIndex
            lock.unlock()
            NSLog("\(VGARKitLiveGreenScreenPreviewCoordinator.captureBundleCapturedMarker) sessionId=\(sessionId) dir=\(outputDir) label=\(label) frameIndex=\(frameIndex) canvas=\(Int(res.canvasRect.width))x\(Int(res.canvasRect.height)) captureMs=\(captureMs)")
        } catch {
            let detail: String
            if case RenderError.terminal(let reason) = error {
                detail = reason
            } else {
                detail = error.localizedDescription
            }
            let reason = "capture_bundle_failed: \(detail)"
            let captureMs = (CACurrentMediaTime() - captureStart) * 1000.0
            lock.lock()
            captureBundleFailureReason = reason
            captureBundleMs = captureMs
            captureBundleFrameIndex = frameIndex
            lock.unlock()
            NSLog("\(VGARKitLiveGreenScreenPreviewCoordinator.captureBundleFailMarker) sessionId=\(sessionId) dir=\(outputDir) label=\(label) frameIndex=\(frameIndex) reason=\(reason)")
            recordTerminalFailure(reason)
        }
    }

    /// Renders the *same* oriented/aspect-filled `cameraImage` the live
    /// composite just blended and the same oriented/aspect-filled RAW
    /// `maskImage` it just refined (the refinement input, never the refined
    /// mask: the replay lab re-runs the refinement stages on this bundle) into
    /// full-canvas buffers through the same CIContext (no new orientation or
    /// fill policy), plus the background
    /// the live composite used (solid teal for the probe), and writes them with
    /// VGLiveGreenScreenReplayDiagnostics.writeReplayInputBundle. sourceRect and
    /// cameraRect are both the full canvas, so replay applies no second crop or
    /// distortion (a canvas-sized buffer aspect-filled into the canvas is the
    /// identity transform).
    private func captureReplayBundle(outputDir: String,
                                     label: String,
                                     backgroundImage: CIImage,
                                     cameraImage: CIImage,
                                     maskImage: CIImage,
                                     with res: RenderResources) throws -> [String: Any] {
        let width  = Int(res.canvasRect.width)
        let height = Int(res.canvasRect.height)

        let backgroundBuffer = try VGARKitLiveGreenScreenPreviewCoordinator.makeCaptureBuffer(
            width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA, what: "background")
        res.ciContext.render(backgroundImage, to: backgroundBuffer, bounds: res.canvasRect, colorSpace: nil)

        let cameraBuffer = try VGARKitLiveGreenScreenPreviewCoordinator.makeCaptureBuffer(
            width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA, what: "camera")
        res.ciContext.render(cameraImage, to: cameraBuffer, bounds: res.canvasRect, colorSpace: nil)

        // The matte goes through the same BGRA render path as the live composite
        // output and its red channel is copied into the OneComponent8 mask
        // buffer, so mask.r8 holds exactly the per-pixel matte value the live
        // CIBlendWithMask sampled (a OneComponent8 source reads with R == matte
        // in CoreImage whether it is treated as L8 or R8).
        let maskScratch = try VGARKitLiveGreenScreenPreviewCoordinator.makeCaptureBuffer(
            width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA, what: "mask_scratch")
        res.ciContext.render(maskImage, to: maskScratch, bounds: res.canvasRect, colorSpace: nil)
        let maskBuffer = try VGARKitLiveGreenScreenPreviewCoordinator.makeCaptureBuffer(
            width: width, height: height, pixelFormat: kCVPixelFormatType_OneComponent8, what: "mask")
        try VGARKitLiveGreenScreenPreviewCoordinator.copyRedChannel(from: maskScratch, into: maskBuffer)

        return try VGLiveGreenScreenReplayDiagnostics.writeReplayInputBundle(
            outputDir: outputDir,
            label: label,
            canvasWidth: width,
            canvasHeight: height,
            sourceFrame: backgroundBuffer,
            sourceRect: res.canvasRect,
            cameraRect: res.canvasRect,
            cameraFrame: cameraBuffer,
            maskFrame: maskBuffer)
    }

    /// One standalone (non-pooled) IOSurface-backed, Metal-compatible buffer
    /// for the capture, with the same attributes as the render pools so the
    /// CIContext render path is identical to the live output.
    private static func makeCaptureBuffer(width: Int, height: Int,
                                          pixelFormat: OSType, what: String) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:     Int(pixelFormat),
            kCVPixelBufferWidthKey as String:               width,
            kCVPixelBufferHeightKey as String:              height,
            kCVPixelBufferMetalCompatibilityKey as String:  true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let created = buffer else {
            throw RenderError.terminal("capture_\(what)_buffer_create_failed_\(status)")
        }
        return created
    }

    /// Copies the red channel of a rendered BGRA buffer into a OneComponent8
    /// buffer of the same size (stride-aware). Used for the captured mask.
    private static func copyRedChannel(from bgra: CVPixelBuffer, into mask: CVPixelBuffer) throws {
        let width  = CVPixelBufferGetWidth(bgra)
        let height = CVPixelBufferGetHeight(bgra)
        guard CVPixelBufferGetWidth(mask) == width, CVPixelBufferGetHeight(mask) == height else {
            throw RenderError.terminal("capture_mask_size_mismatch")
        }
        let srcLock = CVPixelBufferLockBaseAddress(bgra, .readOnly)
        guard srcLock == kCVReturnSuccess else {
            throw RenderError.terminal("capture_mask_scratch_lock_failed_\(srcLock)")
        }
        defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        let dstLock = CVPixelBufferLockBaseAddress(mask, [])
        guard dstLock == kCVReturnSuccess else {
            throw RenderError.terminal("capture_mask_lock_failed_\(dstLock)")
        }
        defer { CVPixelBufferUnlockBaseAddress(mask, []) }
        guard let src = CVPixelBufferGetBaseAddress(bgra),
              let dst = CVPixelBufferGetBaseAddress(mask) else {
            throw RenderError.terminal("capture_mask_base_address_nil")
        }
        let srcStride = CVPixelBufferGetBytesPerRow(bgra)
        let dstStride = CVPixelBufferGetBytesPerRow(mask)
        guard srcStride >= width * 4, dstStride >= width else {
            throw RenderError.terminal("capture_mask_stride_too_small_\(srcStride)_\(dstStride)")
        }
        for y in 0..<height {
            let srcRow = src.advanced(by: y * srcStride).assumingMemoryBound(to: UInt8.self)
            let dstRow = dst.advanced(by: y * dstStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                dstRow[x] = srcRow[x * 4 + 2]   // BGRA byte layout: B G R A
            }
        }
    }

    /// Acquires a pooled OneComponent8 buffer for the matte, (re)creating the
    /// pool when the matte size is first seen or changes.
    private func acquireMatteBuffer(width: Int, height: Int, from res: RenderResources) throws -> CVPixelBuffer {
        if res.mattePool == nil || res.mattePoolWidth != width || res.mattePoolHeight != height {
            guard let pool = VGARKitLiveGreenScreenPreviewCoordinator.makePool(
                width: width, height: height,
                pixelFormat: kCVPixelFormatType_OneComponent8, minimumBufferCount: 2) else {
                throw RenderError.terminal("matte_pool_create_failed_\(width)x\(height)")
            }
            res.mattePool = pool
            res.mattePoolWidth = width
            res.mattePoolHeight = height
        }
        guard let pool = res.mattePool else {
            throw RenderError.terminal("matte_pool_missing")
        }
        var buffer: CVPixelBuffer?
        let aux: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: VGARKitLiveGreenScreenPreviewCoordinator.mattePoolAllocationThreshold,
        ]
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, aux as CFDictionary, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw RenderError.poolExhausted
        }
        guard status == kCVReturnSuccess, let out = buffer else {
            throw RenderError.terminal("matte_pixel_buffer_create_failed_\(status)")
        }
        return out
    }

    /// Copies an `.r8Unorm` matte texture row-by-row into a OneComponent8
    /// CVPixelBuffer of the same size (stride-aware, single copy).
    private static func copy(matteTexture: MTLTexture, into buffer: CVPixelBuffer) throws {
        let width  = matteTexture.width
        let height = matteTexture.height
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
            throw RenderError.terminal("matte_pixel_buffer_size_mismatch")
        }
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw RenderError.terminal("matte_pixel_buffer_lock_failed_\(lockStatus)")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw RenderError.terminal("matte_pixel_buffer_base_address_nil")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard bytesPerRow >= width else {
            throw RenderError.terminal("matte_pixel_buffer_stride_too_small_\(bytesPerRow)")
        }
        matteTexture.getBytes(base,
                              bytesPerRow: bytesPerRow,
                              from: MTLRegionMake2D(0, 0, width, height),
                              mipmapLevel: 0)
    }

    /// Applies `orientation` and translates the result so its extent origin is
    /// exactly (0,0). Mirrors the still proof: the same call is made for the
    /// camera image and the matte so they receive the identical transform.
    private static func orientedNormalizedCIImage(_ image: CIImage,
                                                  orientation: CGImagePropertyOrientation) -> CIImage {
        let oriented = image.oriented(orientation)
        let extent = oriented.extent
        guard extent.origin != .zero else { return oriented }
        return oriented.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                          y: -extent.origin.y))
    }

    /// Aspect-fill transform (scale first, then centre) from the oriented
    /// image size into `rect` (CoreImage bottom-left space). Both `leftMirrored`
    /// and `right` swap width/height, so the oriented size is (height x width)
    /// of the captured image. Cached per captured-image size and target rect;
    /// only the render queue touches the cache.
    private func fillTransform(forImageWidth width: Int, height: Int,
                               into rect: CGRect, in res: RenderResources) -> CGAffineTransform {
        if res.cachedTransformWidth == width, res.cachedTransformHeight == height,
           res.cachedTransformRect == rect {
            return res.cachedFillTransform
        }
        let orientedWidth  = CGFloat(height)
        let orientedHeight = CGFloat(width)
        let scale = max(rect.width / orientedWidth, rect.height / orientedHeight)
        let scaledWidth  = orientedWidth * scale
        let scaledHeight = orientedHeight * scale
        let tx = rect.minX + ((rect.width  - scaledWidth)  / 2.0).rounded()
        let ty = rect.minY + ((rect.height - scaledHeight) / 2.0).rounded()
        let transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        res.cachedTransformWidth = width
        res.cachedTransformHeight = height
        res.cachedTransformRect = rect
        res.cachedFillTransform = transform
        NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_FILL_TRANSFORM sessionId=\(sessionId) oriented=\(Int(orientedWidth))x\(Int(orientedHeight)) canvas=\(Int(res.canvasRect.width))x\(Int(res.canvasRect.height)) targetRect=\(VGARKitLiveGreenScreenPreviewCoordinator.describe(rect)) scale=\(scale) tx=\(tx) ty=\(ty)")
        return transform
    }

    /// Converts a top-left-origin canvas rect to CoreImage bottom-left space,
    /// snapping edges to whole pixels and clipping to the canvas. Same rule as
    /// VGDuetPreviewCompositor.ciRect(fromTopLeft:) so a foreground transform
    /// lands on identical pixels on the ARKit and adapter paths. `.zero` for a
    /// degenerate rect.
    static func ciRect(fromTopLeft rect: CGRect, canvas: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x0 = rect.minX.rounded()
        let x1 = rect.maxX.rounded()
        let y0 = rect.minY.rounded()
        let y1 = rect.maxY.rounded()
        guard x1 > x0, y1 > y0 else { return .zero }
        let flipped = CGRect(x: x0,
                             y: canvas.height - y1,
                             width: x1 - x0,
                             height: y1 - y0)
        let clipped = flipped.intersection(canvas)
        return clipped.isNull ? .zero : clipped
    }

    /// Compact "x,y wxh" rect description for log markers (whole pixels).
    static func describe(_ rect: CGRect) -> String {
        return "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }

    // MARK: - Failure

    /// First terminal failure wins; rendering and frame accounting stop, the
    /// texture stays registered until stop() collects the summary. When the
    /// failure happens while running, `onTerminalFailure` (if set) is invoked
    /// once on main so the owner can stop this engine and fall back.
    private func recordTerminalFailure(_ reason: String) {
        lock.lock()
        let first = failureReason == nil
        if first { failureReason = reason }
        let wasRunning = state == .running
        if wasRunning { state = .failed }
        lock.unlock()
        if first {
            NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_FAIL sessionId=\(sessionId) reason=\(reason)")
        }
        guard first, wasRunning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let handler = self.onTerminalFailure else { return }
            self.onTerminalFailure = nil
            handler(reason)
        }
    }

    // MARK: - Pools

    private static func makePool(width: Int, height: Int,
                                 pixelFormat: OSType, minimumBufferCount: Int) -> CVPixelBufferPool? {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:     Int(pixelFormat),
            kCVPixelBufferWidthKey as String:               width,
            kCVPixelBufferHeightKey as String:              height,
            kCVPixelBufferMetalCompatibilityKey as String:  true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: minimumBufferCount,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes as CFDictionary,
                                             pixelBufferAttributes as CFDictionary,
                                             &pool)
        guard status == kCVReturnSuccess, let created = pool else {
            NSLog("[VGARKitLiveGreenScreenPreviewCoordinator] CVPixelBufferPoolCreate failed: \(status) (\(width)x\(height) format \(pixelFormat))")
            return nil
        }
        return created
    }

    // MARK: - Result maps

    private func makeFailedStartMap(reason: String,
                                    faceTrackingSupported: Bool,
                                    facePersonSegmentationSupported: Bool) -> [String: Any] {
        NSLog("IOS_ARKIT_LIVE_PREVIEW_NATIVE_FAIL sessionId=\(sessionId) reason=\(reason)")
        return [
            "pass": false,
            "proofBoundary": VGARKitLiveGreenScreenPreviewCoordinator.proofBoundary,
            "supported": false,
            "sessionId": sessionId,
            "width": request.canvasWidth,
            "height": request.canvasHeight,
            "targetFps": request.targetFps,
            "trackingConfiguration": VGARKitLiveGreenScreenPreviewCoordinator.trackingConfiguration,
            "activeTrackingUsesFrontCamera": true,
            "orientationMode": request.displayOrientationMode,
            "background": backgroundName,
            "faceTrackingSupported": faceTrackingSupported,
            "facePersonSegmentationSupported": facePersonSegmentationSupported,
            "failureReason": reason,
            "liveMatteRefinement": request.liveMatteRefinementMode.rawValue,
            "maskRefinementPath": VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsMaskRefinementPath,
            "captureBundleRequested": captureRequested,
            "captureBundleOutputDir": request.captureBundleOutputDir.map { $0 as Any } ?? NSNull(),
            "captureBundleAfterPublishedFrames": request.captureBundleAfterPublishedFrames,
            "captureBundleCaptured": false,
        ]
    }

    private static func percentile95(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((Double(sorted.count) * 0.95).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }

    /// Caller holds `lock`. `endTime` bounds the run duration (stopTime after
    /// stop, now while running). `includeProofClaims` adds the probe-only
    /// `claimsAllowed` / `nonClaims` arrays (stop summary only).
    private func makeSummaryLocked(endTime: CFTimeInterval, includeProofClaims: Bool) -> [String: Any] {
        // A requested capture that never happened (no frame was ever published,
        // or the capture failed) is a failure: pass requires the bundle. While
        // still running (diagnostics snapshot) a pending capture is not yet a
        // failure.
        let finalised = state == .stopped
        var effectiveFailureReason = failureReason
        if finalised, captureRequested, !captureBundleCaptured, effectiveFailureReason == nil {
            effectiveFailureReason = captureBundleFailureReason ?? "capture_bundle_not_captured_no_frame_published"
        }
        let pass = effectiveFailureReason == nil && publishedFrames > 0 && (!captureRequested || captureBundleCaptured)
        let runDurationMs = startTime > 0 ? max(0, (endTime - startTime) * 1000.0) : 0
        let avgFrameIntervalMs: Double? = frameIntervalCount > 0
            ? frameIntervalSumMs / Double(frameIntervalCount) : nil
        var effectiveFps: Double?
        var avgPublishIntervalMs: Double?
        if let first = firstPublishTime, let last = lastPublishTime, publishedFrames >= 2, last > first {
            effectiveFps = Double(publishedFrames - 1) / (last - first)
            avgPublishIntervalMs = (last - first) * 1000.0 / Double(publishedFrames - 1)
        }
        let avgMatteMs: Double? = matteGenerationCount > 0 ? matteGenerationSumMs / Double(matteGenerationCount) : nil
        let avgMatteCopyMs: Double? = compositeCount > 0 ? matteCopySumMs / Double(compositeCount) : nil
        let avgCompositeMs: Double? = compositeCount > 0 ? compositeSumMs / Double(compositeCount) : nil
        let firstPublishLatencyMs: Double? = firstPublishTime.map { ($0 - startTime) * 1000.0 }
        let engineState: String
        switch state {
        case .idle:     engineState = "idle"
        case .running:  engineState = "running"
        case .failed:   engineState = "failed"
        case .stopping: engineState = "stopping"
        case .stopped:  engineState = "stopped"
        }
        let backgroundDescriptor = currentBackground != nil
            ? VGARKitLiveGreenScreenPreviewCoordinator.sessionBackgroundName
            : VGARKitLiveGreenScreenPreviewCoordinator.backgroundName

        let mirrorDescription = request.displayOrientationMode == "leftMirrored" ? "selfie-mirrored" : "non-mirrored"
        var claimsAllowed: [String] = [
            "Whether ARMatteGenerator(device:matteResolution: .full) can generate a full-resolution person matte per live ARFrame from a physical-device front-camera ARFaceTrackingConfiguration + .personSegmentation session, and how many of those frames were refined through the production VGDuetPreviewCompositor live mask pipeline (mode \(request.liveMatteRefinementMode.rawValue)), composited over solid teal, and published to a Flutter texture during the hold.",
            "Coarse per-frame timing on this device for matte generation (avg/p95) and for matte copy + CoreImage composite (avg/p95), plus the published-frame cadence (effectiveFps) and drop/skip/throttle counts under one-render-in-flight backpressure.",
            "That the locked still-proof display orientation (\(request.displayOrientationMode)) applied identically to camera image and matte yields an upright, \(mirrorDescription) live preview for visual inspection on device.",
        ]
        var nonClaims: [String] = [
            "Not a production integration: does not exercise VGLiveGreenScreenSessionCoordinator, VGDuetPreviewCompositor.composite(), Vision, LiteRT, or any public Dart API (VGDuetPreviewCompositor is used for mask refinement only); no Vision/LiteRT comparison is made.",
            "No export MP4, no image or video background (solid teal only), no audio.",
            "No automated pixel-quality or temporal-stability assertion; visual inspection of the live texture is the proof.",
            "Front camera / face tracking only; rear-camera world tracking is not exercised.",
        ]
        if captureRequested {
            claimsAllowed.append(
                "That exactly one replay input bundle (background.bgra, camera.bgra, mask.r8, metadata.json) was written from the first successfully composited frame using the identical oriented/aspect-filled camera image the live composite blended and the identical oriented/aspect-filled raw (pre-refinement) matte it refined, at full canvas size with full-canvas sourceRect/cameraRect, through VGLiveGreenScreenReplayDiagnostics.writeReplayInputBundle without overwriting.")
            nonClaims.append(
                "The captured bundle is a raw ARKit baseline only: no visual metric, no tuning constant, no TikTok-parity claim, and no production promotion follow from it; the capture frame is the first published frame, not a chosen or representative pose.")
        }

        var summary: [String: Any] = [
            "pass": pass,
            "proofBoundary": VGARKitLiveGreenScreenPreviewCoordinator.proofBoundary,
            "sessionId": sessionId,
            "textureId": textureId,
            "ownsTexture": ownsTexture,
            "engineState": engineState,
            "providerKind": VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsProviderKind,
            "providerMode": VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsProviderMode,
            "timingSemantics": VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsTimingSemantics,
            "modelName": VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsModelName,
            "mattePath": VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsMattePath,
            "maskRefinementPath": VGARKitLiveGreenScreenPreviewCoordinator.diagnosticsMaskRefinementPath,
            "liveMatteRefinement": request.liveMatteRefinementMode.rawValue,
            "maskRefinementFrames": maskRefinementFrames,
            "maskRefinementApplied": maskRefinementFrames > 0,
            "maskMorphologyCloseApplied": maskMorphologyCloseApplied,
            "maskFeatherApplied": maskFeatherApplied,
            "maskTrimapApplied": maskTrimapApplied,
            "maskGuidedEdgeApplied": maskGuidedEdgeApplied,
            "liveTightAlphaR1Applied": liveTightAlphaR1Applied,
            "liveS4GuidedAlphaR1Applied": liveS4GuidedAlphaR1Applied,
            "liveS4GuidedAlphaApplied": liveS4GuidedAlphaApplied,
            "width": request.canvasWidth,
            "height": request.canvasHeight,
            "targetFps": request.targetFps,
            "trackingConfiguration": VGARKitLiveGreenScreenPreviewCoordinator.trackingConfiguration,
            "activeTrackingUsesFrontCamera": true,
            "orientationMode": request.displayOrientationMode,
            "background": backgroundDescriptor,
            "foregroundRect": VGARKitLiveGreenScreenPreviewCoordinator.describe(currentForegroundRect),
            "firstMaskLatencyMs": firstMaskLatencyMs.map { $0 as Any } ?? NSNull(),
            "firstPublishLatencyMs": firstPublishLatencyMs.map { $0 as Any } ?? NSNull(),
            "avgPublishIntervalMs": avgPublishIntervalMs.map { $0 as Any } ?? NSNull(),
            "maxMatteGenerationMs": matteGenerationCount > 0 ? matteGenerationMaxMs as Any : NSNull(),
            "avgMatteCopyMs": avgMatteCopyMs.map { $0 as Any } ?? NSNull(),
            "maxMatteCopyMs": compositeCount > 0 ? matteCopyMaxMs as Any : NSNull(),
            "maxCompositeMs": compositeCount > 0 ? compositeMaxMs as Any : NSNull(),
            "frameCount": frameCount,
            "maskCount": maskCount,
            "publishedFrames": publishedFrames,
            "droppedBusyFrames": droppedBusyFrames,
            "skippedNoMaskFrames": skippedNoMaskFrames,
            "throttledFrames": throttledFrames,
            "droppedPoolExhaustedFrames": droppedPoolExhaustedFrames,
            "renderFailureCount": renderFailureCount,
            "interruptionCount": interruptionCount,
            "avgFrameIntervalMs": avgFrameIntervalMs.map { $0 as Any } ?? NSNull(),
            "effectiveFps": effectiveFps.map { $0 as Any } ?? NSNull(),
            "avgMatteGenerationMs": avgMatteMs.map { $0 as Any } ?? NSNull(),
            "p95MatteGenerationMs": VGARKitLiveGreenScreenPreviewCoordinator.percentile95(matteGenerationSamplesMs).map { $0 as Any } ?? NSNull(),
            "avgCompositeMs": avgCompositeMs.map { $0 as Any } ?? NSNull(),
            "p95CompositeMs": VGARKitLiveGreenScreenPreviewCoordinator.percentile95(compositeSamplesMs).map { $0 as Any } ?? NSNull(),
            "runDurationMs": runDurationMs,
            "capturedImageWidth": capturedImageWidth,
            "capturedImageHeight": capturedImageHeight,
            "rawSegmentationBufferWidth": rawSegmentationBufferWidth,
            "rawSegmentationBufferHeight": rawSegmentationBufferHeight,
            "matteWidth": matteWidth,
            "matteHeight": matteHeight,
            "videoFormatWidth": videoFormatWidth,
            "videoFormatHeight": videoFormatHeight,
            "videoFormatFramesPerSecond": videoFormatFramesPerSecond,
            "stopRenderDrainTimedOut": stopRenderDrainTimedOut,
            "failureReason": effectiveFailureReason.map { $0 as Any } ?? NSNull(),
            "captureBundleRequested": captureRequested,
            "captureBundleOutputDir": request.captureBundleOutputDir.map { $0 as Any } ?? NSNull(),
            "captureBundleLabel": captureRequested ? captureLabel as Any : NSNull(),
            "captureBundleAfterPublishedFrames": request.captureBundleAfterPublishedFrames,
            "captureBundleCaptured": captureBundleCaptured,
            "captureBundle": captureBundleResult.map { $0 as Any } ?? NSNull(),
            "captureBundleMs": captureBundleMs.map { $0 as Any } ?? NSNull(),
            "captureBundleFrameIndex": captureBundleFrameIndex.map { $0 as Any } ?? NSNull(),
            "captureBundleFailureReason": captureBundleFailureReason.map { $0 as Any } ?? NSNull(),
        ]
        if includeProofClaims {
            summary["claimsAllowed"] = claimsAllowed
            summary["nonClaims"] = nonClaims
        }
        return summary
    }
}
