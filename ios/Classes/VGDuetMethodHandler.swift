// VGDuetMethodHandler.swift
// VG-DUET-SLICE-2/4A: Thin dispatch layer from VanguardMediaEnginePlugin to VGDuetNativeSessionCoordinator.
//
// Owns the 12 MethodChannel route names for Duet (10 original + 2 Slice 4A texture routes).
// Plugin is a thin router only — all session logic lives in VGDuetNativeSessionCoordinator.

import Flutter
import Foundation

/// Thin dispatch handler for all Duet MethodChannel routes.
/// Plugin owns one instance and calls `handle` for routes `ownsMethod` returns true for.
/// All methods execute on the main thread (guaranteed by Flutter plugin architecture).
final class VGDuetMethodHandler {

    // MARK: - Owned routes

    private static let ownedMethods: Set<String> = [
        "initializeDuetSession",
        "updateDuetLayout",
        "setDuetRecordingSpeed",
        "setDuetAudioMixGains",
        "startDuetRecording",
        "pauseDuetRecording",
        "resumeDuetRecording",
        "deleteLastDuetSegment",
        "stopDuetRecording",
        "disposeDuetSession",
        // Slice 4A: preview texture lifecycle
        "attachDuetPreviewTexture",
        "detachDuetPreviewTexture",
        // Diagnostic-only: deterministic CoreImage matte-blend pixel proof.
        "runIosDuetPixelProof",
    ]

    static func ownsMethod(_ method: String) -> Bool {
        return ownedMethods.contains(method)
    }

    // MARK: - Coordinator

    private let coordinator: VGDuetNativeSessionCoordinator

    // MARK: - Init

    /// Designated initializer.
    /// [textureRegistry] is passed down to the coordinator for Slice 4A texture allocation.
    /// [onDuetEvent] is passed down to the coordinator for `onDuetEvent` emission.
    init(textureRegistry: FlutterTextureRegistry? = nil,
         onDuetEvent: (([String: Any]) -> Void)? = nil) {
        coordinator = VGDuetNativeSessionCoordinator(textureRegistry: textureRegistry, onDuetEvent: onDuetEvent)
    }

    // MARK: - Dispatch

    func handle(method: String, args: [String: Any]?, result: @escaping FlutterResult) {
        switch method {

        case "initializeDuetSession":
            handleInitialize(args: args, result: result)

        case "updateDuetLayout":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let layoutMap = args?["layoutConfig"] as? [String: Any] ?? [:]
            coordinator.updateLayout(sessionId: sid, layoutConfigMap: layoutMap) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "setDuetRecordingSpeed":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let speed = (args?["speed"] as? NSNumber)?.doubleValue ?? 1.0
            coordinator.setRecordingSpeed(sessionId: sid, speed: speed) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "setDuetAudioMixGains":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let sourceGain = (args?["sourceGain"] as? NSNumber)?.doubleValue ?? 1.0
            let micGain    = (args?["micGain"]    as? NSNumber)?.doubleValue ?? 1.0
            coordinator.setAudioMixGains(sessionId: sid, sourceGain: sourceGain, micGain: micGain) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "startDuetRecording":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.startRecording(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "pauseDuetRecording":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.pauseRecording(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "resumeDuetRecording":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.resumeRecording(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "deleteLastDuetSegment":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.deleteLastSegment(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "stopDuetRecording":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.stopRecording(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "disposeDuetSession":
            let sid = args?["sessionId"] as? String ?? ""
            coordinator.disposeSession(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        // ── Slice 4A: preview texture ─────────────────────────────────────────

        case "attachDuetPreviewTexture":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            let canvasSizeMap = args?["canvasSize"] as? [String: Any]
                ?? ["width": 1080.0, "height": 1920.0]
            let layoutConfigMap = args?["layoutConfig"] as? [String: Any]
            coordinator.attachPreviewTexture(
                sessionId:       sid,
                canvasSize:      canvasSizeMap,
                layoutConfigMap: layoutConfigMap
            ) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        case "detachDuetPreviewTexture":
            guard let sid = requireSessionId(args: args, method: method, result: result) else { return }
            coordinator.detachPreviewTexture(sessionId: sid) { val, err in
                self.reply(result: result, value: val, error: err)
            }

        // ── Diagnostic-only: deterministic CoreImage matte-blend pixel proof ──────
        // Simulator-safe; synthetic buffers only. Never throws — always replies with
        // a fail-shaped map on any internal failure. See
        // VGDuetPreviewCompositor.runDeterministicPixelProof().
        case "runIosDuetPixelProof":
            result(VGDuetPreviewCompositor.runDeterministicPixelProof())

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Teardown

    func disposeAll() {
        coordinator.disposeAll()
    }

    // MARK: - Helpers

    private func handleInitialize(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let sourceRaw  = args?["source"] as? [String: Any],
              let trimRaw    = args?["trimWindow"] as? [String: Any] else {
            result(FlutterError(
                code:    "source_invalid",
                message: "initializeDuetSession: missing required arguments 'source' and/or 'trimWindow'.",
                details: nil))
            return
        }

        let layoutMap   = args?["layoutConfig"] as? [String: Any] ?? ["mode": "pip"]
        let speed       = (args?["speed"]       as? NSNumber)?.doubleValue ?? 1.0
        let sourceGain  = (args?["sourceGain"]  as? NSNumber)?.doubleValue ?? 1.0
        let micGain     = (args?["micGain"]     as? NSNumber)?.doubleValue ?? 1.0

        coordinator.initializeSession(
            sourceMap:       sourceRaw,
            trimWindowMap:   trimRaw,
            layoutConfigMap: layoutMap,
            speed:           speed,
            sourceGain:      sourceGain,
            micGain:         micGain
        ) { sessionId, error in
            if let err = error {
                result(err)
            } else {
                result(sessionId)
            }
        }
    }

    private func requireSessionId(args: [String: Any]?, method: String, result: @escaping FlutterResult) -> String? {
        guard let sid = args?["sessionId"] as? String, !sid.isEmpty else {
            result(FlutterError(
                code:    "source_invalid",
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
