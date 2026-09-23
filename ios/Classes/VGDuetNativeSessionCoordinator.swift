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
//   - Slice 4B-C: while not recording (before the first take, paused, or after a
//     seek/rollback) the coordinator keeps the loop in idle preview instead of leaving
//     it passive, so the camera/foreground preview never freezes before recording starts.
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

    // Slice 1: segment recording, audio preview, and mic capture
    var segmentAssetPaths: [String] = []
    var currentRecorder: VGDuetSegmentRecorder?
    var audioPlayer: VGDuetPreviewAudioPlayer?
    var micCapture: VGDuetMicrophoneCapture?

    // One-shot latch for the `auto_stop` Duet event: set when the event is
    // emitted for the active take, reset each time a take begins (start or
    // resume) so the clamped clock never re-emits while held at trim end.
    var autoStopEmitted: Bool = false

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

    /// Aborts the clock's active (uncommitted) recording segment, if any,
    /// WITHOUT removing any already-committed segment or its asset.
    ///
    /// VGDuetPreviewClock has no direct "abort active only" API:
    /// deleteLastSegment() clears the active-recording flag AND additionally
    /// removes the last COMMITTED segment whenever one exists -- it is
    /// designed for the user-facing "delete last segment" rollback, which
    /// intentionally rewinds past a completed take. Calling it directly
    /// after a FAILED (never-committed) segment's asset write would
    /// therefore silently discard the previous GOOD take's segment instead
    /// of only the failed one (e.g. a second take's recorder-finish failure
    /// wrongly erasing the first take).
    ///
    /// Achieves a true "abort active only" using only VGDuetPreviewClock's
    /// existing public API: commitSegment() first transitions the clock out
    /// of "recording" and provisionally appends the active segment as the
    /// new last segment; deleteLastSegment() is then called immediately,
    /// which removes exactly that just-committed record (it is now the
    /// clock's last segment) and rewinds sourceCursorMs/outputCursorMs and
    /// isAutoStopped back to their state before this segment started --
    /// leaving every earlier committed segment and its asset path untouched.
    /// No-op if the clock has no active recording segment.
    func abortActiveSegment() {
        guard previewClock.isRecordingActive else { return }
        previewClock.commitSegment()
        previewClock.deleteLastSegment()
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
            "totalDurationMs":       totalDurationMs(),
            "segmentCount":          segmentCount(),
            "segmentAssets":         segmentAssetPaths,
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
        // recording (re-attach mid-take) the loop goes active immediately;
        // otherwise (Slice 4B-C) it enters idle preview so the camera
        // preview keeps redrawing live over that held frame instead of
        // freezing on the single initial snapshot.
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
            let provider: VGDuetForegroundProvider
            if #available(iOS 13.0, *), VGDuetGPUZeroForegroundProvider.isSupported {
                provider = VGDuetGPUZeroForegroundProvider(canvasWidth: Int(width), canvasHeight: Int(height))
            } else {
                provider = VGDuetGraphGreenScreenForegroundProvider()
            }
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
        session.audioPlayer?.seek(toMilliseconds: session.trimStartMs)
        if session.state == .recording {
            loop.startActive()
        } else {
            // Slice 4B-C: before the first take (or on re-attach while
            // paused/completed), keep live foreground/camera samples
            // redrawing over the held source frame instead of freezing on
            // the single renderInitialFrame() snapshot -- iOS sibling of
            // Android's camera idle redraw pump.
            loop.startIdlePreview()
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
    /// on main.  Captures avoid retain cycles (session and self weak).
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
        let mode         = session.layoutConfigMap["mode"] as? String ?? "pip"
        let isSplitLeftRight = (mode == "splitLeftRight")
        let scaleMode: VGDuetScaleMode = isSplitLeftRight ? .aspectFit : .aspectFill

        return VGDuetPreviewRenderLoop(
            compositor:  compositor,
            trimStartMs: session.trimStartMs,
            trimEndMs:   session.trimEndMs,
            sourceRect:  rects.source,
            cameraRect:  rects.camera,
            rotationDegrees: rects.rotation.rotationDegrees,
            anchorX:     rects.rotation.anchorX,
            anchorY:     rects.rotation.anchorY,
            scaleMode:   scaleMode,
            targetPtsProvider: { [weak self, weak session] in
                // Main thread (display link / renderInitialFrame). Also the
                // trim-end observation point for the one-shot `auto_stop`
                // event: the loop evaluates this every active tick and stops
                // doing so on pause/seek/stop, so no take-scoped timer is
                // needed. maybeEmitAutoStop itself refuses anything but a live
                // RECORDING take.
                let sourcePtsMs = clock.currentSourcePtsMs()
                if let self = self, let session = session {
                    self.maybeEmitAutoStop(session: session, sourcePtsMs: sourcePtsMs)
                }
                return sourcePtsMs
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
                guard let sample = session?.foregroundProvider?.sampleRetained() else { return nil }
                if let session = session, session.state == .recording, let recorder = session.currentRecorder {
                    let pixelBuffer = sample.frame.takeUnretainedValue()
                    let currentPtsMs = session.previewClock.currentOutputPtsMs() - session.previewClock.outputCursorMs
                    let pts = CMTimeMake(value: Int64(max(0, currentPtsMs)), timescale: 1000)
                    recorder.appendVideoPixelBuffer(pixelBuffer, presentationTime: pts)
                }
                return sample
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

        let freeBytes = Self.availableDiskSpaceBytes()
        guard freeBytes >= 200 * 1024 * 1024 else {
            reply(nil, FlutterError(code: "disk_full", message: "Insufficient disk space for recording (minimum 200MB required)", details: nil))
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

                        // Slice 1: attach preview audio player for source video
                        let player = VGDuetPreviewAudioPlayer(sourceURL: url)
                        player.setVolume(Float(sourceGain))
                        session.audioPlayer = player

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
            let mode = layoutConfigMap["mode"] as? String ?? "pip"
            let isSplitLeftRight = (mode == "splitLeftRight")
            let scaleMode: VGDuetScaleMode = isSplitLeftRight ? .aspectFit : .aspectFill
            session.previewRenderLoop?.updateLayout(
                sourceRect:  rects.source,
                cameraRect:  rects.camera,
                rotationDegrees: rects.rotation.rotationDegrees,
                anchorX:     rects.rotation.anchorX,
                anchorY:     rects.rotation.anchorY,
                scaleMode:   scaleMode,
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
        session.audioPlayer?.setRate(speed)
        session.micCapture?.setSpeedMultiplier(speed)
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
        session.audioPlayer?.setVolume(Float(sourceGain))
        reply(nil, nil)
    }

    // MARK: - startRecording

    func startRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .initialized else {
            reply(nil, invalidState("startDuetRecording", current: stateName(session.state), expected: "initialized")); return
        }
        guard session.previewRenderLoop != nil, session.foregroundProvider != nil else {
            reply(nil, FlutterError(code: "preview_not_attached",
                                     message: "Cannot start recording: preview texture or camera foreground provider is not attached",
                                     details: nil))
            return
        }

        let freeBytes = Self.availableDiskSpaceBytes()
        guard freeBytes >= 200 * 1024 * 1024 else {
            reply(nil, FlutterError(code: "disk_full", message: "Insufficient disk space for recording", details: nil))
            return
        }

        let segIdx = session.segmentCount()
        let segURL = Self.segmentFileURL(sessionId: sessionId, index: segIdx)
        let width = session.previewWidthPx ?? 1080
        let height = session.previewHeightPx ?? 1920
        do {
            let recorder = try VGDuetSegmentRecorder(outputURL: segURL, videoSize: CGSize(width: width, height: height))
            session.currentRecorder = recorder
        } catch {
            reply(nil, FlutterError(code: "recording_start_failed", message: "Failed to initialize segment recorder: \(error.localizedDescription)", details: nil))
            return
        }

        let mic = VGDuetMicrophoneCapture(speedMultiplier: session.speedMultiplier) { [weak session] sampleBuffer in
            session?.currentRecorder?.appendAudioSampleBuffer(sampleBuffer)
        }
        session.micCapture = mic
        mic.start()

        session.state = .recording
        session.autoStopEmitted = false
        session.startSegment()
        session.previewRenderLoop?.startActive()   // Slice 4B-B

        session.audioPlayer?.seek(toMilliseconds: session.trimStartMs) { [weak session] in
            guard let session = session, session.state == .recording else { return }
            session.audioPlayer?.play(atRate: session.speedMultiplier)
        }

        reply(nil, nil)
    }

    // MARK: - pauseRecording

    func pauseRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .recording else {
            reply(nil, invalidState("pauseDuetRecording", current: stateName(session.state), expected: "recording")); return
        }
        session.audioPlayer?.pause()
        session.micCapture?.stop()
        session.micCapture = nil

        let recorder = session.currentRecorder
        session.currentRecorder = nil

        // Slice 4B-B: the render loop owns decoder stepping; hold the committed cursor frame.
        session.previewRenderLoop?.pauseAndHold(targetPtsMs: session.previewClock.currentSourcePtsMs())

        if let recorder = recorder {
            recorder.finishWriting { [weak session] result in
                guard let session = session else {
                    reply(nil, FlutterError(code: "session_deallocated", message: "Session deallocated during pause", details: nil))
                    return
                }
                switch result {
                case .success(let url):
                    session.segmentAssetPaths.append(url.path)
                    session.commitSegment()
                    session.state = session.previewClock.isAutoStopped ? .completed : .paused
                    reply(nil, nil)
                case .failure(let err):
                    NSLog("[VGDuetNativeSessionCoordinator] Segment write finish failed: %@", err.localizedDescription)
                    session.abortActiveSegment()
                    try? FileManager.default.removeItem(at: recorder.outputURL)
                    session.state = .paused
                    reply(nil, FlutterError(code: "segment_write_failed",
                                             message: "Failed to persist segment asset: \(err.localizedDescription)",
                                             details: nil))
                }
            }
        } else {
            session.commitSegment()
            session.state = session.previewClock.isAutoStopped ? .completed : .paused
            reply(nil, nil)
        }
    }

    // MARK: - resumeRecording

    func resumeRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        guard session.state == .paused else {
            reply(nil, invalidState("resumeDuetRecording", current: stateName(session.state), expected: "paused")); return
        }
        guard session.previewRenderLoop != nil, session.foregroundProvider != nil else {
            reply(nil, FlutterError(code: "preview_not_attached",
                                     message: "Cannot resume recording: preview texture or camera foreground provider is not attached",
                                     details: nil))
            return
        }

        let freeBytes = Self.availableDiskSpaceBytes()
        guard freeBytes >= 100 * 1024 * 1024 else {
            reply(nil, FlutterError(code: "disk_full", message: "Insufficient disk space for recording", details: nil))
            return
        }

        let segIdx = session.segmentCount()
        let segURL = Self.segmentFileURL(sessionId: sessionId, index: segIdx)
        let width = session.previewWidthPx ?? 1080
        let height = session.previewHeightPx ?? 1920
        do {
            let recorder = try VGDuetSegmentRecorder(outputURL: segURL, videoSize: CGSize(width: width, height: height))
            session.currentRecorder = recorder
        } catch {
            reply(nil, FlutterError(code: "recording_resume_failed", message: "Failed to initialize segment recorder: \(error.localizedDescription)", details: nil))
            return
        }

        let mic = VGDuetMicrophoneCapture(speedMultiplier: session.speedMultiplier) { [weak session] sampleBuffer in
            session?.currentRecorder?.appendAudioSampleBuffer(sampleBuffer)
        }
        session.micCapture = mic
        mic.start()

        session.state = .recording
        session.autoStopEmitted = false
        session.startSegment()
        session.previewRenderLoop?.startActive()   // Slice 4B-B

        let cursorMs = session.previewClock.currentSourcePtsMs()
        session.audioPlayer?.seek(toMilliseconds: cursorMs) { [weak session] in
            guard let session = session, session.state == .recording else { return }
            session.audioPlayer?.play(atRate: session.speedMultiplier)
        }

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

        if !session.segmentAssetPaths.isEmpty {
            let removedPath = session.segmentAssetPaths.removeLast()
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(atPath: removedPath)
            }
        }

        let cursorMs = session.previewClock.currentSourcePtsMs()
        session.audioPlayer?.seek(toMilliseconds: cursorMs)
        // Slice 4B-B: the render loop owns decoder seeking; hold the rolled-back cursor frame.
        session.previewRenderLoop?.seekAndHold(targetPtsMs: cursorMs)
        reply(nil, nil)
    }

    // MARK: - stopRecording

    func stopRecording(sessionId: String, reply: @escaping (Any?, FlutterError?) -> Void) {
        assert(Thread.isMainThread)
        guard let session = resolveActiveSession(sessionId: sessionId, reply: reply) else { return }
        switch session.state {
        case .recording, .paused, .completed:
            break
        default:
            reply(nil, invalidState("stopDuetRecording", current: stateName(session.state), expected: "recording, paused, or completed")); return
        }

        session.state = .stopped
        session.audioPlayer?.stop()
        session.audioPlayer = nil
        session.micCapture?.stop()
        session.micCapture = nil

        let recorder = session.currentRecorder
        session.currentRecorder = nil

        stopPreviewRenderLoop(for: session)   // Slice 4B-B: loop first, then texture, then decoder
        let dec = session.decoder
        session.decoder = nil
        releasePreviewTexture(for: session)   // Slice 4A: detach before drop
        activeSession = nil
        decoderQueue.async { dec?.release() }

        let finalizeResult = { (session: VGDuetNativeSession, stopTakeError: Error?) in
            if let err = stopTakeError {
                reply(nil, FlutterError(code: "recording_failed",
                                         message: "Failed to persist final segment asset: \(err.localizedDescription)",
                                         details: nil))
                return
            }
            guard session.segmentCount() > 0 && !session.segmentAssetPaths.isEmpty else {
                reply(nil, FlutterError(code: "recording_failed",
                                         message: "Cannot stop recording: no valid segment assets were recorded or persisted",
                                         details: nil))
                return
            }
            let resultMap = session.buildStopResult()
            reply(resultMap, nil)
        }

        if let recorder = recorder {
            recorder.finishWriting { result in
                var stopTakeError: Error? = nil
                switch result {
                case .success(let url):
                    session.segmentAssetPaths.append(url.path)
                    session.commitSegment()
                case .failure(let err):
                    NSLog("[VGDuetNativeSessionCoordinator] Final segment write failed: %@", err.localizedDescription)
                    session.abortActiveSegment()
                    try? FileManager.default.removeItem(at: recorder.outputURL)
                    stopTakeError = err
                }
                finalizeResult(session, stopTakeError)
            }
        } else {
            finalizeResult(session, nil)
        }
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
            session.audioPlayer?.stop()
            session.audioPlayer = nil
            session.micCapture?.stop()
            session.micCapture = nil
            session.currentRecorder?.cancel()
            session.currentRecorder = nil
            let pathsToDelete = session.segmentAssetPaths
            session.segmentAssetPaths.removeAll()
            let sessionDir = Self.sessionDirectory(sessionId: session.sessionId)
            DispatchQueue.global(qos: .utility).async {
                for p in pathsToDelete {
                    try? FileManager.default.removeItem(atPath: p)
                }
                try? FileManager.default.removeItem(at: sessionDir)
            }

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
            session.audioPlayer?.stop()
            session.audioPlayer = nil
            session.micCapture?.stop()
            session.micCapture = nil
            session.currentRecorder?.cancel()
            session.currentRecorder = nil
            let pathsToDelete = session.segmentAssetPaths
            session.segmentAssetPaths.removeAll()
            let sessionDir = Self.sessionDirectory(sessionId: session.sessionId)
            DispatchQueue.global(qos: .utility).async {
                for p in pathsToDelete {
                    try? FileManager.default.removeItem(atPath: p)
                }
                try? FileManager.default.removeItem(at: sessionDir)
            }

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
                scaleMode:   .aspectFill,
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

    // MARK: - Auto-stop signal

    /// One-shot `auto_stop` signal, emitted via `onDuetEvent` the first time
    /// the active take's source cursor reaches the session's trim end. Called
    /// from the render loop's `targetPtsProvider` (main thread), which the loop
    /// evaluates every active display tick and stops evaluating on
    /// pause/seek/stop, so this rides the existing tick cadence with no timer
    /// of its own. `VGDuetPreviewClock.currentSourcePtsMs` clamps at trimEnd,
    /// so without `VGDuetNativeSession.autoStopEmitted` every later tick would
    /// re-emit while the source frame is held.
    ///
    /// Signal only: nothing here pauses, stops, commits, or finalizes the take.
    /// The Dart session owner reacts by calling its normal pause/stop path, so
    /// pause/stop/dispose keep their single owner and no duplicate finalize can
    /// originate natively. Never emits unless the session is still active and
    /// `.recording` with a live recorder and an open clock segment -- i.e. not
    /// paused (the recorder is cleared synchronously at the top of
    /// pauseRecording, before its async finish lands), completed, stopped,
    /// disposed, or before a take has begun.
    private func maybeEmitAutoStop(session: VGDuetNativeSession, sourcePtsMs: Int) {
        if session.autoStopEmitted { return }
        guard activeSession === session else { return }
        guard session.state == .recording else { return }
        guard session.currentRecorder != nil else { return }
        guard session.previewClock.isRecordingActive else { return }
        guard sourcePtsMs >= session.trimEndMs else { return }
        session.autoStopEmitted = true
        NSLog("[VGDuetNativeSessionCoordinator] IOS_DUET_AUTO_STOP_EMITTED session=%@ sourcePtsMs=%d trimEndMs=%d",
              session.sessionId, sourcePtsMs, session.trimEndMs)
        onDuetEvent?([
            "event":     "auto_stop",
            "sessionId": session.sessionId,
            "reason":    "trim_end_reached",
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

    // MARK: - Slice 1 Helpers

    static func sessionDirectory(sessionId: String) -> URL {
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vanguard_duet_segments", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    static func segmentFileURL(sessionId: String, index: Int) -> URL {
        return sessionDirectory(sessionId: sessionId)
            .appendingPathComponent("take_\(index).mp4", isDirectory: false)
    }

    static func availableDiskSpaceBytes() -> Int64 {
        let tempPath = NSTemporaryDirectory()
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: tempPath)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
    }
}

// MARK: - Slice 1: Preview Audio Player

final class VGDuetPreviewAudioPlayer {

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var endObserver: Any?
    private var currentSpeed: Double = 1.0
    private var currentVolume: Float = 1.0
    private var isPlaying: Bool = false

    init(sourceURL: URL) {
        assert(Thread.isMainThread)
        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let pl = AVPlayer(playerItem: item)
        pl.actionAtItemEnd = .pause
        self.player = pl
        self.playerItem = item

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
    }

    deinit {
        stop()
    }

    func play(atRate rate: Double) {
        assert(Thread.isMainThread)
        guard let player = player else { return }
        currentSpeed = rate
        player.volume = currentVolume
        player.rate = Float(rate)
        isPlaying = true
    }

    func pause() {
        assert(Thread.isMainThread)
        guard let player = player else { return }
        player.pause()
        isPlaying = false
    }

    func seek(toMilliseconds ms: Int, completion: (() -> Void)? = nil) {
        assert(Thread.isMainThread)
        guard let player = player else {
            completion?()
            return
        }
        let time = CMTimeMake(value: Int64(ms), timescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func setRate(_ rate: Double) {
        assert(Thread.isMainThread)
        currentSpeed = rate
        if isPlaying, let player = player {
            player.rate = Float(rate)
        }
    }

    func setVolume(_ volume: Float) {
        assert(Thread.isMainThread)
        let clamped = max(0.0, min(1.0, volume))
        currentVolume = clamped < 0.0001 ? 0.0 : clamped
        player?.volume = currentVolume
    }

    func stop() {
        assert(Thread.isMainThread)
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        if let player = player {
            player.pause()
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.replaceCurrentItem(with: nil)
            self.player = nil
            self.playerItem = nil
        }
        isPlaying = false
    }
}

// MARK: - Slice 1: Segment Recorder

final class VGDuetSegmentRecorder {

    let outputURL: URL
    private let videoSize: CGSize
    private let averageBitRate: Int
    private let writerQueue = DispatchQueue(label: "com.connects.vanguard.duet.segment.writer",
                                            qos: .userInitiated)

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?

    private var isSessionStarted: Bool = false
    private var isFinished: Bool = false
    private var isCancelled: Bool = false

    private var lastVideoPTS: CMTime = .invalid
    private var firstPTS: CMTime?

    init(outputURL: URL, videoSize: CGSize = CGSize(width: 1080, height: 1920), averageBitRate: Int = 10_000_000) throws {
        self.outputURL = outputURL
        self.videoSize = videoSize
        self.averageBitRate = averageBitRate

        let parentDir = outputURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ]
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: nil
        )

        guard writer.canAdd(vInput) else {
            throw NSError(domain: "VGDuetSegmentRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add video input to AVAssetWriter"])
        }
        writer.add(vInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true

        if writer.canAdd(aInput) {
            writer.add(aInput)
            self.audioInput = aInput
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "VGDuetSegmentRecorder", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter startWriting failed"])
        }

        self.assetWriter = writer
        self.videoInput = vInput
        self.pixelBufferAdaptor = adaptor
    }

    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        writerQueue.async { [self] in
            guard let writer = self.assetWriter,
                  let adaptor = self.pixelBufferAdaptor,
                  let input = self.videoInput,
                  !self.isFinished,
                  !self.isCancelled,
                  writer.status == .writing else { return }

            if !self.isSessionStarted {
                writer.startSession(atSourceTime: .zero)
                self.isSessionStarted = true
            }

            guard presentationTime >= .zero else { return }

            if self.lastVideoPTS.isValid && presentationTime <= self.lastVideoPTS {
                return
            }

            if input.isReadyForMoreMediaData {
                if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                    self.lastVideoPTS = presentationTime
                } else {
                    NSLog("[VGDuetSegmentRecorder] appendVideo failed: status=%ld, error=%@",
                          writer.status.rawValue, String(describing: writer.error))
                }
            }
        }
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [self] in
            guard let writer = self.assetWriter,
                  let aInput = self.audioInput,
                  self.isSessionStarted,
                  !self.isFinished,
                  !self.isCancelled,
                  writer.status == .writing else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts >= .zero else { return }

            if aInput.isReadyForMoreMediaData {
                if !aInput.append(sampleBuffer) {
                    NSLog("[VGDuetSegmentRecorder] appendAudio failed: status=%ld, error=%@",
                          writer.status.rawValue, String(describing: writer.error))
                }
            }
        }
    }

    func finishWriting(completion: @escaping (Result<URL, Error>) -> Void) {
        writerQueue.async { [self] in
            guard !self.isFinished, !self.isCancelled, let writer = self.assetWriter else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "VGDuetSegmentRecorder", code: 3,
                                                userInfo: [NSLocalizedDescriptionKey: "Recorder not active or already finished"])))
                }
                return
            }

            self.isFinished = true

            // If the writer never started or failed, do NOT call writer.finishWriting because
            // AVAssetWriter will hang or drop the completion callback!
            guard self.isSessionStarted, writer.status == .writing else {
                let status = writer.status.rawValue
                let err = writer.error ?? NSError(domain: "VGDuetSegmentRecorder", code: 5,
                                                  userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter status is \(status) (not writing), sessionStarted=\(self.isSessionStarted)"])
                NSLog("[VGDuetSegmentRecorder] Cannot finishWriting: status=%ld, error=%@", status, String(describing: writer.error))
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                DispatchQueue.main.async {
                    completion(.failure(err))
                }
                return
            }

            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()

            let url = self.outputURL
            writer.finishWriting {
                if writer.status == .completed {
                    let fileAttrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? 0
                    if size > 0 {
                        DispatchQueue.main.async {
                            completion(.success(url))
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(.failure(NSError(domain: "VGDuetSegmentRecorder", code: 4,
                                                        userInfo: [NSLocalizedDescriptionKey: "Output segment file is empty: \(url.path)"])))
                        }
                    }
                } else {
                    let err = writer.error ?? NSError(domain: "VGDuetSegmentRecorder", code: 5,
                                                      userInfo: [NSLocalizedDescriptionKey: "finishWriting failed with status \(writer.status.rawValue), error: \(String(describing: writer.error))"])
                    DispatchQueue.main.async {
                        completion(.failure(err))
                    }
                }
            }
        }
    }

    func cancel() {
        let writer = self.assetWriter
        let outputURL = self.outputURL
        self.isCancelled = true
        self.assetWriter = nil
        self.videoInput = nil
        self.pixelBufferAdaptor = nil
        self.audioInput = nil

        writerQueue.async {
            if writer?.status == .writing {
                writer?.cancelWriting()
            }
            try? FileManager.default.removeItem(at: outputURL)
        }
    }
}

// MARK: - GSD-08: Microphone WSOLA time-stretcher
//
// Lightweight time-domain WSOLA (Waveform Similarity Overlap-Add) time-stretcher.
//
// Pure DSP: operates only on mono Float32 sample arrays, independent of CMSampleBuffer /
// AVFoundation. Driven incrementally from a live capture callback via `process(_:)`, which
// buffers newly arrived input samples and returns whatever output samples became available;
// `flush()` drains the remainder at end-of-stream, zero-padding the final analysis window if
// the buffered input runs out mid-window. Over a whole take, the total emitted output sample
// count approximates inputSamples * speedMultiplier.
//
// Structure mirrors the proven AndroidDuetWsolaFilter.kt: an absolute input base index, a
// running count of real (non-padded) samples ever appended, a fractional absolute analysis
// position, threshold-gated safe compaction of the consumed input prefix, EOS zero padding of
// the analysis window, a sliding OLA accumulator, and a previous-frame-tail similarity search
// used to pick each new frame's alignment.
//
// Packaging note: this type lives in this file (rather than its own source file) so it is
// compiled by the existing example Pods project without requiring a Pods project mutation.
// `ios/Classes/VGDuetWsolaFilter.swift` is a comment-only placeholder for that reason.

fileprivate final class VGDuetWsolaFilter {

    static let windowLength = 1024
    static let synthesisHop = 512
    static let searchRadius = 256
    private static let overlapLength = windowLength - synthesisHop

    /// Below this many samples of buffer growth, don't bother compacting yet.
    private static let compactThreshold = 8192

    private var speed: Double
    // SYNTHESIS_HOP / speed, floored at 1.0 sample/frame so a pathological speed can never
    // stall the analysis position (which would otherwise spin flush()'s drain loop forever).
    private var analysisHop: Double

    // Samples received but not yet dropped by compaction.
    private var inputBuffer: [Float] = []
    // Absolute sample index (since the last reset) of inputBuffer[0].
    private var inputBufferBaseIndex: Int = 0
    // Absolute count of real (non-padded) samples ever appended via process().
    private var totalRealAppended: Int = 0

    // Fractional analysis-frame read position, in absolute input-sample coordinates.
    private var analysisPos: Double = 0
    private var hasPlacedFirstFrame = false

    // Raw (unwindowed) tail of the most recently placed analysis frame, used as the
    // similarity reference for locating the next frame's best alignment.
    private var previousFrameTail: [Float]

    // Sliding overlap-add accumulator; accumulator[0..<synthesisHop] is finalized output
    // once a frame has been added, then shifted left by synthesisHop each iteration.
    private var accumulator: [Float]

    // Periodic Hann window: sum of two copies offset by windowLength/2 is exactly 1.0,
    // giving unity-gain overlap-add at the fixed 50% synthesis hop used here.
    private let window: [Float]

    init(speedMultiplier: Double = 1.0) {
        let clamped = VGDuetWsolaFilter.clampedSpeed(speedMultiplier)
        self.speed = clamped
        self.analysisHop = VGDuetWsolaFilter.computeAnalysisHop(speed: clamped)
        self.accumulator = [Float](repeating: 0, count: Self.windowLength)
        self.previousFrameTail = [Float](repeating: 0, count: Self.overlapLength)
        self.window = VGDuetWsolaFilter.makeHannWindow(length: Self.windowLength)
    }

    func setSpeedMultiplier(_ speedMultiplier: Double) {
        self.speed = VGDuetWsolaFilter.clampedSpeed(speedMultiplier)
        self.analysisHop = VGDuetWsolaFilter.computeAnalysisHop(speed: self.speed)
    }

    /// Drops all buffered state. Call when starting a new, unrelated audio stream so no
    /// stale samples bleed across the discontinuity.
    func reset() {
        inputBuffer.removeAll(keepingCapacity: true)
        inputBufferBaseIndex = 0
        totalRealAppended = 0
        analysisPos = 0
        hasPlacedFirstFrame = false
        previousFrameTail = [Float](repeating: 0, count: Self.overlapLength)
        accumulator = [Float](repeating: 0, count: Self.windowLength)
    }

    /// Feeds newly captured mono samples and returns any output samples now available.
    /// May return an empty array if not enough input has accumulated yet to place
    /// another analysis frame; the input is retained internally for the next call.
    func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        inputBuffer.append(contentsOf: input)
        totalRealAppended += input.count

        var output: [Float] = []
        while tryProduceFrame(allowPad: false, output: &output) { }
        compact()
        return output
    }

    /// Signals end-of-input: drains every remaining real sample (zero-padding the final
    /// analysis window if it runs past the buffered input) plus the last window's
    /// un-overlapped OLA tail, then returns the whole remainder. Leaves the filter in a
    /// freshly reset state afterward.
    func flush() -> [Float] {
        var output: [Float] = []
        while true {
            let nominalAbs = hasPlacedFirstFrame ? Int(analysisPos.rounded()) : 0
            if nominalAbs >= totalRealAppended { break }
            if !tryProduceFrame(allowPad: true, output: &output) { break }
        }
        if hasPlacedFirstFrame {
            // Only one window ever contributed to this tail (natural fade-out).
            output.append(contentsOf: accumulator[0..<Self.overlapLength])
        }
        reset()
        return output
    }

    // MARK: - Input buffer

    /// Zero-pads inputBuffer up to local length `uptoAbs - inputBufferBaseIndex` (EOS-only helper).
    private func padInputTo(_ uptoAbs: Int) {
        let uptoLocal = uptoAbs - inputBufferBaseIndex
        guard uptoLocal > inputBuffer.count else { return }
        inputBuffer.append(contentsOf: repeatElement(0, count: uptoLocal - inputBuffer.count))
    }

    /// Drops already-consumed prefix once it grows past compactThreshold; keeps the search margin intact.
    private func compact() {
        let safeAbs = Int(analysisPos.rounded()) - Self.searchRadius - 1
        let dropAbs = min(safeAbs, inputBufferBaseIndex + inputBuffer.count) - inputBufferBaseIndex
        guard dropAbs >= Self.compactThreshold else { return }
        let drop = min(max(dropAbs, 0), inputBuffer.count)
        guard drop > 0 else { return }
        inputBuffer.removeFirst(drop)
        inputBufferBaseIndex += drop
    }

    // MARK: - WSOLA core

    /// Attempts to produce exactly one synthesis frame; false means "wait for more input"
    /// (or, at EOS, "nothing left").
    @discardableResult
    private func tryProduceFrame(allowPad: Bool, output: inout [Float]) -> Bool {
        let nominalAbs = hasPlacedFirstFrame ? Int(analysisPos.rounded()) : 0
        var availableAbsEnd = inputBufferBaseIndex + inputBuffer.count

        if !hasPlacedFirstFrame {
            if nominalAbs + Self.windowLength > availableAbsEnd {
                guard allowPad else { return false }
                padInputTo(nominalAbs + Self.windowLength)
            }
            guard totalRealAppended > 0 else { return false }
            emitFrame(startAbs: nominalAbs, output: &output)
            return true
        }

        guard nominalAbs < availableAbsEnd else { return false }

        var searchMaxStart = availableAbsEnd - Self.windowLength
        if nominalAbs > searchMaxStart {
            guard allowPad else { return false }
            padInputTo(nominalAbs + Self.searchRadius + Self.windowLength)
            availableAbsEnd = inputBufferBaseIndex + inputBuffer.count
            searchMaxStart = availableAbsEnd - Self.windowLength
        }

        let loBound = max(inputBufferBaseIndex, nominalAbs - Self.searchRadius)
        let hiBound = min(searchMaxStart, nominalAbs + Self.searchRadius)
        var bestStart = min(max(nominalAbs, loBound), max(loBound, hiBound))
        if hiBound >= loBound {
            var bestScore = Double.greatestFiniteMagnitude
            var candidate = loBound
            while candidate <= hiBound {
                let local = candidate - inputBufferBaseIndex
                var score: Double = 0
                for j in 0..<Self.overlapLength {
                    score += abs(Double(inputBuffer[local + j]) - Double(previousFrameTail[j]))
                }
                if score < bestScore {
                    bestScore = score
                    bestStart = candidate
                }
                candidate += 1
            }
        }
        emitFrame(startAbs: bestStart, output: &output)
        return true
    }

    /// Windows+OLA-accumulates the windowLength-length segment at startAbs, emits its ready
    /// hop, advances the analysis position.
    private func emitFrame(startAbs: Int, output: inout [Float]) {
        let local = startAbs - inputBufferBaseIndex
        for j in 0..<Self.windowLength {
            accumulator[j] += inputBuffer[local + j] * window[j]
        }
        for j in 0..<Self.overlapLength {
            previousFrameTail[j] = inputBuffer[local + Self.synthesisHop + j]
        }
        hasPlacedFirstFrame = true
        output.append(contentsOf: accumulator[0..<Self.synthesisHop])
        for i in 0..<Self.overlapLength {
            accumulator[i] = accumulator[i + Self.synthesisHop]
        }
        for i in Self.overlapLength..<Self.windowLength {
            accumulator[i] = 0
        }
        analysisPos += analysisHop
    }

    private static func clampedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return 1.0 }
        return min(max(speed, 0.1), 4.0)
    }

    private static func computeAnalysisHop(speed: Double) -> Double {
        max(Double(synthesisHop) / speed, 1.0)
    }

    /// Periodic (DFT-even) Hann window: w(n) = 0.5 - 0.5*cos(2*pi*n/N). Unlike the
    /// "symmetric" Hann window (which divides by N-1), this variant satisfies the
    /// constant-overlap-add identity w(n) + w(n + N/2) == 1 exactly at a 50% hop.
    private static func makeHannWindow(length: Int) -> [Float] {
        var w = [Float](repeating: 0, count: length)
        for i in 0..<length {
            w[i] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(length)))
        }
        return w
    }
}

// MARK: - Slice 1: Microphone Capture

final class VGDuetMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    typealias AudioBufferHandler = (CMSampleBuffer) -> Void

    private let captureQueue = DispatchQueue(label: "com.connects.vanguard.duet.mic.capture",
                                             qos: .userInitiated)
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?

    private var onAudioBuffer: AudioBufferHandler?
    private var speedMultiplier: Double = 1.0

    private var firstPTS: CMTime?
    private var isCapturing: Bool = false

    // GSD-08: WSOLA time-stretch path for non-1.0 speeds. `wsolaOutputSampleCursor` is
    // seeded lazily from the wall-clock elapsed time at the moment WSOLA output first
    // becomes available, so a live speed change away from 1.0x hands off from the
    // metadata-retimed clock without an immediate large PTS jump.
    private static let wsolaTargetSampleRate: Double = 44100
    private let wsolaFilter: VGDuetWsolaFilter
    private var wsolaOutputSampleCursor: Int64?
    private var pcmAudioConverter: AVAudioConverter?
    private var pcmConverterSourceFormat: AVAudioFormat?

    init(speedMultiplier: Double = 1.0, onAudioBuffer: @escaping AudioBufferHandler) {
        self.speedMultiplier = speedMultiplier
        self.onAudioBuffer = onAudioBuffer
        self.wsolaFilter = VGDuetWsolaFilter(speedMultiplier: speedMultiplier)
        super.init()
    }

    deinit {
        let session = self.captureSession
        let output = self.audioOutput
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let s = session, s.isRunning {
            captureQueue.async {
                s.stopRunning()
            }
        }
    }

    func start() {
        captureQueue.async { [weak self] in
            guard let self = self, !self.isCapturing else { return }
            self.firstPTS = nil
            self.wsolaOutputSampleCursor = nil
            self.wsolaFilter.reset()

            let session = AVCaptureSession()
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic) else {
                NSLog("[VGDuetMicrophoneCapture] Microphone device unavailable")
                return
            }

            if session.canAddInput(input) {
                session.addInput(input)
            }

            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }

            session.startRunning()
            self.captureSession = session
            self.audioOutput = output
            self.isCapturing = true
        }
    }

    /// GSD-08: synchronizes the WSOLA tail flush + `onAudioBuffer` teardown on
    /// `captureQueue` -- the same serial queue `captureOutput` runs on as the
    /// output's delegate queue -- so no in-flight `captureOutput` call can
    /// interleave with (or run after) the final flushed append. Blocking the
    /// caller here is intentional: `handler(tailBuffer)` must complete before
    /// `stop()` returns so `pauseRecording`/`stopRecording` enqueue the tail
    /// onto the recorder's writer queue before `finishWriting` marks audio
    /// finished.
    func stop() {
        captureQueue.sync { [self] in
            if abs(self.speedMultiplier - 1.0) >= 0.001, let cursor = self.wsolaOutputSampleCursor {
                let tailSamples = self.wsolaFilter.flush()
                if !tailSamples.isEmpty, let handler = self.onAudioBuffer {
                    let pts = CMTime(value: cursor, timescale: Int32(Self.wsolaTargetSampleRate))
                    if let tailBuffer = Self.makeMonoFloatSampleBuffer(
                        samples: tailSamples,
                        sampleRate: Self.wsolaTargetSampleRate,
                        presentationTimeStamp: pts
                    ) {
                        handler(tailBuffer)
                    }
                }
            }

            self.isCapturing = false
            self.onAudioBuffer = nil
            self.wsolaOutputSampleCursor = nil
            self.firstPTS = nil
        }

        let session = self.captureSession
        let output = self.audioOutput
        self.captureSession = nil
        self.audioOutput = nil

        output?.setSampleBufferDelegate(nil, queue: nil)
        if let s = session, s.isRunning {
            captureQueue.async {
                s.stopRunning()
            }
        }
    }

    func setSpeedMultiplier(_ speed: Double) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.speedMultiplier = speed
            self.wsolaFilter.setSpeedMultiplier(speed)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isCapturing, let handler = onAudioBuffer else { return }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil {
            firstPTS = rawPTS
        }

        guard let startPTS = firstPTS else { return }

        if abs(speedMultiplier - 1.0) < 0.001 {
            // Low-risk path: original PCM bytes pass through untouched, only the
            // presentation timestamp metadata is rewritten.
            let elapsed = CMTimeSubtract(rawPTS, startPTS)
            if let timedBuffer = Self.retimedSampleBuffer(sampleBuffer, newPTS: elapsed) {
                handler(timedBuffer)
            } else {
                handler(sampleBuffer)
            }
            return
        }

        // GSD-08: non-1.0 speeds must actually time-scale the waveform (WSOLA), not just
        // rewrite timestamps -- metadata-only retiming leaves silent gaps in the encoded
        // audio for speed > 1.0 and produces overlapping/non-monotonic timing for speed < 1.0
        // once appended to AVAssetWriter.
        guard let inputSamples = extractMonoFloatSamples(from: sampleBuffer) else {
            // Fail-soft: drop this chunk rather than risk feeding malformed audio to the writer.
            return
        }

        if wsolaOutputSampleCursor == nil {
            let elapsedSec = CMTimeGetSeconds(CMTimeSubtract(rawPTS, startPTS))
            wsolaOutputSampleCursor = Int64(max(0.0, elapsedSec) * Self.wsolaTargetSampleRate)
        }

        let outputSamples = wsolaFilter.process(inputSamples)
        guard !outputSamples.isEmpty, let cursor = wsolaOutputSampleCursor else { return }

        let pts = CMTime(value: cursor, timescale: Int32(Self.wsolaTargetSampleRate))
        guard let stretchedBuffer = Self.makeMonoFloatSampleBuffer(
            samples: outputSamples,
            sampleRate: Self.wsolaTargetSampleRate,
            presentationTimeStamp: pts
        ) else {
            return
        }

        wsolaOutputSampleCursor = cursor + Int64(outputSamples.count)
        handler(stretchedBuffer)
    }

    /// Extracts mono Float32 PCM at the WSOLA target sample rate from a captured
    /// CMSampleBuffer, converting from whatever native format the capture device
    /// produced. Returns nil (fail-soft) if the buffer cannot be parsed or converted.
    private func extractMonoFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        guard let sourceFormat = AVAudioFormat(streamDescription: asbdPointer) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: Self.wsolaTargetSampleRate,
                                                channels: 1,
                                                interleaved: false) else {
            return nil
        }

        if sourceFormat.commonFormat == targetFormat.commonFormat,
           sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.isInterleaved == targetFormat.isInterleaved,
           let floatData = sourceBuffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
        }

        if pcmAudioConverter == nil || !(pcmConverterSourceFormat?.isEqual(sourceFormat) ?? false) {
            pcmAudioConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            pcmConverterSourceFormat = sourceFormat
        }
        guard let converter = pcmAudioConverter else { return nil }

        let ratio = targetFormat.sampleRate / max(sourceFormat.sampleRate, 1)
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }

        // Streaming contract: the converter is cached and reused across capture
        // buffers, so after supplying this buffer we must report `.noDataNow`
        // (not `.endOfStream`). `.endOfStream` latches the converter into EOF and
        // every subsequent call would produce zero frames for the rest of the take.
        var hasSuppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if hasSuppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasSuppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, conversionError == nil, let floatData = outBuffer.floatChannelData else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(outBuffer.frameLength)))
    }

    /// Builds a mono Float32 PCM CMSampleBuffer at the WSOLA target sample rate with the
    /// given start presentation timestamp. AVAssetWriterInput transcodes uncompressed PCM
    /// of any supported format to its configured AAC output settings, so this does not need
    /// to match the original capture device's native format.
    private static func makeMonoFloatSampleBuffer(samples: [Float],
                                                    sampleRate: Double,
                                                    presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let format = formatDescription else { return nil }

        let dataLength = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let buffer = blockBuffer else { return nil }

        let copyStatus = samples.withUnsafeBufferPointer { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr else { return nil }
        return sampleBuffer
    }

    private static func retimedSampleBuffer(_ buffer: CMSampleBuffer, newPTS: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }

        var timingArray = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timingArray, entriesNeededOut: &count)

        for i in 0..<count {
            timingArray[i].presentationTimeStamp = newPTS
        }

        var retimedBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: timingArray,
            sampleBufferOut: &retimedBuffer
        )

        return (status == noErr) ? retimedBuffer : nil
    }
}
