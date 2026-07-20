// VGAudioLifecycleCoordinator.swift
// Vanguard Media Engine — Audio Slice O
//
// Owns all inhibitor state, event coalescing, and lifecycle recovery ordering
// for audio interruptions, app backgrounding, and physical route changes.
//
// ── Responsibilities ─────────────────────────────────────────────────────────
//   • Persistent inhibitor flags: isInterrupted, isBackgrounded.
//   • Route-recovery coalescing: routeRecoveryPending (transient trigger).
//   • Capture-quiescence waiting: captureQuiescencePending.
//   • Lifecycle recovery generation: recoveryGeneration (stale-callback guard).
//   • Recovery sequence: forceNormalize → preview recovery → handler outcome.
//
// ── Non-responsibilities ─────────────────────────────────────────────────────
//   • Recording metadata (stop info / error) — owned by VGAudioRecordingHandler.
//   • FlutterResult mapping — owned by VGAudioRecordingHandler.
//   • AVAudioRecorder — owned by VGAudioRecordingHandler.
//   • Timeline playback policy — never calls _timelinePlay().
//   • NotificationCenter registration — owned by VGPluginLifecycleObserver.
//
// ── Threading ────────────────────────────────────────────────────────────────
//   All public methods must be called on the main thread.
//   Recovery completions fire back on the main queue (AVAudioPreviewRuntime
//   contract) so no dispatch is needed after preview recovery returns.

import Foundation
import AVFoundation

#if VG_USE_V2_GRAPH

// MARK: - VGAudioRecordingLifecycleHandling

/// Protocol through which VGAudioLifecycleCoordinator instructs the recording
/// handler to pause, quiesce, and receive lifecycle outcomes.
///
/// All methods are called on the main thread.
protocol VGAudioRecordingLifecycleHandling: AnyObject {

    /// True when a recording operation is active (starting, recording, stopping).
    var hasActiveCaptureOperation: Bool { get }

    /// Asks the handler to quiesce capture due to a lifecycle event.
    ///
    /// - Parameters:
    ///   - reason: The first termination reason for any active take.
    ///   - quiesced: No-argument closure the handler invokes on the main thread
    ///               once capture has fully stopped (recorder stop completed).
    ///               The coordinator awaits this before starting recovery.
    ///               NOTE: This closure carries no recording metadata —
    ///               metadata stays exclusively inside the handler.
    func suspendForLifecycle(
        reason:   VGAudioRecordingTerminationReason,
        quiesced: @escaping () -> Void
    )

    /// Delivers the completed lifecycle transition outcome to the handler.
    ///
    /// Called after normalization + preview recovery complete (or fail).
    /// The handler uses this to resolve any pending FlutterResult and set its
    /// final post-delivery state.
    func completeLifecycleRecovery(_ outcome: VGRecordingLifecycleTransition)
}

// MARK: - VGAudioLifecycleCoordinator

/// Coordinates all lifecycle inhibitor state, coalescing, and recovery for
/// audio interruptions, app backgrounding, and physical route changes.
final class VGAudioLifecycleCoordinator {

    // ── Injected dependencies ─────────────────────────────────────────────────

    private weak var recordingHandler: VGAudioRecordingLifecycleHandling?
    private let coordinator:   VGAudioSessionTransitionCoordinator
    private let timelineLifecycle: VGAudioTimelineLifecycle

    // ── Persistent inhibitors ─────────────────────────────────────────────────

    private var isInterrupted:  Bool = false
    private var isBackgrounded: Bool = false

    // ── Work-pending state ────────────────────────────────────────────────────

    /// True while at least one lifecycle event requires recovery that has not
    /// yet been completed.
    private var lifecycleWorkPending: Bool = false

    /// True while we are waiting for the recording handler to finish stopping
    /// its recorder (capture quiescence). Recovery cannot begin until false.
    private var captureQuiescencePending: Bool = false

    /// Set to true when a route event is pending that has not yet been consumed
    /// by a recovery cycle. Consumed unconditionally at the end of each recovery.
    private var routeRecoveryPending: Bool = false

    // ── Recovery state ────────────────────────────────────────────────────────

    /// True while preview recovery is in-flight. Prevents concurrent attempts.
    private var recoveryInFlight: Bool = false

    /// Incremented to stale any in-flight recovery completion when a new event
    /// arrives during recovery.
    private var recoveryGeneration: UInt64 = 0

    // MARK: - Init

    init(recordingHandler: VGAudioRecordingLifecycleHandling,
         coordinator: VGAudioSessionTransitionCoordinator,
         timelineLifecycle: VGAudioTimelineLifecycle) {
        self.recordingHandler  = recordingHandler
        self.coordinator       = coordinator
        self.timelineLifecycle = timelineLifecycle
    }

    // MARK: - Public event API

    /// Called by VGPluginLifecycleObserver when AVAudioSession.interruptionNotification
    /// fires with type `.began`.
    func interruptionBegan() {
        NSLog("[VGLifecycleCoordinator] interruptionBegan")
        _handleSuspensionEvent(reason: .interruption, setInterrupted: true, setBackgrounded: false)
    }

    /// Called by VGPluginLifecycleObserver when AVAudioSession.interruptionNotification
    /// fires with type `.ended`.
    func interruptionEnded() {
        NSLog("[VGLifecycleCoordinator] interruptionEnded")
        isInterrupted = false
        _attemptRecoveryIfReady()
    }

    /// Called by VGPluginLifecycleObserver on didEnterBackgroundNotification.
    func didEnterBackground() {
        NSLog("[VGLifecycleCoordinator] didEnterBackground")
        _handleSuspensionEvent(reason: .background, setInterrupted: false, setBackgrounded: true)
    }

    /// Called by VGPluginLifecycleObserver on didBecomeActiveNotification.
    func didBecomeActive() {
        NSLog("[VGLifecycleCoordinator] didBecomeActive")
        isBackgrounded = false
        _attemptRecoveryIfReady()
    }

    /// Called by VGPluginLifecycleObserver for physical route changes.
    ///
    /// Only `.oldDeviceUnavailable` and `.newDeviceAvailable` are forwarded;
    /// `.categoryChange` and other reasons are ignored at the observer level.
    func routeChanged(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            NSLog("[VGLifecycleCoordinator] routeChanged: oldDeviceUnavailable")
            _handleRouteRemoval(reason: .routeLost)

        case .newDeviceAvailable:
            NSLog("[VGLifecycleCoordinator] routeChanged: newDeviceAvailable")
            _handleRouteAddition(reason: .routeChanged)

        default:
            // All other reasons are ignored in Slice O.
            break
        }
    }

    // MARK: - Private: suspension helpers

    private func _handleSuspensionEvent(
        reason:           VGAudioRecordingTerminationReason,
        setInterrupted:   Bool,
        setBackgrounded:  Bool
    ) {
        // 1. Set the persistent inhibitor first.
        if setInterrupted  { isInterrupted  = true }
        if setBackgrounded { isBackgrounded = true }

        // 2. Mark lifecycle work pending and invalidate any in-flight recovery.
        lifecycleWorkPending = true
        recoveryGeneration += 1   // stales any in-flight preview-recovery callback

        // 3. Pause the authoritative timeline.
        timelineLifecycle.pauseTimeline()

        // 4. Ask handler to quiesce capture.
        if let handler = recordingHandler, handler.hasActiveCaptureOperation {
            captureQuiescencePending = true
            handler.suspendForLifecycle(reason: reason) { [weak self] in
                guard let self = self else { return }
                self.captureQuiescencePending = false
                // Recorder has stopped. Attempt recovery if all conditions are met.
                self._attemptRecoveryIfReady()
            }
        }
        // If no active capture, we do not set captureQuiescencePending —
        // recovery can begin as soon as inhibitors clear.
    }

    private func _handleRouteRemoval(reason: VGAudioRecordingTerminationReason) {
        // Always pause the timeline on device removal.
        timelineLifecycle.pauseTimeline()

        if let handler = recordingHandler, handler.hasActiveCaptureOperation {
            // Active capture must be quiesced before recovery.
            lifecycleWorkPending     = true
            recoveryGeneration      += 1
            captureQuiescencePending = true
            handler.suspendForLifecycle(reason: reason) { [weak self] in
                guard let self = self else { return }
                self.captureQuiescencePending = false
                self._handleRouteRecoveryTrigger()
            }
        } else {
            _handleRouteRecoveryTrigger()
        }
    }

    private func _handleRouteAddition(reason: VGAudioRecordingTerminationReason) {
        if let handler = recordingHandler, handler.hasActiveCaptureOperation {
            // Active capture: must quiesce before recovery. Pause timeline.
            timelineLifecycle.pauseTimeline()
            lifecycleWorkPending     = true
            recoveryGeneration      += 1
            captureQuiescencePending = true
            handler.suspendForLifecycle(reason: reason) { [weak self] in
                guard let self = self else { return }
                self.captureQuiescencePending = false
                self._handleRouteRecoveryTrigger()
            }
        } else {
            // No active capture — no timeline pause required; coalesce normally.
            _handleRouteRecoveryTrigger()
        }
    }

    private func _handleRouteRecoveryTrigger() {
        if isInterrupted || isBackgrounded {
            // Coalesce under an active inhibitor; consumed when inhibitors clear.
            routeRecoveryPending = true
        } else {
            // Mark work pending and invalidate any in-flight recovery so the
            // new trigger is guaranteed to produce a fresh cycle.
            lifecycleWorkPending  = true
            recoveryGeneration   += 1   // P1-1: stale any in-flight recovery
            _attemptRecoveryIfReady()
        }
    }

    // MARK: - Private: recovery

    private func _attemptRecoveryIfReady() {
        // All conditions must be met before we start recovery:
        guard lifecycleWorkPending        else { return }
        guard !captureQuiescencePending   else { return }
        guard !isInterrupted              else { return }
        guard !isBackgrounded            else { return }
        guard !recoveryInFlight           else {
            // Another lifecycle/route event will re-invoke after the stale
            // callback returns via the generation guard.
            return
        }

        recoveryInFlight = true
        let capturedGeneration = recoveryGeneration

        NSLog("[VGLifecycleCoordinator] starting lifecycle recovery (gen %llu)", capturedGeneration)

        // 1. Force Playback category — bypasses the Playback early-return.
        let normOutcome = coordinator.forceNormalizePlaybackAfterExternalChange()

        if normOutcome.status != .success {
            // Normalization failed — do not call preview recovery.
            let errCode = normOutcome.primaryError?.localizedDescription ?? "unknown"
            NSLog("[VGLifecycleCoordinator] forceNormalize failed: %@", errCode)
            recoveryInFlight     = false
            lifecycleWorkPending = false
            routeRecoveryPending = false
            recordingHandler?.completeLifecycleRecovery(
                .sessionFailed(code: "SESSION_FORCE_NORMALIZE_FAILED"))
            return
        }

        // 2. Call timeline-adapter preview recovery.
        timelineLifecycle.recoverPreview { [weak self] recoveryErr in
            guard let self = self else { return }

            // Generation guard: stale if another event arrived during recovery.
            guard self.recoveryGeneration == capturedGeneration else {
                NSLog("[VGLifecycleCoordinator] stale recovery callback (gen %llu, current %llu) — discarding",
                      capturedGeneration, self.recoveryGeneration)
                self.recoveryInFlight = false
                // Do NOT clear lifecycleWorkPending — the new event owns it.
                // Re-attempt if all conditions are now satisfied.
                self._attemptRecoveryIfReady()
                return
            }

            self.recoveryInFlight     = false
            self.lifecycleWorkPending = false
            self.routeRecoveryPending = false   // consumed

            // 3. Build outcome and complete handler.
            let transition: VGRecordingLifecycleTransition
            if let err = recoveryErr {
                NSLog("[VGLifecycleCoordinator] preview recovery failed: %@",
                      err.localizedDescription)
                transition = .previewFailed(code: "PREVIEW_RECOVERY_FAILED")
            } else {
                NSLog("[VGLifecycleCoordinator] lifecycle recovery complete")
                transition = .success
            }

            // 4. Never call _timelinePlay().
            self.recordingHandler?.completeLifecycleRecovery(transition)
        }
    }
}

#endif // VG_USE_V2_GRAPH
