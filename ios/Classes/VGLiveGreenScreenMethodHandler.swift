// VGLiveGreenScreenMethodHandler.swift
// Generic live green-screen: thin MethodChannel dispatch layer from
// VanguardMediaEnginePlugin to VGLiveGreenScreenSessionCoordinator.
//
// Owns exactly six routes:
//   startLiveGreenScreenSession, updateLiveGreenScreenBackground,
//   updateLiveGreenScreenTransform, stopLiveGreenScreenSession, and the two
//   diagnostic-only routes getLiveGreenScreenDiagnostics (physical-smoke
//   telemetry) and setLiveGreenScreenDiagnosticsOptions (RND options for the
//   next start; live_busy while a session is active). Neither diagnostic
//   route is part of the public Dart interface.
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
//                         iosSegmentationBackend?: String}  (optional; "visionFast" default |
//                                                            "litert" | "visionBalanced" |
//                                                            "visionAccurate" (RND only);
//                                                            non-string / unknown → INVALID_ARG)
//                      ← {iosFastMetalPrecision, iosSegmentationBackend}  (stored for the next start)
//
// All methods execute on the main thread (guaranteed by the Flutter plugin architecture).

import CoreGraphics
import Flutter
import Foundation

final class VGLiveGreenScreenMethodHandler {

    // MARK: - Owned routes

    private static let ownedMethods: Set<String> = [
        "startLiveGreenScreenSession",
        "updateLiveGreenScreenBackground",
        "updateLiveGreenScreenTransform",
        "stopLiveGreenScreenSession",
        "getLiveGreenScreenDiagnostics",
        "setLiveGreenScreenDiagnosticsOptions",
    ]

    static func ownsMethod(_ method: String) -> Bool {
        return ownedMethods.contains(method)
    }

    // MARK: - Coordinator

    private let coordinator: VGLiveGreenScreenSessionCoordinator

    // MARK: - Init

    /// [textureRegistry] is passed down for preview texture allocation.
    /// [onLiveGreenScreenEvent] is passed down for `onLiveGreenScreenEvent` emission.
    init(textureRegistry: FlutterTextureRegistry? = nil,
         onLiveGreenScreenEvent: (([String: Any]) -> Void)? = nil) {
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

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Teardown

    func disposeAll() {
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

    /// `{iosFastMetalPrecision: Bool, iosSegmentationBackend?: String}`.
    /// `iosFastMetalPrecision` is required and must be a genuine boolean (a
    /// Dart `bool`); numbers, strings, and null are rejected so an A/B run can
    /// never silently fall back to the default. `iosSegmentationBackend` is
    /// optional (missing / null → "visionFast") but, when present, must be a
    /// string equal to one of the VGLiveGreenScreenSegmentationBackend*
    /// constants; any other type or value is rejected for the same reason.
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
        return options
    }

    /// Exact backend strings accepted for `iosSegmentationBackend` (single
    /// source of truth: the adapter's header constants).
    static let segmentationBackends: [String] = [
        VGLiveGreenScreenSegmentationBackendLiteRT,
        VGLiveGreenScreenSegmentationBackendVisionFast,
        VGLiveGreenScreenSegmentationBackendVisionBalanced,
        VGLiveGreenScreenSegmentationBackendVisionAccurate,
        VGLiveGreenScreenSegmentationBackendLiteRTSelfie,
    ]

    /// Missing (nil / NSNull) defaults to `visionFast`; a non-string or unknown
    /// value is rejected.
    static func parseSegmentationBackend(_ raw: Any?) throws -> String {
        guard let raw = raw, !(raw is NSNull) else {
            return VGLiveGreenScreenSegmentationBackendVisionFast
        }
        guard let name = raw as? String else {
            throw ParseError(message: "iosSegmentationBackend must be a string")
        }
        guard segmentationBackends.contains(name) else {
            throw ParseError(message: "iosSegmentationBackend must be one of \(segmentationBackends.joined(separator: ", ")) (got '\(name)')")
        }
        return name
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

    // MARK: - Reply helpers

    private static func invalidArg(method: String, error: Error) -> FlutterError {
        let message = (error as? ParseError)?.message ?? error.localizedDescription
        return FlutterError(
            code:    VGLiveGreenScreenSessionCoordinator.errorInvalidArg,
            message: "\(method): \(message)",
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
