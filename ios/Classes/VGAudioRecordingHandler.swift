// VGAudioRecordingHandler.swift
// Vanguard Media Engine — Audio Slice O
//
// State machine:
//   idle                — ready for startAudioRecording.
//   starting            — PlayAndRecord + preview recovery + recorder start.
//   recording           — active capture.
//   stopping            — user-initiated stop in progress.
//   suspended           — paused by a lifecycle event.
//   terminalResultPending — cached system-terminated take awaits retrieval.
//   blocked             — session state unknown; normalization required.
//
// FlutterResult ownership rule:
//   Every entry point that begins an async operation stores `result` in
//   `pendingResult` BEFORE the first async call. Every consuming path does:
//       let cb = pendingResult; pendingResult = nil; cb?(value)
//   Synchronous guard/validation returns may fire `result` directly (they
//   return before ownership is acquired).
//
// Generation scheme:
//   operationGeneration — guards start-path async recovery only.
//     Incremented: at the start of _performStart, on lifecycle preemption of
//     .starting, and on lifecycle preemption of blocked-start recovery.
//   cleanupGeneration   — guards stop cleanup preview-recovery only.
//     Incremented: when _performCleanupWithMetadata begins, on lifecycle
//     takeover of .stopping.
//   Recorder-stop callbacks are NEVER generation-guarded.
//
// Stop metadata ownership rule:
//   Stored to pendingStopInfo/pendingStopError immediately when the recorder-
//   stop callback fires, before any cleanup begins. Cleared exactly once by
//   whichever path delivers the result (normal cleanup or lifecycle takeover).
//
// Threading: all public methods on main thread; recovery callbacks on main.

import Flutter

#if VG_USE_V2_GRAPH

// MARK: - Testable seam protocols

@objc protocol VGRuntimeHandle: AnyObject {}
extension VanguardGraphRuntime: VGRuntimeHandle {}

protocol VGRecorderControl: AnyObject {
    var isRecording: Bool { get }
    func startRecording(handle: VGRuntimeHandle,
                        outputPath: String) throws -> VGAudioRecordingStartInfo
    func stopRecording(completion: @escaping (VGAudioRecordingStopInfo?, Error?) -> Void)
    func cancelRecording()
}

protocol VGRecorderFactory {
    func makeRecorder() -> VGRecorderControl
}

typealias VGPreviewRecovery = (
    _ handle: VGRuntimeHandle,
    _ completion: @escaping (Error?) -> Void
) -> Void

typealias VGFlutterErrorFactory = (
    _ code: String,
    _ message: String?,
    _ details: Any?
) -> Any

// MARK: - Production conformances

private final class _ProductionRecorder: VGRecorderControl {
    private let recorder = VanguardAudioRecorder()
    var isRecording: Bool { recorder.isRecording }

    func startRecording(handle: VGRuntimeHandle,
                        outputPath: String) throws -> VGAudioRecordingStartInfo {
        guard let runtime = handle as? VanguardGraphRuntime else {
            throw NSError(domain: "VGRecorderErrorDomain", code: 8,
                userInfo: [NSLocalizedDescriptionKey:
                    "_ProductionRecorder: handle is not a VanguardGraphRuntime"])
        }
        return try recorder.startRecording(with: runtime, outputPath: outputPath)
    }

    func stopRecording(completion: @escaping (VGAudioRecordingStopInfo?, Error?) -> Void) {
        recorder.stopRecording { info, err in completion(info, err) }
    }

    func cancelRecording() { recorder.cancelRecording() }
}

private struct _ProductionRecorderFactory: VGRecorderFactory {
    func makeRecorder() -> VGRecorderControl { _ProductionRecorder() }
}

private let _productionPreviewRecovery: VGPreviewRecovery = { handle, completion in
    guard let runtime = handle as? VanguardGraphRuntime else {
        completion(NSError(domain: "VGRecorderErrorDomain", code: 9,
            userInfo: [NSLocalizedDescriptionKey:
                "previewRecovery: handle is not a VanguardGraphRuntime"]))
        return
    }
    runtime.recoverAudioPreviewAfterSessionTransition(completion: completion)
}

private let _productionFlutterErrorFactory: VGFlutterErrorFactory = { code, message, details in
    FlutterError(code: code, message: message, details: details)
}

// MARK: - VGAudioRecordingHandler

final class VGAudioRecordingHandler {

    // ── State ────────────────────────────────────────────────────────────────

    private enum HandlerState: Equatable {
        case idle, starting, recording, stopping
        case suspended, terminalResultPending, blocked
    }
    private var state: HandlerState = .idle

    // ── Dependencies ─────────────────────────────────────────────────────────

    let coordinator:         VGAudioSessionTransitionCoordinator
    private let recorderFactory:     VGRecorderFactory
    private let previewRecovery:     VGPreviewRecovery
    let flutterErrorFactory: VGFlutterErrorFactory

    // ── Active recorder ───────────────────────────────────────────────────────

    private var activeRecorder: VGRecorderControl?

    // ── FlutterResult ownership ───────────────────────────────────────────────

    private var pendingResult:       FlutterResult?
    private var operationGeneration: UInt64 = 0   // start-path only
    private var cleanupGeneration:   UInt64 = 0   // stop-cleanup only

    // ── Lifecycle suspension ──────────────────────────────────────────────────

    private var lifecycleIsSuspended:      Bool = false
    private var capturedTerminationReason: VGAudioRecordingTerminationReason?
    private var storedQuiescenceCompletion: (() -> Void)?

    // ── Stop metadata + terminal result ──────────────────────────────────────

    private var pendingStopInfo:          VGAudioRecordingStopInfo?
    private var pendingStopError:         Error?
    private var terminalResult:           VGRecordingTerminalResult?
    private var terminalDeliveryStateIsIdle: Bool = true

    // MARK: - Init

    init(coordinator: VGAudioSessionTransitionCoordinator) {
        self.coordinator         = coordinator
        self.recorderFactory     = _ProductionRecorderFactory()
        self.previewRecovery     = _productionPreviewRecovery
        self.flutterErrorFactory = _productionFlutterErrorFactory
    }

    convenience init() {
        self.init(coordinator: VGAudioSessionTransitionCoordinator())
    }

    init(coordinator:         VGAudioSessionTransitionCoordinator,
         recorderFactory:     VGRecorderFactory,
         previewRecovery:     @escaping VGPreviewRecovery,
         flutterErrorFactory: @escaping VGFlutterErrorFactory = _productionFlutterErrorFactory) {
        self.coordinator         = coordinator
        self.recorderFactory     = recorderFactory
        self.previewRecovery     = previewRecovery
        self.flutterErrorFactory = flutterErrorFactory
    }

    // MARK: - handleStart

    func handleStart(args: [String: Any]?,
                     handle: VGRuntimeHandle?,
                     result: @escaping FlutterResult) {
        switch state {
        case .starting:
            result(flutterErrorFactory("START_IN_PROGRESS",
                "startAudioRecording: a start is already in progress", nil)); return
        case .recording:
            result(flutterErrorFactory("ALREADY_RECORDING",
                "startAudioRecording: a recording is already active.", nil)); return
        case .stopping:
            result(flutterErrorFactory("STOP_IN_PROGRESS",
                "startAudioRecording: a stop is currently in progress", nil)); return
        case .suspended:
            result(flutterErrorFactory("LIFECYCLE_SUSPENDED",
                "startAudioRecording: audio lifecycle is suspended", nil)); return
        case .terminalResultPending:
            result(flutterErrorFactory("STOP_RESULT_PENDING",
                "startAudioRecording: a previous system-terminated result has not been retrieved",
                nil)); return
        case .blocked, .idle:
            break
        }

        guard let handle = handle else {
            result(flutterErrorFactory("NO_TIMELINE",
                "startAudioRecording: no active timeline runtime", nil)); return
        }
        guard let outputPath = args?["outputPath"] as? String, !outputPath.isEmpty else {
            result(flutterErrorFactory("INVALID_ARG",
                "startAudioRecording: outputPath is required and must be non-empty", nil)); return
        }

        if state == .blocked {
            _handleStartFromBlocked(handle: handle, outputPath: outputPath, result: result)
            return
        }
        _performStart(handle: handle, outputPath: outputPath, result: result)
    }

    // MARK: - handleStop

    func handleStop(handle: VGRuntimeHandle?, result: @escaping FlutterResult) {
        switch state {
        case .idle:
            result(flutterErrorFactory("NOT_RECORDING",
                "stopAudioRecording: no recording is active", nil)); return
        case .starting:
            result(flutterErrorFactory("START_IN_PROGRESS",
                "stopAudioRecording: a start is currently in progress", nil)); return
        case .stopping:
            result(flutterErrorFactory("STOP_IN_PROGRESS",
                "stopAudioRecording: a stop is already in progress", nil)); return
        case .suspended:
            result(flutterErrorFactory("STOP_IN_PROGRESS",
                "stopAudioRecording: recording is suspended; wait for lifecycle recovery",
                nil)); return
        case .blocked:
            result(flutterErrorFactory("SESSION_STATE_UNKNOWN",
                "stopAudioRecording: session state is unknown", nil)); return
        case .terminalResultPending:
            _deliverTerminalResult(result: result); return
        case .recording:
            break
        }

        guard let recorder = activeRecorder, recorder.isRecording else {
            NSLog("[VGAudioRecordingHandler] state=recording but recorder absent — cleanup")
            state = .stopping
            pendingResult = result          // Acquire ownership before first async call.
            activeRecorder = nil            // Clear synchronously so quiescence check in
                                            // suspendForLifecycle sees nil immediately.
            cleanupGeneration += 1
            let capturedCleanupGen = cleanupGeneration
            _performCleanup(handle: handle) { [weak self] sr, _, _, _ in
                guard let self = self else { return }
                // Generation guard before any state mutation or result delivery.
                guard self.cleanupGeneration == capturedCleanupGen else { return }
                self.state = sr ? .idle : .blocked
                let cb = self.pendingResult; self.pendingResult = nil
                cb?(self.flutterErrorFactory("NOT_RECORDING",
                    "stopAudioRecording: recorder is not active", nil))
            }
            return
        }

        state = .stopping
        pendingResult = result   // ← owned before first async call

        recorder.stopRecording { [weak self] info, objcErr in
            guard let self = self else { return }
            // Always store metadata immediately — never generation-guarded.
            self.pendingStopInfo  = info
            self.pendingStopError = objcErr
            self.activeRecorder   = nil

            if self.lifecycleIsSuspended {
                // Lifecycle took over during our stop. Signal quiescence so
                // completeLifecycleRecovery can deliver via pendingResult.
                if let cb = self.storedQuiescenceCompletion {
                    self.storedQuiescenceCompletion = nil
                    cb()
                }
                return
            }
            // Normal path: run cleanup and deliver via pendingResult.
            self._performCleanupWithMetadata(handle: handle, reason: nil)
        }
    }

    // MARK: - Private: terminal result delivery

    private func _deliverTerminalResult(result: @escaping FlutterResult) {
        guard let terminal = terminalResult else {
            result(flutterErrorFactory("INTERNAL_ERROR",
                "stopAudioRecording: terminal result state is corrupt", nil)); return
        }
        terminalResult = nil
        state = terminalDeliveryStateIsIdle ? .idle : .blocked

        if let failDetail = terminal.stopFailedDetail() {
            result(flutterErrorFactory("STOP_FAILED", failDetail.message, failDetail.details))
            return
        }
        if let map = terminal.toResultMap() {
            result(map)
        } else {
            result(flutterErrorFactory("STOP_FAILED",
                "stopAudioRecording: terminal result has no metadata", nil))
        }
    }

    // MARK: - Private: blocked-start path

    private func _handleStartFromBlocked(handle: VGRuntimeHandle,
                                         outputPath: String,
                                         result: @escaping FlutterResult) {
        let normOutcome = coordinator.normalizationAttempt()

        guard normOutcome.status == .success else {
            NSLog("[VGAudioRecordingHandler] normalization failed from blocked")
            // Best-effort recovery only; state stays .blocked.
            // No ownership acquired — returns synchronously before async.
            previewRecovery(handle) { [weak self] _ in
                guard let self = self else { return }
                result(self.flutterErrorFactory("SESSION_STATE_UNKNOWN",
                    "startAudioRecording: session state is unknown and normalization failed",
                    nil))
            }
            return
        }

        NSLog("[VGAudioRecordingHandler] normalization succeeded; recovering preview")
        state = .starting
        // Acquire pendingResult ownership before the async recovery call.
        operationGeneration += 1
        let capturedGen = operationGeneration
        pendingResult = result

        previewRecovery(handle) { [weak self] recoveryErr in
            guard let self = self else { return }
            guard self.operationGeneration == capturedGen else {
                // Lifecycle preempted this blocked-start recovery.
                // pendingResult was already consumed by suspendForLifecycle.
                return
            }
            if let err = recoveryErr {
                NSLog("[VGAudioRecordingHandler] blocked-start preview recovery failed: \(err)")
                self._performCleanup(handle: handle) { [weak self] sr, _, _, _ in
                    guard let self = self else { return }
                    guard self.operationGeneration == capturedGen else { return }
                    self.state = sr ? .idle : .blocked
                    let cb = self.pendingResult; self.pendingResult = nil
                    cb?(self.flutterErrorFactory("ENGINE_RECOVERY_FAILED",
                        err.localizedDescription, nil))
                }
                return
            }
            // Recover succeeded — proceed to start. Transfer pendingResult to
            // _performStart which will immediately re-acquire ownership.
            guard let cb = self.pendingResult else {
                NSLog("[VGAudioRecordingHandler] blocked-start: pendingResult nil after gen guard")
                return
            }
            self.pendingResult = nil
            self._performStart(handle: handle, outputPath: outputPath, result: cb)
        }
    }

    // MARK: - Private: normal start

    private func _performStart(handle: VGRuntimeHandle,
                               outputPath: String,
                               result: @escaping FlutterResult) {
        state = .starting
        // Acquire ownership before the first async call.
        operationGeneration += 1
        let capturedGen = operationGeneration
        pendingResult = result

        let sessionOutcome = coordinator.switchToPlayAndRecord()
        guard sessionOutcome.status == .success else {
            let errMsg = sessionOutcome.primaryError?.localizedDescription
                ?? "PlayAndRecord activation failed"
            switch sessionOutcome.status {
            case .failedNoMutation:
                // Synchronous failure; no cleanup needed. State → .idle.
                state = .idle
                let cb = pendingResult; pendingResult = nil
                cb?(flutterErrorFactory("SESSION_ACTIVATION_FAILED", errMsg, nil))
            default:
                _performCleanup(handle: handle) { [weak self] sr, _, _, _ in
                    guard let self = self else { return }
                    guard self.operationGeneration == capturedGen else { return }
                    self.state = sr ? .idle : .blocked
                    let cb = self.pendingResult; self.pendingResult = nil
                    cb?(self.flutterErrorFactory("SESSION_ACTIVATION_FAILED", errMsg, nil))
                }
            }
            return
        }

        let routeSnapshot = coordinator.captureRouteSnapshot()
        guard routeSnapshot.inputAvailable else {
            NSLog("[VGAudioRecordingHandler] no input available after PlayAndRecord")
            _performCleanup(handle: handle) { [weak self] sr, _, _, _ in
                guard let self = self else { return }
                guard self.operationGeneration == capturedGen else { return }
                self.state = sr ? .idle : .blocked
                let cb = self.pendingResult; self.pendingResult = nil
                cb?(self.flutterErrorFactory("NO_INPUT_AVAILABLE",
                    "startAudioRecording: no audio input available", nil))
            }
            return
        }

        previewRecovery(handle) { [weak self] engineErr in
            guard let self = self else { return }
            guard self.operationGeneration == capturedGen else {
                // Lifecycle preempted this start; pendingResult already consumed.
                return
            }
            if let err = engineErr {
                NSLog("[VGAudioRecordingHandler] preview recovery under PlayAndRecord failed")
                self._performCleanup(handle: handle) { [weak self] sr, _, _, _ in
                    guard let self = self else { return }
                    guard self.operationGeneration == capturedGen else { return }
                    self.state = sr ? .idle : .blocked
                    let cb = self.pendingResult; self.pendingResult = nil
                    cb?(self.flutterErrorFactory("ENGINE_RECOVERY_FAILED",
                        err.localizedDescription, nil))
                }
                return
            }

            let recorder = self.recorderFactory.makeRecorder()
            do {
                let info = try recorder.startRecording(handle: handle, outputPath: outputPath)
                self.activeRecorder = recorder
                self.state = .recording
                let cb = self.pendingResult; self.pendingResult = nil
                cb?(["filePath":              info.filePath,
                     "startPTS":              info.startPTS,
                     "isHeadphonesConnected": routeSnapshot.hasHeadphoneOutput,
                     "audioRoute":            routeSnapshot.toMap()] as [String: Any])
            } catch {
                let nsErr = error as NSError
                self._performCleanup(handle: handle) { [weak self] sr, _, _, _ in
                    guard let self = self else { return }
                    guard self.operationGeneration == capturedGen else { return }
                    self.state = sr ? .idle : .blocked
                    let cb = self.pendingResult; self.pendingResult = nil
                    cb?(self.flutterErrorFactory("RECORDING_FAILED",
                        error.localizedDescription, "\(nsErr.domain):\(nsErr.code)"))
                }
            }
        }
    }

    // MARK: - Private: cleanup after stop metadata is cached

    /// Runs session restore + preview recovery using pre-cached pendingStopInfo/Error.
    /// Delivers via pendingResult exactly once. Clears metadata after use.
    private func _performCleanupWithMetadata(
        handle: VGRuntimeHandle?,
        reason: VGAudioRecordingTerminationReason?
    ) {
        cleanupGeneration += 1
        let capturedCleanupGen = cleanupGeneration

        _performCleanup(handle: handle) { [weak self] sr, sec, pr, pec in
            guard let self = self else { return }
            // Generation guard BEFORE any state mutation or result delivery.
            guard self.cleanupGeneration == capturedCleanupGen else { return }

            // Generation validated: commit state, consume metadata, deliver result.
            self.state = sr ? .idle : .blocked

            let stopInfo  = self.pendingStopInfo
            let stopErr   = self.pendingStopError
            self.pendingStopInfo  = nil
            self.pendingStopError = nil

            let cb = self.pendingResult; self.pendingResult = nil
            if let err = stopErr {
                let nsErr = err as NSError
                cb?(self.flutterErrorFactory("STOP_FAILED",
                    err.localizedDescription, "\(nsErr.domain):\(nsErr.code)"))
                return
            }
            guard let info = stopInfo else {
                cb?(self.flutterErrorFactory("STOP_FAILED",
                    "stopAudioRecording: recorder returned no metadata", nil))
                return
            }
            cb?(self._buildStopResultMap(info: info, sr: sr, sec: sec, pr: pr, pec: pec,
                                         reason: reason))
        }
    }

    /// Shared result-map builder for both normal-stop and lifecycle-during-stop paths.
    private func _buildStopResultMap(
        info:   VGAudioRecordingStopInfo,
        sr:     Bool, sec: String?,
        pr:     Bool, pec: String?,
        reason: VGAudioRecordingTerminationReason?
    ) -> [String: Any] {
        var ts: [String: Any] = ["sessionRestored": sr, "previewRecovered": pr]
        if let c = sec { ts["sessionErrorCode"] = c }
        if let c = pec { ts["previewErrorCode"] = c }
        if let r = reason { ts["terminationReason"] = r.rawValue }
        return ["filePath": info.filePath, "startPTS": info.startPTS,
                "durationSeconds": info.durationSeconds, "transitionStatus": ts]
    }

    // MARK: - Private: session + preview cleanup

    private func _performCleanup(
        handle: VGRuntimeHandle?,
        completion: @escaping (Bool, String?, Bool, String?) -> Void
    ) {
        let restoreOutcome = coordinator.restorePlayback()
        let sessionRestored: Bool
        let sessionErrCode:  String?

        if restoreOutcome.status == .success {
            sessionRestored = true;  sessionErrCode = nil
        } else {
            let normOutcome = coordinator.normalizationAttempt()
            if normOutcome.status == .success {
                sessionRestored = true;  sessionErrCode = nil
            } else {
                sessionRestored = false; sessionErrCode = "SESSION_RESTORE_FAILED"
            }
        }

        guard let handle = handle else {
            // No async call — caller commits state inside its completion.
            completion(sessionRestored, sessionErrCode, false, "RECOVERY_RUNTIME_NIL")
            return
        }

        previewRecovery(handle) { [weak self] err in
            guard let self = self else { return }
            // State is NOT committed here. The owning call site commits state
            // after validating its relevant generation (operation or cleanup).
            if err != nil {
                completion(sessionRestored, sessionErrCode, false, "PREVIEW_RECOVERY_FAILED")
            } else {
                completion(sessionRestored, sessionErrCode, true, nil)
            }
        }
    }
}

// MARK: - VGAudioRecordingLifecycleHandling

extension VGAudioRecordingHandler: VGAudioRecordingLifecycleHandling {

    var hasActiveCaptureOperation: Bool {
        switch state {
        case .starting, .recording, .stopping: return true
        default: return false
        }
    }

    func suspendForLifecycle(
        reason:   VGAudioRecordingTerminationReason,
        quiesced: @escaping () -> Void
    ) {
        lifecycleIsSuspended = true
        if capturedTerminationReason == nil { capturedTerminationReason = reason }

        switch state {
        case .idle, .blocked:
            quiesced()

        case .starting:
            // Stale in-flight start recovery and consume its FlutterResult.
            operationGeneration += 1
            activeRecorder?.cancelRecording()
            activeRecorder = nil
            let cb = pendingResult; pendingResult = nil
            cb?(flutterErrorFactory("RECORDING_INTERRUPTED",
                "startAudioRecording: interrupted by system event", reason.rawValue))
            state = .suspended
            quiesced()

        case .recording:
            state = .suspended
            guard let recorder = activeRecorder else { quiesced(); return }
            recorder.stopRecording { [weak self] info, err in
                guard let self = self else { return }
                self.pendingStopInfo  = info
                self.pendingStopError = err
                self.activeRecorder   = nil
                quiesced()
            }

        case .stopping:
            // Don't stop recorder again. Stale the cleanup callback.
            cleanupGeneration += 1
            storedQuiescenceCompletion = quiesced
            // If recorder already finished, signal immediately.
            if activeRecorder == nil {
                let cb = storedQuiescenceCompletion
                storedQuiescenceCompletion = nil
                cb?()
            }

        case .suspended, .terminalResultPending:
            quiesced()
        }
    }

    func completeLifecycleRecovery(_ outcome: VGRecordingLifecycleTransition) {
        lifecycleIsSuspended      = false
        let reason                = capturedTerminationReason
        capturedTerminationReason = nil

        switch state {
        case .suspended:
            let hadRecording = (pendingStopInfo != nil || pendingStopError != nil)
            if hadRecording {
                let terminal = VGRecordingTerminalResult(
                    stopInfo:            pendingStopInfo,
                    stopError:           pendingStopError,
                    terminationReason:   reason ?? .interruption,
                    lifecycleTransition: outcome)
                pendingStopInfo  = nil
                pendingStopError = nil
                terminalResult   = terminal
                terminalDeliveryStateIsIdle = outcome.sessionRestored
                state = .terminalResultPending
            } else {
                state = outcome.sessionRestored ? .idle : .blocked
            }

        case .stopping:
            // Lifecycle arrived during user stop. Deliver via original pendingResult.
            let stopInfo = pendingStopInfo
            let stopErr  = pendingStopError
            pendingStopInfo  = nil
            pendingStopError = nil
            state = outcome.sessionRestored ? .idle : .blocked
            let cb = pendingResult; pendingResult = nil

            if let err = stopErr {
                let nsErr = err as NSError
                cb?(flutterErrorFactory("STOP_FAILED", err.localizedDescription,
                                        "\(nsErr.domain):\(nsErr.code)"))
                return
            }
            guard let info = stopInfo else {
                cb?(flutterErrorFactory("STOP_FAILED",
                    "stopAudioRecording: recorder returned no metadata after lifecycle event",
                    nil)); return
            }
            // terminationReason deliberately omitted: user initiated the stop.
            cb?(_buildStopResultMap(info: info,
                sr: outcome.sessionRestored, sec: outcome.sessionErrorCode,
                pr: outcome.previewRecovered, pec: outcome.previewErrorCode,
                reason: nil))

        default:
            NSLog("[VGAudioRecordingHandler] completeLifecycleRecovery unexpected state: \(state)")
            state = outcome.sessionRestored ? .idle : .blocked
        }
    }
}

#endif // VG_USE_V2_GRAPH
