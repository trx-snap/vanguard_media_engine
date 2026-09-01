package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION (under
 * P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the parameterized N-source
 * native True-DAG audio graph export session diagnostic proof, see
 * [AndroidAudioGraphExportSessionDriver]. The driver is synchronous,
 * creates every native session it needs, and destroys them all before
 * returning (destroy is idempotent and re-run defensively in its finally
 * block), so lifecycle here is trivial: nothing to cancel mid-run and
 * nothing to release on dispose.
 *
 * Honest non-claims (Proof Boundary): diagnostic foundation only — no
 * production route swap (AndroidAudioMixdownEngine and
 * AndroidNativeAudioMixBusChunkMixer untouched), no runtime/realtime sink,
 * no AudioTrack/AAudio/OpenSL/Oboe, no MediaCodec/MediaExtractor, no file
 * IO, no native worker threads, no app/editor/product, no streaming/cache,
 * no iOS.
 *
 * Threading: one background worker [Thread] per accepted run owns every
 * bridge call; runs are serialized by an active flag and never overlap.
 *
 * Detach-safe: [disposeAll] sets a disposed flag. Because the driver
 * destroys its own native sessions, the flag's only job is reply hygiene:
 * no MethodChannel reply is ever delivered after disposal (an in-flight
 * run's reply is dropped).
 */
class AndroidAudioGraphExportSessionSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4GraphExport"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioGraphExportSessionSmoke"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)

    // Dispose flag: the driver cleans up its own native sessions, so this
    // only gates replies after plugin detach.
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
                "P4_AUDIO_GRAPH_EXPORT_SESSION_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        runSmoke(result)
        return true
    }

    /**
     * Marks the coordinator disposed. An in-flight run finishes on its own
     * worker thread (the driver destroys its own native sessions) and its
     * reply is dropped.
     */
    fun disposeAll() {
        disposed = true
    }

    private fun runSmoke(result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult = AndroidAudioGraphExportSessionDriver().run()
                postReply(replied, result, toPayload(runResult))
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME failed", t)
                postReply(
                    replied,
                    result,
                    toPayload(
                        AndroidAudioGraphExportSessionDriver.failedResult(
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
        r: AndroidAudioGraphExportSessionDriver.RunResult,
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
