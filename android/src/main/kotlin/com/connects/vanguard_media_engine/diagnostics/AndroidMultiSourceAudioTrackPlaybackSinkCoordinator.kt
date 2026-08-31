package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-MULTI-SOURCE-AUDIOTRACK-SINK
 * (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice K): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the Kotlin-owned
 * android.media.AudioTrack MODE_STREAM PCM16 output sink diagnostic fed
 * from the multi-source (real decoder + synthetic second track)
 * closed-loop native audio graph pipeline output ring via
 * [AndroidMultiSourceAudioTrackPlaybackSinkDriver].
 *
 * Honest non-claims (Proof Boundary): diagnostic proof core only — OS sink
 * writes plus HAL consumption proven by playback-head advancement and
 * conditional AudioTimestamp telemetry. No audible-output claim, no
 * speaker-route verification, no audio quality/glitch-freedom/latency
 * claim, no realtime clock sync, no A/V sync, AudioTrack pause/flush is
 * seek-epoch mechanics only (no transport pause/resume semantics), no
 * audio focus, no route-change handling, no offload/low-latency mode, no
 * AAudio/OpenSL/Oboe, no dead-object recovery, no second OS decoder, no
 * production source-node wiring, no export or pass-2 reroute, no
 * streaming/cache, no iOS, no product/editor UI. Native never reads a wall
 * clock; every native tick is frame-derived.
 *
 * Threading: one background worker [Thread] per accepted run owns every
 * JNI call and every AudioTrack call; runs are serialized by an active
 * flag and never overlap. The one short-lived extra probe thread inside
 * the native session exists only to prove the native owner-thread
 * rejection.
 *
 * Detach-safe by source audit only: [disposeAll] sets a cancellation flag
 * the driver loop polls every iteration, forcing prompt AudioTrack release;
 * no MethodChannel reply is ever delivered after disposal (an in-flight
 * run's reply is dropped). Because a real disposeAll() cancels the run and
 * drops the reply by design, dispose cancellation is never exercised
 * in-band by this diagnostic — the payload only attests that the flag was
 * polled, and detachCancellationProven is always false.
 */
class AndroidMultiSourceAudioTrackPlaybackSinkCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4MultiSrcSink"
        private const val METHOD_NAME = "runAndroidDagPhase4MultiSourceAudioTrackSinkSmoke"
        private const val MAX_DURATION_SEC = 2.0

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)

    // Dispose cancellation flag: polled by the driver loop on every
    // iteration so an in-flight run releases its AudioTrack promptly after
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
        // durationSec is clamped here; the driver fail-closes on a blank
        // sourcePath, a seek target outside [0, duration), and a volume
        // outside [0, 1].
        val config = AndroidMultiSourceAudioTrackPlaybackSinkDriver.RunConfig(
            sourcePath = args?.get("sourcePath") as? String ?: "",
            durationSec = ((args?.get("durationSec") as? Number)?.toDouble() ?: 1.0)
                .coerceAtMost(MAX_DURATION_SEC),
            seekTargetSec = (args?.get("seekTargetSec") as? Number)?.toDouble() ?: 0.35,
            volume = (args?.get("volume") as? Number)?.toFloat() ?: 0.0f,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 8_192,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 4_096,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_MULTI_SOURCE_AUDIO_TRACK_SINK_SMOKE_BUSY",
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
     * releases the AudioTrack and native session promptly in its finally
     * block, and its reply is dropped.
     */
    fun disposeAll() {
        disposed = true
    }

    private fun runSmoke(
        config: AndroidMultiSourceAudioTrackPlaybackSinkDriver.RunConfig,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult = AndroidMultiSourceAudioTrackPlaybackSinkDriver(
                    cancelled = { disposed },
                ).run(config)
                postReply(replied, result, toPayload(runResult))
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME failed", t)
                postReply(
                    replied,
                    result,
                    toPayload(
                        AndroidMultiSourceAudioTrackPlaybackSinkDriver.failedResult(
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

    // The driver already builds its lanes/metrics as flat maps, so the
    // success and failure payload shapes are identical by construction.
    private fun toPayload(
        r: AndroidMultiSourceAudioTrackPlaybackSinkDriver.RunResult,
    ): Map<String, Any?> = mapOf(
        "pass" to r.pass,
        "status" to r.status,
        "marker" to r.marker,
        "proofBoundary" to r.proofBoundary,
        "failureReason" to r.failureReason,
        "details" to r.details,
        "lanes" to r.lanes,
        "metrics" to r.metrics,
        // Informational, never gated: dispose cancellation is
        // source-audited only and never exercised in-band by this slice.
        "detachCancellationProven" to false,
        "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
    )
}
