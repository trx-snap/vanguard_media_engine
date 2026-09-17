// VGLiveGreenScreenSessionCoordinator.swift
// Generic live green-screen: single active session owner. Caller-agnostic —
// live meeting/calling, going live, camera, or any other surface starts one
// session through the public Dart API; nothing here is scoped to Duet.
//
// Owns, per session: Flutter preview texture, static background buffer,
// VGLiveGreenScreenMaskProviderAdapter (Vision Fast backend as iOS production
// default; or LiteRT/Metal over selfie_multiclass_256x256.tflite with heuristic
// fallback; or diagnostics options for Vision Balanced / Vision Accurate /
// litertSelfie), VGDuetCameraSource (front camera ingress), VGDuetPreviewCompositor,
// VGLiveGreenScreenRenderLoop. The Duet-named primitives are reused as generic
// building blocks only.
//
// Lifecycle:
//   startSession     → busy check → static background → texture register →
//                      adapter start → camera start (frames observed into the
//                      adapter) → render loop start → {sessionId, textureId,
//                      width, height}.
//   updateBackground → rebuild the static buffer and swap it on the loop; the
//                      camera, segmenter, and texture are NOT restarted.
//   updateTransform  → recompute the foreground rect through
//                      VGDuetLayoutGeometry.greenScreen(canvasWidth:canvasHeight:transform:)
//                      and swap it on the loop.
//   stopSession      → idempotent for unknown/already-stopped ids.
//   diagnostics      → diagnostic-only read of the adapter's matte latency /
//                      publication telemetry plus the camera's selected
//                      session preset for the active session id
//                      (session_not_found otherwise). No state change.
//   setDiagnosticsOptions
//                    → diagnostic-only (not public Dart API). Rejected with
//                      live_busy while a session is active. Stores
//                      {iosFastMetalPrecision, iosSegmentationBackend} for the
//                      NEXT startSession only: that start consumes them
//                      (adapter fastMetalPrecision → LiteRT Metal
//                      allow_precision_loss; adapter segmentationBackend →
//                      visionFast (iOS production default) | litert |
//                      visionBalanced | ...; diagnostics can override next start)
//                      and the pending values reset to the defaults. Never alters a
//                      running session.
//   disposeAll       → plugin detach; releases the active session and drops
//                      any pending diagnostics options.
//
// Terminal order (stop / dispose):
//   render loop stop → adapter invalidate → camera observer clear → camera stop
//   → texture invalidate → texture unregister → active session cleared.
//
// Segmentation failure (the adapter could create no mask provider at all):
// keying is disabled, the adapter is invalidated, and the loop keeps presenting
// the unkeyed live camera over the same background. `onLiveGreenScreenEvent`
// receives a degraded payload whose `reason` / `failureReason` carry the
// adapter's exact setup failure (for example model_asset_missing). Before the
// adapter is released its last diagnostics snapshot is cached on the session
// (`terminalDiagnostics`), so a later `diagnostics(sessionId:)` still reports
// providerKind / providerMode / segmentationBackend / failureReason /
// sampleCount / maskPublishCount instead of a bare "released" placeholder.
// LiteRT-unavailable → heuristic fallback is NOT a
// failure (the adapter logs IOS_LIVE_GREENSCREEN_MASK_PROVIDER_FALLBACK). A
// diagnostics-requested Vision backend that is unavailable (iOS < 15) has no
// fallback and takes this same segmentation-failure path by design. Model
// warm-up is NOT a failure: until the first fresh mask lands the compositor
// already shows the unkeyed camera, so start never waits on the model. A stale
// mask (older than `maskMaxAgeSeconds` of camera time) is withheld by the
// adapter, so the loop presents that frame unkeyed instead of mis-keyed.
//
// Mask/camera PTS pairing: the render loop fetches the mask (with the camera
// PTS it was computed from) first, then the camera provider returns the
// history frame nearest that PTS (VGDuetCameraSource.snapshotRetained(near:
// maxDeltaSeconds:), window `maskPairingMaxDeltaSeconds`). With no numeric
// PTS or no frame in the window it returns the latest frame, so a render is
// never dropped. The first aligned pair logs
// IOS_LIVE_GREENSCREEN_PTS_ALIGNED_PAIR_FIRST with the achieved |delta| ms.
//
// Threading: all public methods run on the main thread (Flutter plugin thread).

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Flutter
import Foundation

// MARK: - Start request

/// Validated `startLiveGreenScreenSession` arguments (built by the handler).
struct VGLiveGreenScreenStartRequest {
    let canvasWidth: Int
    let canvasHeight: Int
    let background: VGLiveGreenScreenBackgroundSpec
    /// nil → full-canvas identity (foregroundTransform omitted or malformed).
    let foregroundTransform: NativeForegroundTransform?
}

// MARK: - Diagnostics options (diagnostic-only; not public Dart API)

/// Options accepted by `setLiveGreenScreenDiagnosticsOptions`. They apply to
/// the next session start only and never alter an active session.
struct VGLiveGreenScreenDiagnosticsOptions {
    /// Forwarded to VGLiveGreenScreenMaskProviderAdapter(fastMetalPrecision:…)
    /// and from there to VGLiteRTMaskProvider metalAllowPrecisionLoss (Metal
    /// delegate allow_precision_loss). false = production float32 path.
    /// Echoed but not applied when a Vision backend is selected.
    var iosFastMetalPrecision: Bool = false

    /// Forwarded to VGLiveGreenScreenMaskProviderAdapter(…segmentationBackend:).
    /// Vision Fast is iOS production default and diagnostics can override next
    /// start ("litert" selectable alternate LiteRT/Metal path | "visionBalanced" |
    /// "visionAccurate" | "litertSelfie").
    /// Validated by the method handler against the
    /// VGLiveGreenScreenSegmentationBackend* constants before reaching here.
    var iosSegmentationBackend: String = VGLiveGreenScreenSegmentationBackendVisionFast

    static let `default` = VGLiveGreenScreenDiagnosticsOptions()

    /// Wire shape echoed back to the caller:
    /// {iosFastMetalPrecision, iosSegmentationBackend}.
    var payload: [String: Any] {
        return [
            "iosFastMetalPrecision":  iosFastMetalPrecision,
            "iosSegmentationBackend": iosSegmentationBackend,
        ]
    }
}

// MARK: - Coordinator

final class VGLiveGreenScreenSessionCoordinator {

    // MARK: Error codes (mirror the Dart VGLiveGreenScreenErrorCode wire values)

    static let errorInvalidArg        = "INVALID_ARG"
    static let errorLiveBusy          = "live_busy"
    static let errorCompositionFailed = "composition_failed"
    static let errorSessionNotFound   = "session_not_found"

    // MARK: Event payload values

    /// `event` wire name parsed by VGLiveGreenScreenEvent on the Dart side.
    static let eventDegraded            = "green_screen_degraded"
    static let backendIosMl             = "ios_ml"
    static let backendUnkeyed           = "unkeyed"
    /// Failure category of the degraded event (`failureCategory`), and the
    /// `reason` fallback when the adapter reported no exact failure reason.
    static let reasonSegmentationFailure = "segmentation_failure"
    /// `terminalState` diagnostics value while keying is active.
    static let terminalStateKeyed        = "keyed"
    /// `terminalState` diagnostics value after the segmentation failure path.
    static let terminalStateDegraded     = "degraded_unkeyed"
    /// `failureReason` / `terminalReason` value while no failure exists.
    static let noFailureReason           = "none"
    private static let degradedUserMessage =
        "Green screen is unavailable on this device. Showing the live camera over the background."

    /// Maximum camera-time lag between the latest submitted frame and the mask
    /// handed to the compositor. Older masks are withheld (frame renders unkeyed).
    static let maskMaxAgeSeconds: TimeInterval =
        VGLiveGreenScreenMaskProviderAdapter.defaultMaxMaskAgeSeconds

    /// Maximum |cameraFramePTS − maskSourcePTS| for a history frame to be paired
    /// with the mask instead of the latest frame (~3.6 frames at 30 fps).
    static let maskPairingMaxDeltaSeconds: Double = 0.12

    // MARK: Session

    private final class LiveSession {
        let sessionId: String
        let textureId: Int64
        let texture: VGDuetPreviewTexture
        let canvasWidth: Int
        let canvasHeight: Int

        /// Segmentation backend requested for this session (diagnostics
        /// options at start; "visionFast" by default). Kept so diagnostics can
        /// still echo it after the adapter has been released.
        let requestedSegmentationBackend: String

        var cameraSource: VGDuetCameraSource?
        var adapter: VGLiveGreenScreenMaskProviderAdapter?
        var renderLoop: VGLiveGreenScreenRenderLoop?
        /// False after the terminal segmentation failure path ran.
        var isKeyed = true
        /// Exact adapter failure reason captured by the terminal segmentation
        /// failure path (nil while keyed).
        var terminalReason: String?
        /// Adapter diagnostics snapshot + session state cached by
        /// `handleAdapterFailure` immediately BEFORE the adapter was
        /// invalidated and dropped. Merged into every later
        /// `diagnostics(sessionId:)` reply so the failure is still observable
        /// after release. nil while the adapter is alive.
        var terminalDiagnostics: [String: Any]?
        /// Set once the first PTS-aligned mask/camera pair was logged (main thread).
        var loggedFirstAlignedPair = false

        init(sessionId: String,
             textureId: Int64,
             texture: VGDuetPreviewTexture,
             canvasWidth: Int,
             canvasHeight: Int,
             requestedSegmentationBackend: String) {
            self.sessionId    = sessionId
            self.textureId    = textureId
            self.texture      = texture
            self.canvasWidth  = canvasWidth
            self.canvasHeight = canvasHeight
            self.requestedSegmentationBackend = requestedSegmentationBackend
        }
    }

    // MARK: State

    private let textureRegistry: FlutterTextureRegistry?

    /// Emits an `onLiveGreenScreenEvent` payload to Dart. The plugin-supplied
    /// closure hops to the main thread before calling `channel.invokeMethod`.
    private let onLiveGreenScreenEvent: (([String: Any]) -> Void)?

    private let backgroundRenderer = VGLiveGreenScreenStaticBackgroundRenderer()

    /// At most one live session at a time.
    private var activeSession: LiveSession?

    /// Diagnostic-only options for the next start (see setDiagnosticsOptions).
    /// Consumed by the start that builds a session; reset by disposeAll.
    private var pendingDiagnosticsOptions = VGLiveGreenScreenDiagnosticsOptions.default

    // MARK: - Init

    init(textureRegistry: FlutterTextureRegistry? = nil,
         onLiveGreenScreenEvent: (([String: Any]) -> Void)? = nil) {
        self.textureRegistry        = textureRegistry
        self.onLiveGreenScreenEvent = onLiveGreenScreenEvent
    }

    // MARK: - start

    func startSession(_ request: VGLiveGreenScreenStartRequest,
                      reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)

        guard activeSession == nil else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorLiveBusy,
                message: "startLiveGreenScreenSession: a live green-screen session is already active.",
                details: nil))
            return
        }
        guard let registry = textureRegistry else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorCompositionFailed,
                message: "startLiveGreenScreenSession: textureRegistry not available.",
                details: nil))
            return
        }

        // Build the static background before allocating the texture or camera
        // so a rejected image path fails with nothing to unwind.
        let background: CVPixelBuffer
        do {
            background = try backgroundRenderer.build(spec: request.background,
                                                      canvasWidth: request.canvasWidth,
                                                      canvasHeight: request.canvasHeight)
        } catch {
            reply(nil, VGLiveGreenScreenSessionCoordinator.flutterError(
                from: error, route: "startLiveGreenScreenSession"))
            return
        }

        let width  = request.canvasWidth
        let height = request.canvasHeight

        // Diagnostic-only options are consumed by exactly this start; a later
        // start without a fresh setDiagnosticsOptions call runs the defaults.
        let diagnosticsOptions = pendingDiagnosticsOptions
        pendingDiagnosticsOptions = .default

        let texture   = VGDuetPreviewTexture()
        let textureId = registry.register(texture)
        let sessionId = "ios_live_gs_" + UUID().uuidString.lowercased()
        let session = LiveSession(sessionId: sessionId,
                                  textureId: textureId,
                                  texture: texture,
                                  canvasWidth: width,
                                  canvasHeight: height,
                                  requestedSegmentationBackend: diagnosticsOptions.iosSegmentationBackend)

        let compositor = VGDuetPreviewCompositor(canvasWidth: Double(width), canvasHeight: Double(height))

        // Mask adapter BEFORE camera start so frames are routed to the provider
        // from the first delivered frame. The unavailable handler is wired
        // before start(); provider setup runs asynchronously and warm-up is not
        // a failure (frames are dropped until the provider is selected).
        let adapter = VGLiveGreenScreenMaskProviderAdapter(
            fastMetalPrecision:  diagnosticsOptions.iosFastMetalPrecision,
            segmentationBackend: diagnosticsOptions.iosSegmentationBackend)
        session.adapter = adapter
        adapter.onProviderUnavailable = { [weak self, weak session] adapterDiagnostics in
            guard let self = self, let session = session else { return }
            self.handleAdapterFailure(session: session, adapterDiagnostics: adapterDiagnostics)
        }
        adapter.start()

        // Camera ingress: observer wired before start() so no frame is missed.
        // Live green-screen requests 960x540 iFrame capture first (vs. the
        // 1080p-first default used by every other camera/Duet caller) — this
        // RND latency path preserves 16:9 aspect while further reducing
        // capture/input cost than 720p; segmentation and compositing do not
        // need full 1080p. Where iFrame960x540 is unsupported the source falls
        // back to 720p before its generic 1080p-first default.
        let camera = VGDuetCameraSource(sessionPresets: [
            AVCaptureSession.Preset.iFrame960x540.rawValue,
            AVCaptureSession.Preset.hd1280x720.rawValue,
        ])
        session.cameraSource = camera
        // Observer runs synchronously on the capture queue; the adapter's submit
        // is non-blocking (the provider retains and dispatches internally).
        camera.setFrameObserver { [weak adapter] pixelBuffer, pts in
            adapter?.submitFrame(pixelBuffer, presentationTime: pts)
        }
        camera.start()
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_CAMERA_STARTED sessionId=\(sessionId) cameraSelectedSessionPreset=\(camera.selectedSessionPreset ?? "unknown")")

        let rects = VGDuetLayoutGeometry.greenScreen(canvasWidth: CGFloat(width),
                                                     canvasHeight: CGFloat(height),
                                                     transform: request.foregroundTransform)

        // Presents go texture → textureFrameAvailable on main. Providers hold
        // the session weakly so the loop never keeps a released session alive.
        let loop = VGLiveGreenScreenRenderLoop(
            compositor:     compositor,
            background:     background,
            foregroundRect: rects.camera,
            cameraFrameProvider: { [weak session] preferredPTS in
                guard let session = session, let camera = session.cameraSource else { return nil }
                // Pair to the mask's source PTS when it is numeric; otherwise,
                // or when no history frame is inside the window, use the latest.
                if let pts = preferredPTS, pts.isNumeric,
                   let match = camera.snapshotRetainedWithPTS(
                       near: pts,
                       maxDeltaSeconds: VGLiveGreenScreenSessionCoordinator.maskPairingMaxDeltaSeconds) {
                    if !session.loggedFirstAlignedPair {
                        session.loggedFirstAlignedPair = true
                        let absDeltaMs = abs(CMTimeGetSeconds(match.pts) - CMTimeGetSeconds(pts)) * 1000.0
                        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_PTS_ALIGNED_PAIR_FIRST sessionId=\(session.sessionId) absDeltaMs=\(String(format: "%.2f", absDeltaMs)) maskSourcePtsSeconds=\(String(format: "%.4f", CMTimeGetSeconds(pts))) cameraPtsSeconds=\(String(format: "%.4f", CMTimeGetSeconds(match.pts))) maxPairingDeltaMs=\(Int((VGLiveGreenScreenSessionCoordinator.maskPairingMaxDeltaSeconds * 1000.0).rounded()))")
                    }
                    return match.frame
                }
                return camera.snapshotRetained()
            },
            maskProvider: { [weak session] in
                // The adapter returns an owned (+1) CVPixelBuffer that ARC manages
                // in `mask`; passRetained adds the +1 the loop releases after
                // compositing, and `mask` drops its own reference on scope exit.
                // sourcePTS is written only alongside a returned mask.
                var sourcePTS = CMTime.invalid
                guard let mask = session?.adapter?.latestMaskRetained(
                    maxAgeSeconds: VGLiveGreenScreenSessionCoordinator.maskMaxAgeSeconds,
                    sourcePTSOut: &sourcePTS)
                else { return nil }
                return VGLiveGreenScreenRenderLoop.MaskSnapshot(buffer: Unmanaged.passRetained(mask),
                                                                sourcePTS: sourcePTS)
            },
            presentHandler: { pixelBuffer in
                texture.update(pixelBuffer: pixelBuffer)
                registry.textureFrameAvailable(textureId)
            })
        session.renderLoop = loop
        activeSession = session
        loop.start()

        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_SESSION_STARTED sessionId=\(sessionId) textureId=\(textureId) canvas=\(width)x\(height) foregroundRect=\(VGLiveGreenScreenSessionCoordinator.describe(rects.camera)) maskSource=\(diagnosticsOptions.iosSegmentationBackend)_adapter(pending) segmentationBackend=\(diagnosticsOptions.iosSegmentationBackend) fastMetalPrecision=\(diagnosticsOptions.iosFastMetalPrecision)")

        let descriptor: [String: Any] = [
            "sessionId": sessionId,
            "textureId": textureId,
            "width":     width,
            "height":    height,
        ]
        reply(descriptor, nil)
    }

    // MARK: - updateBackground

    func updateBackground(sessionId: String,
                          background spec: VGLiveGreenScreenBackgroundSpec,
                          reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId,
                                                 route: "updateLiveGreenScreenBackground",
                                                 reply: reply) else { return }
        let buffer: CVPixelBuffer
        do {
            buffer = try backgroundRenderer.build(spec: spec,
                                                  canvasWidth: session.canvasWidth,
                                                  canvasHeight: session.canvasHeight)
        } catch {
            reply(nil, VGLiveGreenScreenSessionCoordinator.flutterError(
                from: error, route: "updateLiveGreenScreenBackground"))
            return
        }
        // Atomic swap on the loop; camera / segmenter / texture untouched.
        session.renderLoop?.updateBackground(buffer)
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_BACKGROUND_UPDATED sessionId=\(sessionId) type=\(VGLiveGreenScreenSessionCoordinator.describe(spec))")
        reply(nil, nil)
    }

    // MARK: - updateTransform

    func updateTransform(sessionId: String,
                         transform: NativeForegroundTransform?,
                         reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId,
                                                 route: "updateLiveGreenScreenTransform",
                                                 reply: reply) else { return }
        let rects = VGDuetLayoutGeometry.greenScreen(canvasWidth: CGFloat(session.canvasWidth),
                                                     canvasHeight: CGFloat(session.canvasHeight),
                                                     transform: transform)
        session.renderLoop?.updateForegroundRect(rects.camera)
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_TRANSFORM_UPDATED sessionId=\(sessionId) foregroundRect=\(VGLiveGreenScreenSessionCoordinator.describe(rects.camera))")
        reply(nil, nil)
    }

    // MARK: - stop

    /// Idempotent: an unknown or already-stopped id completes normally.
    func stopSession(sessionId: String,
                     reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = activeSession, session.sessionId == sessionId else {
            reply(nil, nil)
            return
        }
        release(session)
        reply(nil, nil)
    }

    // MARK: - diagnostics (diagnostic-only; physical smoke telemetry)

    /// Returns the adapter's aggregated segmentation timing / matte publication
    /// snapshot for the active session, plus session identity. Read-only: no
    /// lifecycle state changes.
    ///
    /// Always present at top level, in every state:
    ///   isKeyed, degraded (= !isKeyed), terminalState ("keyed" |
    ///   "degraded_unkeyed"), terminalReason / failureReason ("none" while no
    ///   failure), segmentationBackend, providerKind, providerMode,
    ///   sampleCount, maskPublishCount, lastMaskCoveragePercent, adapterReleased.
    /// After the segmentation-degraded path released the adapter, the
    /// snapshot cached by `handleAdapterFailure` (taken while the adapter was
    /// still alive) is merged in, so the exact failure reason and the
    /// provider state at failure time remain observable instead of a bare
    /// "released" placeholder.
    func diagnostics(sessionId: String,
                     reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId,
                                                 route: "getLiveGreenScreenDiagnostics",
                                                 reply: reply) else { return }
        let cameraSelectedSessionPreset =
            session.cameraSource?.selectedSessionPreset ?? "unknown"
        var payload: [String: Any] = [
            "sessionId":                   session.sessionId,
            "textureId":                   session.textureId,
            "isKeyed":                     session.isKeyed,
            "degraded":                    !session.isKeyed,
            "terminalState":               session.isKeyed
                ? VGLiveGreenScreenSessionCoordinator.terminalStateKeyed
                : VGLiveGreenScreenSessionCoordinator.terminalStateDegraded,
            "terminalReason":              session.terminalReason
                ?? VGLiveGreenScreenSessionCoordinator.noFailureReason,
            "failureReason":               session.terminalReason
                ?? VGLiveGreenScreenSessionCoordinator.noFailureReason,
            "segmentationBackend":         session.requestedSegmentationBackend,
            "adapterReleased":             session.adapter == nil,
            "maskMaxAgeSeconds":           VGLiveGreenScreenSessionCoordinator.maskMaxAgeSeconds,
            "cameraSelectedSessionPreset": cameraSelectedSessionPreset,
        ]
        if let adapter = session.adapter {
            // Live adapter: its snapshot is authoritative (failureReason is
            // "none" there unless a failure is in flight).
            for (key, value) in adapter.diagnosticsSnapshot() {
                payload[key] = value
            }
        } else if let terminal = session.terminalDiagnostics {
            // Adapter released by the segmentation failure path: report the
            // snapshot cached at failure time, never a blank placeholder.
            for (key, value) in terminal {
                payload[key] = value
            }
        } else {
            // Defensive: an active session without an adapter and without a
            // cached terminal snapshot is not a state this coordinator
            // produces; say so explicitly rather than looking healthy.
            payload["providerKind"]           = "released"
            payload["providerMode"]           = "released"
            payload["sampleCount"]            = 0
            payload["maskPublishCount"]       = 0
            payload["lastMaskCoveragePercent"] = -1
            payload["terminalReason"]         = "adapter_released_without_terminal_diagnostics"
            payload["failureReason"]          = "adapter_released_without_terminal_diagnostics"
        }
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_DIAGNOSTICS sessionId=\(session.sessionId) isKeyed=\(session.isKeyed) terminalState=\(payload["terminalState"] ?? "?") failureReason=\(payload["failureReason"] ?? "?") adapterReleased=\(payload["adapterReleased"] ?? false) cameraSelectedSessionPreset=\(cameraSelectedSessionPreset) providerKind=\(payload["providerKind"] ?? "?") providerMode=\(payload["providerMode"] ?? "?") segmentationBackend=\(payload["segmentationBackend"] ?? "?") timingSemantics=\(payload["timingSemantics"] ?? "?") fastMetalPrecision=\(payload["fastMetalPrecision"] ?? false) metalAllowPrecisionLoss=\(payload["metalAllowPrecisionLoss"] ?? false) sampleCount=\(payload["sampleCount"] ?? 0) avgTotalMs=\(payload["avgTotalMs"] ?? -1) maxTotalMs=\(payload["maxTotalMs"] ?? -1) avgInferenceMs=\(payload["avgInferenceMs"] ?? -1) avgInputCopyMs=\(payload["avgInputCopyMs"] ?? -1) avgInvokeMs=\(payload["avgInvokeMs"] ?? -1) avgOutputAccessMs=\(payload["avgOutputAccessMs"] ?? -1) avgCadenceMs=\(payload["avgCadenceMs"] ?? -1) maskPublishCount=\(payload["maskPublishCount"] ?? 0) lastMaskCoveragePercent=\(payload["lastMaskCoveragePercent"] ?? -1) firstMaskLatencyMs=\(payload["firstMaskLatencyMs"] ?? -1)")
        reply(payload, nil)
    }

    // MARK: - diagnostics options (diagnostic-only; next start only)

    /// Stores diagnostic-only options for the next `startSession`. Rejected
    /// with `live_busy` while a session is active, so the options can never
    /// change a running session. Replies with the stored options
    /// ({iosFastMetalPrecision, iosSegmentationBackend}). Not part of the
    /// public Dart API.
    func setDiagnosticsOptions(_ options: VGLiveGreenScreenDiagnosticsOptions,
                               reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        if let session = activeSession {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorLiveBusy,
                message: "setLiveGreenScreenDiagnosticsOptions: a live green-screen session is already active (id '\(session.sessionId)'); stop it before changing diagnostics options.",
                details: nil))
            return
        }
        pendingDiagnosticsOptions = options
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_DIAGNOSTICS_OPTIONS_SET iosFastMetalPrecision=\(options.iosFastMetalPrecision) iosSegmentationBackend=\(options.iosSegmentationBackend) appliesTo=next_start")
        reply(options.payload, nil)
    }

    // MARK: - Teardown (plugin detach)

    func disposeAll() {
        assert(Thread.isMainThread)
        if let session = activeSession {
            release(session)
        }
        activeSession = nil
        pendingDiagnosticsOptions = .default
    }

    // MARK: - Private: release

    /// Terminal order: render loop stop → adapter invalidate → camera observer
    /// clear → camera stop → texture invalidate → texture unregister → active nil.
    private func release(_ session: LiveSession) {
        assert(Thread.isMainThread)

        session.renderLoop?.stop()
        session.renderLoop = nil

        session.adapter?.invalidate()
        session.adapter = nil

        session.cameraSource?.setFrameObserver(nil)
        session.cameraSource?.stop()
        session.cameraSource = nil

        session.texture.invalidate()
        textureRegistry?.unregisterTexture(session.textureId)

        if activeSession === session {
            activeSession = nil
        }
        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_SESSION_RELEASED sessionId=\(session.sessionId) textureId=\(session.textureId)")
    }

    // MARK: - Private: segmentation failure

    /// Called on main when VGLiveGreenScreenMaskProviderAdapter could create no
    /// mask provider at all (neither LiteRT nor the heuristic fallback). Keying
    /// is disabled and rendering continues unkeyed over the same background;
    /// the session is NOT stopped.
    ///
    /// `adapterDiagnostics` is the adapter's snapshot handed over by
    /// `onProviderUnavailable` (providerKind "unavailable", exact
    /// `failureReason`, …). It is cached on the session — together with the
    /// session fields that must outlive the adapter — BEFORE the adapter is
    /// invalidated and dropped, so `diagnostics(sessionId:)` and the degraded
    /// event can both report why keying failed.
    private func handleAdapterFailure(session: LiveSession,
                                      adapterDiagnostics: [String: Any]) {
        assert(Thread.isMainThread)
        guard session === activeSession, session.isKeyed else { return }
        session.isKeyed = false

        // ── 1. Capture everything we still can while the adapter is alive ───
        // Start from a fresh snapshot of the live adapter, then overlay the
        // one the adapter handed us (same state; the callback copy wins).
        var cached: [String: Any] = session.adapter?.diagnosticsSnapshot() ?? [:]
        for (key, value) in adapterDiagnostics {
            cached[key] = value
        }
        let snapshotReason = cached["failureReason"] as? String
        let adapterReason  = session.adapter?.failureReason
        let exactReason: String? = [snapshotReason, adapterReason]
            .compactMap { $0 }
            .first { !$0.isEmpty && $0 != VGLiveGreenScreenSessionCoordinator.noFailureReason }
        let terminalReason = exactReason ?? "unknown"
        session.terminalReason = terminalReason

        // Session fields that must survive the adapter release. Values already
        // present in the adapter snapshot (providerKind, providerMode,
        // segmentationBackend, sampleCount, maskPublishCount,
        // lastMaskCoveragePercent, …) are kept; only what the adapter cannot
        // know about the session is added or normalised here.
        cached["isKeyed"]             = false
        cached["degraded"]            = true
        cached["terminalState"]       = VGLiveGreenScreenSessionCoordinator.terminalStateDegraded
        cached["terminalReason"]      = terminalReason
        cached["failureReason"]       = terminalReason
        cached["failureCategory"]     = VGLiveGreenScreenSessionCoordinator.reasonSegmentationFailure
        cached["adapterReleased"]     = true
        if cached["segmentationBackend"] == nil {
            cached["segmentationBackend"] = session.requestedSegmentationBackend
        }
        if cached["providerKind"] == nil {
            cached["providerKind"] = "unavailable"
        }
        if cached["providerMode"] == nil {
            cached["providerMode"] = cached["providerKind"] ?? "unavailable"
        }
        if cached["sampleCount"] == nil             { cached["sampleCount"] = 0 }
        if cached["maskPublishCount"] == nil        { cached["maskPublishCount"] = 0 }
        if cached["lastMaskCoveragePercent"] == nil { cached["lastMaskCoveragePercent"] = -1 }
        session.terminalDiagnostics = cached

        let providerKindName = cached["providerKind"] as? String ?? "unavailable"
        let providerModeName = cached["providerMode"] as? String ?? providerKindName
        let backendName      = cached["segmentationBackend"] as? String ?? session.requestedSegmentationBackend

        NSLog("[VGLiveGreenScreenSessionCoordinator] IOS_LIVE_GREENSCREEN_SEGMENTATION_DEGRADED sessionId=\(session.sessionId) failureReason=\(terminalReason) providerKind=\(providerKindName) providerMode=\(providerModeName) segmentationBackend=\(backendName) sampleCount=\(cached["sampleCount"] ?? 0) maskPublishCount=\(cached["maskPublishCount"] ?? 0) — continuing unkeyed over the same background")

        // ── 2. Stop feeding the segmenter and release it; camera and texture stay up.
        session.cameraSource?.setFrameObserver(nil)
        session.adapter?.invalidate()
        session.adapter = nil
        session.renderLoop?.setKeyingEnabled(false)

        // ── 3. Degraded event: `reason` is the exact adapter failure reason
        // (mirrors the Android payload, where `reason` is e.g.
        // mlkit_init_failed); `failureCategory` keeps the generic
        // segmentation_failure classification and `failureReason` repeats the
        // exact reason under an explicit key.
        onLiveGreenScreenEvent?([
            "event":               VGLiveGreenScreenSessionCoordinator.eventDegraded,
            "type":                "degraded",
            "sessionId":           session.sessionId,
            "previousBackend":     VGLiveGreenScreenSessionCoordinator.backendIosMl,
            "currentBackend":      VGLiveGreenScreenSessionCoordinator.backendUnkeyed,
            "reason":              exactReason ?? VGLiveGreenScreenSessionCoordinator.reasonSegmentationFailure,
            "failureCategory":     VGLiveGreenScreenSessionCoordinator.reasonSegmentationFailure,
            "failureReason":       terminalReason,
            "segmentationBackend": backendName,
            "providerKind":        providerKindName,
            "providerMode":        providerModeName,
            "userMessage":         VGLiveGreenScreenSessionCoordinator.degradedUserMessage,
        ])
    }

    // MARK: - Private helpers

    private func resolveActiveSession(sessionId: String,
                                      route: String,
                                      reply: @escaping (Any?, FlutterError?) -> Void) -> LiveSession? {
        guard let session = activeSession, session.sessionId == sessionId else {
            reply(nil, FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorSessionNotFound,
                message: "\(route): no active live green-screen session with id '\(sessionId)'.",
                details: nil))
            return nil
        }
        return session
    }

    private static func flutterError(from error: Error, route: String) -> FlutterError {
        if let bg = error as? VGLiveGreenScreenBackgroundError {
            let code: String
            switch bg.kind {
            case .invalidArgument:   code = errorInvalidArg
            case .compositionFailed: code = errorCompositionFailed
            }
            return FlutterError(code: code, message: "\(route): \(bg.message)", details: nil)
        }
        return FlutterError(code: errorCompositionFailed,
                            message: "\(route): \(error.localizedDescription)",
                            details: nil)
    }

    /// Compact "x,y wxh" rect description for log markers (whole pixels).
    private static func describe(_ rect: CGRect) -> String {
        return "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }

    private static func describe(_ spec: VGLiveGreenScreenBackgroundSpec) -> String {
        switch spec {
        case .solidColor(let argb):
            return "solidColor(0x" + String(UInt32(bitPattern: argb), radix: 16, uppercase: true) + ")"
        case .image(_, let mode):
            return mode == .aspectFill ? "image(aspectFill)" : "image(aspectFit)"
        }
    }
}
