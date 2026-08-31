package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-NODE-OWNED-SINK-CLOCKED-TRANSPORT (sub-slice O
 * of P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the muted Kotlin-owned
 * android.media.AudioTrack MODE_STREAM sink fed from the NODE-OWNED
 * DecodedAudioPcmSourceNode closed-loop native audio graph pipeline output
 * ring through readNodeOwnedAudioSourceGraphPipelineOutputPcm16, with the
 * AudioTrack as the Kotlin timebase master after pre-roll
 * ([AndroidNodeOwnedAudioTrackSinkClockedTransportDriver] +
 * [AndroidNodeOwnedSinkClockedTimebase]).
 *
 * Honest non-claims (Proof Boundary): diagnostic proof core only — always
 * muted (volume 0.0), no audible-output claim, no speaker-route
 * verification, no audio quality/glitch-freedom/latency claim, no realtime
 * A/V sync, no audio focus/becoming-noisy/route-change handling, no
 * dead-object recovery, no offload/low-latency mode, no AAudio/OpenSL/
 * Oboe, no production export or pass-2 graph reroute, no product/editor
 * UI, no ConnectsApp, no streaming/cache, no iOS. The C++ AudioClock and
 * ClockedAudioTransportCoordinator stay caller-clocked and unchanged;
 * native never reads a wall clock (System.nanoTime() lives in the Kotlin
 * timebase only). The steady-state underrun lane claims a zero delta from
 * the post-play baseline only, never an absolute device-global count.
 *
 * Threading: one background worker [Thread] per accepted run owns every
 * JNI call and every AudioTrack call; runs are serialized by an active
 * flag and never overlap, so that one thread is the native session's
 * single owner thread.
 *
 * Detach-safe: [disposeAll] sets a cancellation flag the driver loop polls
 * in every decode/dispatch/read/write/wait iteration, forcing prompt
 * AudioTrack/codec/extractor/native-session release in the driver's
 * finally block; no MethodChannel reply is ever delivered after disposal
 * (an in-flight run's reply is dropped).
 */
class AndroidNodeOwnedAudioTrackSinkClockedTransportSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4NodeOwnedSinkClk"
        private const val METHOD_NAME =
            "runAndroidNodeOwnedAudioTrackSinkClockedTransportSmoke"
        private const val MAX_DURATION_SEC = 2.0

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)

    // Dispose cancellation flag: polled by the driver loop on every
    // iteration so an in-flight run releases its AudioTrack, codec,
    // extractor, and native session promptly after disposeAll(); also gates
    // every reply.
    @Volatile
    private var disposed = false

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        if (disposed) {
            // Detached: never reply after disposeAll(); the engine-side
            // channel is already torn down.
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }
        // durationSec is clamped here; the driver fail-closes on a blank
        // sourcePath and a seek target outside [0, duration). Volume is not
        // configurable: this slice is muted-only by boundary.
        val config = AndroidNodeOwnedAudioTrackSinkClockedTransportDriver.RunConfig(
            sourcePath = args?.get("sourcePath") as? String ?: "",
            durationSec = ((args?.get("durationSec") as? Number)?.toDouble() ?: 1.0)
                .coerceAtMost(MAX_DURATION_SEC),
            seekTargetSec = (args?.get("seekTargetSec") as? Number)?.toDouble() ?: 0.35,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 8_192,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 4_096,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_NODE_OWNED_SINK_CLOCKED_TRANSPORT_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        runSmoke(config, result)
        return true
    }

    /**
     * Marks the coordinator disposed and trips the driver cancellation
     * flag. An in-flight run observes the flag on its next loop poll,
     * releases the AudioTrack, codec, extractor, and native session
     * promptly in its finally block, and its reply is dropped.
     */
    fun disposeAll() {
        disposed = true
    }

    private fun runSmoke(
        config: AndroidNodeOwnedAudioTrackSinkClockedTransportDriver.RunConfig,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult = AndroidNodeOwnedAudioTrackSinkClockedTransportDriver(
                    cancelled = { disposed },
                ).run(config)
                postReply(replied, result, toPayload(runResult))
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME failed", t)
                postReply(
                    replied,
                    result,
                    toPayload(
                        AndroidNodeOwnedAudioTrackSinkClockedTransportDriver.failedResult(
                            "exception:${t.javaClass.simpleName}:${t.message}"
                        )
                    ),
                )
            } finally {
                active.set(false)
            }
        }.start()
    }

    // Delivers success at most once, on the main thread, and never after
    // disposeAll() — checked both before posting and inside the posted block.
    private fun postReply(
        replied: AtomicBoolean,
        result: MethodChannel.Result,
        payload: Map<String, Any?>,
    ) {
        if (disposed || !replied.compareAndSet(false, true)) {
            return
        }
        mainHandler.post {
            if (disposed) {
                return@post
            }
            result.success(payload)
        }
    }

    // The driver builds its lanes/metrics as flat maps, so the success and
    // failure payload shapes are identical by construction.
    private fun toPayload(
        r: AndroidNodeOwnedAudioTrackSinkClockedTransportDriver.RunResult,
    ): Map<String, Any?> = mapOf(
        "pass" to r.pass,
        "status" to r.status,
        "marker" to r.marker,
        "proofBoundary" to r.proofBoundary,
        "failureReason" to r.failureReason,
        "details" to r.details,
        "lanes" to r.lanes,
        "metrics" to r.metrics,
        "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
    )
}
