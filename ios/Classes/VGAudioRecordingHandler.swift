// VGAudioRecordingHandler.swift
// Vanguard Media Engine — Audio Slice N
//
// Swift orchestrator for startAudioRecording / stopAudioRecording MethodChannel
// calls. Manages AVAudioSession transitions, preview recovery, and ObjC capture.
//
// ── Handler state machine (main-thread confined) ──────────────────────────────
//   idle      — ready to accept startAudioRecording.
//   starting  — PlayAndRecord switch + preview recovery + recorder start in
//               progress. Rejects new start (START_IN_PROGRESS) and stop
//               (START_IN_PROGRESS).
//   recording — active recording. Accepts stopAudioRecording only.
//   stopping  — stopRecording + restorePlayback + preview recovery in progress.
//               Rejects new start (STOP_IN_PROGRESS) and stop (STOP_IN_PROGRESS).
//   blocked   — coordinator state unknown. Normalization required before any
//               new start. Stop rejects with SESSION_STATE_UNKNOWN.
//
// ── State-guard priority ──────────────────────────────────────────────────────
//   State guards always come first in handleStart / handleStop so that
//   duplicate-operation error codes (START_IN_PROGRESS, ALREADY_RECORDING,
//   STOP_IN_PROGRESS) are returned consistently regardless of runtime presence
//   or argument validity.
//
// ── Start sequence ────────────────────────────────────────────────────────────
//   1. State guards (before runtime / outputPath validation).
//   2. Runtime and outputPath validation.
//   3. If blocked → _handleStartFromBlocked.
//   4. coordinator.switchToPlayAndRecord()
//   5. captureRouteSnapshot() — before preview recovery.
//   6. If inputAvailable == false: _performCleanup → NO_INPUT_AVAILABLE.
//   7. previewRecovery(handle) — injected seam.
//   8. recorder.startRecording(handle:outputPath:) — no headphonesConnected.
//   9. state = .recording; return start result map.
//
// ── Stop sequence ─────────────────────────────────────────────────────────────
//   1. State guards (before activeRecorder check).
//   2. Recorder-presence check → if absent, _performCleanup then NOT_RECORDING.
//   3. recorder.stopRecording()
//   4. _performCleanup — shared async cleanup.
//   5. Return stop result map with nested transitionStatus.
//
// ── Blocked-start behaviour ───────────────────────────────────────────────────
//   normalization failure:
//     • Do NOT call _performCleanup / restorePlayback / normalization again.
//     • Remain blocked.
//     • Best-effort preview recovery (injected seam) only.
//     • Return SESSION_STATE_UNKNOWN after that attempt.
//   normalization success:
//     • Recover preview under Playback.
//     • If recovery succeeds → continue with _performStart.
//     • If recovery fails → _performCleanup → ENGINE_RECOVERY_FAILED (no start).
//
// ── Shared cleanup (_performCleanup) ─────────────────────────────────────────
//   • restorePlayback → if failure, normalizationAttempt.
//   • Preview recovery runs AFTER the final category mutation.
//   • State set from sessionRestored: true→idle, false→blocked.
//     This means a failedUnknown that later restores cleanly finishes idle.
//   • runtime=nil: previewRecovered=false, previewErrorCode="RECOVERY_RUNTIME_NIL".
//   • result fires exactly once, directly inside the recovery completion
//     (no extra main-queue hop — recovery callbacks already fire on main).
//
// ── Result contracts ──────────────────────────────────────────────────────────
//   Start success:
//     { filePath, startPTS, isHeadphonesConnected, audioRoute: routeSnapshot.toMap() }
//
//   Stop success (even when transitionStatus shows failure):
//     { filePath, startPTS, durationSeconds,
//       transitionStatus: { sessionRestored, previewRecovered,
//                           sessionErrorCode?, previewErrorCode? } }
//
//   STOP_FAILED only when recorder stop itself fails or returns no metadata.
//
// Threading: all public methods must be called on the main thread.
//            Recovery callbacks are guaranteed to fire on the main thread.

import Flutter

#if VG_USE_V2_GRAPH

// MARK: - Testable seam protocols

// ── Runtime handle ────────────────────────────────────────────────────────────

/// Opaque handle to an active timeline runtime.
/// VanguardGraphRuntime conforms to this protocol so tests can supply a fake
/// handle without constructing a real graph runtime.
///
/// The protocol carries no methods — it is a marker that travels through the
/// handler's seam boundary. The preview-recovery closure and the recorder
/// adapter are each responsible for casting it to the concrete type they need.
@objc protocol VGRuntimeHandle: AnyObject {}

extension VanguardGraphRuntime: VGRuntimeHandle {}

// ── Recorder control ──────────────────────────────────────────────────────────

/// Controls a single recording session.
/// Production implementation wraps VanguardAudioRecorder.
/// Tests inject a stub that never touches hardware or the graph runtime.
protocol VGRecorderControl: AnyObject {
    var isRecording: Bool { get }
    /// Starts recording to outputPath using handle for PTS computation.
    /// Returns VGAudioRecordingStartInfo on success; throws on failure.
    func startRecording(handle: VGRuntimeHandle,
                        outputPath: String) throws -> VGAudioRecordingStartInfo
    /// Stops the active recording. Completion fires on main thread.
    func stopRecording(completion: @escaping (VGAudioRecordingStopInfo?, Error?) -> Void)
    /// Cancels without result. Idempotent.
    func cancelRecording()
}

// ── Recorder factory ──────────────────────────────────────────────────────────

/// Builds a VGRecorderControl for a new recording session.
/// Inject a stub in tests to avoid microphone access.
protocol VGRecorderFactory {
    func makeRecorder() -> VGRecorderControl
}

// ── Preview recovery ──────────────────────────────────────────────────────────

/// Recovers the audio preview engine after an AVAudioSession category
/// transition. Takes a VGRuntimeHandle so tests can exercise the seam
/// without a real VanguardGraphRuntime.
///
/// The closure must call completion on the main thread.
typealias VGPreviewRecovery = (
    _ handle: VGRuntimeHandle,
    _ completion: @escaping (Error?) -> Void
) -> Void

// ── Flutter error factory ─────────────────────────────────────────────────────

/// Constructs an error value to pass to a FlutterResult callback.
///
/// In production this returns a real FlutterError. In unit tests that run
/// without Flutter.framework loaded into the host process, the factory is
/// replaced with one that returns a lightweight FakeFlutterError so that
/// assertions on error codes work without depending on the Objective-C class.
///
/// The return type is Any because FlutterResult itself is typed as (Any?) -> Void.
typealias VGFlutterErrorFactory = (
    _ code: String,
    _ message: String?,
    _ details: Any?
) -> Any

// MARK: - Production conformances

// ── Production recorder adapter ───────────────────────────────────────────────

/// Production VGRecorderControl — wraps VanguardAudioRecorder.
private final class _ProductionRecorder: VGRecorderControl {
    private let recorder = VanguardAudioRecorder()

    var isRecording: Bool { recorder.isRecording }

    func startRecording(handle: VGRuntimeHandle,
                        outputPath: String) throws -> VGAudioRecordingStartInfo {
        guard let runtime = handle as? VanguardGraphRuntime else {
            // Misconfiguration: production code always passes a real runtime.
            throw NSError(
                domain: "VGRecorderErrorDomain",
                code: 8,
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

// ── Production recorder factory ───────────────────────────────────────────────

/// Production VGRecorderFactory — creates _ProductionRecorder instances.
private struct _ProductionRecorderFactory: VGRecorderFactory {
    func makeRecorder() -> VGRecorderControl { _ProductionRecorder() }
}

// ── Production preview-recovery closure ───────────────────────────────────────

/// Casts handle to VanguardGraphRuntime and forwards to the real engine.
/// Calls completion with an error on misconfiguration.
private let _productionPreviewRecovery: VGPreviewRecovery = { handle, completion in
    guard let runtime = handle as? VanguardGraphRuntime else {
        completion(NSError(
            domain: "VGRecorderErrorDomain",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey:
                "previewRecovery: handle is not a VanguardGraphRuntime"]))
        return
    }
    runtime.recoverAudioPreviewAfterSessionTransition(completion: completion)
}

// ── Production Flutter error factory ─────────────────────────────────────────

/// Production factory — returns a real FlutterError.
private let _productionFlutterErrorFactory: VGFlutterErrorFactory = { code, message, details in
    FlutterError(code: code, message: message, details: details)
}

// MARK: - VGAudioRecordingHandler

/// Swift bridge and orchestrator for audio recording MethodChannel calls.
///
/// Owned by `VanguardMediaEnginePlugin` as a single retained property.
/// Instantiate once at plugin registration time.
final class VGAudioRecordingHandler {

    // ── Handler state ─────────────────────────────────────────────────────────

    private enum HandlerState: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case blocked
    }

    private var state: HandlerState = .idle

    // ── Injected dependencies ─────────────────────────────────────────────────

    private let coordinator:         VGAudioSessionTransitionCoordinator
    private let recorderFactory:     VGRecorderFactory
    private let previewRecovery:     VGPreviewRecovery
    private let flutterErrorFactory: VGFlutterErrorFactory

    // ── Active recorder ───────────────────────────────────────────────────────

    /// Retained for the lifetime of an active recording.
    private var activeRecorder: VGRecorderControl?

    // ── Initialisers ──────────────────────────────────────────────────────────

    /// Production init — uses real AVAudioSession backend, real recorder, and
    /// real preview-recovery via VanguardGraphRuntime.
    init() {
        coordinator         = VGAudioSessionTransitionCoordinator()
        recorderFactory     = _ProductionRecorderFactory()
        previewRecovery     = _productionPreviewRecovery
        flutterErrorFactory = _productionFlutterErrorFactory
    }

    /// Test-injection init — allows fake coordinator, recorder factory,
    /// preview-recovery closure, and error factory without touching real
    /// hardware, graph runtime, or Flutter.framework.
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

    /// Handles the `startAudioRecording` MethodChannel call.
    ///
    /// Expected args: `{ "outputPath": String }`
    func handleStart(args: [String: Any]?,
                     handle: VGRuntimeHandle?,
                     result: @escaping FlutterResult) {

        // ── State guards come first — before argument validation (Req 4) ──────
        switch state {
        case .starting:
            result(flutterErrorFactory("START_IN_PROGRESS",
                                       "startAudioRecording: a start is already in progress",
                                       nil))
            return
        case .recording:
            result(flutterErrorFactory("ALREADY_RECORDING",
                                       "startAudioRecording: a recording is already active. Call stopAudioRecording first.",
                                       nil))
            return
        case .stopping:
            result(flutterErrorFactory("STOP_IN_PROGRESS",
                                       "startAudioRecording: a stop is currently in progress",
                                       nil))
            return
        case .blocked, .idle:
            break
        }

        // ── Argument validation (after state guards) ──────────────────────────

        guard let handle = handle else {
            result(flutterErrorFactory("NO_TIMELINE",
                                       "startAudioRecording: no active timeline runtime",
                                       nil))
            return
        }

        guard let outputPath = args?["outputPath"] as? String, !outputPath.isEmpty else {
            result(flutterErrorFactory("INVALID_ARG",
                                       "startAudioRecording: outputPath is required and must be non-empty",
                                       nil))
            return
        }

        // ── Route to blocked or normal start ──────────────────────────────────

        if state == .blocked {
            _handleStartFromBlocked(handle: handle,
                                    outputPath: outputPath,
                                    result: result)
            return
        }

        // state == .idle
        _performStart(handle: handle, outputPath: outputPath, result: result)
    }

    // MARK: - handleStop

    /// Handles the `stopAudioRecording` MethodChannel call.
    func handleStop(handle: VGRuntimeHandle?, result: @escaping FlutterResult) {

        // ── State guards come first (Req 4) ───────────────────────────────────
        switch state {
        case .idle:
            result(flutterErrorFactory("NOT_RECORDING",
                                       "stopAudioRecording: no recording is active",
                                       nil))
            return
        case .starting:
            result(flutterErrorFactory("START_IN_PROGRESS",
                                       "stopAudioRecording: a start is currently in progress",
                                       nil))
            return
        case .stopping:
            result(flutterErrorFactory("STOP_IN_PROGRESS",
                                       "stopAudioRecording: a stop is already in progress",
                                       nil))
            return
        case .blocked:
            result(flutterErrorFactory("SESSION_STATE_UNKNOWN",
                                       "stopAudioRecording: session state is unknown; call normalizationAttempt first",
                                       nil))
            return
        case .recording:
            break
        }

        // ── Recorder-presence check (Req 5) ───────────────────────────────────
        // State is .recording but recorder is absent or not running.
        // Run shared cleanup before returning so PlayAndRecord is not left
        // active, then surface NOT_RECORDING.
        guard let recorder = activeRecorder, recorder.isRecording else {
            NSLog("[VGAudioRecordingHandler] state=recording but recorder absent/inactive — running cleanup")
            state = .stopping
            _performCleanup(handle: handle) { [weak self] _, _, _, _ in
                guard let self = self else { return }
                self.activeRecorder = nil
                result(self.flutterErrorFactory("NOT_RECORDING",
                                                "stopAudioRecording: recorder is not active",
                                                nil))
            }
            return
        }

        state = .stopping

        recorder.stopRecording { [weak self] info, objcErr in
            guard let self = self else { return }

            // Capture stop metadata before cleanup — must survive session failures.
            let stopInfo = info
            let stopErr  = objcErr

            // Shared async cleanup: restorePlayback → recovery → state → result.
            self._performCleanup(handle: handle) { [weak self] sessionRestored, sessionErrCode,
                                                               previewRecovered, previewErrCode in
                guard let self = self else { return }

                self.activeRecorder = nil

                if let err = stopErr {
                    let nsErr = err as NSError
                    result(self.flutterErrorFactory("STOP_FAILED",
                                                    err.localizedDescription,
                                                    "\(nsErr.domain):\(nsErr.code)"))
                    return
                }

                guard let info = stopInfo else {
                    result(self.flutterErrorFactory("STOP_FAILED",
                                                    "stopAudioRecording: recorder returned no metadata",
                                                    nil))
                    return
                }

                var transitionStatus: [String: Any] = [
                    "sessionRestored":  sessionRestored,
                    "previewRecovered": previewRecovered,
                ]
                if let code = sessionErrCode { transitionStatus["sessionErrorCode"] = code }
                if let code = previewErrCode { transitionStatus["previewErrorCode"] = code }

                result([
                    "filePath":         info.filePath,
                    "startPTS":         info.startPTS,
                    "durationSeconds":  info.durationSeconds,
                    "transitionStatus": transitionStatus,
                ] as [String: Any])
            }
        }
    }

    // MARK: - Private: blocked normalisation path

    /// Handles handleStart when the handler is in the .blocked state.
    ///
    /// normalization failure:
    ///   • Do not call _performCleanup / restorePlayback / normalization again.
    ///   • Remain blocked.
    ///   • Best-effort preview recovery (injected seam) only.
    ///   • Return SESSION_STATE_UNKNOWN after that attempt.
    ///
    /// normalization success:
    ///   • state = .starting to prevent re-entry during async recovery.
    ///   • Recover preview under Playback.
    ///   • If recovery succeeds → _performStart.
    ///   • If recovery fails → _performCleanup (session is Playback) →
    ///     ENGINE_RECOVERY_FAILED.
    private func _handleStartFromBlocked(handle: VGRuntimeHandle,
                                         outputPath: String,
                                         result: @escaping FlutterResult) {
        let normOutcome = coordinator.normalizationAttempt()

        guard normOutcome.status == .success else {
            // Normalization failed — stay blocked, best-effort recovery only.
            NSLog("[VGAudioRecordingHandler] normalization failed from blocked: \(normOutcome.primaryError?.localizedDescription ?? "unknown")")
            previewRecovery(handle) { [weak self] _ in
                guard let self = self else { return }
                // state remains .blocked — do not touch it.
                result(self.flutterErrorFactory("SESSION_STATE_UNKNOWN",
                                                "startAudioRecording: session state is unknown and normalization failed",
                                                nil))
            }
            return
        }

        // Normalization succeeded — session is in Playback.
        // Recover preview before attempting a new recording.
        NSLog("[VGAudioRecordingHandler] normalization succeeded; recovering preview before re-start")
        state = .starting  // block re-entry during async recovery

        previewRecovery(handle) { [weak self] recoveryErr in
            guard let self = self else { return }

            if let err = recoveryErr {
                NSLog("[VGAudioRecordingHandler] preview recovery after normalization failed: \(err)")
                // Session is in Playback — perform cleanup and surface error.
                self._performCleanup(handle: handle) { [weak self] _, _, _, _ in
                    guard let self = self else { return }
                    result(self.flutterErrorFactory("ENGINE_RECOVERY_FAILED",
                                                    err.localizedDescription,
                                                    nil))
                }
                return
            }

            // Recovery succeeded — proceed to start.
            self._performStart(handle: handle, outputPath: outputPath, result: result)
        }
    }

    // MARK: - Private: normal start sequence

    private func _performStart(handle: VGRuntimeHandle,
                               outputPath: String,
                               result: @escaping FlutterResult) {
        state = .starting

        // Step 1: Switch AVAudioSession to PlayAndRecord.
        let sessionOutcome = coordinator.switchToPlayAndRecord()

        guard sessionOutcome.status == .success else {
            let errMsg = sessionOutcome.primaryError?.localizedDescription
                ?? "PlayAndRecord activation failed"

            switch sessionOutcome.status {
            case .failedNoMutation:
                // Nothing mutated — go idle immediately, no recovery needed.
                state = .idle
                result(flutterErrorFactory("SESSION_ACTIVATION_FAILED", errMsg, nil))
            case .failedKnownPlayback:
                // Rolled back to Playback — cleanup owns the state transition.
                _performCleanup(handle: handle) { [weak self] _, _, _, _ in
                    guard let self = self else { return }
                    result(self.flutterErrorFactory("SESSION_ACTIVATION_FAILED", errMsg, nil))
                }
            case .failedUnknown:
                // Unknown — cleanup will set .blocked via sessionRestored=false.
                // Do NOT pre-set .blocked; let cleanup own the transition so
                // a successful restore here finishes idle (Req 2).
                _performCleanup(handle: handle) { [weak self] _, _, _, _ in
                    guard let self = self else { return }
                    result(self.flutterErrorFactory("SESSION_ACTIVATION_FAILED", errMsg, nil))
                }
            case .success:
                break  // not reached
            @unknown default:
                _performCleanup(handle: handle) { [weak self] _, _, _, _ in
                    guard let self = self else { return }
                    result(self.flutterErrorFactory("SESSION_ACTIVATION_FAILED", errMsg, nil))
                }
            }
            return
        }

        // Step 2: Capture route snapshot — before preview recovery.
        let routeSnapshot = coordinator.captureRouteSnapshot()

        // Step 3: Gate on input availability.
        if !routeSnapshot.inputAvailable {
            NSLog("[VGAudioRecordingHandler] no input available after PlayAndRecord; aborting")
            _performCleanup(handle: handle) { [weak self] _, _, _, _ in
                guard let self = self else { return }
                result(self.flutterErrorFactory("NO_INPUT_AVAILABLE",
                                               "startAudioRecording: no audio input available after PlayAndRecord activation",
                                               nil))
            }
            return
        }

        // Step 4: Recover preview under PlayAndRecord.
        previewRecovery(handle) { [weak self] engineErr in
            guard let self = self else { return }

            if let err = engineErr {
                NSLog("[VGAudioRecordingHandler] preview recovery under PlayAndRecord failed: \(err)")
                self._performCleanup(handle: handle) { [weak self] _, _, _, _ in
                    guard let self = self else { return }
                    result(self.flutterErrorFactory("ENGINE_RECOVERY_FAILED",
                                                    err.localizedDescription,
                                                    nil))
                }
                return
            }

            // Step 5: Start capture.
            let recorder = self.recorderFactory.makeRecorder()
            do {
                let info = try recorder.startRecording(handle: handle, outputPath: outputPath)

                self.activeRecorder = recorder
                self.state = .recording

                let map: [String: Any] = [
                    "filePath":              info.filePath,
                    "startPTS":              info.startPTS,
                    "isHeadphonesConnected": routeSnapshot.hasHeadphoneOutput,
                    "audioRoute":            routeSnapshot.toMap(),
                ]
                result(map)

            } catch {
                let nsErr = error as NSError
                NSLog("[VGAudioRecordingHandler] recorder.startRecording failed: \(error)")
                self._performCleanup(handle: handle) { [weak self] _, _, _, _ in
                    guard let self = self else { return }
                    result(self.flutterErrorFactory("RECORDING_FAILED",
                                                    error.localizedDescription,
                                                    "\(nsErr.domain):\(nsErr.code)"))
                }
            }
        }
    }

    // MARK: - Private: shared async cleanup

    /// Shared cleanup for start-failure and stop paths.
    ///
    /// 1. coordinator.restorePlayback()
    /// 2. If restoration fails → coordinator.normalizationAttempt()
    /// 3. Preview recovery runs after the final category mutation (injected seam).
    /// 4. State set from sessionRestored:
    ///      true  → .idle  (even when the caller previously set .blocked)
    ///      false → .blocked
    ///    This ensures failedUnknown followed by a successful restore finishes idle.
    /// 5. handle=nil → previewRecovered=false, previewErrorCode="RECOVERY_RUNTIME_NIL".
    /// 6. result fires exactly once, directly inside the recovery completion.
    ///    Recovery callbacks fire on the main thread; no extra hop is needed.
    ///
    /// - Parameters:
    ///   - handle: nil is handled — previewRecovered=false, code="RECOVERY_RUNTIME_NIL".
    ///   - completion: (sessionRestored, sessionErrCode, previewRecovered, previewErrCode)
    private func _performCleanup(
        handle: VGRuntimeHandle?,
        completion: @escaping (_ sessionRestored: Bool,
                               _ sessionErrCode: String?,
                               _ previewRecovered: Bool,
                               _ previewErrCode: String?) -> Void
    ) {
        // ── Session restoration ───────────────────────────────────────────────
        let restoreOutcome = coordinator.restorePlayback()
        let sessionRestored: Bool
        let sessionErrCode: String?

        if restoreOutcome.status == .success {
            sessionRestored = true
            sessionErrCode  = nil
        } else {
            NSLog("[VGAudioRecordingHandler] restorePlayback failed: \(restoreOutcome.primaryError?.localizedDescription ?? "unknown")")
            let normOutcome = coordinator.normalizationAttempt()
            if normOutcome.status == .success {
                sessionRestored = true
                sessionErrCode  = nil
                NSLog("[VGAudioRecordingHandler] normalizationAttempt succeeded")
            } else {
                sessionRestored = false
                sessionErrCode  = "SESSION_RESTORE_FAILED"
                NSLog("[VGAudioRecordingHandler] normalizationAttempt also failed — will enter blocked")
            }
        }

        // ── State is set from sessionRestored, not from prior state (Req 2) ───
        // This is intentionally deferred into the recovery block below so
        // that the state is committed atomically with the result call.

        // ── Preview recovery (after the final category mutation) ──────────────
        guard let handle = handle else {
            // No handle — cannot recover preview.
            state = sessionRestored ? .idle : .blocked
            completion(sessionRestored, sessionErrCode, false, "RECOVERY_RUNTIME_NIL")
            return
        }

        previewRecovery(handle) { [weak self] recoveryErr in
            guard let self = self else { return }

            let previewRecovered: Bool
            let previewErrCode: String?

            if let err = recoveryErr {
                NSLog("[VGAudioRecordingHandler] preview recovery failed: \(err)")
                previewRecovered = false
                previewErrCode   = "PREVIEW_RECOVERY_FAILED"
            } else {
                previewRecovered = true
                previewErrCode   = nil
            }

            // Commit state from sessionRestored — not from self.state (Req 2).
            self.state = sessionRestored ? .idle : .blocked

            // result fires here — on the main thread, no additional hop needed.
            completion(sessionRestored, sessionErrCode, previewRecovered, previewErrCode)
        }
    }
}

#endif // VG_USE_V2_GRAPH
