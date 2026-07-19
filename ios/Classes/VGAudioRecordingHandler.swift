// VGAudioRecordingHandler.swift
// Vanguard Media Engine — Audio Slice M
//
// Thin Swift bridge that owns MethodChannel argument parsing / marshalling for
// the two recording methods:  startAudioRecording / stopAudioRecording
//
// Design:
//   - Receives the active VanguardGraphRuntime from VanguardMediaEnginePlugin.
//   - Delegates all AVFoundation and timeline-snapshot work to VanguardAudioRecorder (ObjC).
//   - Does NOT call readTimelineStateSnapshot directly.
//   - Does NOT own AVAudioSession logic.
//   - All methods must be called on the main thread (same guarantee as handle(_:result:)).
//
// Swift/ObjC bridging notes:
//   - VanguardAudioRecorder.recording is an ObjC BOOL property exposed with
//     getter=isRecording. Swift sees it as `var isRecording: Bool { get }`.
//     It is a property, NOT a function — do not call it with ().
//   - startRecordingWithRuntime:outputPath:error: returns nullable Obj-C pointer.
//     Because the method has a trailing NSError** parameter, the Swift compiler
//     imports it as a throwing function:
//       func startRecording(withRuntime:outputPath:) throws -> VGAudioRecordingStartInfo
//     Use do/try/catch; do NOT pass &nsErr.
//   - Errors thrown from ObjC are bridged as NSError. Cast `error as NSError`
//     before accessing `.domain` / `.code`.

import Flutter

#if VG_USE_V2_GRAPH

/// Swift bridge for audio recording MethodChannel calls.
///
/// Owned by `VanguardMediaEnginePlugin` as a single retained property.
/// Instantiate once at plugin registration time.
final class VGAudioRecordingHandler {

    // ── Active recorder ───────────────────────────────────────────────────────

    /// Retained for the lifetime of an active recording.
    /// Nil when no recording is in progress.
    private var activeRecorder: VanguardAudioRecorder?

    // ── MethodChannel dispatch ────────────────────────────────────────────────

    /// Handles the `startAudioRecording` MethodChannel call.
    ///
    /// Expected args: `{ "outputPath": String }`
    ///
    /// Requires a live `runtime`; if nil, fails immediately with NO_TIMELINE.
    /// If a recording is already active, fails with ALREADY_RECORDING.
    func handleStart(args: [String: Any]?,
                     runtime: VanguardGraphRuntime?,
                     result: @escaping FlutterResult) {

        guard let runtime = runtime else {
            result(FlutterError(code: "NO_TIMELINE",
                                message: "startAudioRecording: no active timeline runtime",
                                details: nil))
            return
        }

        guard let outputPath = args?["outputPath"] as? String, !outputPath.isEmpty else {
            result(FlutterError(code: "INVALID_ARG",
                                message: "startAudioRecording: outputPath is required and must be non-empty",
                                details: nil))
            return
        }

        // Refuse if a recording is already in progress — do not silently discard user audio.
        if let existing = activeRecorder, existing.isRecording {
            result(FlutterError(code: "ALREADY_RECORDING",
                                message: "A recording is already in progress. Call stopAudioRecording before starting a new one.",
                                details: nil))
            return
        }

        let recorder = VanguardAudioRecorder()
        do {
            // ObjC nullable-with-error bridges as Swift throwing.
            let info = try recorder.startRecording(with: runtime, outputPath: outputPath)
            activeRecorder = recorder
            result([
                "filePath":              info.filePath,
                "startPTS":              info.startPTS,
                "isHeadphonesConnected": info.isHeadphonesConnected,
            ] as [String: Any])
        } catch {
            let nsErr = error as NSError
            result(FlutterError(code: "RECORDING_FAILED",
                                message: error.localizedDescription,
                                details: "\(nsErr.domain):\(nsErr.code)"))
        }
    }

    /// Handles the `stopAudioRecording` MethodChannel call.
    ///
    /// No args expected.
    func handleStop(result: @escaping FlutterResult) {

        guard let recorder = activeRecorder, recorder.isRecording else {
            result(FlutterError(code: "NOT_RECORDING",
                                message: "stopAudioRecording: no active recording",
                                details: nil))
            return
        }

        recorder.stopRecording { [weak self] info, objcErr in
            self?.activeRecorder = nil

            if let err = objcErr {
                let nsErr = err as NSError
                result(FlutterError(code: "STOP_FAILED",
                                    message: err.localizedDescription,
                                    details: "\(nsErr.domain):\(nsErr.code)"))
                return
            }

            guard let info = info else {
                result(FlutterError(code: "STOP_FAILED",
                                    message: "stopAudioRecording: recorder returned no result",
                                    details: nil))
                return
            }

            result([
                "filePath":        info.filePath,
                "startPTS":        info.startPTS,
                "durationSeconds": info.durationSeconds,
            ] as [String: Any])
        }
    }
}

#endif // VG_USE_V2_GRAPH
