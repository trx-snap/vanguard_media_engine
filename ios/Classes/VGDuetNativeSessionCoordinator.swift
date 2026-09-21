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
//   - Preview continuity telemetry: previewContinuityDiagnostics exposes loop diagnostics snapshot.

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

    // Phase 4A foreground provider: owns the live camera frames for the camera
    // slot AND the optional keyer (green-screen).  Created and started only when
    // a preview texture attaches successfully; keying is toggled through
    // setKeyingEnabled on layout changes; stopped in releasePreviewTexture
    // before the render loop and texture teardown (keying off -> camera stop
    // happens inside the provider).  The coordinator never touches the concrete
    // camera source or green-screen adapter directly.
    var foregroundProvider: VGDuetForegroundProvider?

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

    /// Emits a Duet degradation/fallback event (`onDuetEvent`) to Dart. Invoked
    /// from `_handleForegroundProviderFault` after the safe-PiP layout has
    /// been applied; the closure itself hops to the main thread before calling
    /// `channel.invokeMethod`.
    private var onDuetEvent: (([String: Any]) -> Void)?

    // Serial queues (never block main thread)
    private let probeQueue = DispatchQueue(label: "com.connects.vanguard.duet.probe",
                                           qos: .userInitiated)
    private let decoderQueue = DispatchQueue(label: "com.connects.vanguard.duet.decoder",
                                             qos: .userInitiated)

    // MARK: - Init

    init(textureRegistry: FlutterTextureRegistry? = nil,
         onDuetEvent: (([String: Any]) -> Void)? = nil) {
        self.textureRegistry = textureRegistry
        self.onDuetEvent = onDuetEvent
    }

    // MARK: - Preview texture helpers (Slice 4A)

    /// Releases the preview texture associated with [session] if one is registered.
    /// Must be called on the main thread before clearing activeSession.
    /// Slice 4B-B: the render loop is stopped first so no present can race the
    /// texture invalidation / unregister below.
    private func releasePreviewTexture(for session: VGDuetNativeSession) {
        // Foreground provider: idempotent stop turns keying off (adapter
        // invalidated) BEFORE the camera stops, and runs before the render loop
        // stops so no foreground sample is taken after the loop drains its
        // in-flight pipeline.  Order: keying off -> camera stop -> loop stop ->
        // texture invalidate.
        session.foregroundProvider?.stop()
        session.foregroundProvider = nil
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

        // Persist caller-provided layoutConfig into the session so downstream
        // code (buildStopResult, updateLayout) sees the attach-time config as
        // the canonical layout — matches Android attach-time persistence.
        // Only update when a non-nil config was explicitly supplied; nil means
        // "keep the current session layout" (idempotent reattach safety).
        if let callerLayout = layoutConfigMap {
            session.layoutConfigMap = callerLayout
        }

        let typedRects = computeLayoutRects(
            layoutConfigMap: effectiveLayoutMap,
            canvasWidth:  CGFloat(width),
            canvasHeight: CGFloat(height)
        )
        let layoutRects = typedRects.map { serializeLayoutRects((source: $0.source, camera: $0.camera)) }

        // Store original values so idempotent re-attach returns them verbatim.
        session.previewWidthPx    = width
        session.previewHeightPx   = height
        session.previewLayoutRects = layoutRects

        // Slice 4B-B: bring up the render loop after registration + rect
        // computation and draw the held frame (trimStart on a fresh session,
        // the current clock cursor otherwise).  If the session is already
        // recording (re-attach mid-take) the loop goes active immediately.
        //
        // Phase 4A: the foreground provider is created + started now (not at
        // initializeSession) because the render loop is what consumes its
        // samples.  With keying requested (effective layout greenScreen) the
        // provider starts its keyer BEFORE the first camera frame is observed;
        // the first samples may still lack a matte and are composited as the
        // camera overlay, exactly as before.  Guard idempotency: a provider
        // already present (should not happen given the early-return above) is
        // kept as-is.
        let effectiveMode = (effectiveLayoutMap["mode"] as? String) ?? "pip"
        let isGreenScreen = (effectiveMode == "greenScreen")

        if session.foregroundProvider == nil {
            let provider = VGDuetGraphGreenScreenForegroundProvider()
            session.foregroundProvider = provider
            // Wire the fault handler BEFORE start().
            provider.onFault = { [weak self, weak session] fault in
                guard let self = self, let session = session else { return }
                self._handleForegroundProviderFault(session: session, fault: fault)
            }
            provider.start(keyingEnabled: isGreenScreen)
        }

        let loop = makePreviewRenderLoop(
            session:      session,
            texture:      previewTexture,
            textureId:    textureId,
            registry:     registry,
            canvasWidth:  width,
            canvasHeight: height,
            rects:        typedRects ?? Self.fallbackPreviewRects(canvasWidth: width, canvasHeight: height)
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

    // MARK: - previewContinuityDiagnostics

    /// Read-only telemetry snapshot of the session's preview render loop.
    /// Resolves active session via resolveActiveSession (returning session_not_found if missing).
    /// If no loop exists, returns a fail-shaped map with pass: false / reason: no_preview_render_loop.
    func previewContinuityDiagnostics(
        sessionId: String,
        reply: @escaping (Any?, FlutterError?) -> Void
    ) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        let stateStr = stateName(session.state)
        let textureAttached = (session.previewTexture != nil)

        guard let loop = session.previewRenderLoop else {
            reply([
                "pass": false,
                "reason": "no_preview_render_loop",
                "sessionId": session.sessionId,
                "state": stateStr,
                "textureAttached": textureAttached,
            ], nil)
            return
        }

        var snapshot = loop.diagnosticsSnapshot()
        snapshot["pass"] = true
        snapshot["reason"] = "ok"
        snapshot["sessionId"] = session.sessionId
        snapshot["state"] = stateStr
        snapshot["textureAttached"] = textureAttached
        reply(snapshot, nil)
    }

    // MARK: - Layout rect builder

    /// Typed layout rects (top-left canvas coordinates) for the given layoutConfig.
    /// nil for unknown modes.  Serialised via serializeLayoutRects for transport.
    private func computeLayoutRects(
        layoutConfigMap: [String: Any],
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> (source: CGRect, camera: CGRect, rotation: VGDuetForegroundRotation)? {
        let mode = layoutConfigMap["mode"] as? String ?? "pip"
        switch mode {
        case "splitLeftRight":
            let swapped = layoutConfigMap["isSideSwapped"] as? Bool ?? false
            let rects = VGDuetLayoutGeometry.splitLeftRight(
                canvasWidth: canvasWidth, canvasHeight: canvasHeight, isSwapped: swapped)
            return (source: rects.source, camera: rects.camera, rotation: .identity)
        case "splitTopBottom":
            let swapped = layoutConfigMap["isTopBottomSwapped"] as? Bool ?? false
            let rects = VGDuetLayoutGeometry.splitTopBottom(
                canvasWidth: canvasWidth, canvasHeight: canvasHeight, isSwapped: swapped)
            return (source: rects.source, camera: rects.camera, rotation: .identity)
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
            return (source: sourceRect, camera: cameraRect, rotation: .identity)
        case "greenScreen":
            let fgTransform = parseForegroundTransform(layoutConfigMap)
            let rects = VGDuetLayoutGeometry.greenScreen(
                canvasWidth:  canvasWidth,
                canvasHeight: canvasHeight,
                transform:    fgTransform)
            let rotation = VGDuetLayoutGeometry.foregroundRotation(transform: fgTransform)
            return (source: rects.source, camera: rects.camera, rotation: rotation)
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

    /// Parses a `NativeForegroundTransform` from a layout config map.
    ///
    /// Reads the nested `foregroundTransform` map with keys:
    ///   `scale`, `offset` (`x`, `y`), `anchor` (`x`, `y`), `rotationDegrees`.
    ///
    /// Missing or wrong-type `scale` defaults to `1.0` (matching the Dart
    /// `VGDuetForegroundTransform.fromMap` contract); the resulting scale must
    /// still be finite and positive, or nil is returned (full-canvas identity).
    /// Offset/anchor components default per-field (offset → 0.0, anchor → 0.5)
    /// on missing, wrong-type, or non-finite values. `rotationDegrees` defaults
    /// to `0.0` on missing, wrong-type, or non-finite values; it is carried on
    /// the returned transform but does not affect the rect returned by
    /// `VGDuetLayoutGeometry.greenScreen(canvasWidth:canvasHeight:transform:)`.
    private func parseForegroundTransform(_ layoutConfigMap: [String: Any]) -> NativeForegroundTransform? {
        guard let fgMap = layoutConfigMap["foregroundTransform"] as? [String: Any] else { return nil }
        let rawScale = (fgMap["scale"] as? NSNumber)?.doubleValue ?? 1.0
        guard rawScale.isFinite && rawScale > 0.0 else { return nil }
        let offsetMap = fgMap["offset"] as? [String: Any]
        let anchorMap = fgMap["anchor"] as? [String: Any]
        let rawOffsetX = (offsetMap?["x"] as? NSNumber)?.doubleValue ?? Double.nan
        let rawOffsetY = (offsetMap?["y"] as? NSNumber)?.doubleValue ?? Double.nan
        let rawAnchorX = (anchorMap?["x"] as? NSNumber)?.doubleValue ?? Double.nan
        let rawAnchorY = (anchorMap?["y"] as? NSNumber)?.doubleValue ?? Double.nan
        let offsetX = rawOffsetX.isFinite ? rawOffsetX : 0.0
        let offsetY = rawOffsetY.isFinite ? rawOffsetY : 0.0
        let anchorX = rawAnchorX.isFinite ? rawAnchorX : 0.5
        let anchorY = rawAnchorY.isFinite ? rawAnchorY : 0.5
        let rawRotation = (fgMap["rotationDegrees"] as? NSNumber)?.doubleValue ?? 0.0
        let rotationDegrees = rawRotation.isFinite ? rawRotation : 0.0
        return NativeForegroundTransform(
            scale:           CGFloat(rawScale),
            offsetX:         CGFloat(offsetX),
            offsetY:         CGFloat(offsetY),
            anchorX:         CGFloat(anchorX),
            anchorY:         CGFloat(anchorY),
            rotationDegrees: CGFloat(rotationDegrees)
        )
    }

    /// Rects used by the render loop when the layout mode is unknown:
    /// full-canvas source, no camera placeholder, identity rotation.
    private static func fallbackPreviewRects(canvasWidth: Double, canvasHeight: Double) -> (source: CGRect, camera: CGRect, rotation: VGDuetForegroundRotation) {
        return (source: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight),
                camera: .zero,
                rotation: .identity)
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
        session:      VGDuetNativeSession,
        texture:      VGDuetPreviewTexture,
        textureId:    Int64,
        registry:     FlutterTextureRegistry,
        canvasWidth:  Double,
        canvasHeight: Double,
        rects:        (source: CGRect, camera: CGRect, rotation: VGDuetForegroundRotation)
    ) -> VGDuetPreviewRenderLoop {
        let compositor   = VGDuetPreviewCompositor(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let clock        = session.previewClock
        let decoderQueue = self.decoderQueue

        return VGDuetPreviewRenderLoop(
            compositor:  compositor,
            trimStartMs: session.trimStartMs,
            trimEndMs:   session.trimEndMs,
            sourceRect:  rects.source,
            cameraRect:  rects.camera,
            rotationDegrees: rects.rotation.rotationDegrees,
            anchorX:     rects.rotation.anchorX,
            anchorY:     rects.rotation.anchorY,
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
            foregroundSampleProvider: { [weak session] in
                // Called on main or renderQueue; nil when no camera frame yet or
                // after the provider was stopped.  The provider decides whether
                // the sample carries a matte (keyed) or not.
                session?.foregroundProvider?.sampleRetained()
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
            let newMode = (layoutConfigMap["mode"] as? String) ?? "pip"
            let newIsGS = (newMode == "greenScreen")

            // Phase 4A: keying follows the layout mode through the provider
            // (idempotent per state, no session restart).  Entering greenScreen
            // starts the keyer and routes camera frames into it; leaving it
            // turns keying off while the camera keeps feeding the camera slot.
            // Done BEFORE the geometry update so the redraw below already sees
            // the new keying state in its next sample.
            session.foregroundProvider?.setKeyingEnabled(newIsGS)

            let typedRects = computeLayoutRects(
                layoutConfigMap: layoutConfigMap,
                canvasWidth:  CGFloat(width),
                canvasHeight: CGFloat(height)
            )
            session.previewLayoutRects = typedRects.map { serializeLayoutRects((source: $0.source, camera: $0.camera)) }
            let rects = typedRects ?? Self.fallbackPreviewRects(canvasWidth: width, canvasHeight: height)
            session.previewRenderLoop?.updateLayout(
                sourceRect:  rects.source,
                cameraRect:  rects.camera,
                rotationDegrees: rects.rotation.rotationDegrees,
                anchorX:     rects.rotation.anchorX,
                anchorY:     rects.rotation.anchorY,
                targetPtsMs: session.previewClock.currentSourcePtsMs())
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

    // MARK: - Foreground provider fault handler

    /// Called on the main thread by any foreground provider after keying has already
    /// been disabled/failed open. The coordinator falls back to PiP and emits the
    /// provider-supplied metadata.
    ///
    /// Fallback PiP rect: left 0.58, top 0.05, width 0.36, height 0.24, pipAnchor topRight.
    /// These are the cross-platform safe parity values shared with the Android green-screen fallback.
    private func _handleForegroundProviderFault(session: VGDuetNativeSession,
                                                fault: VGDuetForegroundProviderFault) {
        assert(Thread.isMainThread)

        // Guard: only act if this session is still active and still in greenScreen.
        // Keying itself is already off: the provider owns that, not the coordinator.
        guard session === activeSession else { return }
        let currentMode = (session.layoutConfigMap["mode"] as? String) ?? ""
        guard currentMode == "greenScreen" else { return }

        NSLog("[VGDuetNativeSessionCoordinator] Foreground provider keying faulted (previousBackend=\(fault.previousBackend) reason=\(fault.reason)) — falling back to PiP")

        // 1. Update the session layout config to the deterministic PiP fallback.
        //    Safe parity rect — matches Android green-screen fallback geometry.
        let fallbackPipRect: [String: Any] = [
            "left":   0.58,
            "top":    0.05,
            "width":  0.36,
            "height": 0.24,
        ]
        let fallbackLayoutConfig: [String: Any] = [
            "mode":             "pip",
            "pipAnchor":        "topRight",
            "pipNormalizedRect": fallbackPipRect,
        ]
        session.layoutConfigMap = fallbackLayoutConfig

        // 2. Recompute rects and update the render loop (if texture is attached).
        if let width  = session.previewWidthPx,
           let height = session.previewHeightPx {
            let typedRects = computeLayoutRects(
                layoutConfigMap: fallbackLayoutConfig,
                canvasWidth:  CGFloat(width),
                canvasHeight: CGFloat(height)
            )
            session.previewLayoutRects = typedRects.map { serializeLayoutRects((source: $0.source, camera: $0.camera)) }
            let rects = typedRects ?? Self.fallbackPreviewRects(canvasWidth: width, canvasHeight: height)
            session.previewRenderLoop?.updateLayout(
                sourceRect:  rects.source,
                cameraRect:  rects.camera,
                rotationDegrees: rects.rotation.rotationDegrees,
                anchorX:     rects.rotation.anchorX,
                anchorY:     rects.rotation.anchorY,
                targetPtsMs: session.previewClock.currentSourcePtsMs())
        }

        // 3. Emit onDuetEvent only after the PiP fallback layout above has been
        // applied. currentBackend is always "pip" (the resulting preview
        // backend); previousBackend and reason come from the provider's fault
        // metadata (the legacy provider reports "vision" / "adapter_faulted").
        onDuetEvent?([
            "event":           "green_screen_fallback",
            "sessionId":       session.sessionId,
            "previousBackend": fault.previousBackend,
            "currentBackend":  "pip",
            "reason":          fault.reason,
            "userMessage":     "Green screen unavailable. Switched to Picture-in-Picture",
        ])
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
