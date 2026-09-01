package com.connects.vanguard_media_engine.diagnostics

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioRouting
import android.os.Build
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Android True-DAG P4-AUDIO-ASYNC-RUNTIME-QUEUE-MULTI-SOURCE-REALTIME-CLOCK
 * (under P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice X4): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating that the async
 * runtime queue native worker owns a real monotonic
 * std::chrono::steady_clock render/dispatch timebase over the TWO-SOURCE
 * node-owned topology: one Kotlin-owned real MediaExtractor/MediaCodec
 * decoded track plus one Kotlin-synthetic PCM track are lockstep-ingested
 * into two node-owned source rings, jointly mixed by the
 * GraphAudioScheduler/AudioMixBusNode under worker-owned realtime pacing,
 * and the mixed output ring is drained into a Kotlin-owned MUTED AudioTrack
 * MODE_STREAM write-accounting sink via
 * [AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver].
 *
 * X7 (P4-AUDIO-FOCUS-NOISY-EVENT-HANDOFF) event-plane proof: when
 * focusNoisyEventHandoffProofEnabled=true, the coordinator requests audio
 * focus, registers the ACTION_AUDIO_BECOMING_NOISY receiver, posts synthetic
 * events via the main handler into a bounded thread-safe queue, and the
 * driver drains events on the owner thread at safe write/seek/EOS points.
 * Focus and receiver are abandoned/unregistered exactly once on success,
 * failure, or dispose. No playback mutation, duck, pause, resume, restart,
 * gain restore, or route/device monitoring is performed.
 *
 * X8 (P4-AUDIO-FOCUS-DUCK-RESTORE-RESPONSE) duck/restore response proof:
 * when focusDuckRestoreProofEnabled=true (implies the X7 focus/noisy
 * handoff and the non-zero 0.5 base gain), a real
 * AudioManager.OnAudioFocusChangeListener is attached to the focus request
 * (real OS callbacks are counted telemetry only, never a verdict gate). The
 * coordinator posts+awaits ONE synthetic duck event before the driver
 * starts (fail-closed focus_event_injection_timeout) and posts the ONE
 * synthetic gain event only after the driver reports the duck drained and
 * applied. Coordinator callbacks only enqueue typed bounded events and
 * counters; the coordinator never touches the AudioTrack — the driver's
 * owner thread alone mutates gain via setVolume (0.5 -> 0.1 -> 0.5).
 *
 * X9 (P4-AUDIO-FOCUS-LOSS-PAUSE-RESUME-RESPONSE) focus-loss pause/resume
 * response proof: when focusLossPauseResumeProofEnabled=true (implies the X7
 * focus/noisy handoff and the non-zero 0.5 base gain, but NOT X8
 * duck/restore), the coordinator owns a distinct bounded typed queue with
 * per-tag enqueued/drained/dropped accounting. It posts+awaits ONE synthetic
 * transient focus-loss event before the driver starts (fail-closed
 * focus_loss_event_injection_timeout); the driver applies AudioTrack.pause()
 * only, asserts PLAYSTATE_PAUSED, then invokes the plane callback which
 * enqueues the ONE synthetic focus-gain DIRECTLY into the queue (no
 * main-handler wait) so the driver applies AudioTrack.play() at the same
 * owner-thread boundary. Only after the driver reports the transient resume
 * applied does the coordinator enqueue the ONE synthetic becoming-noisy
 * event, which the driver applies at its terminal EOS point (pause() only,
 * no auto-resume before release). Coordinator callbacks only enqueue typed
 * events and counters; the coordinator never touches the AudioTrack.
 *
 * X10 (P4-AUDIO-FOCUS-LOSS-PERMANENT-STOP-RESPONSE) permanent focus-loss
 * stop/no-auto-resume proof: when permanentFocusLossProofEnabled=true
 * (implies the X7 focus/noisy handoff and the non-zero 0.5 base gain, but
 * NOT X8 or X9), the coordinator owns a distinct bounded typed queue,
 * ISOLATED from the X9 queue (no shared counters). It posts+awaits ONE
 * synthetic permanent-loss event before the driver starts (fail-closed
 * permanent_focus_loss_event_injection_timeout); the driver drains it only
 * at its terminal EOS point, applies AudioTrack.pause() only, asserts
 * PLAYSTATE_PAUSED, then invokes the plane callback which enqueues the ONE
 * synthetic focus-gain-attempt DIRECTLY into the queue (no main-handler
 * wait) so the driver rejects it at the same owner-thread boundary — no
 * AudioTrack.play() is ever called, and no resume happens before release.
 * Coordinator callbacks only enqueue typed events and counters; the
 * coordinator never touches the AudioTrack.
 *
 * X11 (P4-AUDIO-ROUTE-CHANGE-EVENT-HANDOFF-RESPONSE) route-change event
 * handoff / fail-closed response proof: when
 * routeChangeEventHandoffProofEnabled=true (implies the X7 focus/noisy
 * handoff and the non-zero 0.5 base gain, but NOT X8, X9 or X10), the
 * coordinator owns a distinct bounded typed queue (capacity 8), ISOLATED
 * from the X8/X9/X10 queues (no shared counters), plus the real
 * android.media.AudioRouting.OnRoutingChangedListener object delivered on
 * the main handler. The driver alone adds that listener to its AudioTrack
 * and removes it exactly once before release; the listener is telemetry/
 * handoff only (it counts the real callback and enqueues route_changed) and
 * never touches the AudioTrack. The coordinator posts+awaits ONE synthetic
 * route_changed before the driver starts (fail-closed
 * route_change_event_injection_timeout); the driver drains it on the owner
 * thread and samples routed-device telemetry. At the terminal EOS point the
 * driver-invoked plane callback enqueues the ONE synthetic route_disconnect
 * DIRECTLY into the queue (no main-handler wait) so the driver applies
 * AudioTrack.pause() at the same owner-thread boundary, asserts
 * PLAYSTATE_PAUSED, and never recreates or restarts the sink.
 *
 * Honest non-claims (Proof Boundary): diagnostic only — the worker-owned
 * steady_clock is a render/dispatch timebase, not a presentation clock; no
 * caller-supplied native time; playback head / AudioTimestamp / underrun
 * facts are telemetry only; no second OS decoder; no independent EOS; no
 * audible output, no speaker route; X7 claims focus request/abandon and
 * noisy receiver register/unregister on real device and synthetic event
 * handoff through owner thread only — no OS focus arbitration correctness,
 * no duck/pause/resume/restart, no route-change or dead-object recovery,
 * no product/editor/app wiring, no export route, no streaming/cache, no iOS,
 * no C++ primitive changes. X9 claims sink-side AudioTrack playstate
 * pause/play response to synthetic events only — no acoustic audibility or
 * speaker verification, no OS focus arbitration correctness, no
 * transport/presentation pause, no pause/resume SLA, no route-change or
 * dead-object recovery, no production restart policy. X10 claims sink-side
 * AudioTrack pause() response to ONE permanent-loss event plus rejection of
 * a same-boundary synthetic focus-gain attempt (no play(), no auto-resume)
 * only — the same non-claims as X9 apply, and X10 shares no counters with
 * the X9 queue. X11 claims real routing-listener register/remove lifecycle on
 * the AudioTrack, synthetic route_changed handoff with routed-device
 * telemetry sampling, and sink-side AudioTrack pause() response to ONE
 * synthetic route_disconnect (no recreate/restart) only — no seamless route
 * recreation or hot-swap, no stream re-anchor, no dead-object recovery, no
 * OS route arbitration correctness, no acoustic audibility/speaker
 * verification, no transport/presentation pause, no pause/resume SLA, no
 * production restart policy; X11 shares no counters with the X8/X9/X10
 * queues.
 *
 * The coordinator dispatches to one background [Thread] per accepted run to
 * keep the Flutter UI thread responsive; runs are serialized by an active
 * flag and never overlap. Detach-safe: after [disposeAll] no MethodChannel
 * reply is ever delivered; an in-flight driver run finishes naturally on
 * its own thread, releases its own AudioTrack, and destroys its own native
 * session.
 */
class AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AsyncMsRtClk"
        private const val METHOD_NAME = "runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke"
        private const val MAX_DURATION_SEC = 2.0
        private const val X7_QUEUE_CAPACITY = 64
        private const val X8_QUEUE_CAPACITY = 8
        private const val X8_INJECTION_AWAIT_MS = 5_000L
        private const val X9_QUEUE_CAPACITY = 8
        private const val X9_INJECTION_AWAIT_MS = 5_000L
        private const val X10_QUEUE_CAPACITY = 8
        private const val X10_INJECTION_AWAIT_MS = 5_000L
        private const val X11_QUEUE_CAPACITY = 8
        private const val X11_INJECTION_AWAIT_MS = 5_000L

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    // Bounded thread-safe event queue for X7 focus/noisy event-plane proof.
    // Overflow drops and increments droppedCount; never blocks callback threads.
    private class FocusNoisyEventQueue(capacity: Int = X7_QUEUE_CAPACITY) {
        private val queue = ArrayBlockingQueue<String>(capacity)
        val enqueuedCount = AtomicInteger(0)
        val droppedCount = AtomicInteger(0)
        val drainedCount = AtomicInteger(0)

        fun offer(tag: String) {
            if (queue.offer(tag)) enqueuedCount.incrementAndGet()
            else droppedCount.incrementAndGet()
        }

        // Must only be called from the driver's owner thread.
        fun drain(): Int {
            var count = 0
            while (queue.poll() != null) count++
            drainedCount.addAndGet(count)
            return count
        }
    }

    // Bounded thread-safe TYPED queue for the X8 duck/restore proof, with
    // per-tag enqueued/drained accounting. Overflow drops and increments
    // droppedCount; never blocks callback threads. The coordinator only
    // enqueues; the driver polls at most one event per drain pass on its
    // owner thread.
    private class DuckRestoreEventQueue(capacity: Int = X8_QUEUE_CAPACITY) {
        private val queue = ArrayBlockingQueue<String>(capacity)
        val duckEnqueuedCount = AtomicInteger(0)
        val gainEnqueuedCount = AtomicInteger(0)
        val duckDrainedCount = AtomicInteger(0)
        val gainDrainedCount = AtomicInteger(0)
        val droppedCount = AtomicInteger(0)

        fun offer(tag: String) {
            if (queue.offer(tag)) {
                if (tag ==
                    AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.X8_EVENT_DUCK
                ) {
                    duckEnqueuedCount.incrementAndGet()
                } else {
                    gainEnqueuedCount.incrementAndGet()
                }
            } else {
                droppedCount.incrementAndGet()
            }
        }

        // Must only be called from the driver's owner thread.
        fun pollOne(): String? {
            val tag = queue.poll() ?: return null
            if (tag ==
                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.X8_EVENT_DUCK
            ) {
                duckDrainedCount.incrementAndGet()
            } else {
                gainDrainedCount.incrementAndGet()
            }
            return tag
        }
    }

    // Bounded thread-safe TYPED queue for the X9 focus-loss pause/resume
    // proof, distinct from the X8 queue, with per-tag enqueued/drained
    // accounting. Overflow drops and increments droppedCount; never blocks
    // callback threads. The coordinator only enqueues; the driver polls on
    // its owner thread only. The coordinator never touches the AudioTrack.
    private class FocusLossPauseResumeEventQueue(capacity: Int = X9_QUEUE_CAPACITY) {
        private val queue = ArrayBlockingQueue<String>(capacity)
        val transientLossEnqueuedCount = AtomicInteger(0)
        val focusGainEnqueuedCount = AtomicInteger(0)
        val becomingNoisyEnqueuedCount = AtomicInteger(0)
        val transientLossDrainedCount = AtomicInteger(0)
        val focusGainDrainedCount = AtomicInteger(0)
        val becomingNoisyDrainedCount = AtomicInteger(0)
        val droppedCount = AtomicInteger(0)

        fun offer(tag: String) {
            if (queue.offer(tag)) {
                when (tag) {
                    AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                        .X9_EVENT_TRANSIENT_LOSS ->
                        transientLossEnqueuedCount.incrementAndGet()
                    AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                        .X9_EVENT_FOCUS_GAIN ->
                        focusGainEnqueuedCount.incrementAndGet()
                    else -> becomingNoisyEnqueuedCount.incrementAndGet()
                }
            } else {
                droppedCount.incrementAndGet()
            }
        }

        // Must only be called from the driver's owner thread.
        fun pollOne(): String? {
            val tag = queue.poll() ?: return null
            when (tag) {
                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                    .X9_EVENT_TRANSIENT_LOSS ->
                    transientLossDrainedCount.incrementAndGet()
                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                    .X9_EVENT_FOCUS_GAIN ->
                    focusGainDrainedCount.incrementAndGet()
                else -> becomingNoisyDrainedCount.incrementAndGet()
            }
            return tag
        }
    }

    // Bounded thread-safe TYPED queue for the X10 permanent focus-loss
    // stop/no-auto-resume proof, ISOLATED from the X9 queue above (no
    // shared counters), with per-tag enqueued/drained accounting. Overflow
    // drops and increments droppedCount; never blocks callback threads. The
    // coordinator only enqueues; the driver polls on its owner thread only,
    // at the terminal EOS point. The coordinator never touches the
    // AudioTrack.
    private class PermanentFocusLossEventQueue(capacity: Int = X10_QUEUE_CAPACITY) {
        private val queue = ArrayBlockingQueue<String>(capacity)
        val permanentLossEnqueuedCount = AtomicInteger(0)
        val focusGainAttemptEnqueuedCount = AtomicInteger(0)
        val permanentLossDrainedCount = AtomicInteger(0)
        val focusGainAttemptDrainedCount = AtomicInteger(0)
        val droppedCount = AtomicInteger(0)

        fun offer(tag: String) {
            if (queue.offer(tag)) {
                if (tag ==
                    AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                        .X10_EVENT_PERMANENT_LOSS
                ) {
                    permanentLossEnqueuedCount.incrementAndGet()
                } else {
                    focusGainAttemptEnqueuedCount.incrementAndGet()
                }
            } else {
                droppedCount.incrementAndGet()
            }
        }

        // Must only be called from the driver's owner thread.
        fun pollOne(): String? {
            val tag = queue.poll() ?: return null
            if (tag ==
                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                    .X10_EVENT_PERMANENT_LOSS
            ) {
                permanentLossDrainedCount.incrementAndGet()
            } else {
                focusGainAttemptDrainedCount.incrementAndGet()
            }
            return tag
        }
    }

    // Bounded thread-safe TYPED queue for the X11 route-change event-handoff
    // proof, ISOLATED from the X8/X9/X10 queues above (no shared counters),
    // with per-tag enqueued/drained accounting. Overflow drops and
    // increments droppedCount; never blocks the main-handler routing
    // listener. The coordinator and the real routing listener only enqueue;
    // the driver polls on its owner thread only. The coordinator never
    // touches the AudioTrack.
    private class RouteChangeEventQueue(capacity: Int = X11_QUEUE_CAPACITY) {
        private val queue = ArrayBlockingQueue<String>(capacity)
        val routeChangedEnqueuedCount = AtomicInteger(0)
        val routeDisconnectEnqueuedCount = AtomicInteger(0)
        val routeChangedDrainedCount = AtomicInteger(0)
        val routeDisconnectDrainedCount = AtomicInteger(0)
        val droppedCount = AtomicInteger(0)

        fun offer(tag: String) {
            if (queue.offer(tag)) {
                if (tag ==
                    AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                        .X11_EVENT_ROUTE_CHANGED
                ) {
                    routeChangedEnqueuedCount.incrementAndGet()
                } else {
                    routeDisconnectEnqueuedCount.incrementAndGet()
                }
            } else {
                droppedCount.incrementAndGet()
            }
        }

        // Must only be called from the driver's owner thread.
        fun pollOne(): String? {
            val tag = queue.poll() ?: return null
            if (tag ==
                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                    .X11_EVENT_ROUTE_CHANGED
            ) {
                routeChangedDrainedCount.incrementAndGet()
            } else {
                routeDisconnectDrainedCount.incrementAndGet()
            }
            return tag
        }
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        if (disposed.get()) {
            // Detached: never reply after disposeAll(); the engine-side
            // channel is already torn down.
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }
        // durationSec is clamped here; the driver fail-closes on a blank
        // sourcePath, on budget/seek geometry outside the window, and on a
        // pre-seek epoch too short for the native one-second timing gate.
        // X8 implies the X7 focus/noisy handoff (and, inside the driver, the
        // non-zero 0.5 base gain). X9 likewise implies X7 and the non-zero
        // base gain but is a distinct mode: it never sets the X8 flag. X10
        // implies the same X7/non-zero-gain setup but is its own distinct
        // mode too: it never sets the X8 or X9 flags. X11 likewise implies
        // the X7/non-zero-gain setup and never sets the X8, X9 or X10 flags.
        val focusDuckRestoreRequested =
            (args?.get("focusDuckRestoreProofEnabled") as? Boolean) ?: false
        val focusLossPauseResumeRequested =
            (args?.get("focusLossPauseResumeProofEnabled") as? Boolean) ?: false
        val permanentFocusLossRequested =
            (args?.get("permanentFocusLossProofEnabled") as? Boolean) ?: false
        val routeChangeEventHandoffRequested =
            (args?.get("routeChangeEventHandoffProofEnabled") as? Boolean) ?: false
        val config = AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.RunConfig(
            sourcePath = args?.get("sourcePath") as? String ?: "",
            durationSec = ((args?.get("durationSec") as? Number)?.toDouble() ?: 2.0)
                .coerceAtMost(MAX_DURATION_SEC),
            seekTargetSec = (args?.get("seekTargetSec") as? Number)?.toDouble() ?: 1.30,
            preSeekBudgetSec =
                (args?.get("preSeekBudgetSec") as? Number)?.toDouble() ?: 1.20,
            postSeekBudgetSec =
                (args?.get("postSeekBudgetSec") as? Number)?.toDouble() ?: 0.55,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 8_192,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 4_096,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
            // X5 dynamic-gain-envelope mode; absent/false preserves the
            // exact X4 unit-gain run.
            envelopeProofEnabled =
                (args?.get("envelopeProofEnabled") as? Boolean) ?: false,
            // X6 non-zero-gain sink proof mode; absent/false preserves the
            // exact X4/X5 muted-output behavior.
            nonZeroGainSinkProofEnabled =
                (args?.get("nonZeroGainSinkProofEnabled") as? Boolean) ?: false,
            // X7 focus/noisy event-plane proof mode; absent/false preserves
            // the exact X4/X5/X6 behavior and args. X8/X9/X10/X11 imply it.
            focusNoisyEventHandoffProofEnabled =
                ((args?.get("focusNoisyEventHandoffProofEnabled") as? Boolean) ?: false) ||
                    focusDuckRestoreRequested ||
                    focusLossPauseResumeRequested ||
                    permanentFocusLossRequested ||
                    routeChangeEventHandoffRequested,
            // X8 focus-duck/restore response proof mode; absent/false
            // preserves the exact X4/X5/X6/X7 behavior and args.
            focusDuckRestoreProofEnabled = focusDuckRestoreRequested,
            // X9 focus-loss pause/resume response proof mode; absent/false
            // preserves the exact X4/X5/X6/X7/X8 behavior and args.
            focusLossPauseResumeProofEnabled = focusLossPauseResumeRequested,
            // X10 permanent focus-loss stop/no-auto-resume proof mode;
            // absent/false preserves the exact X4/X5/X6/X7/X8/X9 behavior
            // and args.
            permanentFocusLossProofEnabled = permanentFocusLossRequested,
            // X11 route-change event-handoff response proof mode;
            // absent/false preserves the exact X4..X10 behavior and args.
            routeChangeEventHandoffProofEnabled = routeChangeEventHandoffRequested,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_ASYNC_RUNTIME_QUEUE_MULTI_SOURCE_REALTIME_CLOCK_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        val replied = AtomicBoolean(false)
        try {
            Thread {
                // X7 coordinator-owned event-plane state; null/false in X4/X5/X6 mode.
                val x7Enabled = config.focusNoisyEventHandoffProofEnabled
                var x7AudioManager: AudioManager? = null
                var x7FocusRequestApi26: Any? = null  // AudioFocusRequest on API 26+
                var x7NoisyReceiver: BroadcastReceiver? = null
                var x7FocusGranted = false
                var x7FocusAbandoned = false
                var x7ReceiverRegistered = false
                var x7ReceiverUnregistered = false
                var x7SyntheticEventsPosted = 0
                val x7Queue: FocusNoisyEventQueue? =
                    if (x7Enabled) FocusNoisyEventQueue() else null

                // X8 coordinator-owned duck/restore state; null/false unless
                // focusDuckRestoreProofEnabled. Real OS focus-change callbacks
                // only bump a counter (telemetry, never a verdict gate).
                val x8Enabled = config.focusDuckRestoreProofEnabled
                var x7FocusListener: AudioManager.OnAudioFocusChangeListener? = null
                var x8ListenerRegistered = false
                var x8SyntheticDuckPosted = 0
                val x8SyntheticGainPosted = AtomicInteger(0)
                val x8RealFocusChangeCallbacks = AtomicInteger(0)
                val x8Queue: DuckRestoreEventQueue? =
                    if (x8Enabled) DuckRestoreEventQueue() else null

                // X9 coordinator-owned focus-loss pause/resume state; null/false
                // unless focusLossPauseResumeProofEnabled. Distinct from X8: no
                // duck/restore gate or injection is touched.
                val x9Enabled = config.focusLossPauseResumeProofEnabled
                var x9SyntheticTransientLossPosted = 0
                val x9SyntheticFocusGainPosted = AtomicInteger(0)
                val x9SyntheticBecomingNoisyPosted = AtomicInteger(0)
                val x9Queue: FocusLossPauseResumeEventQueue? =
                    if (x9Enabled) FocusLossPauseResumeEventQueue() else null

                // X10 coordinator-owned permanent focus-loss stop/
                // no-auto-resume state; null/false unless
                // permanentFocusLossProofEnabled. ISOLATED from X9: no
                // shared counters or queue.
                val x10Enabled = config.permanentFocusLossProofEnabled
                var x10SyntheticPermanentLossPosted = 0
                val x10SyntheticFocusGainAttemptPosted = AtomicInteger(0)
                val x10Queue: PermanentFocusLossEventQueue? =
                    if (x10Enabled) PermanentFocusLossEventQueue() else null

                // X11 coordinator-owned route-change event-handoff state;
                // null/false unless routeChangeEventHandoffProofEnabled.
                // ISOLATED from X8/X9/X10: no shared counters or queue. The
                // real routing listener only counts and hands off while the
                // driver still holds it on the AudioTrack (x11ListenerLive);
                // late deliveries after removal are counted only.
                val x11Enabled = config.routeChangeEventHandoffProofEnabled
                var x11SyntheticRouteChangedPosted = 0
                val x11SyntheticRouteDisconnectPosted = AtomicInteger(0)
                val x11RealRoutingChangedCallbacks = AtomicInteger(0)
                val x11ListenerLive = AtomicBoolean(false)
                val x11Queue: RouteChangeEventQueue? =
                    if (x11Enabled) RouteChangeEventQueue() else null

                try {
                    // ── X7 focus + receiver setup ──────────────────────────
                    if (x7Enabled) {
                        val am =
                            context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        x7AudioManager = am

                        // Real focus-change listener attached to the focus
                        // request on both API paths. Real OS callbacks are
                        // telemetry-only counters — no OS focus arbitration
                        // correctness claim and never a verdict gate.
                        val listener = AudioManager.OnAudioFocusChangeListener { _ ->
                            x8RealFocusChangeCallbacks.incrementAndGet()
                        }
                        x7FocusListener = listener

                        // Request audio focus: AUDIOFOCUS_GAIN,
                        // USAGE_MEDIA / CONTENT_TYPE_MUSIC. Abandon exactly
                        // once in teardown regardless of outcome.
                        val focusResult: Int
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val req = AudioFocusRequest.Builder(
                                AudioManager.AUDIOFOCUS_GAIN,
                            ).setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                    .build(),
                            ).setOnAudioFocusChangeListener(
                                listener, mainHandler,
                            ).build()
                            x7FocusRequestApi26 = req
                            focusResult = am.requestAudioFocus(req)
                        } else {
                            // Pre-26: request and abandon the SAME listener.
                            @Suppress("DEPRECATION")
                            focusResult = am.requestAudioFocus(
                                listener,
                                AudioManager.STREAM_MUSIC,
                                AudioManager.AUDIOFOCUS_GAIN,
                            )
                        }
                        x7FocusGranted =
                            (focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                        if (x8Enabled) {
                            x8ListenerRegistered = x7FocusGranted
                        }

                        if (x7FocusGranted) {
                            // Register ACTION_AUDIO_BECOMING_NOISY receiver.
                            val queue = x7Queue!!
                            val receiver = object : BroadcastReceiver() {
                                override fun onReceive(ctx: Context?, intent: Intent?) {
                                    if (intent?.action ==
                                        AudioManager.ACTION_AUDIO_BECOMING_NOISY
                                    ) {
                                        queue.offer("noisy")
                                    }
                                }
                            }
                            x7NoisyReceiver = receiver
                            try {
                                context.registerReceiver(
                                    receiver,
                                    IntentFilter(
                                        AudioManager.ACTION_AUDIO_BECOMING_NOISY,
                                    ),
                                )
                                x7ReceiverRegistered = true
                            } catch (_: Throwable) {}

                            // Synthetic physical injection: post focus and
                            // noisy callbacks on the main handler after
                            // registration so the callback-to-queue path is
                            // exercised. No OS focus arbitration correctness
                            // claim.
                            mainHandler.post {
                                queue.offer("synthetic_focus")
                                queue.offer("synthetic_noisy")
                            }
                            x7SyntheticEventsPosted = 2
                        }
                    }

                    // ── X8 deterministic pre-start duck injection ──────────
                    // Post the ONE synthetic duck via the main handler and
                    // AWAIT its enqueue before the driver starts, so the duck
                    // is drained/applied strictly before the gain restore can
                    // exist. Fail closed (driver not invoked) on timeout.
                    var x8InjectionTimedOut = false
                    if (x8Enabled && x7FocusGranted) {
                        val queue = x8Queue!!
                        val posted = CountDownLatch(1)
                        mainHandler.post {
                            queue.offer(
                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                    .X8_EVENT_DUCK,
                            )
                            posted.countDown()
                        }
                        if (posted.await(X8_INJECTION_AWAIT_MS, TimeUnit.MILLISECONDS)) {
                            x8SyntheticDuckPosted = 1
                        } else {
                            x8InjectionTimedOut = true
                        }
                    }

                    // X8 event plane handed to the driver: poll-one on the
                    // owner thread; the coordinator callback only enqueues
                    // the typed gain event (never touches the AudioTrack),
                    // and only after the driver reports the duck applied.
                    val duckRestorePlane:
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .DuckRestoreEventPlane? =
                        if (x8Enabled && x7FocusGranted && !x8InjectionTimedOut) {
                            val queue = x8Queue!!
                            object :
                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                    .DuckRestoreEventPlane {
                                override fun pollOneEvent(): String? = queue.pollOne()

                                override fun onDuckApplied() {
                                    if (x8SyntheticGainPosted.compareAndSet(0, 1)) {
                                        mainHandler.post {
                                            queue.offer(
                                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                                    .X8_EVENT_GAIN,
                                            )
                                        }
                                    }
                                }
                            }
                        } else null

                    // ── X9 deterministic pre-start transient-loss injection ─
                    // Post the ONE synthetic transient focus-loss via the main
                    // handler and AWAIT only its enqueue before the driver
                    // starts. Fail closed (driver not invoked) on timeout. No
                    // AudioTrack is touched here.
                    var x9InjectionTimedOut = false
                    if (x9Enabled && x7FocusGranted) {
                        val queue = x9Queue!!
                        val posted = CountDownLatch(1)
                        mainHandler.post {
                            queue.offer(
                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                    .X9_EVENT_TRANSIENT_LOSS,
                            )
                            posted.countDown()
                        }
                        if (posted.await(X9_INJECTION_AWAIT_MS, TimeUnit.MILLISECONDS)) {
                            x9SyntheticTransientLossPosted = 1
                        } else {
                            x9InjectionTimedOut = true
                        }
                    }

                    // X9 event plane handed to the driver: poll-one on the
                    // owner thread; the focus-gain callback enqueues DIRECTLY
                    // into the coordinator-owned queue (no main-handler wait)
                    // so the driver resumes at the same owner-thread boundary;
                    // the becoming-noisy is enqueued only after the driver
                    // reports the transient resume applied. Callbacks only
                    // enqueue typed events; they never touch the AudioTrack.
                    val focusLossPauseResumePlane:
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .FocusLossPauseResumeEventPlane? =
                        if (x9Enabled && x7FocusGranted && !x9InjectionTimedOut) {
                            val queue = x9Queue!!
                            object :
                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                    .FocusLossPauseResumeEventPlane {
                                override fun pollOneEvent(): String? = queue.pollOne()

                                override fun enqueueSyntheticFocusGain() {
                                    if (x9SyntheticFocusGainPosted.compareAndSet(0, 1)) {
                                        queue.offer(
                                            AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                                .X9_EVENT_FOCUS_GAIN,
                                        )
                                    }
                                }

                                override fun onTransientResumeApplied() {
                                    if (x9SyntheticBecomingNoisyPosted.compareAndSet(0, 1)) {
                                        queue.offer(
                                            AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                                .X9_EVENT_BECOMING_NOISY,
                                        )
                                    }
                                }
                            }
                        } else null

                    // ── X10 deterministic pre-start permanent-loss
                    // injection ─────────────────────────────────────────────
                    // Post the ONE synthetic permanent-loss via the main
                    // handler and AWAIT only its enqueue before the driver
                    // starts. Fail closed (driver not invoked) on timeout. No
                    // AudioTrack is touched here.
                    var x10InjectionTimedOut = false
                    if (x10Enabled && x7FocusGranted) {
                        val queue = x10Queue!!
                        val posted = CountDownLatch(1)
                        mainHandler.post {
                            queue.offer(
                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                    .X10_EVENT_PERMANENT_LOSS,
                            )
                            posted.countDown()
                        }
                        if (posted.await(X10_INJECTION_AWAIT_MS, TimeUnit.MILLISECONDS)) {
                            x10SyntheticPermanentLossPosted = 1
                        } else {
                            x10InjectionTimedOut = true
                        }
                    }

                    // X10 event plane handed to the driver: poll-one on the
                    // owner thread, drained only at the terminal EOS point;
                    // the focus-gain-attempt callback enqueues DIRECTLY into
                    // the coordinator-owned queue (no main-handler wait) so
                    // the driver rejects it at the same owner-thread
                    // boundary. Callbacks only enqueue typed events; they
                    // never touch the AudioTrack.
                    val permanentFocusLossPlane:
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .PermanentFocusLossEventPlane? =
                        if (x10Enabled && x7FocusGranted && !x10InjectionTimedOut) {
                            val queue = x10Queue!!
                            object :
                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                    .PermanentFocusLossEventPlane {
                                override fun pollOneEvent(): String? = queue.pollOne()

                                override fun enqueueSyntheticFocusGainAttempt() {
                                    if (x10SyntheticFocusGainAttemptPosted
                                            .compareAndSet(0, 1)
                                    ) {
                                        queue.offer(
                                            AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                                .X10_EVENT_FOCUS_GAIN_ATTEMPT,
                                        )
                                    }
                                }
                            }
                        } else null

                    // ── X11 deterministic pre-start route-changed
                    // injection ─────────────────────────────────────────────
                    // Post the ONE synthetic route_changed via the main
                    // handler and AWAIT only its enqueue before the driver
                    // starts. Fail closed (driver not invoked) on timeout. No
                    // AudioTrack is touched here.
                    var x11InjectionTimedOut = false
                    if (x11Enabled && x7FocusGranted) {
                        val queue = x11Queue!!
                        val posted = CountDownLatch(1)
                        mainHandler.post {
                            queue.offer(
                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                    .X11_EVENT_ROUTE_CHANGED,
                            )
                            posted.countDown()
                        }
                        if (posted.await(X11_INJECTION_AWAIT_MS, TimeUnit.MILLISECONDS)) {
                            x11SyntheticRouteChangedPosted = 1
                        } else {
                            x11InjectionTimedOut = true
                        }
                    }

                    // X11 event plane handed to the driver: poll-one on the
                    // owner thread; the route-disconnect callback enqueues
                    // DIRECTLY into the coordinator-owned queue (no
                    // main-handler wait) so the driver pauses at the same
                    // owner-thread boundary. The real
                    // AudioRouting.OnRoutingChangedListener is created here
                    // and delivered on the main handler, but the driver
                    // alone adds/removes it on the AudioTrack. Callbacks only
                    // count and enqueue typed events; they never touch the
                    // AudioTrack.
                    val routeChangeEventPlane:
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .RouteChangeEventPlane? =
                        if (x11Enabled && x7FocusGranted && !x11InjectionTimedOut) {
                            val queue = x11Queue!!
                            x11ListenerLive.set(true)
                            val realListener = AudioRouting.OnRoutingChangedListener { _ ->
                                x11RealRoutingChangedCallbacks.incrementAndGet()
                                if (x11ListenerLive.get()) {
                                    queue.offer(
                                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                            .X11_EVENT_ROUTE_CHANGED,
                                    )
                                }
                            }
                            object :
                                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                    .RouteChangeEventPlane {
                                override fun pollOneEvent(): String? = queue.pollOne()

                                override fun enqueueSyntheticRouteDisconnect() {
                                    if (x11SyntheticRouteDisconnectPosted
                                            .compareAndSet(0, 1)
                                    ) {
                                        queue.offer(
                                            AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                                                .X11_EVENT_ROUTE_DISCONNECT,
                                        )
                                    }
                                }

                                override val routingChangedListener:
                                    AudioRouting.OnRoutingChangedListener = realListener

                                override val routingListenerHandler: Handler = mainHandler

                                override fun onRoutingListenerRemoved() {
                                    x11ListenerLive.set(false)
                                }
                            }
                        } else null

                    // ── Driver run ─────────────────────────────────────────
                    // In X7/X8/X9/X10/X11 mode with focus denied (or the
                    // X8/X9/X10/X11 injection timed out), fail-close before
                    // track create (driver is not invoked).
                    val shouldRunDriver =
                        (!x7Enabled || x7FocusGranted) &&
                            !x8InjectionTimedOut &&
                            !x9InjectionTimedOut &&
                            !x10InjectionTimedOut &&
                            !x11InjectionTimedOut
                    val drainFn: (() -> Int)? =
                        if (x7Enabled && x7FocusGranted) x7Queue?.let { q ->
                            { q.drain() }
                        } else null

                    val runResult = if (shouldRunDriver) {
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver()
                            .run(
                                config,
                                drainFn,
                                duckRestorePlane,
                                focusLossPauseResumePlane,
                                permanentFocusLossPlane,
                                routeChangeEventPlane,
                            )
                    } else if (x8InjectionTimedOut) {
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .failedResult("focus_event_injection_timeout")
                    } else if (x9InjectionTimedOut) {
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .failedResult("focus_loss_event_injection_timeout")
                    } else if (x10InjectionTimedOut) {
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .failedResult("permanent_focus_loss_event_injection_timeout")
                    } else if (x11InjectionTimedOut) {
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .failedResult("route_change_event_injection_timeout")
                    } else {
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver
                            .failedResult("audio_focus_request_denied")
                    }

                    // ── X7 teardown ────────────────────────────────────────
                    if (x7Enabled) {
                        // Post-run drain on owner thread: catches any events
                        // enqueued by main handler after the driver's last
                        // safe drain point.
                        x7Queue?.drain()

                        // Unregister noisy receiver exactly once.
                        if (x7ReceiverRegistered && !x7ReceiverUnregistered) {
                            try {
                                x7NoisyReceiver?.let { context.unregisterReceiver(it) }
                                x7ReceiverUnregistered = true
                            } catch (_: Throwable) {}
                        }
                        // Abandon focus exactly once.
                        if (!x7FocusAbandoned) {
                            try {
                                val am = x7AudioManager
                                if (am != null) {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                        (x7FocusRequestApi26 as? AudioFocusRequest)?.let {
                                            am.abandonAudioFocusRequest(it)
                                        }
                                    } else {
                                        @Suppress("DEPRECATION")
                                        am.abandonAudioFocus(x7FocusListener)
                                    }
                                    x7FocusAbandoned = true
                                }
                            } catch (_: Throwable) {}
                        }
                    }

                    val extraLanes = buildX7Lanes(
                        x7Enabled, x7FocusGranted, x7FocusAbandoned,
                        x7ReceiverRegistered, x7ReceiverUnregistered,
                        x7Queue, runResult,
                    ) + buildX8Lanes(
                        x8Enabled, x8ListenerRegistered,
                        x8SyntheticDuckPosted, x8SyntheticGainPosted.get(),
                        x8Queue, runResult,
                    ) + buildX9Lanes(
                        x9Enabled, x9SyntheticTransientLossPosted,
                        x9SyntheticFocusGainPosted.get(),
                        x9SyntheticBecomingNoisyPosted.get(),
                        x9Queue, runResult,
                    ) + buildX10Lanes(
                        x10Enabled, x10SyntheticPermanentLossPosted,
                        x10SyntheticFocusGainAttemptPosted.get(),
                        x10Queue, runResult,
                    ) + buildX11Lanes(
                        x11Enabled, x11SyntheticRouteChangedPosted,
                        x11SyntheticRouteDisconnectPosted.get(),
                        x11RealRoutingChangedCallbacks.get(),
                        x11Queue, runResult,
                    )
                    val extraMetrics = buildX7Metrics(
                        x7Enabled, x7SyntheticEventsPosted, x7Queue,
                    ) + buildX8Metrics(
                        x8Enabled, x8SyntheticDuckPosted,
                        x8SyntheticGainPosted.get(),
                        x8RealFocusChangeCallbacks.get(), x8Queue,
                    ) + buildX9Metrics(
                        x9Enabled, x9SyntheticTransientLossPosted,
                        x9SyntheticFocusGainPosted.get(),
                        x9SyntheticBecomingNoisyPosted.get(),
                        x8RealFocusChangeCallbacks.get(), x9Queue,
                    ) + buildX10Metrics(
                        x10Enabled, x10SyntheticPermanentLossPosted,
                        x10SyntheticFocusGainAttemptPosted.get(),
                        x8RealFocusChangeCallbacks.get(), x10Queue,
                    ) + buildX11Metrics(
                        x11Enabled, x11SyntheticRouteChangedPosted,
                        x11SyntheticRouteDisconnectPosted.get(),
                        x11RealRoutingChangedCallbacks.get(), x11Queue,
                    )
                    postReply(replied, result, toPayload(runResult, extraLanes, extraMetrics))
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_NAME failed", t)
                    // Symmetric X7 teardown on exception.
                    if (x7Enabled) {
                        if (x7ReceiverRegistered && !x7ReceiverUnregistered) {
                            try {
                                x7NoisyReceiver?.let { context.unregisterReceiver(it) }
                                x7ReceiverUnregistered = true
                            } catch (_: Throwable) {}
                        }
                        if (!x7FocusAbandoned) {
                            try {
                                val am = x7AudioManager
                                if (am != null) {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                        (x7FocusRequestApi26 as? AudioFocusRequest)?.let {
                                            am.abandonAudioFocusRequest(it)
                                        }
                                    } else {
                                        @Suppress("DEPRECATION")
                                        am.abandonAudioFocus(x7FocusListener)
                                    }
                                    x7FocusAbandoned = true
                                }
                            } catch (_: Throwable) {}
                        }
                    }
                    val extraLanes = buildX7Lanes(
                        x7Enabled, x7FocusGranted, x7FocusAbandoned,
                        x7ReceiverRegistered, x7ReceiverUnregistered,
                        x7Queue, null,
                    ) + buildX8Lanes(
                        x8Enabled, x8ListenerRegistered,
                        x8SyntheticDuckPosted, x8SyntheticGainPosted.get(),
                        x8Queue, null,
                    ) + buildX9Lanes(
                        x9Enabled, x9SyntheticTransientLossPosted,
                        x9SyntheticFocusGainPosted.get(),
                        x9SyntheticBecomingNoisyPosted.get(),
                        x9Queue, null,
                    ) + buildX10Lanes(
                        x10Enabled, x10SyntheticPermanentLossPosted,
                        x10SyntheticFocusGainAttemptPosted.get(),
                        x10Queue, null,
                    ) + buildX11Lanes(
                        x11Enabled, x11SyntheticRouteChangedPosted,
                        x11SyntheticRouteDisconnectPosted.get(),
                        x11RealRoutingChangedCallbacks.get(),
                        x11Queue, null,
                    )
                    val extraMetrics = buildX7Metrics(
                        x7Enabled, x7SyntheticEventsPosted, x7Queue,
                    ) + buildX8Metrics(
                        x8Enabled, x8SyntheticDuckPosted,
                        x8SyntheticGainPosted.get(),
                        x8RealFocusChangeCallbacks.get(), x8Queue,
                    ) + buildX9Metrics(
                        x9Enabled, x9SyntheticTransientLossPosted,
                        x9SyntheticFocusGainPosted.get(),
                        x9SyntheticBecomingNoisyPosted.get(),
                        x8RealFocusChangeCallbacks.get(), x9Queue,
                    ) + buildX10Metrics(
                        x10Enabled, x10SyntheticPermanentLossPosted,
                        x10SyntheticFocusGainAttemptPosted.get(),
                        x8RealFocusChangeCallbacks.get(), x10Queue,
                    ) + buildX11Metrics(
                        x11Enabled, x11SyntheticRouteChangedPosted,
                        x11SyntheticRouteDisconnectPosted.get(),
                        x11RealRoutingChangedCallbacks.get(), x11Queue,
                    )
                    postReply(
                        replied,
                        result,
                        toPayload(
                            AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.failedResult(
                                "exception:${t.javaClass.simpleName}:${t.message}"
                            ),
                            extraLanes,
                            extraMetrics,
                        ),
                    )
                } finally {
                    active.set(false)
                }
            }.start()
        } catch (t: Throwable) {
            // Fail closed if the diagnostic thread cannot be created or
            // started: release the run slot and reply exactly once.
            Log.e(TAG, "$METHOD_NAME thread startup failed", t)
            active.set(false)
            postReply(
                replied,
                result,
                toPayload(
                    AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.failedResult(
                        "thread_startup_failed:${t.javaClass.simpleName}:${t.message}"
                    )
                ),
            )
        }
        return true
    }

    /**
     * Marks the coordinator disposed. An in-flight driver run is allowed to
     * finish naturally (its reply is dropped); the AudioTrack and the
     * native session are released/destroyed by the driver's own finally
     * block.
     */
    fun disposeAll() {
        disposed.set(true)
    }

    // Delivers success at most once, on the main thread, and never after
    // disposeAll() — checked both before posting and inside the posted block.
    private fun postReply(
        replied: AtomicBoolean,
        result: MethodChannel.Result,
        payload: Map<String, Any?>,
    ) {
        if (disposed.get() || !replied.compareAndSet(false, true)) {
            return
        }
        mainHandler.post {
            if (disposed.get()) {
                return@post
            }
            result.success(payload)
        }
    }

    // The driver's RunResult already carries lane/metric maps with a stable
    // key shape shared by pass and failure paths. Both proof boundaries
    // travel top-level: the Kotlin driver boundary (muted AudioTrack sink
    // claim) and the observed native TU boundary (no native sink claim).
    // extraLanes/extraMetrics carry X7/X8/X9/X10/X11 coordinator-owned
    // fields; empty in X4/X5/X6 mode, preserving exact backward-compatible
    // payload shape.
    private fun toPayload(
        r: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.RunResult,
        extraLanes: Map<String, Any?> = emptyMap(),
        extraMetrics: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> = mapOf(
        "pass" to r.pass,
        "status" to r.status,
        "marker" to r.marker,
        "proofBoundary" to r.proofBoundary,
        "nativeProofBoundary" to r.nativeProofBoundary,
        "failureReason" to r.failureReason,
        "details" to r.details,
        "lanes" to if (extraLanes.isEmpty()) r.lanes else r.lanes + extraLanes,
        "metrics" to if (extraMetrics.isEmpty()) r.metrics else r.metrics + extraMetrics,
        "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
    )

    // Builds X7 coordinator-owned lane map. Returns empty map in X4/X5/X6 mode.
    private fun buildX7Lanes(
        x7Enabled: Boolean,
        focusGranted: Boolean,
        focusAbandoned: Boolean,
        receiverRegistered: Boolean,
        receiverUnregistered: Boolean,
        queue: FocusNoisyEventQueue?,
        runResult: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.RunResult?,
    ): Map<String, Any?> {
        if (!x7Enabled) return emptyMap()
        val q = queue
        val enqueued = q?.enqueuedCount?.get() ?: 0
        val dropped = q?.droppedCount?.get() ?: 0
        val drained = q?.drainedCount?.get() ?: 0
        val ownerDrainOk = drained > 0
        val gatesHeld = focusGranted && focusAbandoned &&
            receiverRegistered && receiverUnregistered &&
            enqueued > 0 && dropped == 0 && drained == enqueued && ownerDrainOk
        return mapOf(
            "audioFocusRequestGrantedOk" to focusGranted,
            "audioFocusAbandonedOk" to focusAbandoned,
            "noisyReceiverRegisteredOk" to receiverRegistered,
            "noisyReceiverUnregisteredOk" to receiverUnregistered,
            "focusNoisyOwnerThreadDrainOk" to ownerDrainOk,
            "focusNoisyEventHandoffGatesHeld" to gatesHeld,
        )
    }

    // Builds X7 coordinator-owned metric map. Returns empty map in X4/X5/X6 mode.
    private fun buildX7Metrics(
        x7Enabled: Boolean,
        syntheticEventsPosted: Int,
        queue: FocusNoisyEventQueue?,
    ): Map<String, Any?> {
        if (!x7Enabled) return emptyMap()
        val q = queue
        return mapOf(
            "focusNoisySyntheticEventsPosted" to syntheticEventsPosted,
            "focusNoisyEventsEnqueued" to (q?.enqueuedCount?.get() ?: 0),
            "focusNoisyEventsDropped" to (q?.droppedCount?.get() ?: 0),
            "focusNoisyEventsDrained" to (q?.drainedCount?.get() ?: 0),
        )
    }

    // Builds the X8 coordinator-owned lane map, folding the driver's
    // duck/restore metrics into the composite gate. Returns empty map unless
    // focusDuckRestoreProofEnabled.
    private fun buildX8Lanes(
        x8Enabled: Boolean,
        listenerRegistered: Boolean,
        syntheticDuckPosted: Int,
        syntheticGainPosted: Int,
        queue: DuckRestoreEventQueue?,
        runResult: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.RunResult?,
    ): Map<String, Any?> {
        if (!x8Enabled) return emptyMap()
        val q = queue
        val dropped = q?.droppedCount?.get() ?: 0
        val duckEnqueued = q?.duckEnqueuedCount?.get() ?: 0
        val gainEnqueued = q?.gainEnqueuedCount?.get() ?: 0
        val duckDrained = q?.duckDrainedCount?.get() ?: 0
        val gainDrained = q?.gainDrainedCount?.get() ?: 0
        val m = runResult?.metrics
        val duckApplied = (m?.get("duckAppliedCount") as? Number)?.toLong() ?: -1L
        val restoreApplied = (m?.get("restoreAppliedCount") as? Number)?.toLong() ?: -1L
        val duckSetOk = (m?.get("duckSetVolumeOk") as? Boolean) ?: false
        val restoreSetOk = (m?.get("restoreSetVolumeOk") as? Boolean) ?: false
        val duckSeq = (m?.get("duckDrainSeq") as? Number)?.toLong() ?: -1L
        val restoreSeq = (m?.get("restoreDrainSeq") as? Number)?.toLong() ?: -1L
        val baseVolume = (m?.get("baseVolume") as? Number)?.toDouble() ?: -1.0
        val duckedVolume = (m?.get("duckedVolume") as? Number)?.toDouble() ?: -1.0
        val restoredVolume = (m?.get("restoredVolume") as? Number)?.toDouble() ?: -1.0
        val finalVolume = (m?.get("finalVolume") as? Number)?.toDouble() ?: -1.0
        val gatesHeld = listenerRegistered &&
            syntheticDuckPosted == 1 && syntheticGainPosted == 1 &&
            dropped == 0 &&
            duckEnqueued == 1 && duckDrained == 1 &&
            gainEnqueued == 1 && gainDrained == 1 &&
            duckApplied == 1L && restoreApplied == 1L &&
            duckSetOk && restoreSetOk &&
            duckSeq >= 0L && restoreSeq > duckSeq &&
            baseVolume == 0.5 && duckedVolume == 0.1 &&
            restoredVolume == 0.5 && finalVolume == 0.5
        return mapOf(
            "focusListenerRegisteredOk" to listenerRegistered,
            "focusDuckRestoreGatesHeld" to gatesHeld,
        )
    }

    // Builds the X8 coordinator-owned metric map (typed per-tag enqueue/drain
    // accounting plus real-callback telemetry). Returns empty map unless
    // focusDuckRestoreProofEnabled.
    private fun buildX8Metrics(
        x8Enabled: Boolean,
        syntheticDuckPosted: Int,
        syntheticGainPosted: Int,
        realFocusChangeCallbacks: Int,
        queue: DuckRestoreEventQueue?,
    ): Map<String, Any?> {
        if (!x8Enabled) return emptyMap()
        val q = queue
        return mapOf(
            "syntheticDuckPosted" to syntheticDuckPosted,
            "syntheticGainPosted" to syntheticGainPosted,
            "duckEventsEnqueued" to (q?.duckEnqueuedCount?.get() ?: 0),
            "gainEventsEnqueued" to (q?.gainEnqueuedCount?.get() ?: 0),
            "duckEventsDrained" to (q?.duckDrainedCount?.get() ?: 0),
            "gainEventsDrained" to (q?.gainDrainedCount?.get() ?: 0),
            "focusEventsDropped" to (q?.droppedCount?.get() ?: 0),
            "realFocusChangeCallbackCount" to realFocusChangeCallbacks,
        )
    }

    // Builds the X9 coordinator-owned lane map, folding the driver's
    // focus-loss pause/resume metrics into the composite gate. Returns empty
    // map unless focusLossPauseResumeProofEnabled. Sink-side playstate proof
    // only (see class doc non-claims).
    private fun buildX9Lanes(
        x9Enabled: Boolean,
        syntheticTransientLossPosted: Int,
        syntheticFocusGainPosted: Int,
        syntheticBecomingNoisyPosted: Int,
        queue: FocusLossPauseResumeEventQueue?,
        runResult: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.RunResult?,
    ): Map<String, Any?> {
        if (!x9Enabled) return emptyMap()
        val q = queue
        val dropped = q?.droppedCount?.get() ?: 0
        val transientEnqueued = q?.transientLossEnqueuedCount?.get() ?: 0
        val gainEnqueued = q?.focusGainEnqueuedCount?.get() ?: 0
        val noisyEnqueued = q?.becomingNoisyEnqueuedCount?.get() ?: 0
        val transientDrained = q?.transientLossDrainedCount?.get() ?: 0
        val gainDrained = q?.focusGainDrainedCount?.get() ?: 0
        val noisyDrained = q?.becomingNoisyDrainedCount?.get() ?: 0
        val m = runResult?.metrics
        val transientApplied =
            (m?.get("transientLossAppliedCount") as? Number)?.toLong() ?: -1L
        val gainApplied = (m?.get("focusGainAppliedCount") as? Number)?.toLong() ?: -1L
        val noisyApplied =
            (m?.get("becomingNoisyAppliedCount") as? Number)?.toLong() ?: -1L
        val pauseOk = (m?.get("focusLossPauseOk") as? Boolean) ?: false
        val resumeOk = (m?.get("focusGainResumeOk") as? Boolean) ?: false
        val noisyPauseOk = (m?.get("becomingNoisyPauseOk") as? Boolean) ?: false
        val transientSeq = (m?.get("transientPauseApplySeq") as? Number)?.toLong() ?: -1L
        val gainSeq = (m?.get("focusGainResumeApplySeq") as? Number)?.toLong() ?: -1L
        val noisySeq = (m?.get("noisyPauseApplySeq") as? Number)?.toLong() ?: -1L
        val terminalPausedOk =
            (m?.get("terminalPlayStatePausedBeforeReleaseOk") as? Boolean) ?: false
        val gatesHeld =
            syntheticTransientLossPosted == 1 &&
                syntheticFocusGainPosted == 1 &&
                syntheticBecomingNoisyPosted == 1 &&
                dropped == 0 &&
                transientEnqueued == 1 && transientDrained == 1 &&
                gainEnqueued == 1 && gainDrained == 1 &&
                noisyEnqueued == 1 && noisyDrained == 1 &&
                transientApplied == 1L && gainApplied == 1L && noisyApplied == 1L &&
                pauseOk && resumeOk && noisyPauseOk &&
                transientSeq >= 0L && gainSeq > transientSeq && noisySeq > gainSeq &&
                terminalPausedOk
        return mapOf(
            "focusLossPauseResumeGatesHeld" to gatesHeld,
        )
    }

    // Builds the X9 coordinator-owned metric map (typed per-tag
    // posted/enqueued/drained/dropped accounting plus real-callback
    // telemetry). Returns empty map unless focusLossPauseResumeProofEnabled.
    private fun buildX9Metrics(
        x9Enabled: Boolean,
        syntheticTransientLossPosted: Int,
        syntheticFocusGainPosted: Int,
        syntheticBecomingNoisyPosted: Int,
        realFocusChangeCallbacks: Int,
        queue: FocusLossPauseResumeEventQueue?,
    ): Map<String, Any?> {
        if (!x9Enabled) return emptyMap()
        val q = queue
        return mapOf(
            "syntheticTransientLossPosted" to syntheticTransientLossPosted,
            "syntheticFocusGainPosted" to syntheticFocusGainPosted,
            "syntheticBecomingNoisyPosted" to syntheticBecomingNoisyPosted,
            "transientLossEventsEnqueued" to (q?.transientLossEnqueuedCount?.get() ?: 0),
            "focusGainEventsEnqueued" to (q?.focusGainEnqueuedCount?.get() ?: 0),
            "becomingNoisyEventsEnqueued" to (q?.becomingNoisyEnqueuedCount?.get() ?: 0),
            "transientLossEventsDrained" to (q?.transientLossDrainedCount?.get() ?: 0),
            "focusGainEventsDrained" to (q?.focusGainDrainedCount?.get() ?: 0),
            "becomingNoisyEventsDrained" to (q?.becomingNoisyDrainedCount?.get() ?: 0),
            "focusLossPauseResumeEventsDropped" to (q?.droppedCount?.get() ?: 0),
            "focusLossRealFocusChangeCallbackCount" to realFocusChangeCallbacks,
        )
    }

    // Builds the X10 coordinator-owned lane map, folding the driver's
    // permanent focus-loss metrics into the composite gate. Returns empty
    // map unless permanentFocusLossProofEnabled. ISOLATED from the X9 lane
    // builder above: no shared counters. Sink-side playstate proof only (see
    // class doc non-claims).
    private fun buildX10Lanes(
        x10Enabled: Boolean,
        syntheticPermanentLossPosted: Int,
        syntheticFocusGainAttemptPosted: Int,
        queue: PermanentFocusLossEventQueue?,
        runResult: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.RunResult?,
    ): Map<String, Any?> {
        if (!x10Enabled) return emptyMap()
        val q = queue
        val dropped = q?.droppedCount?.get() ?: 0
        val lossEnqueued = q?.permanentLossEnqueuedCount?.get() ?: 0
        val attemptEnqueued = q?.focusGainAttemptEnqueuedCount?.get() ?: 0
        val lossDrained = q?.permanentLossDrainedCount?.get() ?: 0
        val attemptDrained = q?.focusGainAttemptDrainedCount?.get() ?: 0
        val m = runResult?.metrics
        val lossApplied = (m?.get("permanentLossAppliedCount") as? Number)?.toLong() ?: -1L
        val attemptRejected =
            (m?.get("focusGainAttemptRejectedCount") as? Number)?.toLong() ?: -1L
        val pauseOk = (m?.get("permanentFocusLossPauseOk") as? Boolean) ?: false
        val rejectedOk = (m?.get("focusGainAutoResumeRejectedOk") as? Boolean) ?: false
        val autoResumeAllowed = (m?.get("autoResumeAllowed") as? Boolean) ?: true
        val lossSeq = (m?.get("permanentLossApplySeq") as? Number)?.toLong() ?: -1L
        val attemptSeq = (m?.get("focusGainAttemptApplySeq") as? Number)?.toLong() ?: -1L
        val terminalPausedOk =
            (m?.get("terminalPlayStatePausedBeforeReleasePermanentOk") as? Boolean) ?: false
        val gatesHeld =
            syntheticPermanentLossPosted == 1 &&
                syntheticFocusGainAttemptPosted == 1 &&
                dropped == 0 &&
                lossEnqueued == 1 && lossDrained == 1 &&
                attemptEnqueued == 1 && attemptDrained == 1 &&
                lossApplied == 1L && attemptRejected == 1L &&
                pauseOk && rejectedOk && !autoResumeAllowed &&
                lossSeq >= 0L && attemptSeq > lossSeq &&
                terminalPausedOk
        return mapOf(
            "permanentFocusLossGatesHeld" to gatesHeld,
        )
    }

    // Builds the X10 coordinator-owned metric map (typed per-tag
    // posted/enqueued/drained/dropped accounting plus real-callback
    // telemetry). Returns empty map unless permanentFocusLossProofEnabled.
    private fun buildX10Metrics(
        x10Enabled: Boolean,
        syntheticPermanentLossPosted: Int,
        syntheticFocusGainAttemptPosted: Int,
        realFocusChangeCallbacks: Int,
        queue: PermanentFocusLossEventQueue?,
    ): Map<String, Any?> {
        if (!x10Enabled) return emptyMap()
        val q = queue
        return mapOf(
            "syntheticPermanentLossPosted" to syntheticPermanentLossPosted,
            "syntheticFocusGainAttemptPosted" to syntheticFocusGainAttemptPosted,
            "permanentLossEventsEnqueued" to (q?.permanentLossEnqueuedCount?.get() ?: 0),
            "focusGainAttemptEventsEnqueued" to
                (q?.focusGainAttemptEnqueuedCount?.get() ?: 0),
            "permanentLossEventsDrained" to (q?.permanentLossDrainedCount?.get() ?: 0),
            "focusGainAttemptEventsDrained" to
                (q?.focusGainAttemptDrainedCount?.get() ?: 0),
            "permanentFocusLossEventsDropped" to (q?.droppedCount?.get() ?: 0),
            "permanentFocusLossRealFocusChangeCallbackCount" to realFocusChangeCallbacks,
        )
    }

    // Builds the X11 coordinator-owned lane map, folding the driver's
    // route-change lanes/metrics into the composite gate. Returns empty map
    // unless routeChangeEventHandoffProofEnabled. ISOLATED from the X8/X9/X10
    // lane builders above: no shared counters. Real routing callbacks are
    // telemetry: they may add route_changed handoffs (bounded by the real
    // callback count) but never gate the verdict on their own. The synthetic
    // route_disconnect must be the LAST applied event.
    private fun buildX11Lanes(
        x11Enabled: Boolean,
        syntheticRouteChangedPosted: Int,
        syntheticRouteDisconnectPosted: Int,
        realRoutingChangedCallbacks: Int,
        queue: RouteChangeEventQueue?,
        runResult: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.RunResult?,
    ): Map<String, Any?> {
        if (!x11Enabled) return emptyMap()
        val q = queue
        val dropped = q?.droppedCount?.get() ?: 0
        val changedEnqueued = q?.routeChangedEnqueuedCount?.get() ?: 0
        val disconnectEnqueued = q?.routeDisconnectEnqueuedCount?.get() ?: 0
        val changedDrained = q?.routeChangedDrainedCount?.get() ?: 0
        val disconnectDrained = q?.routeDisconnectDrainedCount?.get() ?: 0
        val l = runResult?.lanes
        val m = runResult?.metrics
        val registeredOk = (l?.get("routingListenerRegisteredOk") as? Boolean) ?: false
        val unregisteredOk = (l?.get("routingListenerUnregisteredOk") as? Boolean) ?: false
        val observationOk = (l?.get("routeChangeObservationOk") as? Boolean) ?: false
        val pauseOk = (l?.get("routeDisconnectFailClosedPauseOk") as? Boolean) ?: false
        val terminalPausedOk =
            (l?.get("terminalPlayStatePausedBeforeReleaseRouteChangeOk") as? Boolean)
                ?: false
        val changedApplied = (m?.get("routeChangedAppliedCount") as? Number)?.toLong() ?: -1L
        val disconnectApplied =
            (m?.get("routeDisconnectAppliedCount") as? Number)?.toLong() ?: -1L
        val changedSeq = (m?.get("routeChangedApplySeq") as? Number)?.toLong() ?: -1L
        val disconnectSeq = (m?.get("routeDisconnectApplySeq") as? Number)?.toLong() ?: -1L
        val gatesHeld =
            registeredOk && unregisteredOk && observationOk && pauseOk && terminalPausedOk &&
                syntheticRouteChangedPosted == 1 &&
                syntheticRouteDisconnectPosted == 1 &&
                dropped == 0 &&
                changedEnqueued >= 1 &&
                changedEnqueued <= 1 + realRoutingChangedCallbacks &&
                changedDrained == changedEnqueued &&
                disconnectEnqueued == 1 && disconnectDrained == 1 &&
                changedApplied >= 1L && changedApplied == changedDrained.toLong() &&
                disconnectApplied == 1L &&
                changedSeq >= 0L && disconnectSeq > changedSeq &&
                disconnectSeq == changedApplied
        return mapOf(
            "routeChangeEventHandoffGatesHeld" to gatesHeld,
        )
    }

    // Builds the X11 coordinator-owned metric map (typed per-tag
    // posted/enqueued/drained/dropped accounting plus real routing-callback
    // telemetry). Returns empty map unless routeChangeEventHandoffProofEnabled.
    private fun buildX11Metrics(
        x11Enabled: Boolean,
        syntheticRouteChangedPosted: Int,
        syntheticRouteDisconnectPosted: Int,
        realRoutingChangedCallbacks: Int,
        queue: RouteChangeEventQueue?,
    ): Map<String, Any?> {
        if (!x11Enabled) return emptyMap()
        val q = queue
        return mapOf(
            "syntheticRouteChangedPosted" to syntheticRouteChangedPosted,
            "syntheticRouteDisconnectPosted" to syntheticRouteDisconnectPosted,
            "routeChangedEventsEnqueued" to (q?.routeChangedEnqueuedCount?.get() ?: 0),
            "routeDisconnectEventsEnqueued" to
                (q?.routeDisconnectEnqueuedCount?.get() ?: 0),
            "routeChangedEventsDrained" to (q?.routeChangedDrainedCount?.get() ?: 0),
            "routeDisconnectEventsDrained" to
                (q?.routeDisconnectDrainedCount?.get() ?: 0),
            "routeChangeEventsDropped" to (q?.droppedCount?.get() ?: 0),
            "realRoutingChangedCallbackCount" to realRoutingChangedCallbacks,
        )
    }
}
