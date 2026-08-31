package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-MULTI-SOURCE-GRAPH-PIPELINE (Phase 4 foundation
 * under P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): verification
 * smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the diagnostic-only
 * two-source closed-loop native audio graph pipeline proof (one real
 * MediaExtractor/MediaCodec decoder track plus one Kotlin-synthesized track
 * in lockstep) via [AndroidMultiSourceAudioGraphPipelineDriver].
 *
 * Honest non-claims (Proof Boundary): Kotlin-owned real-decoder-plus-
 * synthetic-second-track step-driven closed-loop native audio graph
 * pipeline session proof only; the native frame axis is the SHARED accepted
 * frame count, not media PTS, with full overlap only (no independent EOS,
 * no ragged tail). Lossless within the common budget L only; truncation
 * beyond L is an explicit non-claim. No second OS decoder, no AudioTrack,
 * no AAudio, no OpenSL, no Oboe, no audible or realtime playback, no export
 * reroute, no pass-2 graph reroute, no streaming, no cache, no iOS, no
 * product/editor UI. Native never owns MediaCodec/MediaExtractor, spawns no
 * threads, takes no locks inside the vanguard audio primitives, does no
 * file IO, and never reads a wall clock; every tick is caller-derived. Two
 * routed tracks at unit gain; forward-only joint seek; writer-local EOS
 * only.
 *
 * Threading: one background worker [Thread] per accepted run owns every JNI
 * call and every MediaCodec/MediaExtractor call; runs are serialized by an
 * active flag and never overlap. The one short-lived extra probe thread
 * inside the native session exists only to prove the native owner-thread
 * rejection.
 *
 * Detach-safe: [disposeAll] sets a cancellation flag the driver loop polls
 * every iteration, so an in-flight run releases its codec/extractor and
 * native session promptly via its own finally block; no MethodChannel reply
 * is ever delivered after disposal (an in-flight run's reply is dropped).
 */
class AndroidMultiSourceAudioGraphPipelineSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4MultiSourcePipeline"
        private const val METHOD_NAME = "runAndroidDagPhase4MultiSourceGraphPipelineSmoke"
        private const val MAX_DURATION_SEC = 2.0
        private const val FAIL_MARKER =
            AndroidMultiSourceAudioGraphPipelineDriver.FAIL_MARKER
        private const val PROOF_BOUNDARY =
            AndroidMultiSourceAudioGraphPipelineDriver.PROOF_BOUNDARY

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)

    // Dispose cancellation flag: polled by the driver loop on every
    // iteration so an in-flight run tears down promptly after disposeAll();
    // also gates every reply.
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
        // sourcePath and on a seek target outside [0, duration).
        val config = AndroidMultiSourceAudioGraphPipelineDriver.RunConfig(
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
                "P4_MULTI_SOURCE_GRAPH_PIPELINE_SMOKE_BUSY",
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
     * releases its codec/extractor and native session promptly in its
     * finally block, and its reply is dropped.
     */
    fun disposeAll() {
        disposed = true
    }

    private fun runSmoke(
        config: AndroidMultiSourceAudioGraphPipelineDriver.RunConfig,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult = AndroidMultiSourceAudioGraphPipelineDriver(
                    cancelled = { disposed },
                ).run(config)
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
        r: AndroidMultiSourceAudioGraphPipelineDriver.RunResult,
    ): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to r.formatProbeOk,
            "topologyRoutedSourcesOk" to r.topologyRoutedSourcesOk,
            "track0IngestOk" to r.track0IngestOk,
            "track1SyntheticIngestOk" to r.track1SyntheticIngestOk,
            "trackFrameAxisLockstepOk" to r.trackFrameAxisLockstepOk,
            "jointDispatchGateOk" to r.jointDispatchGateOk,
            "referenceMixChecksumOk" to r.referenceMixChecksumOk,
            "mixedOutputFrameAccountingOk" to r.mixedOutputFrameAccountingOk,
            "twoTrackContributionOk" to r.twoTrackContributionOk,
            "seekOk" to r.seekOk,
            "jointTailFlushOk" to r.jointTailFlushOk,
            "noProviderUnderrunOk" to r.noProviderUnderrunOk,
            "noZeroFillOk" to r.noZeroFillOk,
            "noForwardSkipOk" to r.noForwardSkipOk,
            "noRewindRejectOk" to r.noRewindRejectOk,
            "noSilenceOk" to r.noSilenceOk,
            "noRingPushShortfallOk" to r.noRingPushShortfallOk,
            "zeroNativeSteadyStateAllocationOk" to r.zeroNativeSteadyStateAllocationOk,
            "ownerThreadOk" to r.ownerThreadOk,
            "lifecycleOk" to r.lifecycleOk,
            "canonical" to r.canonical,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to r.sampleRate,
            "channelCount" to r.channelCount,
            "pcmEncoding" to r.pcmEncoding,
            "commonBudgetFrames" to r.commonBudgetFrames,
            "framesTruncatedBeyondBudget" to r.framesTruncatedBeyondBudget,
            "totalFramesExtracted" to r.totalFramesExtracted,
            "totalFramesAcceptedTrack0" to r.totalFramesAcceptedTrack0,
            "totalFramesAcceptedTrack1" to r.totalFramesAcceptedTrack1,
            "totalOutputFramesDrained" to r.totalOutputFramesDrained,
            "postSeekFramesAccepted" to r.postSeekFramesAccepted,
            "postSeekFramesDrained" to r.postSeekFramesDrained,
            "seekAcceptedFrame" to r.seekAcceptedFrame,
            "track1NonZeroSampleCount" to r.track1NonZeroSampleCount,
            "mixedChecksumDiffersFromTrack0" to r.mixedChecksumDiffersFromTrack0,
            "mixedChecksumDiffersFromTrack1" to r.mixedChecksumDiffersFromTrack1,
            "decoderBenignFormatChangeCount" to r.decoderBenignFormatChangeCount,
            "providerUnderrunEventsTrack0" to r.providerUnderrunEventsTrack0,
            "providerUnderrunEventsTrack1" to r.providerUnderrunEventsTrack1,
            "providerFramesZeroFilledTrack0" to r.providerFramesZeroFilledTrack0,
            "providerFramesZeroFilledTrack1" to r.providerFramesZeroFilledTrack1,
            "providerForwardSkipFramesTrack0" to r.providerForwardSkipFramesTrack0,
            "providerForwardSkipFramesTrack1" to r.providerForwardSkipFramesTrack1,
            "providerRewindRejectsTrack0" to r.providerRewindRejectsTrack0,
            "providerRewindRejectsTrack1" to r.providerRewindRejectsTrack1,
            "coordinatorSilenceCount" to r.coordinatorSilenceCount,
            "nativeAcceptedChecksumHexTrack0" to r.nativeAcceptedChecksumHexTrack0,
            "nativeAcceptedChecksumHexTrack1" to r.nativeAcceptedChecksumHexTrack1,
            "nativeOutputDrainChecksumHex" to r.nativeOutputDrainChecksumHex,
            "kotlinAcceptedChecksumHexTrack0" to r.kotlinAcceptedChecksumHexTrack0,
            "kotlinAcceptedChecksumHexTrack1" to r.kotlinAcceptedChecksumHexTrack1,
            "kotlinReferenceMixChecksumHex" to r.kotlinReferenceMixChecksumHex,
            "maxFramesPerMix" to r.maxFramesPerMix,
            "sourceAvailableReadFramesTrack0" to r.sourceAvailableReadFramesTrack0,
            "sourceAvailableReadFramesTrack1" to r.sourceAvailableReadFramesTrack1,
            "outputAvailableReadFrames" to r.outputAvailableReadFrames,
            "dispatchCount" to r.dispatchCount,
            "nextDispatchFrame" to r.nextDispatchFrame,
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
            "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
        )
    }

    // Same key shape as toPayload so the Dart harness sees a stable map even
    // when the driver throws before producing a RunResult.
    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to false,
            "topologyRoutedSourcesOk" to false,
            "track0IngestOk" to false,
            "track1SyntheticIngestOk" to false,
            "trackFrameAxisLockstepOk" to false,
            "jointDispatchGateOk" to false,
            "referenceMixChecksumOk" to false,
            "mixedOutputFrameAccountingOk" to false,
            "twoTrackContributionOk" to false,
            "seekOk" to false,
            "jointTailFlushOk" to false,
            "noProviderUnderrunOk" to false,
            "noZeroFillOk" to false,
            "noForwardSkipOk" to false,
            "noRewindRejectOk" to false,
            "noSilenceOk" to false,
            "noRingPushShortfallOk" to false,
            "zeroNativeSteadyStateAllocationOk" to false,
            "ownerThreadOk" to false,
            "lifecycleOk" to false,
            "canonical" to false,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to 0,
            "channelCount" to 0,
            "pcmEncoding" to 0,
            "commonBudgetFrames" to 0L,
            "framesTruncatedBeyondBudget" to 0L,
            "totalFramesExtracted" to 0L,
            "totalFramesAcceptedTrack0" to 0L,
            "totalFramesAcceptedTrack1" to 0L,
            "totalOutputFramesDrained" to 0L,
            "postSeekFramesAccepted" to 0L,
            "postSeekFramesDrained" to 0L,
            "seekAcceptedFrame" to -1L,
            "track1NonZeroSampleCount" to 0L,
            "mixedChecksumDiffersFromTrack0" to false,
            "mixedChecksumDiffersFromTrack1" to false,
            "decoderBenignFormatChangeCount" to 0L,
            "providerUnderrunEventsTrack0" to 0L,
            "providerUnderrunEventsTrack1" to 0L,
            "providerFramesZeroFilledTrack0" to 0L,
            "providerFramesZeroFilledTrack1" to 0L,
            "providerForwardSkipFramesTrack0" to 0L,
            "providerForwardSkipFramesTrack1" to 0L,
            "providerRewindRejectsTrack0" to 0L,
            "providerRewindRejectsTrack1" to 0L,
            "coordinatorSilenceCount" to 0L,
            "nativeAcceptedChecksumHexTrack0" to "",
            "nativeAcceptedChecksumHexTrack1" to "",
            "nativeOutputDrainChecksumHex" to "",
            "kotlinAcceptedChecksumHexTrack0" to "",
            "kotlinAcceptedChecksumHexTrack1" to "",
            "kotlinReferenceMixChecksumHex" to "",
            "maxFramesPerMix" to 0L,
            "sourceAvailableReadFramesTrack0" to -1L,
            "sourceAvailableReadFramesTrack1" to -1L,
            "outputAvailableReadFrames" to -1L,
            "dispatchCount" to 0L,
            "nextDispatchFrame" to -1L,
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
            "lastError" to reason,
        )
    }
}
