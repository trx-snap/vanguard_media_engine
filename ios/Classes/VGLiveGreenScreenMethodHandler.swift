// VGLiveGreenScreenMethodHandler.swift
// Generic live green-screen: thin MethodChannel dispatch layer from
// VanguardMediaEnginePlugin to VGLiveGreenScreenSessionCoordinator.
//
// Owns exactly twelve routes:
//   startLiveGreenScreenSession, updateLiveGreenScreenBackground,
//   updateLiveGreenScreenTransform, stopLiveGreenScreenSession, and eight
//   diagnostic-only routes: getLiveGreenScreenDiagnostics (physical-smoke
//   telemetry), setLiveGreenScreenDiagnosticsOptions (RND options for the
//   next start; live_busy while a session is active),
//   replayLiveGreenScreenInputBundle (offline deterministic replay of a
//   captured bundle to one PNG), runLiveGreenScreenMatteStageLab (offline
//   per-stage matte PNG dump), runLiveGreenScreenARKitPersonSegmentationProbe
//   (RND ARKit person-segmentation capability probe: its own throwaway
//   ARSession, never the coordinator's; `trackingConfiguration` selects
//   ARWorldTrackingConfiguration ("world", default, rear camera) or
//   ARFaceTrackingConfiguration ("face", front camera)), and
//   runLiveGreenScreenARKitPersonSegmentationMatteStillProbe (RND ARMatteGenerator
//   still-image visual proof: its own throwaway ARSession, delegates matte
//   generation/compositing/PNG-write to
//   VGARKitPersonSegmentationMatteStillProbe; `trackingConfiguration` selects
//   ARFaceTrackingConfiguration ("face", default, front camera) or
//   ARWorldTrackingConfiguration ("world", rear camera)), and the paired
//   startLiveGreenScreenARKitPreviewProbe /
//   stopLiveGreenScreenARKitPreviewProbe (discardable RND live ARKit
//   person-matte preview over solid teal, delegated to
//   VGARKitLiveGreenScreenPreviewCoordinator: its own ARSession and its own
//   VGDuetPreviewTexture, front camera / "face" only, at most one active at a
//   time). No diagnostic route is part of the public Dart interface.
//
//   VGARKitPersonSegmentationMatteStillProbe and its private frame-capture
//   helper live in ios/Classes/VGARKitPersonSegmentationMatteStillProbe.swift.
//   The two replay routes need no live session; they run synchronously on the
//   platform thread via VGLiveGreenScreenReplayDiagnostics and never touch the
//   coordinator, camera, or segmentation.
//
// Responsibilities: parse/validate MethodChannel args (`INVALID_ARG` on any
// malformed or unsupported input, including video backgrounds), delegate every
// lifecycle action to the coordinator, and expose disposeAll() for plugin
// detach. No session, camera, segmentation, or rendering logic lives here.
//
// Wire shapes (see lib/src/green_screen/vg_live_green_screen_models.dart):
//   start   → {canvasSize: {width, height}, background, foregroundTransform?}
//           ← {sessionId, textureId, width, height}
//   background → {type: "solidColor", argbColor} | {type: "image", filePath, scaleMode?}
//   foregroundTransform → {scale, offset: {x, y}, anchor: {x, y}}
//   diagnostics → {sessionId}
//               ← {sessionId, textureId, isKeyed, maskMaxAgeSeconds, providerKind,
//                  sampleCount, avgTotalMs, maxTotalMs, avgInferenceMs, …}
//                  (see VGLiveGreenScreenMaskProviderAdapter.diagnosticsSnapshot)
//   diagnosticsOptions → {iosFastMetalPrecision: Bool,      (required, genuine bool)
//                         iosSegmentationBackend?: String,  (optional; "auto" default = ARKit
//                                                            ARMatteGenerator engine when the
//                                                            device supports front-camera face
//                                                            tracking + person segmentation, else
//                                                            Vision Fast | "arkit" explicit ARKit
//                                                            (no Vision fallback) | "visionFast" |
//                                                            "litert" | "visionBalanced" |
//                                                            "visionAccurate" | "litertSelfie"
//                                                            (adapter path, RND);
//                                                            non-string / unknown → INVALID_ARG)
//                         iosLiveMatteRefinement?: String}  (optional; missing / null →
//                                                            "s4SoftAlphaR2", the production
//                                                            live default (S1 stages + S4 soft
//                                                            R2 refinement) | "s1" explicit
//                                                            fallback = the previous S1-only
//                                                            production path | "tightAlphaR1"
//                                                            opt-in RND candidate ("A tight
//                                                            alpha" offline A/B) |
//                                                            "s4GuidedAlphaR1" opt-in S4 R1
//                                                            guided-alpha RND live mode
//                                                            (physical comparison only);
//                                                            "s4TightAlphaR2" is lab-only and
//                                                            NOT accepted here;
//                                                            non-string / unknown → INVALID_ARG)
//                      ← {iosFastMetalPrecision, iosSegmentationBackend, iosLiveMatteRefinement}
//                        (stored for the next start)
//   replay   → {inputDir: String, outputPath: String, label?: String}
//            ← VGLiveGreenScreenReplayDiagnostics.replay result map
//   matteLab → {inputDir: String, outputDir: String, label?: String,
//               refinementMode?: String}   (optional; "s1" default = S1 base stages (lab
//                                            default, independent of the live default) |
//                                            "s4GuidedAlphaR1" | "s5GuidedFilterR1" RND
//                                            candidates on this lab route (the live mode,
//                                            s4SoftAlphaR2 by default, is selected only via
//                                            iosLiveMatteRefinement above); non-string /
//                                            unknown → INVALID_ARG. Never forwarded to
//                                            replay or any live session.)
//            ← VGLiveGreenScreenReplayDiagnostics.runMatteStageLab result map
//   Replay/lab errors: INVALID_ARG for bad args and file collisions
//   (VGLiveGreenScreenReplayError.isInvalidArgument); every other failure is
//   `replay_diagnostic_failed` so a broken diagnostic never looks like success.
//   matteStillProbe → {trackingConfiguration?: String,  (optional; "face" default |
//                                                         "world"; non-string / unknown →
//                                                         INVALID_ARG)
//                      timeoutSeconds?: Number,          (optional; default 8.0)
//                      maxFrameCount?: Int}              (optional; default 90)
//                    ← VGARKitPersonSegmentationMatteStillProbe.run result map
//                       (proofBoundary ios_arkit_person_segmentation_matte_still_physical_smoke)
//   arkitPreviewStart → {width?: Int, height?: Int,     (optional; default 1080x1920; both or
//                                                         neither; 64…4096; height >= width)
//                        targetFps?: Int,               (optional; default 30; 1…120)
//                        trackingConfiguration?: String, (optional; only "face" accepted)
//                        captureBundleOutputDir?: String, (optional; non-empty; when present
//                                                          one replay input bundle is captured
//                                                          there from the first composited
//                                                          frame; RND capture/replay harness)
//                        captureBundleLabel?: String,    (optional; non-empty; requires
//                                                          captureBundleOutputDir; default
//                                                          "arkit_live_capture")
//                        captureBundleAfterPublishedFrames?: Int} (optional; default 1; 1...10000;
//                                                          warmup frames before capture)
//                      ← {sessionId, textureId, width, height, targetFps, …} on start, or a
//                        fail-closed {pass: false, failureReason, …} map without textureId
//                        when unsupported; live_busy while one is active;
//                        composition_failed when the texture registry is missing
//   arkitPreviewStop  → {sessionId?: String}            (optional; must match when present)
//                      ← VGARKitLiveGreenScreenPreviewCoordinator.stop summary map
//                        (proofBoundary ios_arkit_person_segmentation_matte_live_physical_smoke);
//                        session_not_found when none is active
//
// All methods execute on the main thread (guaranteed by the Flutter plugin architecture).

import ARKit
import CoreGraphics
import CoreVideo
import Flutter
import Foundation
import QuartzCore

final class VGLiveGreenScreenMethodHandler {

    // MARK: - Owned routes

    private static let ownedMethods: Set<String> = [
        "startLiveGreenScreenSession",
        "updateLiveGreenScreenBackground",
        "updateLiveGreenScreenTransform",
        "stopLiveGreenScreenSession",
        "getLiveGreenScreenDiagnostics",
        "setLiveGreenScreenDiagnosticsOptions",
        "replayLiveGreenScreenInputBundle",
        "runLiveGreenScreenMatteStageLab",
        "runLiveGreenScreenARKitPersonSegmentationProbe",
        "runLiveGreenScreenARKitPersonSegmentationMatteStillProbe",
        "startLiveGreenScreenARKitPreviewProbe",
        "stopLiveGreenScreenARKitPreviewProbe",
    ]

    /// Error code for a replay / matte-lab diagnostic that failed for a reason
    /// other than bad arguments (I/O, unsupported buffer, composition failure).
    static let errorReplayDiagnosticFailed = "replay_diagnostic_failed"

    static func ownsMethod(_ method: String) -> Bool {
        return ownedMethods.contains(method)
    }

    // MARK: - Coordinator

    private let coordinator: VGLiveGreenScreenSessionCoordinator

    /// Kept separately (not only inside the coordinator) so the diagnostic-only
    /// ARKit live matte preview probe can register/unregister its own
    /// VGDuetPreviewTexture without touching VGLiveGreenScreenSessionCoordinator.
    private let textureRegistry: FlutterTextureRegistry?

    /// Diagnostic-only: the single active RND ARKit live matte preview probe
    /// (nil when none is running). Owns its own ARSession and texture; never
    /// shared with `coordinator`.
    private var activeARKitPreviewProbe: VGARKitLiveGreenScreenPreviewCoordinator?

    // MARK: - Init

    /// [textureRegistry] is passed down for preview texture allocation.
    /// [onLiveGreenScreenEvent] is passed down for `onLiveGreenScreenEvent` emission.
    init(textureRegistry: FlutterTextureRegistry? = nil,
         onLiveGreenScreenEvent: (([String: Any]) -> Void)? = nil) {
        self.textureRegistry = textureRegistry
        coordinator = VGLiveGreenScreenSessionCoordinator(
            textureRegistry: textureRegistry,
            onLiveGreenScreenEvent: onLiveGreenScreenEvent)
    }

    // MARK: - Dispatch

    func handle(method: String, args: [String: Any]?, result: @escaping FlutterResult) {
        switch method {

        case "startLiveGreenScreenSession":
            let request: VGLiveGreenScreenStartRequest
            do {
                request = try VGLiveGreenScreenMethodHandler.parseStartRequest(args)
            } catch {
                result(VGLiveGreenScreenMethodHandler.invalidArg(method: method, error: error))
                return
            }
            coordinator.startSession(request) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "updateLiveGreenScreenBackground":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let spec: VGLiveGreenScreenBackgroundSpec
            do {
                spec = try VGLiveGreenScreenMethodHandler.parseBackground(args?["background"])
            } catch {
                result(VGLiveGreenScreenMethodHandler.invalidArg(method: method, error: error))
                return
            }
            coordinator.updateBackground(sessionId: sid, background: spec) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "updateLiveGreenScreenTransform":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            // nil / malformed degrades to the full-canvas identity in the geometry.
            let transform = VGLiveGreenScreenMethodHandler.parseTransform(args?["foregroundTransform"])
            coordinator.updateTransform(sessionId: sid, transform: transform) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "stopLiveGreenScreenSession":
            // Idempotent: a missing/unknown id completes normally in the coordinator.
            let sid = args?["sessionId"] as? String ?? ""
            coordinator.stopSession(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "getLiveGreenScreenDiagnostics":
            // Diagnostic-only. Unknown id → session_not_found (not idempotent
            // like stop: the caller wants numbers for a specific session).
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.diagnostics(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "setLiveGreenScreenDiagnosticsOptions":
            // Diagnostic-only (not public Dart API). Applies to the next start;
            // the coordinator rejects it with live_busy while a session is active.
            let options: VGLiveGreenScreenDiagnosticsOptions
            do {
                options = try VGLiveGreenScreenMethodHandler.parseDiagnosticsOptions(args)
            } catch {
                result(VGLiveGreenScreenMethodHandler.invalidArg(method: method, error: error))
                return
            }
            coordinator.setDiagnosticsOptions(options) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "replayLiveGreenScreenInputBundle":
            // Diagnostic-only (not public Dart API). Offline deterministic replay of a
            // captured input bundle to one PNG; no live session involved. Runs
            // synchronously on the platform thread.
            let inputDir: String
            let outputPath: String
            let label: String
            do {
                inputDir   = try VGLiveGreenScreenMethodHandler.requireString(args, key: "inputDir")
                outputPath = try VGLiveGreenScreenMethodHandler.requireString(args, key: "outputPath")
                label      = try VGLiveGreenScreenMethodHandler.parseLabel(args, defaultValue: "replay_diagnostic")
            } catch {
                result(VGLiveGreenScreenMethodHandler.invalidArg(method: method, error: error))
                return
            }
            do {
                let value = try VGLiveGreenScreenReplayDiagnostics.replay(inputDir: inputDir,
                                                                          outputPath: outputPath,
                                                                          label: label)
                result(value)
            } catch {
                result(VGLiveGreenScreenMethodHandler.replayDiagnosticError(method: method, error: error))
            }

        case "runLiveGreenScreenMatteStageLab":
            // Diagnostic-only (not public Dart API). Offline per-stage matte PNG dump
            // for the same bundle format as replay; no live session involved. Runs
            // synchronously on the platform thread.
            let inputDir: String
            let outputDir: String
            let label: String
            let refinementMode: VGMatteRefinementPipeline.GreenScreenRefinementMode
            do {
                inputDir       = try VGLiveGreenScreenMethodHandler.requireString(args, key: "inputDir")
                outputDir      = try VGLiveGreenScreenMethodHandler.requireString(args, key: "outputDir")
                label          = try VGLiveGreenScreenMethodHandler.parseLabel(args, defaultValue: "matte_stage_lab")
                refinementMode = try VGLiveGreenScreenMethodHandler.parseRefinementMode(args?["refinementMode"])
            } catch {
                result(VGLiveGreenScreenMethodHandler.invalidArg(method: method, error: error))
                return
            }
            do {
                let value = try VGLiveGreenScreenReplayDiagnostics.runMatteStageLab(inputDir: inputDir,
                                                                                    outputDir: outputDir,
                                                                                    label: label,
                                                                                    refinementMode: refinementMode)
                result(value)
            } catch {
                result(VGLiveGreenScreenMethodHandler.replayDiagnosticError(method: method, error: error))
            }

        case "runLiveGreenScreenARKitPersonSegmentationProbe":
            // Diagnostic-only (not public Dart API). RND capability probe: starts
            // a throwaway ARSession with ARWorldTrackingConfiguration ("world",
            // default, rear camera) or ARFaceTrackingConfiguration ("face", front
            // camera) + .personSegmentation and reports capability/timing. Never
            // touches the coordinator, Vision, LiteRT, or any live compositing.
            let timeoutSeconds = VGLiveGreenScreenMethodHandler.doubleValue(args?["timeoutSeconds"]) ?? 8.0
            let maxFrameCount  = VGLiveGreenScreenMethodHandler.intValue(args?["maxFrameCount"]) ?? 90
            let trackingConfiguration: String
            do {
                trackingConfiguration = try VGLiveGreenScreenMethodHandler.parseARKitPersonSegmentationProbeTrackingConfiguration(args?["trackingConfiguration"])
            } catch {
                result(VGLiveGreenScreenMethodHandler.invalidArg(method: method, error: error))
                return
            }
            VGLiveGreenScreenMethodHandler.runARKitPersonSegmentationProbe(
                timeoutSeconds: timeoutSeconds,
                maxFrameCount: maxFrameCount,
                trackingConfiguration: trackingConfiguration
            ) { value in
                result(value)
            }

        case "runLiveGreenScreenARKitPersonSegmentationMatteStillProbe":
            // Diagnostic-only (not public Dart API). RND still-image visual proof:
            // starts a throwaway ARSession (own instance, never the coordinator's)
            // and delegates matte generation/compositing/PNG-write to
            // VGARKitPersonSegmentationMatteStillProbe. Never touches the
            // coordinator, Vision, LiteRT, or any live compositing.
            let matteStillTimeoutSeconds = VGLiveGreenScreenMethodHandler.doubleValue(args?["timeoutSeconds"]) ?? 8.0
            let matteStillMaxFrameCount  = VGLiveGreenScreenMethodHandler.intValue(args?["maxFrameCount"]) ?? 90
            let matteStillTrackingConfiguration: String
            do {
                matteStillTrackingConfiguration = try VGLiveGreenScreenMethodHandler.parseARKitPersonSegmentationMatteStillProbeTrackingConfiguration(args?["trackingConfiguration"])
            } catch {
                result(VGLiveGreenScreenMethodHandler.invalidArg(method: method, error: error))
                return
            }
            VGARKitPersonSegmentationMatteStillProbe.run(
                trackingConfiguration: matteStillTrackingConfiguration,
                timeoutSeconds: matteStillTimeoutSeconds,
                maxFrameCount: matteStillMaxFrameCount
            ) { value in
                result(value)
            }

        case "startLiveGreenScreenARKitPreviewProbe":
            // Diagnostic-only (not public Dart API). Discardable RND live ARKit
            // person-matte preview over solid teal: its own ARSession and its own
            // VGDuetPreviewTexture (front camera / "face" only). Never touches the
            // coordinator, Vision, LiteRT, or any production compositing.
            let arkitPreviewRequest: VGARKitLiveGreenScreenPreviewCoordinator.StartRequest
            do {
                arkitPreviewRequest = try VGLiveGreenScreenMethodHandler.parseARKitPreviewProbeStartRequest(args)
            } catch {
                result(VGLiveGreenScreenMethodHandler.invalidArg(method: method, error: error))
                return
            }
            if let active = activeARKitPreviewProbe {
                result(FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorLiveBusy,
                    message: "\(method): an ARKit live preview probe is already active (id '\(active.sessionId)'); stop it first.",
                    details: nil))
                return
            }
            guard let registry = textureRegistry else {
                result(FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorCompositionFailed,
                    message: "\(method): textureRegistry not available.",
                    details: nil))
                return
            }
            let probe = VGARKitLiveGreenScreenPreviewCoordinator(request: arkitPreviewRequest,
                                                                 textureRegistry: registry)
            switch probe.start() {
            case .started(let descriptor):
                activeARKitPreviewProbe = probe
                result(descriptor)
            case .failed(let failure):
                // Fail-closed map (pass=false, no textureId); nothing was
                // registered or started, so nothing is retained.
                result(failure)
            }

        case "stopLiveGreenScreenARKitPreviewProbe":
            // Diagnostic-only. Returns the probe's summary exactly once; the
            // optional sessionId must match the active probe when present.
            guard let probe = activeARKitPreviewProbe else {
                result(FlutterError(
                    code:    VGLiveGreenScreenSessionCoordinator.errorSessionNotFound,
                    message: "\(method): no ARKit live preview probe is active.",
                    details: nil))
                return
            }
            if let rawSessionId = args?["sessionId"], !(rawSessionId is NSNull) {
                guard let requestedSessionId = rawSessionId as? String else {
                    result(FlutterError(
                        code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                        message: "\(method): sessionId must be a string.",
                        details: nil))
                    return
                }
                guard requestedSessionId.isEmpty || requestedSessionId == probe.sessionId else {
                    result(FlutterError(
                        code:    VGLiveGreenScreenSessionCoordinator.errorSessionNotFound,
                        message: "\(method): sessionId '\(requestedSessionId)' does not match the active ARKit live preview probe '\(probe.sessionId)'.",
                        details: nil))
                    return
                }
            }
            let summary = probe.stop()
            activeARKitPreviewProbe = nil
            result(summary)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Teardown

    func disposeAll() {
        // The diagnostic ARKit preview probe is independent of the coordinator;
        // stop it first so its texture is unregistered before the coordinator's.
        activeARKitPreviewProbe?.dispose()
        activeARKitPreviewProbe = nil
        coordinator.disposeAll()
    }

    // MARK: - Parsing

    struct ParseError: Error {
        let message: String
    }

    static func parseStartRequest(_ args: [String: Any]?) throws -> VGLiveGreenScreenStartRequest {
        guard let args = args else {
            throw ParseError(message: "missing arguments")
        }
        guard let canvas = args["canvasSize"] as? [String: Any] else {
            throw ParseError(message: "missing required argument 'canvasSize'")
        }
        guard let width  = intValue(canvas["width"]),
              let height = intValue(canvas["height"]),
              width > 0, height > 0 else {
            throw ParseError(message: "canvasSize.width and canvasSize.height must be numbers > 0")
        }
        let background = try parseBackground(args["background"])
        let transform  = parseTransform(args["foregroundTransform"])
        return VGLiveGreenScreenStartRequest(canvasWidth: width,
                                             canvasHeight: height,
                                             background: background,
                                             foregroundTransform: transform)
    }

    /// Accepts `solidColor` and `image` only. Video (and any unknown type) is
    /// rejected: video backgrounds are not supported by the live session.
    static func parseBackground(_ raw: Any?) throws -> VGLiveGreenScreenBackgroundSpec {
        guard let dict = raw as? [String: Any] else {
            throw ParseError(message: "missing required argument 'background'")
        }
        guard let type = dict["type"] as? String else {
            throw ParseError(message: "background.type must be a string")
        }
        switch type {
        case "solidColor":
            guard let color = int64Value(dict["argbColor"]) else {
                throw ParseError(message: "background.argbColor must be a number")
            }
            return .solidColor(argb: Int32(truncatingIfNeeded: color))

        case "image":
            guard let path = dict["filePath"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ParseError(message: "background.filePath must be a non-blank string")
            }
            let scaleMode = try parseScaleMode(dict["scaleMode"])
            return .image(filePath: path, scaleMode: scaleMode)

        case "video", "videoFile":
            throw ParseError(message: "video backgrounds are not supported by the live green-screen session; use solidColor or image")

        default:
            throw ParseError(message: "background.type must be one of solidColor, image (got '\(type)')")
        }
    }

    /// Missing (nil / NSNull) defaults to `aspectFill`; any other non-string or
    /// unknown value is rejected.
    static func parseScaleMode(_ raw: Any?) throws -> VGLiveGreenScreenBackgroundScaleMode {
        guard let raw = raw, !(raw is NSNull) else { return .aspectFill }
        guard let name = raw as? String else {
            throw ParseError(message: "background.scaleMode must be a string")
        }
        switch name {
        case "aspectFill": return .aspectFill
        case "aspectFit":  return .aspectFit
        default:
            throw ParseError(message: "background.scaleMode must be one of aspectFill, aspectFit (got '\(name)')")
        }
    }

    /// Returns nil when the transform is absent or not a map (→ full-canvas
    /// identity). Missing components default like the Dart model
    /// (scale 1.0, offset 0.0, anchor 0.5); non-finite values are left for
    /// VGDuetLayoutGeometry to degrade/clamp.
    static func parseTransform(_ raw: Any?) -> NativeForegroundTransform? {
        guard let dict = raw as? [String: Any] else { return nil }
        let offset = dict["offset"] as? [String: Any]
        let anchor = dict["anchor"] as? [String: Any]
        return NativeForegroundTransform(
            scale:   cgFloatValue(dict["scale"])  ?? 1.0,
            offsetX: cgFloatValue(offset?["x"])   ?? 0.0,
            offsetY: cgFloatValue(offset?["y"])   ?? 0.0,
            anchorX: cgFloatValue(anchor?["x"])   ?? 0.5,
            anchorY: cgFloatValue(anchor?["y"])   ?? 0.5)
    }

    /// `{iosFastMetalPrecision: Bool, iosSegmentationBackend?: String,
    /// iosLiveMatteRefinement?: String}`.
    /// `iosFastMetalPrecision` is required and must be a genuine boolean (a
    /// Dart `bool`); numbers, strings, and null are rejected so an A/B run can
    /// never silently fall back to the default. `iosSegmentationBackend` is
    /// optional (missing / null → "auto": ARKit when supported, else Vision
    /// Fast) but, when present, must be a string equal to one of
    /// `segmentationBackends` ("auto" | "arkit" | the
    /// VGLiveGreenScreenSegmentationBackend* constants); any other type or
    /// value is rejected for the same reason.
    /// `iosLiveMatteRefinement` is optional (missing / null → "s4SoftAlphaR2", the
    /// production live default, VGMatteRefinementPipeline.defaultLiveMatteRefinementMode)
    /// but, when present, must be a string equal to one of
    /// VGMatteRefinementPipeline.LiveMatteRefinementMode's raw values ("s4SoftAlphaR2"
    /// default | "s1" explicit S1-only fallback | "tightAlphaR1" | "s4GuidedAlphaR1"
    /// opt-in RND live modes; "s4TightAlphaR2" is lab-only and rejected); any other
    /// type or value is rejected for the same reason.
    static func parseDiagnosticsOptions(_ args: [String: Any]?) throws -> VGLiveGreenScreenDiagnosticsOptions {
        guard let args = args else {
            throw ParseError(message: "missing arguments")
        }
        guard let fastMetal = boolValue(args["iosFastMetalPrecision"]) else {
            throw ParseError(message: "iosFastMetalPrecision must be a boolean")
        }
        var options = VGLiveGreenScreenDiagnosticsOptions.default
        options.iosFastMetalPrecision  = fastMetal
        if let rawBackend = args["iosSegmentationBackend"], !(rawBackend is NSNull) {
            options.iosSegmentationBackend = try parseSegmentationBackend(rawBackend)
        }
        if let rawLiveMatteRefinement = args["iosLiveMatteRefinement"], !(rawLiveMatteRefinement is NSNull) {
            options.iosLiveMatteRefinement = try parseLiveMatteRefinement(rawLiveMatteRefinement)
        }
        return options
    }

    /// Exact backend strings accepted for `iosSegmentationBackend` (single
    /// source of truth: the coordinator's engine selectors — "auto" (default:
    /// ARKit when supported, else Vision Fast) and "arkit" (explicit ARKit, no
    /// Vision fallback) — plus the adapter's header constants).
    static let segmentationBackends: [String] = [
        VGLiveGreenScreenSessionCoordinator.segmentationBackendAuto,
        VGLiveGreenScreenSessionCoordinator.segmentationBackendARKit,
        VGLiveGreenScreenSegmentationBackendLiteRT,
        VGLiveGreenScreenSegmentationBackendVisionFast,
        VGLiveGreenScreenSegmentationBackendVisionBalanced,
        VGLiveGreenScreenSegmentationBackendVisionAccurate,
        VGLiveGreenScreenSegmentationBackendLiteRTSelfie,
    ]

    /// Missing (nil / NSNull) defaults to `auto` (the production default:
    /// ARKit when supported, else Vision Fast); a non-string or unknown value
    /// is rejected.
    static func parseSegmentationBackend(_ raw: Any?) throws -> String {
        guard let raw = raw, !(raw is NSNull) else {
            return VGLiveGreenScreenSessionCoordinator.segmentationBackendAuto
        }
        guard let name = raw as? String else {
            throw ParseError(message: "iosSegmentationBackend must be a string")
        }
        guard segmentationBackends.contains(name) else {
            throw ParseError(message: "iosSegmentationBackend must be one of \(segmentationBackends.joined(separator: ", ")) (got '\(name)')")
        }
        return name
    }

    /// Exact strings accepted for `iosLiveMatteRefinement` (single source of truth:
    /// VGMatteRefinementPipeline.LiveMatteRefinementMode's raw values, currently "s1" |
    /// "tightAlphaR1" | "s4GuidedAlphaR1" | "s4SoftAlphaR2"; never a hand-written list;
    /// the lab-only "s4TightAlphaR2" is not a live case and is therefore rejected).
    static let liveMatteRefinementModes: [String] =
        VGMatteRefinementPipeline.LiveMatteRefinementMode.allCases.map { $0.rawValue }

    /// Missing (nil / NSNull) defaults to the production live default
    /// (`VGMatteRefinementPipeline.defaultLiveMatteRefinementMode`, "s4SoftAlphaR2");
    /// explicit "s1" selects the S1-only fallback. A non-string or unknown value is
    /// rejected so an explicit request can never silently fall back to the default.
    static func parseLiveMatteRefinement(_ raw: Any?) throws -> String {
        guard let raw = raw, !(raw is NSNull) else {
            return VGMatteRefinementPipeline.defaultLiveMatteRefinementMode.rawValue
        }
        guard let name = raw as? String else {
            throw ParseError(message: "iosLiveMatteRefinement must be a string")
        }
        guard liveMatteRefinementModes.contains(name) else {
            throw ParseError(message: "iosLiveMatteRefinement must be one of \(liveMatteRefinementModes.joined(separator: ", ")) (got '\(name)')")
        }
        return name
    }

    /// Required non-blank string argument for the replay / matte-lab routes.
    /// Missing, NSNull, non-string, or blank values are rejected so a diagnostic
    /// can never silently run against an empty path.
    static func requireString(_ args: [String: Any]?, key: String) throws -> String {
        guard let args = args else {
            throw ParseError(message: "missing arguments")
        }
        guard let raw = args[key], !(raw is NSNull) else {
            throw ParseError(message: "missing required argument '\(key)'")
        }
        guard let value = raw as? String else {
            throw ParseError(message: "'\(key)' must be a string")
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError(message: "'\(key)' must be a non-blank string")
        }
        return value
    }

    /// Optional `label` for the replay / matte-lab routes: missing / NSNull →
    /// `defaultValue`; a present non-string value is rejected.
    static func parseLabel(_ args: [String: Any]?, defaultValue: String) throws -> String {
        guard let raw = args?["label"], !(raw is NSNull) else { return defaultValue }
        guard let value = raw as? String else {
            throw ParseError(message: "'label' must be a string")
        }
        return value
    }

    /// Exact strings accepted for the matte-lab `refinementMode` argument (single
    /// source of truth: the compositor's diagnostic-only mode enum raw values).
    static let refinementModes: [String] =
        VGMatteRefinementPipeline.GreenScreenRefinementMode.allCases.map { $0.rawValue }

    /// Optional matte-lab `refinementMode`: missing / NSNull → `.s1` (the S1 base
    /// stages; this lab default is independent of the live default); a non-string or
    /// unknown value is rejected so an RND lab run can never silently fall back to S1.
    static func parseRefinementMode(_ raw: Any?) throws -> VGMatteRefinementPipeline.GreenScreenRefinementMode {
        guard let raw = raw, !(raw is NSNull) else { return .s1 }
        guard let name = raw as? String else {
            throw ParseError(message: "'refinementMode' must be a string")
        }
        guard let mode = VGMatteRefinementPipeline.GreenScreenRefinementMode(rawValue: name) else {
            throw ParseError(message: "'refinementMode' must be one of \(refinementModes.joined(separator: ", ")) (got '\(name)')")
        }
        return mode
    }

    // MARK: - Value helpers

    /// Accepts only a genuine boolean NSNumber (what the standard codec
    /// produces for a Dart `bool`); integers such as 0/1 and NSNull are rejected.
    private static func boolValue(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, !(raw is NSNull) else { return nil }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func intValue(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, !(raw is NSNull) else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return Int(value)
    }

    private static func int64Value(_ raw: Any?) -> Int64? {
        guard let number = raw as? NSNumber, !(raw is NSNull) else { return nil }
        return number.int64Value
    }

    private static func cgFloatValue(_ raw: Any?) -> CGFloat? {
        guard let number = raw as? NSNumber, !(raw is NSNull) else { return nil }
        return CGFloat(number.doubleValue)
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, !(raw is NSNull) else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return value
    }

    // MARK: - ARKit person-segmentation capability probe (diagnostic-only)

    /// Missing (nil / NSNull) defaults to `"world"` (existing rear-camera
    /// ARWorldTrackingConfiguration behavior, unchanged); a non-string or
    /// unknown value is rejected so a typo can never silently fall back to
    /// `"world"`.
    static func parseARKitPersonSegmentationProbeTrackingConfiguration(_ raw: Any?) throws -> String {
        guard let raw = raw, !(raw is NSNull) else { return "world" }
        guard let name = raw as? String else {
            throw ParseError(message: "trackingConfiguration must be a string")
        }
        guard name == "world" || name == "face" else {
            throw ParseError(message: "trackingConfiguration must be one of world, face (got '\(name)')")
        }
        return name
    }

    /// Missing (nil / NSNull) defaults to `"face"` (the physical harness's preferred
    /// front-camera configuration, matching the matte still probe's design); a
    /// non-string or unknown value is rejected so a typo can never silently fall
    /// back to `"face"`.
    static func parseARKitPersonSegmentationMatteStillProbeTrackingConfiguration(_ raw: Any?) throws -> String {
        guard let raw = raw, !(raw is NSNull) else { return "face" }
        guard let name = raw as? String else {
            throw ParseError(message: "trackingConfiguration must be a string")
        }
        guard name == "world" || name == "face" else {
            throw ParseError(message: "trackingConfiguration must be one of world, face (got '\(name)')")
        }
        return name
    }

    /// Diagnostic-only ARKit live preview probe start arguments. `width` /
    /// `height` are optional but must be given together (default 1080x1920),
    /// each 64…4096 with height >= width (portrait output only); `targetFps`
    /// is optional (default 30, 1…120); `trackingConfiguration` is optional but
    /// only "face" is accepted (front camera is the only supported path);
    /// `displayOrientationMode` (or `orientationMode`) is optional (default
    /// "leftMirrored", accepted: "leftMirrored", "right").
    /// `captureBundleOutputDir` is optional (non-empty string when present; it
    /// requests the one-shot replay-bundle capture) and `captureBundleLabel`
    /// is optional (non-empty string when present; rejected without an output
    /// dir so a label can never silently do nothing).
    static func parseARKitPreviewProbeStartRequest(_ args: [String: Any]?) throws -> VGARKitLiveGreenScreenPreviewCoordinator.StartRequest {
        let rawWidth  = args?["width"]
        let rawHeight = args?["height"]
        let hasWidth  = rawWidth  != nil && !(rawWidth  is NSNull)
        let hasHeight = rawHeight != nil && !(rawHeight is NSNull)
        var width  = 1080
        var height = 1920
        if hasWidth || hasHeight {
            guard hasWidth, hasHeight else {
                throw ParseError(message: "width and height must be given together")
            }
            guard let w = intValue(rawWidth), let h = intValue(rawHeight) else {
                throw ParseError(message: "width and height must be numbers")
            }
            guard (64...4096).contains(w), (64...4096).contains(h) else {
                throw ParseError(message: "width and height must be within 64...4096 (got \(w)x\(h))")
            }
            guard h >= w else {
                throw ParseError(message: "portrait canvas required: height must be >= width (got \(w)x\(h))")
            }
            width  = w
            height = h
        }

        var targetFps = 30
        if let rawFps = args?["targetFps"], !(rawFps is NSNull) {
            guard let fps = intValue(rawFps) else {
                throw ParseError(message: "targetFps must be a number")
            }
            guard (1...120).contains(fps) else {
                throw ParseError(message: "targetFps must be within 1...120 (got \(fps))")
            }
            targetFps = fps
        }

        if let rawTracking = args?["trackingConfiguration"], !(rawTracking is NSNull) {
            guard let name = rawTracking as? String else {
                throw ParseError(message: "trackingConfiguration must be a string")
            }
            guard name == VGARKitLiveGreenScreenPreviewCoordinator.trackingConfiguration else {
                throw ParseError(message: "trackingConfiguration must be '\(VGARKitLiveGreenScreenPreviewCoordinator.trackingConfiguration)' for the ARKit live preview probe (got '\(name)')")
            }
        }

        var rawOrientation = args?["displayOrientationMode"]
        if rawOrientation == nil || rawOrientation is NSNull {
            rawOrientation = args?["orientationMode"]
        }
        var orientationMode = VGARKitLiveGreenScreenPreviewCoordinator.defaultOrientationMode
        if let rawOrientation = rawOrientation, !(rawOrientation is NSNull) {
            guard let mode = rawOrientation as? String else {
                throw ParseError(message: "displayOrientationMode must be a string")
            }
            guard VGARKitLiveGreenScreenPreviewCoordinator.supportedOrientationModes[mode] != nil else {
                let accepted = Array(VGARKitLiveGreenScreenPreviewCoordinator.supportedOrientationModes.keys).sorted()
                throw ParseError(message: "displayOrientationMode must be one of \(accepted) (got '\(mode)')")
            }
            orientationMode = mode
        }
        guard let displayOrientation = VGARKitLiveGreenScreenPreviewCoordinator.supportedOrientationModes[orientationMode] else {
            throw ParseError(message: "unsupported displayOrientationMode '\(orientationMode)'")
        }

        var captureBundleOutputDir: String?
        if let rawCaptureDir = args?["captureBundleOutputDir"], !(rawCaptureDir is NSNull) {
            guard let dir = rawCaptureDir as? String else {
                throw ParseError(message: "captureBundleOutputDir must be a string")
            }
            let trimmedDir = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDir.isEmpty else {
                throw ParseError(message: "captureBundleOutputDir must be a non-empty string")
            }
            captureBundleOutputDir = trimmedDir
        }

        var captureBundleLabel: String?
        if let rawCaptureLabel = args?["captureBundleLabel"], !(rawCaptureLabel is NSNull) {
            guard let label = rawCaptureLabel as? String else {
                throw ParseError(message: "captureBundleLabel must be a string")
            }
            guard !label.isEmpty else {
                throw ParseError(message: "captureBundleLabel must be a non-empty string")
            }
            guard captureBundleOutputDir != nil else {
                throw ParseError(message: "captureBundleLabel requires captureBundleOutputDir")
            }
            captureBundleLabel = label
        }

        var captureBundleAfterPublishedFrames = 1
        if let rawAfterFrames = args?["captureBundleAfterPublishedFrames"], !(rawAfterFrames is NSNull) {
            guard let number = rawAfterFrames as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let frames = intValue(rawAfterFrames),
                  Double(frames) == number.doubleValue else {
                throw ParseError(message: "captureBundleAfterPublishedFrames must be an integer")
            }
            guard (1...10000).contains(frames) else {
                throw ParseError(message: "captureBundleAfterPublishedFrames must be within 1...10000 (got \(frames))")
            }
            captureBundleAfterPublishedFrames = frames
        }

        return VGARKitLiveGreenScreenPreviewCoordinator.StartRequest(
            canvasWidth: width,
            canvasHeight: height,
            targetFps: targetFps,
            displayOrientationMode: orientationMode,
            displayOrientation: displayOrientation,
            captureBundleOutputDir: captureBundleOutputDir,
            captureBundleLabel: captureBundleLabel,
            captureBundleAfterPublishedFrames: captureBundleAfterPublishedFrames)
    }

    /// Diagnostic-only (not public Dart API; RND proof boundary
    /// `ios_arkit_person_segmentation_probe_physical_smoke`). Starts a
    /// throwaway ARSession with either ARWorldTrackingConfiguration
    /// (`trackingConfiguration == "world"`, default, rear camera) or
    /// ARFaceTrackingConfiguration (`trackingConfiguration == "face"`, front
    /// camera), both with `.personSegmentation`, and collects until the
    /// first non-nil `ARFrame.segmentationBuffer`, `maxFrameCount`, or
    /// `timeoutSeconds`, whichever comes first; the session is paused on
    /// every completion, failure, or timeout path. Reports
    /// `.personSegmentationWithDepth` support for both configurations
    /// without requiring it, regardless of which one is active. Fails
    /// closed with a Dart-friendly map (never crashes) when the selected
    /// tracking configuration / person segmentation is unsupported on this
    /// device. Never touches VGLiveGreenScreenSessionCoordinator, Vision,
    /// LiteRT, production live compositing, or any public Dart API.
    static func runARKitPersonSegmentationProbe(timeoutSeconds: Double,
                                                 maxFrameCount: Int,
                                                 trackingConfiguration: String,
                                                 completion: @escaping ([String: Any]) -> Void) {
        NSLog("IOS_ARKIT_PERSON_SEGMENTATION_PROBE_START trackingConfiguration=\(trackingConfiguration) timeoutSeconds=\(timeoutSeconds) maxFrameCount=\(maxFrameCount)")

        let worldTrackingSupported = ARWorldTrackingConfiguration.isSupported
        let personSegmentationSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentation)
        let personSegmentationWithDepthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)

        let faceTrackingSupported = ARFaceTrackingConfiguration.isSupported
        let facePersonSegmentationSupported = ARFaceTrackingConfiguration.supportsFrameSemantics(.personSegmentation)
        let facePersonSegmentationWithDepthSupported = ARFaceTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)

        NSLog("IOS_ARKIT_PERSON_SEGMENTATION_PROBE_CAPABILITY trackingConfiguration=\(trackingConfiguration) worldTrackingSupported=\(worldTrackingSupported) personSegmentationSupported=\(personSegmentationSupported) personSegmentationWithDepthSupported=\(personSegmentationWithDepthSupported) faceTrackingSupported=\(faceTrackingSupported) facePersonSegmentationSupported=\(facePersonSegmentationSupported) facePersonSegmentationWithDepthSupported=\(facePersonSegmentationWithDepthSupported)")

        let activeTrackingUsesFrontCamera = trackingConfiguration == "face"
        let activeSupported: Bool
        let failureReasonIfUnsupported: String
        let configuration: ARConfiguration

        if activeTrackingUsesFrontCamera {
            activeSupported = faceTrackingSupported && facePersonSegmentationSupported
            failureReasonIfUnsupported = !faceTrackingSupported
                ? "face_tracking_unsupported"
                : "face_person_segmentation_unsupported"
            let faceConfiguration = ARFaceTrackingConfiguration()
            faceConfiguration.frameSemantics.insert(.personSegmentation)
            configuration = faceConfiguration
        } else {
            activeSupported = worldTrackingSupported && personSegmentationSupported
            failureReasonIfUnsupported = !worldTrackingSupported
                ? "world_tracking_unsupported"
                : "person_segmentation_unsupported"
            let worldConfiguration = ARWorldTrackingConfiguration()
            worldConfiguration.frameSemantics.insert(.personSegmentation)
            configuration = worldConfiguration
        }

        guard activeSupported else {
            NSLog("IOS_ARKIT_PERSON_SEGMENTATION_PROBE_STOP trackingConfiguration=\(trackingConfiguration) reason=\(failureReasonIfUnsupported)")
            NSLog("IOS_ARKIT_PERSON_SEGMENTATION_PROBE_FAIL trackingConfiguration=\(trackingConfiguration) reason=\(failureReasonIfUnsupported)")
            completion(makeARKitPersonSegmentationProbeResult(
                pass: false,
                supported: false,
                trackingConfiguration: trackingConfiguration,
                activeTrackingUsesFrontCamera: activeTrackingUsesFrontCamera,
                worldTrackingSupported: worldTrackingSupported,
                personSegmentationSupported: personSegmentationSupported,
                personSegmentationWithDepthSupported: personSegmentationWithDepthSupported,
                faceTrackingSupported: faceTrackingSupported,
                facePersonSegmentationSupported: facePersonSegmentationSupported,
                facePersonSegmentationWithDepthSupported: facePersonSegmentationWithDepthSupported,
                frameCount: 0, maskCount: 0,
                segmentationBufferWidth: 0, segmentationBufferHeight: 0, segmentationPixelFormat: 0,
                capturedImageWidth: 0, capturedImageHeight: 0,
                firstMaskLatencyMs: nil, averageFrameIntervalMs: nil,
                failureReason: failureReasonIfUnsupported))
            return
        }

        // Retained for its own lifetime by the strong `self` capture in its
        // pending timeout closure (ARSession.delegate is a weak reference).
        let probe = ARPersonSegmentationCapabilityProbe(
            configuration: configuration,
            trackingConfiguration: trackingConfiguration,
            maxFrameCount: max(1, maxFrameCount),
            timeoutSeconds: max(0.1, timeoutSeconds)
        ) { outcome in
            NSLog("IOS_ARKIT_PERSON_SEGMENTATION_PROBE_STOP trackingConfiguration=\(trackingConfiguration) frameCount=\(outcome.frameCount) maskCount=\(outcome.maskCount) failureReason=\(outcome.failureReason ?? "none")")
            NSLog(outcome.maskCount > 0
                ? "IOS_ARKIT_PERSON_SEGMENTATION_PROBE_PASS trackingConfiguration=\(trackingConfiguration)"
                : "IOS_ARKIT_PERSON_SEGMENTATION_PROBE_FAIL trackingConfiguration=\(trackingConfiguration)")
            completion(makeARKitPersonSegmentationProbeResult(
                pass: outcome.maskCount > 0,
                supported: true,
                trackingConfiguration: trackingConfiguration,
                activeTrackingUsesFrontCamera: activeTrackingUsesFrontCamera,
                worldTrackingSupported: worldTrackingSupported,
                personSegmentationSupported: personSegmentationSupported,
                personSegmentationWithDepthSupported: personSegmentationWithDepthSupported,
                faceTrackingSupported: faceTrackingSupported,
                facePersonSegmentationSupported: facePersonSegmentationSupported,
                facePersonSegmentationWithDepthSupported: facePersonSegmentationWithDepthSupported,
                frameCount: outcome.frameCount, maskCount: outcome.maskCount,
                segmentationBufferWidth: outcome.segmentationBufferWidth,
                segmentationBufferHeight: outcome.segmentationBufferHeight,
                segmentationPixelFormat: outcome.segmentationPixelFormat,
                capturedImageWidth: outcome.capturedImageWidth,
                capturedImageHeight: outcome.capturedImageHeight,
                firstMaskLatencyMs: outcome.firstMaskLatencyMs,
                averageFrameIntervalMs: outcome.averageFrameIntervalMs,
                failureReason: outcome.failureReason))
        }
        probe.start()
    }

    private static func makeARKitPersonSegmentationProbeResult(
        pass: Bool,
        supported: Bool,
        trackingConfiguration: String,
        activeTrackingUsesFrontCamera: Bool,
        worldTrackingSupported: Bool,
        personSegmentationSupported: Bool,
        personSegmentationWithDepthSupported: Bool,
        faceTrackingSupported: Bool,
        facePersonSegmentationSupported: Bool,
        facePersonSegmentationWithDepthSupported: Bool,
        frameCount: Int,
        maskCount: Int,
        segmentationBufferWidth: Int,
        segmentationBufferHeight: Int,
        segmentationPixelFormat: Int,
        capturedImageWidth: Int,
        capturedImageHeight: Int,
        firstMaskLatencyMs: Double?,
        averageFrameIntervalMs: Double?,
        failureReason: String?
    ) -> [String: Any] {
        // Claims are mode-aware: only the tracking configuration that was
        // actually started this run produced frame/mask/timing data. The
        // other one remains a static capability query only.
        let claimsAllowed: [String]
        let nonClaims: [String]
        if activeTrackingUsesFrontCamera {
            claimsAllowed = [
                "Whether this device's front-camera ARFaceTrackingConfiguration supports the .personSegmentation frame semantic (and, separately, .personSegmentationWithDepth).",
                "When supported: the first ARFrame.segmentationBuffer observed from an actual front-camera ARFaceTrackingConfiguration session, its pixel dimensions and pixel format, and coarse first-mask-latency / average-frame-interval timing.",
                "Whether this device's rear-camera ARWorldTrackingConfiguration supports the .personSegmentation and .personSegmentationWithDepth frame semantics (capability query only; not exercised in this run).",
            ]
            nonClaims = [
                "Not a production integration proof: does not exercise VGLiveGreenScreenSessionCoordinator, Vision, LiteRT, or any live green-screen compositing path.",
                "Does not validate mask visual quality, edge accuracy, or matte fidelity.",
                "Not a public Dart API; diagnostic-only RND capability probe.",
                "worldTrackingSupported / personSegmentationSupported / personSegmentationWithDepthSupported are static capability queries only in this (face) run; no ARWorldTrackingConfiguration session is started, so no rear-camera frame, mask, or timing data is collected or claimed.",
            ]
        } else {
            claimsAllowed = [
                "Whether this device's ARKit ARWorldTrackingConfiguration supports the .personSegmentation frame semantic (and, separately, .personSegmentationWithDepth).",
                "When supported: the first ARFrame.segmentationBuffer observed, its pixel dimensions and pixel format, and coarse first-mask-latency / average-frame-interval timing.",
                "Whether this device's front-camera ARFaceTrackingConfiguration supports the .personSegmentation and .personSegmentationWithDepth frame semantics (capability query only; not exercised in this run).",
            ]
            nonClaims = [
                "Not a production integration proof: does not exercise VGLiveGreenScreenSessionCoordinator, Vision, LiteRT, or any live green-screen compositing path.",
                "Does not validate mask visual quality, edge accuracy, or matte fidelity.",
                "Not a public Dart API; diagnostic-only RND capability probe.",
                "faceTrackingSupported / facePersonSegmentationSupported / facePersonSegmentationWithDepthSupported are static capability queries only in this (world) run; no ARFaceTrackingConfiguration session is ever started, so no front-camera frame, mask, or timing data is collected or claimed.",
            ]
        }
        return [
            "pass": pass,
            "proofBoundary": "ios_arkit_person_segmentation_probe_physical_smoke",
            "supported": supported,
            "trackingConfiguration": trackingConfiguration,
            "activeTrackingUsesFrontCamera": activeTrackingUsesFrontCamera,
            "worldTrackingSupported": worldTrackingSupported,
            "personSegmentationSupported": personSegmentationSupported,
            "personSegmentationWithDepthSupported": personSegmentationWithDepthSupported,
            "faceTrackingSupported": faceTrackingSupported,
            "facePersonSegmentationSupported": facePersonSegmentationSupported,
            "facePersonSegmentationWithDepthSupported": facePersonSegmentationWithDepthSupported,
            "frameCount": frameCount,
            "maskCount": maskCount,
            "segmentationBufferWidth": segmentationBufferWidth,
            "segmentationBufferHeight": segmentationBufferHeight,
            "segmentationPixelFormat": segmentationPixelFormat,
            "capturedImageWidth": capturedImageWidth,
            "capturedImageHeight": capturedImageHeight,
            "firstMaskLatencyMs": firstMaskLatencyMs.map { $0 as Any } ?? NSNull(),
            "averageFrameIntervalMs": averageFrameIntervalMs.map { $0 as Any } ?? NSNull(),
            "failureReason": failureReason.map { $0 as Any } ?? NSNull(),
            "claimsAllowed": claimsAllowed,
            "nonClaims": nonClaims,
        ]
    }

    // MARK: - Reply helpers

    private static func invalidArg(method: String, error: Error) -> FlutterError {
        let message = (error as? ParseError)?.message ?? error.localizedDescription
        return FlutterError(
            code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
            message: "\(method): \(message)",
            details: nil)
    }

    /// Maps a replay / matte-lab failure to a FlutterError: INVALID_ARG when the
    /// diagnostics helper classifies it as an argument / collision problem, else
    /// `replay_diagnostic_failed` (never a success-shaped value).
    private static func replayDiagnosticError(method: String, error: Error) -> FlutterError {
        if let replayError = error as? VGLiveGreenScreenReplayError {
            let code = replayError.isInvalidArgument
                ? VGLiveGreenScreenSessionCoordinator.errorInvalidArg
                : errorReplayDiagnosticFailed
            let description = replayError.errorDescription ?? String(describing: replayError)
            return FlutterError(code: code,
                                message: "\(method): \(description)",
                                details: nil)
        }
        return FlutterError(code: errorReplayDiagnosticFailed,
                            message: "\(method): \(error.localizedDescription)",
                            details: nil)
    }

    private func requireSessionId(args: [String: Any]?, method: String, result: @escaping FlutterResult) -> String? {
        guard let sid = args?["sessionId"] as? String, !sid.isEmpty else {
            result(FlutterError(
                code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
                message: "\(method): missing required argument 'sessionId'.",
                details: nil))
            return nil
        }
        return sid
    }

    private func reply(result: @escaping FlutterResult, value: Any?, error: FlutterError?) {
        if let err = error {
            result(err)
        } else {
            result(value)
        }
    }
}

// MARK: - ARKit person-segmentation capability probe driver (diagnostic-only)

/// Owns one throwaway ARSession for
/// `runLiveGreenScreenARKitPersonSegmentationProbe`. Not part of any live
/// green-screen session; never shared with VGLiveGreenScreenSessionCoordinator.
/// Runs whichever `ARConfiguration` (ARWorldTrackingConfiguration or
/// ARFaceTrackingConfiguration) it is handed; `trackingConfiguration` is used
/// only for NSLog markers. Collects frames until the first non-nil
/// `ARFrame.segmentationBuffer`, `maxFrameCount`, or `timeoutSeconds`, and
/// pauses the session on every completion, failure, or timeout path.
/// `completion` fires exactly once, on the main queue.
private final class ARPersonSegmentationCapabilityProbe: NSObject, ARSessionDelegate {

    struct Outcome {
        let frameCount: Int
        let maskCount: Int
        let segmentationBufferWidth: Int
        let segmentationBufferHeight: Int
        let segmentationPixelFormat: Int
        let capturedImageWidth: Int
        let capturedImageHeight: Int
        let firstMaskLatencyMs: Double?
        let averageFrameIntervalMs: Double?
        let failureReason: String?
    }

    private let session = ARSession()
    private let configuration: ARConfiguration
    private let trackingConfiguration: String
    private let maxFrameCount: Int
    private let timeoutSeconds: Double
    private let completion: (Outcome) -> Void

    private let lock = NSLock()
    private var isFinished = false
    private var frameCount = 0
    private var maskCount = 0
    private var segmentationBufferWidth = 0
    private var segmentationBufferHeight = 0
    private var segmentationPixelFormat = 0
    private var capturedImageWidth = 0
    private var capturedImageHeight = 0
    private var startTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval?
    private var frameIntervalSumMs: Double = 0
    private var frameIntervalCount = 0
    private var firstMaskLatencyMs: Double?

    init(configuration: ARConfiguration, trackingConfiguration: String, maxFrameCount: Int, timeoutSeconds: Double, completion: @escaping (Outcome) -> Void) {
        self.configuration = configuration
        self.trackingConfiguration = trackingConfiguration
        self.maxFrameCount = maxFrameCount
        self.timeoutSeconds = timeoutSeconds
        self.completion = completion
        super.init()
    }

    func start() {
        session.delegate = self
        startTime = CACurrentMediaTime()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        // Strong `self` capture keeps this probe alive for its own worst-case
        // lifetime (ARSession.delegate is a weak reference); the closure runs
        // once and is then discarded, so this does not leak.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            self.finish(failureReason: "timeout")
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lock.lock()
        guard !isFinished else {
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
        capturedImageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        capturedImageHeight = CVPixelBufferGetHeight(frame.capturedImage)

        if let mask = frame.segmentationBuffer {
            maskCount += 1
            segmentationBufferWidth = CVPixelBufferGetWidth(mask)
            segmentationBufferHeight = CVPixelBufferGetHeight(mask)
            segmentationPixelFormat = Int(CVPixelBufferGetPixelFormatType(mask))
            if firstMaskLatencyMs == nil {
                let latencyMs = (now - startTime) * 1000.0
                firstMaskLatencyMs = latencyMs
                NSLog("IOS_ARKIT_PERSON_SEGMENTATION_PROBE_FIRST_MASK trackingConfiguration=\(trackingConfiguration) latencyMs=\(latencyMs) width=\(segmentationBufferWidth) height=\(segmentationBufferHeight)")
            }
        }

        let shouldFinish = maskCount > 0 || frameCount >= maxFrameCount
        lock.unlock()

        if shouldFinish {
            finish(failureReason: maskCount > 0 ? nil : "max_frame_count_reached_without_mask")
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        finish(failureReason: "session_failed: \(error.localizedDescription)")
    }

    private func finish(failureReason: String?) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let outcome = Outcome(
            frameCount: frameCount,
            maskCount: maskCount,
            segmentationBufferWidth: segmentationBufferWidth,
            segmentationBufferHeight: segmentationBufferHeight,
            segmentationPixelFormat: segmentationPixelFormat,
            capturedImageWidth: capturedImageWidth,
            capturedImageHeight: capturedImageHeight,
            firstMaskLatencyMs: firstMaskLatencyMs,
            averageFrameIntervalMs: frameIntervalCount > 0 ? frameIntervalSumMs / Double(frameIntervalCount) : nil,
            failureReason: failureReason)
        lock.unlock()

        DispatchQueue.main.async {
            self.session.pause()
            self.completion(outcome)
        }
    }
}
