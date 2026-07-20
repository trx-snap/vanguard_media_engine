// VGRecordingTerminalResult.swift
// Vanguard Media Engine — Audio Slice O
//
// Internal Flutter-independent value types that represent:
//   - the lifecycle transition outcome (session/preview restoration status);
//   - a finalized recording take that arrived via system termination;
//   - the platform-neutral termination reasons.
//
// These types must not import Flutter, own FlutterResult, or control recovery.
// They are consumed by VGAudioRecordingHandler to construct the existing
// stop-result dictionary once the take is ready to be delivered.
//
// Threading: all values are constructed and consumed on the main thread.

#if VG_USE_V2_GRAPH

// MARK: - VGAudioRecordingTerminationReason

/// Platform-neutral reason that a recording was terminated by a system event.
///
/// These raw values are the frozen contract strings inserted into the
/// transitionStatus sub-map of the stop-result dictionary and parsed by the
/// Dart VGTransitionStatus.fromMap() deserializer.
///
/// Normal user-initiated stops carry no termination reason.
enum VGAudioRecordingTerminationReason: String {
    /// An AVAudioSession interruption (phone call, Siri, alarm).
    case interruption
    /// The app entered the background.
    case background
    /// A physical audio output/input device was removed (oldDeviceUnavailable).
    case routeLost
    /// A new audio device became available during active capture (newDeviceAvailable).
    case routeChanged
}

// MARK: - VGRecordingLifecycleTransition

/// Immutable snapshot of the session-restore and preview-recovery outcome
/// produced by VGAudioLifecycleCoordinator after a lifecycle recovery cycle.
///
/// Passed from the coordinator into VGAudioRecordingHandler via
/// VGAudioRecordingLifecycleHandling.completeLifecycleRecovery(_:).
struct VGRecordingLifecycleTransition {
    let sessionRestored:  Bool
    let sessionErrorCode: String?
    let previewRecovered: Bool
    let previewErrorCode: String?

    // Convenience constructor for a fully successful transition.
    static var success: VGRecordingLifecycleTransition {
        VGRecordingLifecycleTransition(
            sessionRestored:  true,
            sessionErrorCode: nil,
            previewRecovered: true,
            previewErrorCode: nil)
    }

    // Convenience constructor when session normalization fails outright.
    static func sessionFailed(code: String) -> VGRecordingLifecycleTransition {
        VGRecordingLifecycleTransition(
            sessionRestored:  false,
            sessionErrorCode: code,
            previewRecovered: false,
            previewErrorCode: nil)
    }

    // Convenience constructor when session is restored but preview recovery fails.
    static func previewFailed(code: String) -> VGRecordingLifecycleTransition {
        VGRecordingLifecycleTransition(
            sessionRestored:  true,
            sessionErrorCode: nil,
            previewRecovered: false,
            previewErrorCode: code)
    }
}

// MARK: - VGRecordingTerminalResult

/// A finalized recording take whose result delivery has been deferred because
/// a system event (interruption, background, or route change) terminated the
/// active recording before the user called stopAudioRecording().
///
/// Owned exclusively by VGAudioRecordingHandler.
/// VGAudioLifecycleCoordinator never touches this value.
///
/// Once the lifecycle recovery cycle completes, the handler builds the
/// standard stop-result dictionary via toResultMap() and fires it through
/// the retained FlutterResult obtained on the next stopAudioRecording() call.
struct VGRecordingTerminalResult {

    // ── Recorder output ────────────────────────────────────────────────────────
    let stopInfo:          VGAudioRecordingStopInfo?
    let stopError:         Error?

    // ── System termination context ─────────────────────────────────────────────
    /// Frozen on the first system event that terminates an active take.
    /// Later overlapping events must not overwrite this.
    let terminationReason: VGAudioRecordingTerminationReason

    // ── Lifecycle outcome ──────────────────────────────────────────────────────
    /// Set once lifecycle recovery (normalization + preview) completes.
    var lifecycleTransition: VGRecordingLifecycleTransition?

    // ── Saved post-delivery state ──────────────────────────────────────────────
    /// True when session normalization succeeded (delivery state → idle).
    /// False when normalization failed (delivery state → blocked).
    var sessionWasRestored: Bool { lifecycleTransition?.sessionRestored ?? false }

    // MARK: Result map construction

    /// Constructs the same stop-result dictionary shape returned by normal user
    /// stops, extended with the optional terminationReason inside transitionStatus.
    ///
    /// Returns nil when the recorder reported a stop error (caller should
    /// surface STOP_FAILED instead) or when lifecycle recovery has not yet
    /// been received (guard against premature delivery).
    func toResultMap() -> [String: Any]? {
        guard let transition = lifecycleTransition else { return nil }
        guard stopError == nil, let info = stopInfo else { return nil }

        var transitionStatus: [String: Any] = [
            "sessionRestored":  transition.sessionRestored,
            "previewRecovered": transition.previewRecovered,
        ]
        if let code = transition.sessionErrorCode {
            transitionStatus["sessionErrorCode"] = code
        }
        if let code = transition.previewErrorCode {
            transitionStatus["previewErrorCode"] = code
        }
        // System termination reason — always present for terminal results.
        transitionStatus["terminationReason"] = terminationReason.rawValue

        return [
            "filePath":         info.filePath,
            "startPTS":         info.startPTS,
            "durationSeconds":  info.durationSeconds,
            "transitionStatus": transitionStatus,
        ]
    }

    /// Returns a STOP_FAILED error detail string when the recorder reported an
    /// error, otherwise nil.
    func stopFailedDetail() -> (message: String, details: String?)? {
        guard let err = stopError else { return nil }
        let nsErr = err as NSError
        return (err.localizedDescription, "\(nsErr.domain):\(nsErr.code)")
    }
}

#endif // VG_USE_V2_GRAPH
