package com.connects.vanguard_media_engine.duet

import android.os.SystemClock
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
//   - Production ladder: mediapipe_cpu -> mlkit -> none (safe PiP), driven by
//     AndroidDuetSegmentationBackendSelector. mediapipe_gpu is NOT part of the
//     production ladder — physical proof on SM-A566B (Android 16) showed
//     MediaPipe Tasks GPU + confidence masks can native-abort (SIGABRT) during
//     result conversion, which cannot be caught as a Kotlin failure; the
//     selector's `supports`/`primaryBackendId` never route a production
//     session to it. The gpu/cpu-aware plumbing below (message text, rung
//     constants) is kept latent for a caller that experimentally starts an
//     adapter on mediapipe_gpu directly. Movement is one-way and latched:
//       * A MediaPipe rung failure (init or runtime) closes that rung, opens
//         the next rung and emits exactly one [onDegraded] (non-terminal;
//         green screen stays live). cpu -> mlkit is a non-terminal degrade
//         (as would gpu -> cpu, if a caller ever started on the experimental
//         gpu rung).
//       * ML Kit failure (init or runtime) closes ML Kit and emits [onFallback]
//         (terminal; the coordinator applies safe PiP).
//   - Backends open lazily on the analysis thread at the first frame, so model
//     loading never blocks the main thread or the preview/compositor. Each
//     MediaPipe rung owns its own lifecycle thread internally (see
//     AndroidDuetMediaPipeSegmentationBackend); open() still blocks the
//     analysis thread until that rung is ready or has definitively failed.
//   - Single-in-flight gate + drop-stale: at most one frame is being segmented;
//     extra frames are closed immediately.
//   - Every ImageProxy closes on every path (success / skipped / failure /
//     drop / not running / backend missing / synchronous throw).
//   - Timestamps come from ImageInfo.timestamp (camera clock, ns -> ms) and
//     are forced strictly increasing across the adapter's lifetime.
//   - Idempotent start/stop; stop closes the active backend and any other
//     backend opened during a multi-hop ladder walk.
//   - No EventChannel wiring; no ML on the render thread.
//
// Threading:
//   - start/stop are called on the main thread.
//   - analyze() runs on the CameraX analysis executor (dedicated single thread).
//   - MediaPipe (GPU and CPU) completes asynchronously on its own owned
//     lifecycle thread; ML Kit completes on the main thread (Task listeners).
//     Both funnel through [finishFrame], which is guarded so a frame finishes
//     exactly once regardless of which thread calls it.
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

        private const val GPU_TO_CPU_DEGRADED_USER_MESSAGE =
            "Green screen switched from GPU to CPU processing; performance may be reduced."
        private const val DEGRADED_USER_MESSAGE =
            "Green screen switched to the compatibility segmenter (ML Kit); edge quality may be reduced."
        private const val FALLBACK_USER_MESSAGE =
            "Green screen segmentation is unavailable on this device. Falling back to Picture-in-Picture."

        /**
         * Rung-aware degrade message keyed on the *destination* rung: a
         * transition landing on mediapipe_cpu must not claim ML Kit (this only
         * fires today for the experimental gpu -> cpu case, since production
         * sessions never start on mediapipe_gpu); any transition landing on
         * mlkit (including a multi-hop open-failure walk) keeps the existing
         * compatibility-segmenter wording other code/tests already depend on.
         */
        private fun degradedUserMessage(currentBackend: String): String = when (currentBackend) {
            DuetSegmentationBackend.MEDIAPIPE_CPU -> GPU_TO_CPU_DEGRADED_USER_MESSAGE
            else -> DEGRADED_USER_MESSAGE
        }
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
    private var activeBackend: AndroidDuetSegmentationBackend? = null

    /**
     * Every backend opened by this adapter that has not yet been closed,
     * rung-neutral (gpu/cpu/mlkit alike). [activeBackend] is always a member
     * while set. Guarded by [backendLock]; lets [closeAllBackends] close the
     * active backend and any backend opened during a multi-hop ladder walk
     * exactly once, without hard-coding a fixed number of rungs.
     */
    private val openedBackends = linkedSetOf<AndroidDuetSegmentationBackend>()

    /** Rung the next lazy open() will try (guarded by backendLock). */
    private var plannedBackendId: String = initialBackendId

    @Volatile private var _currentBackendId: String = initialBackendId

    /** Analysis-thread-only monotonic timestamp guard (ms, camera clock). */
    private var lastTimestampMs = Long.MIN_VALUE

    /** Single owned temporal smoother between backend output and compositor upload. */
    private val temporalSmoother = AndroidDuetMaskTemporalSmoother()

    /** Single owned adaptive-quality policy: pacing, thermal adaptation, inference-budget monitoring. */
    private val qualityPolicy = AndroidDuetAdaptiveQualityPolicy(selector.hostContext)

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
        qualityPolicy.reset()
        Log.d(TAG, "stop() — backends closed")
    }

    // ── ImageAnalysis.Analyzer ─────────────────────────────────────────────────

    override fun analyze(proxy: ImageProxy) {
        val timestampMs = monotonicTimestampMs(proxy)

        // Adaptive pacing: paced-out frames never enter the in-flight gate at all.
        if (!qualityPolicy.shouldProcessFrame(timestampMs)) {
            proxy.close()
            return
        }

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

        val closer = FrameCloser(proxy)

        val thermalDegrade = qualityPolicy.evaluateThermal()
        if (thermalDegrade != null) {
            closer.finish {
                handleBackendFailure(
                    backend,
                    DuetSegmentationOutcome.Failure(
                        thermalDegrade.reason,
                        "adaptive quality policy requested degrade (${thermalDegrade.reason})",
                    ),
                )
            }
            return
        }

        val segmentStartElapsedMs = SystemClock.elapsedRealtime()
        try {
            backend.segment(proxy, timestampMs) { outcome ->
                val durationMs = SystemClock.elapsedRealtime() - segmentStartElapsedMs
                finishFrame(backend, outcome, closer, durationMs)
            }
        } catch (t: Throwable) {
            val durationMs = SystemClock.elapsedRealtime() - segmentStartElapsedMs
            finishFrame(
                backend,
                DuetSegmentationOutcome.Failure(
                    DuetSegmentationFailureReason.segmentThrew(backend.backendId),
                    "${backend.backendId}.segment() threw: ${t.javaClass.simpleName}: ${t.message}",
                    t,
                ),
                closer,
                durationMs,
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
        durationMs: Long,
    ) {
        closer.finish {
            val inferenceDegrade = qualityPolicy.recordInferenceDuration(durationMs)
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
            if (inferenceDegrade != null) {
                // No-ops if [backend] was already replaced by the Failure branch above
                // (handleBackendFailure ignores stale backends).
                handleBackendFailure(
                    backend,
                    DuetSegmentationOutcome.Failure(
                        inferenceDegrade.reason,
                        "adaptive quality policy requested degrade (${inferenceDegrade.reason})",
                    ),
                )
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
                    qualityPolicy.reset()
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
                qualityPolicy.reset()
                event = PendingEvent(
                    isTerminal = false,
                    previousBackend = failedRung,
                    currentBackend = live.backendId,
                    reason = reason,
                    userMessage = degradedUserMessage(live.backendId),
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
            openedBackends.remove(backend)
            closeQuietly(backend)

            val firstNext = selector.nextBackendId(failedId)
            if (firstNext == null) {
                temporalSmoother.reset()
                qualityPolicy.reset()
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

            // Walk downward through every lower rung until one opens or the
            // ladder is exhausted, so a runtime failure degrades exactly as far
            // as an open-time failure would (e.g. gpu runtime failure -> cpu
            // open failure -> mlkit).
            var rung: String? = firstNext
            var lastFailedRung = failedId
            var replacement: AndroidDuetSegmentationBackend? = null
            while (rung != null) {
                val candidate = openRungLocked(rung)
                if (candidate != null) {
                    replacement = candidate
                    break
                }
                lastFailedRung = rung
                rung = selector.nextBackendId(rung)
            }

            if (replacement == null) {
                temporalSmoother.reset()
                qualityPolicy.reset()
                terminal.set(true)
                _currentBackendId = DuetSegmentationBackend.NONE
                event = PendingEvent(
                    isTerminal = true,
                    previousBackend = lastFailedRung,
                    currentBackend = DuetSegmentationBackend.NONE,
                    reason = DuetSegmentationFailureReason.initFailed(lastFailedRung),
                    userMessage = FALLBACK_USER_MESSAGE,
                )
                return@synchronized
            }

            degraded.set(true)
            plannedBackendId = replacement.backendId
            temporalSmoother.reset()
            qualityPolicy.reset()
            activeBackend = replacement
            _currentBackendId = replacement.backendId
            event = PendingEvent(
                isTerminal = false,
                previousBackend = failedId,
                currentBackend = replacement.backendId,
                reason = failure.reason,
                userMessage = degradedUserMessage(replacement.backendId),
            )
        }
        event?.let { emit(it) }
    }

    /**
     * Creates and opens [rung]; adds it to [openedBackends] on success. Returns
     * null (after closing any partial instance) when construction or open()
     * throws. Must be called with [backendLock] held.
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
            openedBackends.add(created)
            Log.i(TAG, "backend $rung opened")
            created
        } catch (t: Throwable) {
            Log.w(TAG, "backend $rung failed to open: ${t.javaClass.simpleName}: ${t.message}", t)
            instance?.let { closeQuietly(it) }
            null
        }
    }

    /**
     * Closes the active backend and any other backend opened during a
     * multi-hop ladder walk (e.g. gpu opened then failed while walking to cpu
     * within the same lazy-open pass), each exactly once, rung-neutral.
     */
    private fun closeAllBackends() {
        synchronized(backendLock) {
            val toClose = openedBackends.toList()
            openedBackends.clear()
            activeBackend = null
            toClose.forEach { closeQuietly(it) }
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
