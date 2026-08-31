package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-AAUDIO-NODE-OWNED-SINK-DIAGNOSTIC (under
 * P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the MUTED native AAudio
 * diagnostic callback sink fed from the proven two-source node-owned
 * closed-loop graph pipeline (real decoder + synthetic second track), see
 * [AndroidAaudioNodeOwnedSinkDriver]. AAudio is reached exclusively via
 * runtime dlopen behind an API-26 device gate (minSdk 24 safe; never
 * direct-linked), and the owner-thread pump zero-scales the mixed PCM
 * before it enters the callback sink ring.
 *
 * Honest non-claims (Proof Boundary): diagnostic sink foundation only —
 * every callback-fed sample is zero, no audible-output claim, no speaker
 * route, no audio focus/route-change handling, no dead-object recovery, no
 * low-latency/MMAP/EXCLUSIVE mode, no xrun-freedom or latency/glitch
 * claim, no product playback, no editor UI, no ConnectsApp, no
 * export/pass-2 graph reroute, no streaming/cache, no iOS.
 *
 * Threading: one background worker [Thread] per accepted run owns every
 * JNI call (including destroy — native destroy is owner-thread-only in
 * this slice because it stops/closes the AAudio stream); runs are
 * serialized by an active flag and never overlap.
 *
 * Detach-safe: [disposeAll] sets a cancellation flag the driver loop polls
 * in every decode/ingest/step/pump/wait iteration, forcing prompt
 * codec/extractor/native-session (and thus AAudio stream) release in the
 * driver's finally block; no MethodChannel reply is ever delivered after
 * disposal (an in-flight run's reply is dropped).
 */
class AndroidAaudioNodeOwnedSinkSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AaudioSink"
        private const val METHOD_NAME = "runAndroidDagPhase4AaudioNodeOwnedSinkSmoke"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)

    // Dispose cancellation flag: polled by the driver loop on every
    // iteration so an in-flight run releases its codec, extractor, and
    // native session (closing the AAudio stream) promptly after
    // disposeAll(); also gates every reply.
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
        // The driver clamps durationSec into the mandatory 0.5s-1.0s proof
        // window and fail-closes on a blank sourcePath or a seek target
        // outside [0, duration). There is no volume knob: this slice is
        // muted-only by boundary (owner-thread zero-scale before the
        // callback ring).
        val config = AndroidAaudioNodeOwnedSinkDriver.RunConfig(
            sourcePath = args?.get("sourcePath") as? String ?: "",
            durationSec = (args?.get("durationSec") as? Number)?.toDouble() ?: 0.6,
            seekTargetSec = (args?.get("seekTargetSec") as? Number)?.toDouble() ?: 0.25,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 8_192,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 4_096,
            sinkRingCapacityFrames =
                (args?.get("sinkRingCapacityFrames") as? Number)?.toInt() ?: 65_536,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_AAUDIO_NODE_OWNED_SINK_SMOKE_BUSY",
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
     * releases the codec, extractor, and native session (stopping/closing
     * the AAudio stream on its own worker thread) promptly in its finally
     * block, and its reply is dropped.
     */
    fun disposeAll() {
        disposed = true
    }

    private fun runSmoke(
        config: AndroidAaudioNodeOwnedSinkDriver.RunConfig,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult = AndroidAaudioNodeOwnedSinkDriver(
                    cancelled = { disposed },
                ).run(config)
                postReply(replied, result, toPayload(runResult))
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME failed", t)
                postReply(
                    replied,
                    result,
                    toPayload(
                        AndroidAaudioNodeOwnedSinkDriver.failedResult(
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
        r: AndroidAaudioNodeOwnedSinkDriver.RunResult,
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
