package com.connects.vanguard_media_engine.duet

import android.util.Log
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import java.util.concurrent.atomic.AtomicBoolean

// -----------------------------------------------------------------------------
// VG-DUET-GREEN-SCREEN: Single CameraX ImageAnalysis.Analyzer facade that owns
// the segmentation backend ladder for the Duet preview.
// -----------------------------------------------------------------------------
//
// Responsibilities — strictly bounded:
//   - Is the ONE analyzer bound to CameraX. Backends are swapped underneath it;
//     CameraX is never rebound on degradation and no second analyzer exists.
//   - Ladder: mediapipe_cpu -> mlkit -> none (safe PiP), driven by
//     AndroidDuetSegmentationBackendSelector. Movement is one-way and latched:
//       * MediaPipe failure (init or runtime) closes MediaPipe, opens ML Kit and
//         emits exactly one [onDegraded] (non-terminal; green screen stays live).
//       * ML Kit failure (init or runtime) closes ML Kit and emits [onFallback]
//         (terminal; the coordinator applies safe PiP).
//   - Backends open lazily on the analysis thread at the first frame, so model
//     loading never blocks the main thread or the preview/compositor.
//   - Single-in-flight gate + drop-stale: at most one frame is being segmented;
//     extra frames are closed immediately.
//   - Every ImageProxy closes on every path (success / skipped / failure /
//     drop / not running / backend missing / synchronous throw).
//   - Timestamps come from ImageInfo.timestamp (camera clock, ns -> ms) and
//     are forced strictly increasing across the adapter's lifetime.
//   - Idempotent start/stop; stop closes the active AND any fallback backend.
//   - No EventChannel wiring; no ML on the render thread.
//
// Threading:
//   - start/stop are called on the main thread.
//   - analyze() runs on the CameraX analysis executor (dedicated single thread).
//   - MediaPipe completes synchronously on the analysis thread; ML Kit
//     completes on the main thread (Task listeners). Both funnel through
//     [finishFrame], which is guarded so a frame finishes exactly once.
//   - Backend transitions are serialised by [backendLock]. Callbacks
//     ([onDegraded]/[onFallback]) are invoked outside the lock.

class AndroidDuetGreenScreenAdapter(
    private val selector: AndroidDuetSegmentationBackendSelector,
    /**
     * Rung to start on. Defaults to the selector's primary; the coordinator
     * passes the session-latched rung after a prior degradation so the ladder
     * never climbs back up within one session.
     */
    initialBackendId: String = selector.primaryBackendId(),
    /** Called with each owned mask frame. May fire off main thread. */
    private val onMask: (AndroidDuetSegmentationFrame) -> Unit,
    /**
     * Non-terminal degradation: [previousBackend] -> [currentBackend] with green
     * screen still live on [currentBackend]. Fires at most once per adapter.
     * May fire off main thread.
     */
    private val onDegraded: (
        previousBackend: String,
        currentBackend: String,
        reason: String,
        userMessage: String,
    ) -> Unit,
    /**
     * Terminal fallback: [previousBackend] -> [currentBackend] (`none`); the
     * ladder is exhausted and the coordinator must apply safe PiP. Fires at
     * most once per adapter. May fire off main thread.
     */
    private val onFallback: (
        previousBackend: String,
        currentBackend: String,
        reason: String,
        userMessage: String,
    ) -> Unit,
) : ImageAnalysis.Analyzer {

    companion object {
        private const val TAG = "DuetGreenScreenAdapter"

        private const val DEGRADED_USER_MESSAGE =
            "Green screen switched to the compatibility segmenter (ML Kit); edge quality may be reduced."
        private const val FALLBACK_USER_MESSAGE =
            "Green screen segmentation is unavailable on this device. Falling back to Picture-in-Picture."
    }

    // ── Run / frame gates ──────────────────────────────────────────────────────

    private val isRunning = AtomicBoolean(false)
    private val inFlight  = AtomicBoolean(false)

    /** Latched once the ladder is exhausted (terminal fallback emitted or pending). */
    private val terminal = AtomicBoolean(false)

    /** Latched once the adapter moved off its initial rung (one-way). */
    private val degraded = AtomicBoolean(false)

    // ── Backend state (guarded by backendLock) ────────────────────────────────

    private val backendLock = Any()
    private var activeBackend:   AndroidDuetSegmentationBackend? = null
    private var primaryBackend:  AndroidDuetSegmentationBackend? = null
    private var fallbackBackend: AndroidDuetSegmentationBackend? = null

    /** Rung the next lazy open() will try (guarded by backendLock). */
    private var plannedBackendId: String = initialBackendId

    @Volatile private var _currentBackendId: String = initialBackendId

    /** Analysis-thread-only monotonic timestamp guard (ms, camera clock). */
    private var lastTimestampMs = Long.MIN_VALUE

    /** Single owned temporal smoother between backend output and compositor upload. */
    private val temporalSmoother = AndroidDuetMaskTemporalSmoother()

    // ── Public API ─────────────────────────────────────────────────────────────

    /**
     * Backend the adapter is currently on (or will open on the first frame):
     * `mediapipe_cpu`, `mlkit`, or `none` after terminal fallback.
     */
    val currentBackendId: String get() = _currentBackendId

    /** True once the adapter has moved down the ladder at least once. */
    val isDegraded: Boolean get() = degraded.get()

    /** True once the ladder is exhausted (no live segmentation backend). */
    val isTerminal: Boolean get() = terminal.get()

    /**
     * Arms the analyzer. Backends are opened lazily on the analysis thread at
     * the first frame. Idempotent: if already running, logs and returns.
     */
    fun start() {
        if (!isRunning.compareAndSet(false, true)) {
            Log.w(TAG, "start() called while already running — ignored")
            return
        }
        Log.d(TAG, "start() — armed; ladder starts at ${_currentBackendId} " +
            "(selector primary=${selector.primaryBackendId()})")
    }

    /**
     * Disarms the analyzer and closes the active and any fallback backend.
     * Idempotent: if not running, logs and returns. Safe to call while a frame
     * is in flight — that frame's completion still closes its ImageProxy.
     */
    fun stop() {
        if (!isRunning.compareAndSet(true, false)) {
            Log.d(TAG, "stop() called while not running — ignored")
            return
        }
        closeAllBackends()
        temporalSmoother.reset()
        Log.d(TAG, "stop() — backends closed")
    }

    // ── ImageAnalysis.Analyzer ─────────────────────────────────────────────────

    override fun analyze(proxy: ImageProxy) {
        // Drop stale: if a previous frame is still in flight, close and skip.
        if (!inFlight.compareAndSet(false, true)) {
            Log.v(TAG, "analyze(): frame dropped (previous still in flight)")
            proxy.close()
            return
        }

        if (!isRunning.get() || terminal.get()) {
            inFlight.set(false)
            proxy.close()
            return
        }

        val backend = ensureActiveBackend()
        if (backend == null) {
            inFlight.set(false)
            proxy.close()
            return
        }

        val timestampMs = monotonicTimestampMs(proxy)
        val closer = FrameCloser(proxy)
        try {
            backend.segment(proxy, timestampMs) { outcome ->
                finishFrame(backend, outcome, closer)
            }
        } catch (t: Throwable) {
            finishFrame(
                backend,
                DuetSegmentationOutcome.Failure(
                    DuetSegmentationFailureReason.segmentThrew(backend.backendId),
                    "${backend.backendId}.segment() threw: ${t.javaClass.simpleName}: ${t.message}",
                    t,
                ),
                closer,
            )
        }
    }

    // ── Frame completion ───────────────────────────────────────────────────────

    /**
     * Guarantees one ImageProxy.close() and one in-flight release per frame,
     * regardless of how many times (or from which thread) completion fires.
     */
    private inner class FrameCloser(private val proxy: ImageProxy) {
        private val done = AtomicBoolean(false)

        fun finish(block: () -> Unit) {
            if (!done.compareAndSet(false, true)) return
            try {
                block()
            } finally {
                try { proxy.close() } catch (t: Throwable) {
                    Log.w(TAG, "ImageProxy.close() threw: ${t.message}")
                }
                inFlight.set(false)
            }
        }
    }

    private fun finishFrame(
        backend: AndroidDuetSegmentationBackend,
        outcome: DuetSegmentationOutcome,
        closer: FrameCloser,
    ) {
        closer.finish {
            when (outcome) {
                is DuetSegmentationOutcome.Mask -> {
                    if (isRunning.get() && !terminal.get()) {
                        try { onMask(temporalSmoother.smooth(outcome.frame)) } catch (t: Throwable) {
                            Log.w(TAG, "onMask threw: ${t.message}")
                        }
                    }
                }
                is DuetSegmentationOutcome.Skipped -> {
                    Log.v(TAG, "frame skipped by ${backend.backendId}: ${outcome.reason}")
                }
                is DuetSegmentationOutcome.Failure -> {
                    handleBackendFailure(backend, outcome)
                }
            }
        }
    }

    // ── Timestamps ─────────────────────────────────────────────────────────────

    /** Camera-clock ms from ImageInfo.timestamp (ns), forced strictly increasing. */
    private fun monotonicTimestampMs(proxy: ImageProxy): Long {
        val raw = proxy.imageInfo.timestamp / 1_000_000L
        val ts = if (raw <= lastTimestampMs) lastTimestampMs + 1 else raw
        lastTimestampMs = ts
        return ts
    }

    // ── Ladder ─────────────────────────────────────────────────────────────────

    private class PendingEvent(
        val isTerminal: Boolean,
        val previousBackend: String,
        val currentBackend: String,
        val reason: String,
        val userMessage: String,
    )

    /**
     * Returns the live backend, opening the planned rung lazily (analysis
     * thread). Walks the ladder on open() failure: MediaPipe init failure ->
     * ML Kit + one degrade event; ML Kit init failure -> terminal fallback.
     * Returns null when not running or terminal.
     */
    private fun ensureActiveBackend(): AndroidDuetSegmentationBackend? {
        var event: PendingEvent? = null
        val backend: AndroidDuetSegmentationBackend? = synchronized(backendLock) {
            if (!isRunning.get() || terminal.get()) return@synchronized null
            activeBackend?.let { return@synchronized it }

            var rung: String? = plannedBackendId
            var firstFailedRung: String? = null
            var degradeReason: String? = null
            var opened: AndroidDuetSegmentationBackend? = null
            while (rung != null && opened == null) {
                val candidate = openRungLocked(rung)
                if (candidate != null) {
                    opened = candidate
                    break
                }
                val failedRung = rung
                val next = selector.nextBackendId(failedRung)
                val reason = DuetSegmentationFailureReason.initFailed(failedRung)
                if (next == null) {
                    temporalSmoother.reset()
                    terminal.set(true)
                    _currentBackendId = DuetSegmentationBackend.NONE
                    event = PendingEvent(
                        isTerminal = true,
                        previousBackend = failedRung,
                        currentBackend = DuetSegmentationBackend.NONE,
                        reason = reason,
                        userMessage = FALLBACK_USER_MESSAGE,
                    )
                    return@synchronized null
                }
                degraded.set(true)
                if (firstFailedRung == null) {
                    firstFailedRung = failedRung
                    degradeReason = reason
                }
                plannedBackendId = next
                rung = next
            }
            val live = opened ?: return@synchronized null
            activeBackend = live
            _currentBackendId = live.backendId
            val failedRung = firstFailedRung
            val reason = degradeReason
            if (failedRung != null && reason != null) {
                // Exactly one degrade event, emitted only once the lower rung is live.
                temporalSmoother.reset()
                event = PendingEvent(
                    isTerminal = false,
                    previousBackend = failedRung,
                    currentBackend = live.backendId,
                    reason = reason,
                    userMessage = DEGRADED_USER_MESSAGE,
                )
            }
            live
        }
        event?.let { emit(it) }
        return backend
    }

    /**
     * Runtime failure on [backend]: closes it and moves one rung down.
     * Stale backends (already replaced) and stopped/terminal adapters are ignored.
     */
    private fun handleBackendFailure(
        backend: AndroidDuetSegmentationBackend,
        failure: DuetSegmentationOutcome.Failure,
    ) {
        var event: PendingEvent? = null
        synchronized(backendLock) {
            if (backend !== activeBackend) {
                Log.d(TAG, "ignoring failure from stale backend ${backend.backendId}: ${failure.reason}")
                return@synchronized
            }
            if (!isRunning.get() || terminal.get()) return@synchronized

            val failedId = backend.backendId
            Log.w(TAG, "backend $failedId failed (${failure.reason}): ${failure.message}", failure.cause)
            activeBackend = null
            closeQuietly(backend)
            if (primaryBackend === backend) primaryBackend = null
            if (fallbackBackend === backend) fallbackBackend = null

            val next = selector.nextBackendId(failedId)
            if (next == null) {
                temporalSmoother.reset()
                terminal.set(true)
                _currentBackendId = DuetSegmentationBackend.NONE
                event = PendingEvent(
                    isTerminal = true,
                    previousBackend = failedId,
                    currentBackend = DuetSegmentationBackend.NONE,
                    reason = failure.reason,
                    userMessage = FALLBACK_USER_MESSAGE,
                )
                return@synchronized
            }

            degraded.set(true)
            plannedBackendId = next
            val replacement = openRungLocked(next)
            if (replacement == null) {
                temporalSmoother.reset()
                terminal.set(true)
                _currentBackendId = DuetSegmentationBackend.NONE
                event = PendingEvent(
                    isTerminal = true,
                    previousBackend = next,
                    currentBackend = DuetSegmentationBackend.NONE,
                    reason = DuetSegmentationFailureReason.initFailed(next),
                    userMessage = FALLBACK_USER_MESSAGE,
                )
                return@synchronized
            }
            temporalSmoother.reset()
            activeBackend = replacement
            _currentBackendId = replacement.backendId
            event = PendingEvent(
                isTerminal = false,
                previousBackend = failedId,
                currentBackend = replacement.backendId,
                reason = failure.reason,
                userMessage = DEGRADED_USER_MESSAGE,
            )
        }
        event?.let { emit(it) }
    }

    /**
     * Creates and opens [rung]; stores it in the matching slot. Returns null
     * (after closing any partial instance) when construction or open() throws.
     * Must be called with [backendLock] held.
     */
    private fun openRungLocked(rung: String): AndroidDuetSegmentationBackend? {
        if (!selector.supports(rung)) {
            Log.w(TAG, "rung $rung unsupported by selector — skipping")
            return null
        }
        var instance: AndroidDuetSegmentationBackend? = null
        return try {
            val created = selector.createBackend(rung)
            instance = created
            created.open()
            if (rung == DuetSegmentationBackend.MEDIAPIPE_CPU) primaryBackend = created
            else fallbackBackend = created
            Log.i(TAG, "backend $rung opened")
            created
        } catch (t: Throwable) {
            Log.w(TAG, "backend $rung failed to open: ${t.javaClass.simpleName}: ${t.message}", t)
            instance?.let { closeQuietly(it) }
            null
        }
    }

    private fun closeAllBackends() {
        synchronized(backendLock) {
            val active = activeBackend
            val primary = primaryBackend
            val fallback = fallbackBackend
            activeBackend = null
            primaryBackend = null
            fallbackBackend = null
            active?.let { closeQuietly(it) }
            if (primary != null && primary !== active) closeQuietly(primary)
            if (fallback != null && fallback !== active && fallback !== primary) closeQuietly(fallback)
        }
    }

    private fun closeQuietly(backend: AndroidDuetSegmentationBackend) {
        try { backend.close() } catch (t: Throwable) {
            Log.w(TAG, "${backend.backendId}.close() threw: ${t.message}")
        }
    }

    private fun emit(event: PendingEvent) {
        val kind = if (event.isTerminal) "fallback" else "degraded"
        Log.w(
            TAG,
            "[GreenScreen $kind] ${event.previousBackend} -> ${event.currentBackend} " +
                "(${event.reason}): ${event.userMessage}",
        )
        try {
            if (event.isTerminal) {
                onFallback(event.previousBackend, event.currentBackend, event.reason, event.userMessage)
            } else {
                onDegraded(event.previousBackend, event.currentBackend, event.reason, event.userMessage)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "on${kind.replaceFirstChar { it.uppercase() }} threw: ${t.message}")
        }
    }
}
