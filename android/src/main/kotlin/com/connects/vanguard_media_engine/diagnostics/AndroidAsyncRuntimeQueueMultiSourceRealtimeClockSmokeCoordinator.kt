package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

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
 * Honest non-claims (Proof Boundary): diagnostic only — the worker-owned
 * steady_clock is a render/dispatch timebase, not a presentation clock; no
 * caller-supplied native time; playback head / AudioTimestamp / underrun
 * facts are telemetry only; no second OS decoder; no independent EOS; no
 * audible output, no speaker route, no audio focus, no becoming-noisy
 * handling, no route change, no dead-object recovery, no
 * latency/glitch/A-V sync claim, no zero-underrun claim, no
 * realtime-priority claim, no fleet claim, no product/editor/app wiring,
 * no export route, no streaming/cache, no iOS, no C++ primitive changes.
 *
 * The coordinator dispatches to one background [Thread] per accepted run to
 * keep the Flutter UI thread responsive; runs are serialized by an active
 * flag and never overlap. Detach-safe: after [disposeAll] no MethodChannel
 * reply is ever delivered; an in-flight driver run finishes naturally on
 * its own thread, releases its own AudioTrack, and destroys its own native
 * session.
 */
class AndroidAsyncRuntimeQueueMultiSourceRealtimeClockSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AsyncMsRtClk"
        private const val METHOD_NAME = "runAsyncRuntimeQueueMultiSourceRealtimeClockSmoke"
        private const val MAX_DURATION_SEC = 2.0

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
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
                try {
                    val runResult =
                        AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver().run(config)
                    postReply(replied, result, toPayload(runResult))
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_NAME failed", t)
                    postReply(
                        replied,
                        result,
                        toPayload(
                            AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.failedResult(
                                "exception:${t.javaClass.simpleName}:${t.message}"
                            )
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
    private fun toPayload(
        r: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockDriver.RunResult,
    ): Map<String, Any?> = mapOf(
        "pass" to r.pass,
        "status" to r.status,
        "marker" to r.marker,
        "proofBoundary" to r.proofBoundary,
        "nativeProofBoundary" to r.nativeProofBoundary,
        "failureReason" to r.failureReason,
        "details" to r.details,
        "lanes" to r.lanes,
        "metrics" to r.metrics,
        "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
    )
}
