package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-SCHEDULER-ENVELOPE-WIRING (sub-slice S under
 * P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the native
 * GraphAudioScheduler per-source static-gain/envelope wiring diagnostic
 * proof, see [AndroidAudioSchedulerEnvelopeDriver]. The native route is
 * one-shot, stack-scoped, synchronous, and holds no OS resource, so
 * lifecycle here is trivial: nothing to cancel mid-run and nothing to
 * release on dispose.
 *
 * Honest non-claims (Proof Boundary): diagnostic only — GraphAudioScheduler
 * envelope wiring only. No production mixdown change, no export/pass-2
 * reroute, no runtime queue, no backpressure, no realtime sink, no native
 * worker threads, no AudioTrack/AAudio/OpenSL/Oboe, no
 * MediaCodec/MediaExtractor, no file IO, no streaming/cache, no iOS, no
 * app/product/editor UI.
 *
 * Threading: one background worker [Thread] per accepted run owns the
 * single JNI call; runs are serialized by an active flag and never overlap.
 *
 * Detach-safe: [disposeAll] sets a disposed flag. Because the native route
 * is one-shot with no OS resource, the flag's only job is reply hygiene: no
 * MethodChannel reply is ever delivered after disposal (an in-flight run's
 * reply is dropped).
 */
class AndroidAudioSchedulerEnvelopeSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4SchedEnv"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioSchedulerEnvelopeSmoke"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)

    // Dispose flag: the native route is stack-scoped and synchronous, so
    // this only gates replies after plugin detach (no cancellation of any
    // OS resource is needed).
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
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_AUDIO_SCHEDULER_ENVELOPE_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        runSmoke(result)
        return true
    }

    /**
     * Marks the coordinator disposed. An in-flight run finishes its
     * one-shot native call on its own worker thread (stack-scoped native
     * state, nothing to release) and its reply is dropped.
     */
    fun disposeAll() {
        disposed = true
    }

    private fun runSmoke(result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult = AndroidAudioSchedulerEnvelopeDriver().run()
                postReply(replied, result, toPayload(runResult))
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME failed", t)
                postReply(
                    replied,
                    result,
                    toPayload(
                        AndroidAudioSchedulerEnvelopeDriver.failedResult(
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
        r: AndroidAudioSchedulerEnvelopeDriver.RunResult,
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
