package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-AUDIOTRACK-OUTPUT-SINK-WRITE
 * (P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice I): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the Kotlin-owned
 * android.media.AudioTrack MODE_STREAM PCM16 output sink diagnostic fed
 * from the sub-slice H1 closed-loop native output ring via
 * [AndroidAudioTrackPlaybackSinkDriver].
 *
 * Honest non-claims (Proof Boundary): diagnostic proof core only — OS sink
 * writes plus HAL consumption proven by playback-head advancement and
 * conditional AudioTimestamp telemetry. No audible-output claim, no
 * speaker-route verification, no audio quality/glitch-freedom/latency
 * claim, no realtime clock sync, no A/V sync, no pause/resume feature, no
 * audio focus, no route-change handling, no offload/low-latency mode, no
 * AAudio/OpenSL/Oboe, no dead-object recovery, no production wiring, no
 * export or pass-2 reroute, no streaming/cache, no iOS, no product/editor
 * UI. Native never reads a wall clock; every native tick is frame-derived.
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
 * polled (cancellationPollingLiveOk / cancellationPollCount), and
 * detachCancellationProven is always false. A physical dispose-cancellation
 * proof is deferred to a future negative-path harness.
 */
class AndroidAudioTrackPlaybackSinkSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioTrackSink"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioTrackOutputSinkSmoke"
        private const val MAX_DURATION_SEC = 2.0
        private const val FAIL_MARKER =
            AndroidAudioTrackPlaybackSinkDriver.FAIL_MARKER
        private const val PROOF_BOUNDARY =
            AndroidAudioTrackPlaybackSinkDriver.PROOF_BOUNDARY

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
        val config = AndroidAudioTrackPlaybackSinkDriver.RunConfig(
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
                "P4_AUDIOTRACK_OUTPUT_SINK_SMOKE_BUSY",
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
        config: AndroidAudioTrackPlaybackSinkDriver.RunConfig,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult =
                    AndroidAudioTrackPlaybackSinkDriver(cancelled = { disposed }).run(config)
                postReply(replied, result, toPayload(runResult))
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME failed", t)
                postReply(
                    replied,
                    result,
                    makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}"),
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

    private fun toPayload(
        r: AndroidAudioTrackPlaybackSinkDriver.RunResult,
    ): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to r.formatProbeOk,
            "audioTrackInitOk" to r.audioTrackInitOk,
            "prerollOk" to r.prerollOk,
            "sinkWriteAccountingOk" to r.sinkWriteAccountingOk,
            "checksumIdentityOk" to r.checksumIdentityOk,
            "playbackHeadMonotonicOk" to r.playbackHeadMonotonicOk,
            "playbackHeadAdvancedOk" to r.playbackHeadAdvancedOk,
            "headNeverExceedsWrittenOk" to r.headNeverExceedsWrittenOk,
            "tailDrainedOk" to r.tailDrainedOk,
            "seekEpochAccountingOk" to r.seekEpochAccountingOk,
            "noUnderrunOk" to r.noUnderrunOk,
            "noSilenceOk" to r.noSilenceOk,
            "noRingPushShortfallOk" to r.noRingPushShortfallOk,
            "zeroNativeSteadyStateAllocationOk" to r.zeroNativeSteadyStateAllocationOk,
            "ownerThreadOk" to r.ownerThreadOk,
            "lifecycleOk" to r.lifecycleOk,
            "canonical" to r.canonical,
            // Conditional/telemetry lanes: recorded, not required for PASS.
            "cancellationPollingLiveOk" to r.cancellationPollingLiveOk,
            "audioTimestampAvailable" to r.audioTimestampAvailable,
            "audioTimestampValidOk" to r.audioTimestampValidOk,
        )
        val metrics = mapOf<String, Any?>(
            "cancellationPollCount" to r.cancellationPollCount,
            "sampleRate" to r.sampleRate,
            "channelCount" to r.channelCount,
            "audioTimestampAttemptCount" to r.audioTimestampAttemptCount,
            "audioTimestampSuccessCount" to r.audioTimestampSuccessCount,
            "playbackHeadFinal" to r.playbackHeadFinal,
            "framesWrittenTotal" to r.framesWrittenTotal,
            "framesReadFromRingTotal" to r.framesReadFromRingTotal,
            "partialWriteCount" to r.partialWriteCount,
            "zeroWriteCount" to r.zeroWriteCount,
            "getUnderrunCount" to r.getUnderrunCount,
            "bufferSizeInFrames" to r.bufferSizeInFrames,
            "bufferCapacityInFrames" to r.bufferCapacityInFrames,
            "maxHeadLagFrames" to r.maxHeadLagFrames,
            "finalHeadLagFrames" to r.finalHeadLagFrames,
            "prerollFrames" to r.prerollFrames,
            "seekAcceptedFrame" to r.seekAcceptedFrame,
            "totalFramesAccepted" to r.totalFramesAccepted,
            "totalOutputFramesDrained" to r.totalOutputFramesDrained,
            "dispatchCount" to r.dispatchCount,
            "nativeOutputDrainChecksumHex" to r.nativeOutputDrainChecksumHex,
            "kotlinSinkChecksumHex" to r.kotlinSinkChecksumHex,
            "nativeLastStatus" to r.nativeLastStatus,
        )
        return mapOf(
            "pass" to r.pass,
            "status" to r.status,
            "marker" to r.marker,
            "proofBoundary" to r.proofBoundary,
            "failureReason" to r.failureReason,
            "details" to r.details,
            "lanes" to lanes,
            "metrics" to metrics,
            // Informational, never gated: dispose cancellation is
            // source-audited only and never exercised in-band by this slice.
            "detachCancellationProven" to false,
            "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
        )
    }

    // Same key shape as toPayload so the Dart harness sees a stable map even
    // when the driver throws before producing a RunResult.
    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to false,
            "audioTrackInitOk" to false,
            "prerollOk" to false,
            "sinkWriteAccountingOk" to false,
            "checksumIdentityOk" to false,
            "playbackHeadMonotonicOk" to false,
            "playbackHeadAdvancedOk" to false,
            "headNeverExceedsWrittenOk" to false,
            "tailDrainedOk" to false,
            "seekEpochAccountingOk" to false,
            "noUnderrunOk" to false,
            "noSilenceOk" to false,
            "noRingPushShortfallOk" to false,
            "zeroNativeSteadyStateAllocationOk" to false,
            "ownerThreadOk" to false,
            "lifecycleOk" to false,
            "canonical" to false,
            "cancellationPollingLiveOk" to false,
            "audioTimestampAvailable" to false,
            "audioTimestampValidOk" to false,
        )
        val metrics = mapOf<String, Any?>(
            "cancellationPollCount" to 0L,
            "sampleRate" to 0,
            "channelCount" to 0,
            "audioTimestampAttemptCount" to 0L,
            "audioTimestampSuccessCount" to 0L,
            "playbackHeadFinal" to 0L,
            "framesWrittenTotal" to 0L,
            "framesReadFromRingTotal" to 0L,
            "partialWriteCount" to 0L,
            "zeroWriteCount" to 0L,
            "getUnderrunCount" to -1L,
            "bufferSizeInFrames" to 0L,
            "bufferCapacityInFrames" to 0L,
            "maxHeadLagFrames" to 0L,
            "finalHeadLagFrames" to -1L,
            "prerollFrames" to 0L,
            "seekAcceptedFrame" to -1L,
            "totalFramesAccepted" to 0L,
            "totalOutputFramesDrained" to 0L,
            "dispatchCount" to 0L,
            "nativeOutputDrainChecksumHex" to "",
            "kotlinSinkChecksumHex" to "",
            "nativeLastStatus" to "",
        )
        return mapOf(
            "pass" to false,
            "status" to "fail",
            "marker" to FAIL_MARKER,
            "proofBoundary" to PROOF_BOUNDARY,
            "failureReason" to reason,
            "details" to "",
            "lanes" to lanes,
            "metrics" to metrics,
            // Informational, never gated: dispose cancellation is
            // source-audited only and never exercised in-band by this slice.
            "detachCancellationProven" to false,
            "lastError" to reason,
        )
    }
}
