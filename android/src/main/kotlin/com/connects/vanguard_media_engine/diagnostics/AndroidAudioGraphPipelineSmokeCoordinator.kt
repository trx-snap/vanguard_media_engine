package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice H1: verification
 * smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the session-scoped,
 * step-driven closed-loop native audio graph pipeline JNI seam via the
 * Kotlin synthetic PCM16 step driver
 * ([AndroidAudioGraphPipelineSyntheticDriver]).
 *
 * Honest non-claims (Proof Boundary):
 * - Kotlin-owned synthetic PCM step-driven closed-loop native audio graph
 *   pipeline session proof only; no MediaCodec, no MediaExtractor (real
 *   decode is sub-slice H2 and out of scope here), no AudioTrack, no AAudio,
 *   no OpenSL, no Oboe, no audible or realtime playback, no export reroute,
 *   no pass-2 graph reroute, no streaming, no cache, no iOS, no
 *   product/editor UI. Native spawns no threads, takes no locks inside the
 *   vanguard audio primitives, does no file IO, and never reads a wall
 *   clock; every tick is caller-derived. Single routed track at unit gain;
 *   forward-only seek; writer-local EOS only.
 * - The coordinator dispatches to one background [Thread] per accepted run
 *   to keep the Flutter UI thread responsive; runs are serialized by an
 *   active flag and never overlap. The one short-lived extra probe thread
 *   inside the driver exists only to prove the native owner-thread
 *   rejection.
 * - Detach-safe: after [disposeAll] no MethodChannel reply is ever
 *   delivered; an in-flight driver run finishes naturally on its own thread.
 */
class AndroidAudioGraphPipelineSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioGraphPipeline"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioGraphPipelineSmoke"
        private const val FAIL_MARKER =
            AndroidAudioGraphPipelineSyntheticDriver.FAIL_MARKER
        private const val PROOF_BOUNDARY =
            AndroidAudioGraphPipelineSyntheticDriver.PROOF_BOUNDARY

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
        val config = AndroidAudioGraphPipelineSyntheticDriver.RunConfig(
            sampleRate = (args?.get("sampleRate") as? Number)?.toInt() ?: 48_000,
            channelCount = (args?.get("channelCount") as? Number)?.toInt() ?: 2,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 8_192,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 4_096,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            windowCount = (args?.get("windowCount") as? Number)?.toInt() ?: 64,
            seekTargetFrame = (args?.get("seekTargetFrame") as? Number)?.toLong() ?: 4_096L,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_AUDIO_GRAPH_PIPELINE_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        runSmoke(config, result)
        return true
    }

    /**
     * Marks the coordinator disposed. An in-flight driver run is allowed to
     * finish naturally (its reply is dropped); the native session is
     * destroyed by the driver's own finally block.
     */
    fun disposeAll() {
        disposed.set(true)
    }

    private fun runSmoke(
        config: AndroidAudioGraphPipelineSyntheticDriver.RunConfig,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult = AndroidAudioGraphPipelineSyntheticDriver().run(config)
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

    private fun toPayload(
        r: AndroidAudioGraphPipelineSyntheticDriver.RunResult,
    ): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "sourcePartialWriteObserved" to r.sourcePartialWriteObserved,
            "sourceRingFullObserved" to r.sourceRingFullObserved,
            "outputBackpressureObserved" to r.outputBackpressureObserved,
            "checksumIdentityOk" to r.checksumIdentityOk,
            "frameAccountingOk" to r.frameAccountingOk,
            "seekOk" to r.seekOk,
            "tailFlushOk" to r.tailFlushOk,
            "noUnderrunOk" to r.noUnderrunOk,
            "noSilenceOk" to r.noSilenceOk,
            "zeroNativeSteadyStateAllocationOk" to r.zeroNativeSteadyStateAllocationOk,
            "noRingPushShortfallOk" to r.noRingPushShortfallOk,
            "ownerThreadOk" to r.ownerThreadOk,
            "lifecycleOk" to r.lifecycleOk,
            "canonical" to r.canonical,
        )
        val metrics = mapOf<String, Any?>(
            "totalFramesAccepted" to r.totalFramesAccepted,
            "totalOutputFramesDrained" to r.totalOutputFramesDrained,
            "postSeekFramesAccepted" to r.postSeekFramesAccepted,
            "providerUnderrunEvents" to r.providerUnderrunEvents,
            "providerFramesZeroFilled" to r.providerFramesZeroFilled,
            "coordinatorSilenceCount" to r.coordinatorSilenceCount,
            "nativeAcceptedChecksumHex" to r.nativeAcceptedChecksumHex,
            "nativeOutputDrainChecksumHex" to r.nativeOutputDrainChecksumHex,
            "kotlinAcceptedChecksumHex" to r.kotlinAcceptedChecksumHex,
            "maxFramesPerMix" to r.maxFramesPerMix,
            "sourceAvailableReadFrames" to r.sourceAvailableReadFrames,
            "outputAvailableReadFrames" to r.outputAvailableReadFrames,
            "dispatchCount" to r.dispatchCount,
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
            "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
        )
    }

    // Same key shape as toPayload so the Dart harness sees a stable map even
    // when the driver throws before producing a RunResult.
    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "sourcePartialWriteObserved" to false,
            "sourceRingFullObserved" to false,
            "outputBackpressureObserved" to false,
            "checksumIdentityOk" to false,
            "frameAccountingOk" to false,
            "seekOk" to false,
            "tailFlushOk" to false,
            "noUnderrunOk" to false,
            "noSilenceOk" to false,
            "zeroNativeSteadyStateAllocationOk" to false,
            "noRingPushShortfallOk" to false,
            "ownerThreadOk" to false,
            "lifecycleOk" to false,
            "canonical" to false,
        )
        val metrics = mapOf<String, Any?>(
            "totalFramesAccepted" to 0L,
            "totalOutputFramesDrained" to 0L,
            "postSeekFramesAccepted" to 0L,
            "providerUnderrunEvents" to 0L,
            "providerFramesZeroFilled" to 0L,
            "coordinatorSilenceCount" to 0L,
            "nativeAcceptedChecksumHex" to "",
            "nativeOutputDrainChecksumHex" to "",
            "kotlinAcceptedChecksumHex" to "",
            "maxFramesPerMix" to 0L,
            "sourceAvailableReadFrames" to -1L,
            "outputAvailableReadFrames" to -1L,
            "dispatchCount" to 0L,
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
            "lastError" to reason,
        )
    }
}
