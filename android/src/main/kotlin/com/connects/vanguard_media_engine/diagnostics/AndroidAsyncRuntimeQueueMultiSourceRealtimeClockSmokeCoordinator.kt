package com.connects.vanguard_media_engine.diagnostics

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
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
 * Honest non-claims (Proof Boundary): diagnostic only — the worker-owned
 * steady_clock is a render/dispatch timebase, not a presentation clock; no
 * caller-supplied native time; playback head / AudioTimestamp / underrun
 * facts are telemetry only; no second OS decoder; no independent EOS; no
 * audible output, no speaker route; X7 claims focus request/abandon and
 * noisy receiver register/unregister on real device and synthetic event
 * handoff through owner thread only — no OS focus arbitration correctness,
 * no duck/pause/resume/restart, no route-change or dead-object recovery,
 * no product/editor/app wiring, no export route, no streaming/cache, no iOS,
 * no C++ primitive changes.
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
            // the exact X4/X5/X6 behavior and args.
            focusNoisyEventHandoffProofEnabled =
                (args?.get("focusNoisyEventHandoffProofEnabled") as? Boolean) ?: false,
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

                try {
                    // ── X7 focus + receiver setup ──────────────────────────
                    if (x7Enabled) {
                        val am =
                            context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        x7AudioManager = am

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
                            ).build()
                            x7FocusRequestApi26 = req
                            focusResult = am.requestAudioFocus(req)
                        } else {
                            @Suppress("DEPRECATION")
                            focusResult = am.requestAudioFocus(
                                null,
                                AudioManager.STREAM_MUSIC,
                                AudioManager.AUDIOFOCUS_GAIN,
                            )
                        }
                        x7FocusGranted =
                            (focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)

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

                    // ── Driver run ─────────────────────────────────────────
                    // In X7 mode with focus denied, fail-close before track
                    // create (driver is not invoked).
                    val shouldRunDriver = !x7Enabled || x7FocusGranted
                    val drainFn: (() -> Int)? =
                        if (x7Enabled && x7FocusGranted) x7Queue?.let { q ->
                            { q.drain() }
                        } else null

                    val runResult = if (shouldRunDriver) {
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver()
                            .run(config, drainFn)
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
                                        am.abandonAudioFocus(null)
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
                    )
                    val extraMetrics = buildX7Metrics(
                        x7Enabled, x7SyntheticEventsPosted, x7Queue,
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
                                        am.abandonAudioFocus(null)
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
                    )
                    val extraMetrics = buildX7Metrics(
                        x7Enabled, x7SyntheticEventsPosted, x7Queue,
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
    // extraLanes/extraMetrics carry X7 coordinator-owned fields; empty in
    // X4/X5/X6 mode, preserving exact backward-compatible payload shape.
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
}
