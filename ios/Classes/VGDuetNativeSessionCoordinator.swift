// VGDuetNativeSessionCoordinator.swift
// VG-DUET-SLICE-3: Native session lifecycle, source validation, clock & decoder integration.
//
// Responsibilities:
//   - Validates local .mp4/.mov source via AVURLAsset.
//   - Manages the Duet session state machine (initialized → recording → paused / completed → stopped).
//   - Integrates VGDuetPreviewClock for timing math, speed scaling, trim window cursors, rollback.
//   - Integrates VGDuetSourceVideoDecoder for preparing, priming at trimStart, and stepping/seeking.
//   - Enforces single active session invariant.
//   - Threading: coordinator is main-thread state owner; probing runs on probeQueue;
//     decoder work runs on a dedicated serial decoderQueue; replies always on main thread.
//   - Asynchronous decoder release on dispose without blocking the main thread.
//   - Auto-stop: if trimEnd is reached, enters completed state; stopDuetRecording returns descriptor.
//   - Slice 4B-B: owns the preview render loop lifecycle (create on attach, start/hold on
//     record transitions, stop before texture + decoder teardown).  All decoder stepping
//     for preview goes through the loop; the coordinator never draws or ticks itself.

import AVFoundation
import Flutter
import Foundation

// MARK: - State machine

enum VGDuetSessionState {
    case initialized
    case recording
    case paused
    case completed
    case stopped
}

// MARK: - Source probe result

struct VGDuetSourceProbeResult {
    let durationMs: Int
    let hasVideoTrack: Bool
    let hasAudioTrack: Bool
}

struct VGDuetSourceProbeFailure: Error {
    let message: String
}

// MARK: - Session

final class VGDuetNativeSession {
    let sessionId: String
    let sourceMap: [String: Any]
    let trimWindowMap: [String: Any]

    // Configuration set via update* calls
    var layoutConfigMap: [String: Any]
    var speedMultiplier: Double
    var sourceGain: Double
    var micGain: Double

    // State
    var state: VGDuetSessionState = .initialized

    // Trim window
    let trimStartMs: Int
    let trimEndMs: Int

    // Preview clock & source decoder
    let previewClock: VGDuetPreviewClock
    var decoder: VGDuetSourceVideoDecoder?

    // Source probe result (recorded for descriptor assembly)
    var probeResult: VGDuetSourceProbeResult?

    // Slice 4A: preview texture attachment.
    // Registered with Flutter texture registry on attachPreviewTexture,
    // invalidated and unregistered on detach/stop/dispose.
    var previewTexture: VGDuetPreviewTexture?
    var previewTextureId: Int64?
    // Original dimensions and layout rects stored on first attach;
    // returned verbatim on repeated (idempotent) attach calls.
    var previewWidthPx: Double?
    var previewHeightPx: Double?
    var previewLayoutRects: [String: Any]?

    // Slice 4B-B: compositor render loop bound to previewTexture.
    // Created after texture registration; stopped before texture invalidation
    // and before the decoder is released.  nil whenever no texture is attached.
    var previewRenderLoop: VGDuetPreviewRenderLoop?

    // Duet camera ingress: front-camera live preview for the camera slot.
    // Created and started only when a preview texture attaches successfully.
    // Stopped in releasePreviewTexture before the render loop and texture teardown.
    var cameraSource: VGDuetCameraSource?

    // Green-screen adapter: wraps VanguardMLSegmenter for person keying.
    // Non-nil only when the effective layout at attach time is greenScreen.
    // Invalidated before cameraSource.stop() in all terminal paths.
    var greenScreenAdapter: VGDuetGreenScreenAdapter?

    init(sessionId: String,
         sourceMap: [String: Any],
         trimWindowMap: [String: Any],
         layoutConfigMap: [String: Any],
         speedMultiplier: Double,
         sourceGain: Double,
         micGain: Double,
         trimStartMs: Int,
         trimEndMs: Int,
         previewClock: VGDuetPreviewClock,
         decoder: VGDuetSourceVideoDecoder?) {
        self.sessionId       = sessionId
        self.sourceMap       = sourceMap
        self.trimWindowMap   = trimWindowMap
        self.layoutConfigMap = layoutConfigMap
        self.speedMultiplier = speedMultiplier
        self.sourceGain      = sourceGain
        self.micGain         = micGain
        self.trimStartMs     = trimStartMs
        self.trimEndMs       = trimEndMs
        self.previewClock    = previewClock
        self.decoder         = decoder
    }

    func startSegment() {
        previewClock.startSegment()
    }

    func commitSegment() {
        previewClock.commitSegment()
    }

    func deleteLastSegment() -> Bool {
        return previewClock.deleteLastSegment()
    }

    func totalDurationMs() -> Int { previewClock.totalDurationMs() }
    func segmentCount() -> Int { previewClock.segmentCount() }

    func buildStopResult() -> [String: Any] {
        let segmentMaps = previewClock.segments.map { $0.toMap() }
        let descriptor: [String: Any] = [
            "source":           sourceMap,
            "layoutConfig":     layoutConfigMap,
            "trimWindow":       trimWindowMap,
            "initialSpeed":     speedMultiplier,
            "segments":         segmentMaps,
            "sourceAudioGain":  sourceGain,
            "micAudioGain":     micGain,
            "sourceAudioMuted": sourceGain < 0.0001,
            "micAudioMuted":    micGain < 0.0001,
        ]
        return [
            "compositionDescriptor": descriptor,
            "totalDurationMs":       max(1, totalDurationMs()),
            "segmentCount":          max(1, segmentCount()),
            "segmentAssets":         [String](),
            "proofOutputPath":       NSNull(),
        ]
    }
}

// MARK: - Coordinator

/// Owns the single active Duet session and all lifecycle transitions.
/// All public methods are called on the main thread by VGDuetMethodHandler.
/// Probing and decoding run on dedicated serial queues and reply on the main thread.
final class VGDuetNativeSessionCoordinator {

    // MARK: Constants

    static let validSpeeds: [Double] = [0.3, 0.5, 1.0, 2.0, 3.0]

    // MARK: State

    private var activeSession: VGDuetNativeSession?
    private var pendingSessionId: String?
    private var canceledProbeIds = Set<String>()

    // Slice 4A: Flutter texture registry, injected at init time.
    // Weak-ish pattern: FlutterTextureRegistry is owned by the registrar which
    // outlives this coordinator; storing as strong is safe for the plugin lifecycle.
    private var textureRegistry: FlutterTextureRegistry?

    // Serial queues (never block main thread)
    private let probeQueue = DispatchQueue(label: "com.connects.vanguard.duet.probe",
                                           qos: .userInitiated)
    private let decoderQueue = DispatchQueue(label: "com.connects.vanguard.duet.decoder",
                                             qos: .userInitiated)

    // MARK: - Init

    init(textureRegistry: FlutterTextureRegistry? = nil) {
        self.textureRegistry = textureRegistry
    }

    // MARK: - Preview texture helpers (Slice 4A)

    /// Releases the preview texture associated with [session] if one is registered.
    /// Must be called on the main thread before clearing activeSession.
    /// Slice 4B-B: the render loop is stopped first so no present can race the
    /// texture invalidation / unregister below.
    private func releasePreviewTexture(for session: VGDuetNativeSession) {
        // Green-screen: invalidate adapter before camera stop so no frames are
        // submitted to the segmenter after teardown begins.
        session.greenScreenAdapter?.invalidate()
        session.greenScreenAdapter = nil
        // Camera ingress: stop before the render loop so no frame snapshot is
        // taken after the loop drains its in-flight pipeline.
        session.cameraSource?.setFrameObserver(nil)
        session.cameraSource?.stop()
        session.cameraSource = nil
        stopPreviewRenderLoop(for: session)
        guard let tex = session.previewTexture,
              let tid = session.previewTextureId else { return }
        tex.invalidate()
        textureRegistry?.unregisterTexture(tid)
        session.previewTexture    = nil
        session.previewTextureId  = nil
        session.previewWidthPx    = nil
        session.previewHeightPx   = nil
        session.previewLayoutRects = nil
    }

    // MARK: - attachPreviewTexture (Slice 4A)

    func attachPreviewTexture(
        sessionId:  String,
        canvasSize: [String: Any],
        layoutConfigMap: [String: Any]?,
        reply: @escaping (Any?, FlutterError?) -> Void
    ) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }

        // Idempotent: return the ORIGINAL stored descriptor, not dims from the new request.
        if let existing = session.previewTexture, let tid = session.previewTextureId {
            var map: [String: Any] = [
                "textureId": tid,
                "width":  session.previewWidthPx ?? 1080.0,
                "height": session.previewHeightPx ?? 1920.0,
                "state":  "surfaceAvailable",
            ]
            if let rects = session.previewLayoutRects { map["layoutRects"] = rects }
            _ = existing  // keep ref alive for lint
            reply(map, nil)
            return
        }

        guard let registry = textureRegistry else {
            reply(nil, FlutterError(
                code:    "composition_failed",
                message: "attachDuetPreviewTexture: textureRegistry not available.",
                details: nil))
            return
        }

        let width  = (canvasSize["width"]  as? NSNumber)?.doubleValue ?? 1080.0
        let height = (canvasSize["height"] as? NSNumber)?.doubleValue ?? 1920.0

        let previewTexture = VGDuetPreviewTexture()
        let textureId = registry.register(previewTexture)

        session.previewTexture   = previewTexture
        session.previewTextureId = textureId

        // Compute optional layout rects from the effective layoutConfig.
        let effectiveLayoutMap = layoutConfigMap ?? session.layoutConfigMap
        let typedRects = computeLayoutRects(
            layoutConfigMap: effectiveLayoutMap,
            canvasWidth:  CGFloat(width),
            canvasHeight: CGFloat(height)
        )
        let layoutRects = typedRects.map { serializeLayoutRects($0) }

        // Store original values so idempotent re-attach returns them verbatim.
        session.previewWidthPx    = width
        session.previewHeightPx   = height
        session.previewLayoutRects = layoutRects

        // Slice 4B-B: bring up the render loop after registration + rect
        // computation and draw the held frame (trimStart on a fresh session,
        // the current clock cursor otherwise).  If the session is already
        // recording (re-attach mid-take) the loop goes active immediately.
        //
        // Green-screen: if the effective layout is greenScreen, create and start
        // the adapter BEFORE camera start so frames are routed to the segmenter
        // from the first delivered frame.
        let effectiveMode = (effectiveLayoutMap["mode"] as? String) ?? "pip"
        let isGreenScreen = (effectiveMode == "greenScreen")

        if isGreenScreen, session.greenScreenAdapter == nil {
            let adapter = VGDuetGreenScreenAdapter()
            session.greenScreenAdapter = adapter
            // Wire the session-failure handler BEFORE adapter.start().
            adapter.onSessionFailure = { [weak self, weak session] in
                guard let self = self, let session = session else { return }
                self._handleGreenScreenAdapterFailure(session: session)
            }
            adapter.start()
        }

        // Camera ingress: create + start the camera source now (not at initializeSession)
        // because the render loop is what consumes its frames.  Guard idempotency: if a
        // cameraSource already exists (should not happen given the early-return above),
        // do not create another.
        if session.cameraSource == nil {
            let cam = VGDuetCameraSource()
            session.cameraSource = cam
            if isGreenScreen, let adapter = session.greenScreenAdapter {
                cam.setFrameObserver { [weak adapter] pixelBuffer, pts in
                    adapter?.submitFrame(pixelBuffer, presentationTime: pts)
                }
            }
            cam.start()
        }

        let loop = makePreviewRenderLoop(
            session:             session,
            texture:             previewTexture,
            textureId:           textureId,
            registry:            registry,
            canvasWidth:         width,
            canvasHeight:        height,
            rects:               typedRects ?? Self.fallbackPreviewRects(canvasWidth: width, canvasHeight: height),
            isGreenScreenLayout: isGreenScreen
        )
        session.previewRenderLoop = loop
        loop.renderInitialFrame()
        if session.state == .recording {
            loop.startActive()
        }

        var map: [String: Any] = [
            "textureId": textureId,
            "width":  width,
            "height": height,
            // iOS: register() immediately makes the texture valid as a
            // surfaceAvailable seam (no separate CALayer negotiation required
            // in this slice).
            "state": "surfaceAvailable",
        ]
        if let rects = layoutRects { map["layoutRects"] = rects }
        reply(map, nil)
    }

    // MARK: - detachPreviewTexture (Slice 4A)

    func detachPreviewTexture(
        sessionId: String,
        reply: @escaping (Any?, FlutterError?) -> Void
    ) {
        assert(Thread.isMainThread)
        // Unknown session → session_not_found per contract.
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        // Idempotent if no attachment exists.
        releasePreviewTexture(for: session)
        reply(nil, nil)
    }

    // MARK: - Layout rect builder

    /// Typed layout rects (top-left canvas coordinates) for the given layoutConfig.
    /// nil for unknown modes.  Serialised via serializeLayoutRects for transport.
    private func computeLayoutRects(
        layoutConfigMap: [String: Any],
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> (source: CGRect, camera: CGRect)? {
        let mode = layoutConfigMap["mode"] as? String ?? "pip"
        switch mode {
        case "splitLeftRight":
            let swapped = layoutConfigMap["isSideSwapped"] as? Bool ?? false
            return VGDuetLayoutGeometry.splitLeftRight(
                canvasWidth: canvasWidth, canvasHeight: canvasHeight, isSwapped: swapped)
        case "splitTopBottom":
            let swapped = layoutConfigMap["isTopBottomSwapped"] as? Bool ?? false
            return VGDuetLayoutGeometry.splitTopBottom(
                canvasWidth: canvasWidth, canvasHeight: canvasHeight, isSwapped: swapped)
        case "pip":
            let sourceRect = VGDuetLayoutGeometry.pipSourceRect(
                canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            var cameraRect = sourceRect
            if let rectMap = layoutConfigMap["pipNormalizedRect"] as? [String: Any],
               let nl = (rectMap["left"]   as? NSNumber)?.doubleValue,
               let nt = (rectMap["top"]    as? NSNumber)?.doubleValue,
               let nw = (rectMap["width"]  as? NSNumber)?.doubleValue,
               let nh = (rectMap["height"] as? NSNumber)?.doubleValue {
                cameraRect = VGDuetLayoutGeometry.pipCameraRect(
                    canvasWidth:      canvasWidth,
                    canvasHeight:     canvasHeight,
                    normalizedLeft:   CGFloat(nl),
                    normalizedTop:    CGFloat(nt),
                    normalizedWidth:  CGFloat(nw),
                    normalizedHeight: CGFloat(nh))
            }
            return (source: sourceRect, camera: cameraRect)
        case "greenScreen":
            return VGDuetLayoutGeometry.greenScreen(
                canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        default:
            return nil
        }
    }

    private func serializeLayoutRects(_ rects: (source: CGRect, camera: CGRect)) -> [String: Any] {
        return [
            "source": VGDuetLayoutGeometry.rectToMap(rects.source),
            "camera": VGDuetLayoutGeometry.rectToMap(rects.camera),
        ]
    }

    /// Rects used by the render loop when the layout mode is unknown:
    /// full-canvas source, no camera placeholder.
    private static func fallbackPreviewRects(canvasWidth: Double, canvasHeight: Double) -> (source: CGRect, camera: CGRect) {
        return (source: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight),
                camera: .zero)
    }

    // MARK: - Preview render loop helpers (Slice 4B-B)

    /// Stops and drops the session's render loop.  Idempotent; safe when no
    /// loop exists.  Must run on main before texture invalidation and before
    /// the decoder release is enqueued.
    private func stopPreviewRenderLoop(for session: VGDuetNativeSession) {
        session.previewRenderLoop?.stop()
        session.previewRenderLoop = nil
    }

    /// Builds the render loop for [session].  The loop never touches the
    /// decoder directly: every request is routed through decoderQueue by the
    /// injected decode handler, and presents go texture → textureFrameAvailable
    /// on main.  Captures avoid retain cycles (session weak, no self).
    private func makePreviewRenderLoop(
        session:             VGDuetNativeSession,
        texture:             VGDuetPreviewTexture,
        textureId:           Int64,
        registry:            FlutterTextureRegistry,
        canvasWidth:         Double,
        canvasHeight:        Double,
        rects:               (source: CGRect, camera: CGRect),
        isGreenScreenLayout: Bool = false
    ) -> VGDuetPreviewRenderLoop {
        let compositor   = VGDuetPreviewCompositor(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let clock        = session.previewClock
        let decoderQueue = self.decoderQueue

        return VGDuetPreviewRenderLoop(
            compositor:          compositor,
            trimStartMs:         session.trimStartMs,
            trimEndMs:           session.trimEndMs,
            sourceRect:          rects.source,
            cameraRect:          rects.camera,
            isGreenScreenLayout: isGreenScreenLayout,
            targetPtsProvider: {
                clock.currentSourcePtsMs()
            },
            decodeHandler: { [weak session] request, completion in
                // Read on main (loop calls us on main); nil once teardown began.
                guard let decoder = session?.decoder else {
                    completion(nil)
                    return
                }
                decoderQueue.async {
                    let buffer: CVPixelBuffer?
                    switch request {
                    case .step(let targetPtsMs):
                        buffer = decoder.stepFrame(targetPtsMs: targetPtsMs)
                    case .seek(let targetPtsMs):
                        try? decoder.seek(to: targetPtsMs)
                        buffer = decoder.lastPixelBuffer
                    }
                    completion(VGDuetPreviewDecodedFrame(
                        pixelBuffer:        buffer,
                        presentationTimeMs: decoder.lastPresentationTimeMs))
                }
            },
            presentHandler: { pixelBuffer in
                // Loop invokes this on main, only while not stopped.
                texture.update(pixelBuffer: pixelBuffer)
                registry.textureFrameAvailable(textureId)
            },
            cameraFrameProvider: { [weak session] in
                // Called on main or renderQueue; returns nil when camera not yet ready.
                session?.cameraSource?.snapshotRetained()
            },
            maskProvider: { [weak session] in
                // Called on renderQueue when isGreenScreen; returns nil when no fresh mask.
                session?.greenScreenAdapter?.latestMaskRetained()
            }
        )
    }

    // MARK: - initialize

    func initializeSession(
        sourceMap:       [String: Any],
        trimWindowMap:   [String: Any],
        layoutConfigMap: [String: Any],
        speed:           Double,
        sourceGain:      Double,
        micGain:         Double,
        reply:           @escaping (String?, FlutterError?) -> Void
    ) {
        assert(Thread.isMainThread)

        if activeSession != nil || pendingSessionId != nil {
            reply(nil, FlutterError(
                code:    "session_conflict",
                message: "A Duet session is already active or initializing. Dispose it before initializing a new one.",
                details: nil))
            return
        }

        guard let trimStartSec = (trimWindowMap["startSeconds"] as? NSNumber)?.doubleValue,
              let trimEndSec   = (trimWindowMap["endSeconds"]   as? NSNumber)?.doubleValue else {
            reply(nil, FlutterError(
                code:    "source_invalid",
                message: "initializeDuetSession: trimWindow is missing startSeconds/endSeconds.",
                details: nil))
            return
        }

        let trimStartMs = Int(trimStartSec * 1000)
        let trimEndMs   = Int(trimEndSec   * 1000)

        guard let filePath = (sourceMap["filePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty else {
            reply(nil, FlutterError(
                code:    "source_invalid",
                message: "initializeDuetSession: source.filePath is empty or missing.",
                details: nil))
            return
        }

        guard Self.isValidSpeed(speed) else {
            reply(nil, FlutterError(
                code:    "source_invalid",
                message: "initializeDuetSession: speed \(speed) is not one of \(Self.validSpeeds).",
                details: nil))
            return
        }
        guard sourceGain >= 0.0 && sourceGain <= 1.0 else {
            reply(nil, FlutterError(code: "source_invalid", message: "initializeDuetSession: sourceGain must be in [0.0, 1.0].", details: nil))
            return
        }
        guard micGain >= 0.0 && micGain <= 1.0 else {
            reply(nil, FlutterError(code: "source_invalid", message: "initializeDuetSession: micGain must be in [0.0, 1.0].", details: nil))
            return
        }

        let sessionId = UUID().uuidString
        pendingSessionId = sessionId
        let capturedFilePath    = filePath
        let capturedTrimStartMs = trimStartMs
        let capturedTrimEndMs   = trimEndMs

        probeQueue.async { [weak self] in
            guard let self = self else { return }

            let probeResult = Self.probeSource(filePath: capturedFilePath)

            switch probeResult {
            case .failure(let failure):
                DispatchQueue.main.async {
                    if self.pendingSessionId == sessionId {
                        self.pendingSessionId = nil
                    }
                    if self.canceledProbeIds.contains(sessionId) {
                        self.canceledProbeIds.remove(sessionId)
                        return
                    }
                    reply(nil, FlutterError(code: "source_invalid", message: failure.message, details: nil))
                }

            case .success(let probe):
                if let err = Self.validateTrimWindow(
                    trimStartMs:      capturedTrimStartMs,
                    trimEndMs:        capturedTrimEndMs,
                    sourceDurationMs: probe.durationMs
                ) {
                    DispatchQueue.main.async {
                        if self.pendingSessionId == sessionId {
                            self.pendingSessionId = nil
                        }
                        if self.canceledProbeIds.contains(sessionId) {
                            self.canceledProbeIds.remove(sessionId)
                            return
                        }
                        reply(nil, FlutterError(code: "source_invalid", message: err, details: nil))
                    }
                    return
                }

                // Resolve file URL for decoder
                let url: URL
                if capturedFilePath.hasPrefix("file://") {
                    url = URL(string: capturedFilePath) ?? URL(fileURLWithPath: capturedFilePath)
                } else {
                    url = URL(fileURLWithPath: capturedFilePath)
                }

                // Prime decoder on serial decoderQueue at trimStartMs
                self.decoderQueue.async {
                    let decoder = VGDuetSourceVideoDecoder(
                        url: url,
                        trimStartMs: capturedTrimStartMs,
                        trimEndMs: capturedTrimEndMs
                    )

                    var prepError: String?
                    do {
                        try decoder.prepare()
                    } catch {
                        prepError = error.localizedDescription
                    }

                    DispatchQueue.main.async {
                        if self.pendingSessionId == sessionId {
                            self.pendingSessionId = nil
                        }
                        if self.canceledProbeIds.contains(sessionId) {
                            self.canceledProbeIds.remove(sessionId)
                            self.decoderQueue.async { decoder.release() }
                            return
                        }

                        if let err = prepError {
                            self.decoderQueue.async { decoder.release() }
                            reply(nil, FlutterError(code: "source_invalid", message: err, details: nil))
                            return
                        }

                        let clock = VGDuetPreviewClock(
                            trimStartMs: capturedTrimStartMs,
                            trimEndMs: capturedTrimEndMs,
                            initialSpeed: speed
                        )

                        let session = VGDuetNativeSession(
                            sessionId:       sessionId,
                            sourceMap:       sourceMap,
                            trimWindowMap:   trimWindowMap,
                            layoutConfigMap: layoutConfigMap,
                            speedMultiplier: speed,
                            sourceGain:      sourceGain,
                            micGain:         micGain,
                            trimStartMs:     capturedTrimStartMs,
                            trimEndMs:       capturedTrimEndMs,
                            previewClock:    clock,
                            decoder:         decoder
                        )
                        session.probeResult = probe
                        self.activeSession = session
                        reply(sessionId, nil)
                    }
                }
            }
        }
    }

    // MARK: - updateLayout

    func updateLayout(sessionId: String, layoutConfigMap: [String: Any], reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .stopped:
            reply(nil, invalidState("updateDuetLayout", current: "stopped")); return
        default: break
        }
        if let modeName = layoutConfigMap["mode"] as? String, modeName == "pip",
           let rectMap  = layoutConfigMap["pipNormalizedRect"] as? [String: Any] {
            if let err = Self.validatePipRect(rectMap) {
                reply(nil, FlutterError(code: "source_invalid", message: err, details: nil)); return
            }
        }
        session.layoutConfigMap = layoutConfigMap

        // Slice 4B-B: with a texture attached, refresh the stored rects and
        // redraw the held/current frame under the new geometry.
        if session.previewTexture != nil,
           let width  = session.previewWidthPx,
           let height = session.previewHeightPx {
            let newMode      = (layoutConfigMap["mode"] as? String) ?? "pip"
            let newIsGS      = (newMode == "greenScreen")
            let currentIsGS  = (session.greenScreenAdapter != nil)

            // Enable adapter when entering greenScreen.
            if newIsGS && !currentIsGS {
                let adapter = VGDuetGreenScreenAdapter()
                session.greenScreenAdapter = adapter
                adapter.onSessionFailure = { [weak self, weak session] in
                    guard let self = self, let session = session else { return }
                    self._handleGreenScreenAdapterFailure(session: session)
                }
                adapter.start()
                session.cameraSource?.setFrameObserver { [weak adapter] pixelBuffer, pts in
                    adapter?.submitFrame(pixelBuffer, presentationTime: pts)
                }
            }

            // Disable adapter when leaving greenScreen.
            if !newIsGS && currentIsGS {
                session.cameraSource?.setFrameObserver(nil)
                session.greenScreenAdapter?.invalidate()
                session.greenScreenAdapter = nil
            }

            let typedRects = computeLayoutRects(
                layoutConfigMap: layoutConfigMap,
                canvasWidth:  CGFloat(width),
                canvasHeight: CGFloat(height)
            )
            session.previewLayoutRects = typedRects.map { serializeLayoutRects($0) }
            let rects = typedRects ?? Self.fallbackPreviewRects(canvasWidth: width, canvasHeight: height)
            session.previewRenderLoop?.updateLayout(
                sourceRect:          rects.source,
                cameraRect:          rects.camera,
                targetPtsMs:         session.previewClock.currentSourcePtsMs(),
                isGreenScreenLayout: newIsGS)
        }
        reply(nil, nil)
    }

    // MARK: - setRecordingSpeed

    func setRecordingSpeed(sessionId: String, speed: Double, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .stopped:
            reply(nil, invalidState("setDuetRecordingSpeed", current: "stopped")); return
        default: break
        }
        guard Self.isValidSpeed(speed) else {
            reply(nil, FlutterError(code: "source_invalid", message: "setDuetRecordingSpeed: speed \(speed) is not one of \(Self.validSpeeds).", details: nil)); return
        }
        session.speedMultiplier = speed
        session.previewClock.setSpeed(speed)
        reply(nil, nil)
    }

    // MARK: - setAudioMixGains

    func setAudioMixGains(sessionId: String, sourceGain: Double, micGain: Double, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .stopped:
            reply(nil, invalidState("setDuetAudioMixGains", current: "stopped")); return
        default: break
        }
        guard sourceGain >= 0.0 && sourceGain <= 1.0 else {
            reply(nil, FlutterError(code: "source_invalid", message: "setDuetAudioMixGains: sourceGain must be in [0.0, 1.0].", details: nil)); return
        }
        guard micGain >= 0.0 && micGain <= 1.0 else {
            reply(nil, FlutterError(code: "source_invalid", message: "setDuetAudioMixGains: micGain must be in [0.0, 1.0].", details: nil)); return
        }
        session.sourceGain = sourceGain
        session.micGain    = micGain
        reply(nil, nil)
    }

    // MARK: - startRecording

    func startRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .initialized else {
            reply(nil, invalidState("startDuetRecording", current: stateName(session.state), expected: "initialized")); return
        }
        session.state = .recording
        session.startSegment()
        session.previewRenderLoop?.startActive()   // Slice 4B-B
        reply(nil, nil)
    }

    // MARK: - pauseRecording

    func pauseRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .recording else {
            reply(nil, invalidState("pauseDuetRecording", current: stateName(session.state), expected: "recording")); return
        }
        session.commitSegment()
        session.state = session.previewClock.isAutoStopped ? .completed : .paused
        // Slice 4B-B: the render loop owns decoder stepping; hold the committed cursor frame.
        session.previewRenderLoop?.pauseAndHold(targetPtsMs: session.previewClock.currentSourcePtsMs())
        reply(nil, nil)
    }

    // MARK: - resumeRecording

    func resumeRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .paused else {
            reply(nil, invalidState("resumeDuetRecording", current: stateName(session.state), expected: "paused")); return
        }
        session.state = .recording
        session.startSegment()
        session.previewRenderLoop?.startActive()   // Slice 4B-B
        reply(nil, nil)
    }

    // MARK: - deleteLastSegment

    func deleteLastSegment(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .stopped:
            reply(nil, invalidState("deleteLastDuetSegment", current: "stopped")); return
        default: break
        }
        _ = session.deleteLastSegment()
        if session.state == .completed {
            session.state = .paused
        }
        // Slice 4B-B: the render loop owns decoder seeking; hold the rolled-back cursor frame.
        session.previewRenderLoop?.seekAndHold(targetPtsMs: session.previewClock.currentSourcePtsMs())
        reply(nil, nil)
    }

    // MARK: - stopRecording

    func stopRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .recording:
            session.commitSegment()
        case .paused, .completed:
            break
        default:
            reply(nil, invalidState("stopDuetRecording", current: stateName(session.state), expected: "recording, paused, or completed")); return
        }
        session.state = .stopped
        stopPreviewRenderLoop(for: session)   // Slice 4B-B: loop first, then texture, then decoder
        let dec = session.decoder
        session.decoder = nil
        releasePreviewTexture(for: session)   // Slice 4A: detach before drop
        activeSession = nil
        decoderQueue.async { dec?.release() }
        let resultMap = session.buildStopResult()
        reply(resultMap, nil)
    }

    // MARK: - disposeSession (idempotent)

    func disposeSession(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        if pendingSessionId == sessionId {
            canceledProbeIds.insert(sessionId)
            pendingSessionId = nil
        }
        if let session = activeSession, session.sessionId == sessionId {
            canceledProbeIds.insert(sessionId)
            stopPreviewRenderLoop(for: session)   // Slice 4B-B: loop first, then texture, then decoder
            let dec = session.decoder
            session.decoder = nil
            releasePreviewTexture(for: session)   // Slice 4A: detach before drop
            activeSession = nil
            decoderQueue.async { dec?.release() }
        }
        reply(nil, nil)
    }

    // MARK: - disposeAll (called from detachFromEngine)

    func disposeAll() {
        if let pending = pendingSessionId {
            canceledProbeIds.insert(pending)
            pendingSessionId = nil
        }
        if let session = activeSession {
            canceledProbeIds.insert(session.sessionId)
            stopPreviewRenderLoop(for: session)   // Slice 4B-B: loop first, then texture, then decoder
            let dec = session.decoder
            session.decoder = nil
            releasePreviewTexture(for: session)   // Slice 4A: detach before drop
            decoderQueue.async { dec?.release() }
        }
        activeSession = nil
    }

    // MARK: - Green-screen adapter failure handler

    /// Called on the main thread when VGDuetGreenScreenAdapter observes VanguardMLStateFaulted.
    /// Deterministically falls back to PiP so the session is never left with an
    /// opaque unkeyed green-screen layout.
    ///
    /// Fallback PiP rect: left 0.62, top 0.68, width 0.32, height 0.24, pipAnchor bottomRight.
    private func _handleGreenScreenAdapterFailure(session: VGDuetNativeSession) {
        assert(Thread.isMainThread)

        // Guard: only act if this session is still active and still in greenScreen.
        guard session === activeSession else { return }
        let currentMode = (session.layoutConfigMap["mode"] as? String) ?? ""
        guard currentMode == "greenScreen" else { return }

        NSLog("[VGDuetNativeSessionCoordinator] Green-screen adapter faulted — falling back to PiP")

        // 1. Disable the adapter and clear the camera observer.
        session.cameraSource?.setFrameObserver(nil)
        session.greenScreenAdapter?.invalidate()
        session.greenScreenAdapter = nil

        // 2. Update the session layout config to the deterministic PiP fallback.
        let fallbackPipRect: [String: Any] = [
            "left":   0.62,
            "top":    0.68,
            "width":  0.32,
            "height": 0.24,
        ]
        let fallbackLayoutConfig: [String: Any] = [
            "mode":             "pip",
            "pipAnchor":        "bottomRight",
            "pipNormalizedRect": fallbackPipRect,
        ]
        session.layoutConfigMap = fallbackLayoutConfig

        // 3. Recompute rects and update the render loop (if texture is attached).
        guard let width  = session.previewWidthPx,
              let height = session.previewHeightPx else { return }

        let typedRects = computeLayoutRects(
            layoutConfigMap: fallbackLayoutConfig,
            canvasWidth:  CGFloat(width),
            canvasHeight: CGFloat(height)
        )
        session.previewLayoutRects = typedRects.map { serializeLayoutRects($0) }
        let rects = typedRects ?? Self.fallbackPreviewRects(canvasWidth: width, canvasHeight: height)
        session.previewRenderLoop?.updateLayout(
            sourceRect:          rects.source,
            cameraRect:          rects.camera,
            targetPtsMs:         session.previewClock.currentSourcePtsMs(),
            isGreenScreenLayout: false)
    }

    // MARK: - Private helpers

    private func resolveActiveSession(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) -> VGDuetNativeSession? {
        guard let session = activeSession, session.sessionId == sessionId else {
            reply(nil, FlutterError(
                code:    "session_not_found",
                message: "No active Duet session with id '\(sessionId)'.",
                details: nil))
            return nil
        }
        return session
    }

    private func invalidState(_ route: String, current: String, expected: String? = nil) -> FlutterError {
        let msg = expected == nil
            ? "\(route): operation not valid in state '\(current)'."
            : "\(route): invalid state transition — current state is '\(current)', expected '\(expected!)'."
        return FlutterError(code: "invalid_state", message: msg, details: nil)
    }

    private func stateName(_ state: VGDuetSessionState) -> String {
        switch state {
        case .initialized: return "initialized"
        case .recording:   return "recording"
        case .paused:      return "paused"
        case .completed:   return "completed"
        case .stopped:     return "stopped"
        }
    }

    // MARK: - Source probing (static, off-main)

    static func probeSource(filePath: String) -> Result<VGDuetSourceProbeResult, VGDuetSourceProbeFailure> {
        let lower = filePath.lowercased()
        guard lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") else {
            return .failure(VGDuetSourceProbeFailure(message: "Source file must be .mp4 or .mov (got '\(filePath)')"))
        }

        let url: URL
        if filePath.hasPrefix("file://") {
            guard let u = URL(string: filePath) else {
                return .failure(VGDuetSourceProbeFailure(message: "Invalid file:// URL: '\(filePath)'"))
            }
            url = u
        } else {
            url = URL(fileURLWithPath: filePath)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(VGDuetSourceProbeFailure(message: "Source file does not exist at path: '\(url.path)'"))
        }

        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = asset.duration
        guard duration.isValid && !duration.isIndefinite && duration.seconds > 0 else {
            return .failure(VGDuetSourceProbeFailure(message: "Source file has zero or invalid duration: '\(filePath)'"))
        }
        let durationMs = Int(duration.seconds * 1000)

        let videoTracks = asset.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            return .failure(VGDuetSourceProbeFailure(message: "Source file has no video track: '\(filePath)'"))
        }

        let hasAudioTrack = !asset.tracks(withMediaType: .audio).isEmpty

        return .success(VGDuetSourceProbeResult(
            durationMs:    durationMs,
            hasVideoTrack: true,
            hasAudioTrack: hasAudioTrack
        ))
    }

    static func validateTrimWindow(trimStartMs: Int, trimEndMs: Int, sourceDurationMs: Int) -> String? {
        if trimStartMs < 0 {
            return "Trim start must be >= 0 (got \(trimStartMs) ms)."
        }
        if trimEndMs <= trimStartMs {
            return "Trim end (\(trimEndMs) ms) must be > trim start (\(trimStartMs) ms)."
        }
        if (trimEndMs - trimStartMs) < 1000 {
            return "Trim window duration must be >= 1.0 s (got \(trimEndMs - trimStartMs) ms)."
        }
        if trimStartMs >= sourceDurationMs {
            return "Trim start (\(trimStartMs) ms) must be < source duration (\(sourceDurationMs) ms)."
        }
        if trimEndMs > sourceDurationMs {
            return "Trim end (\(trimEndMs) ms) exceeds source duration (\(sourceDurationMs) ms)."
        }
        return nil
    }

    static func isValidSpeed(_ speed: Double) -> Bool {
        let epsilon = 0.001
        return validSpeeds.contains(where: { abs($0 - speed) < epsilon })
    }

    static func validatePipRect(_ rectMap: [String: Any]) -> String? {
        guard let left   = (rectMap["left"]   as? NSNumber)?.doubleValue,
              let top    = (rectMap["top"]    as? NSNumber)?.doubleValue,
              let width  = (rectMap["width"]  as? NSNumber)?.doubleValue,
              let height = (rectMap["height"] as? NSNumber)?.doubleValue else {
            return "PiP rect is missing required fields (left, top, width, height)."
        }
        if left < 0 || top < 0 || width <= 0 || height <= 0 {
            return "PiP rect has invalid values (left=\(left), top=\(top), w=\(width), h=\(height))."
        }
        if left + width > 1.0 || top + height > 1.0 {
            return "PiP rect exceeds canvas bounds (right=\(left + width), bottom=\(top + height))."
        }
        return nil
    }
}
