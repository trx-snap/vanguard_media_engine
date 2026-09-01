package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-ASYNC-RUNTIME-QUEUE-REAL-DECODER (under
 * P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice X1): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating the real
 * MediaExtractor/MediaCodec synchronous decoder feeding the verified async
 * runtime queue scheduler native session via
 * [AndroidAsyncRuntimeQueueRealDecoderDriver].
 *
 * Honest non-claims (Proof Boundary): Kotlin-owned real decoder to async
 * runtime queue scheduler proof only. The native worker thread remains the
 * sole caller of the AudioClock mutators, the
 * ClockedAudioTransportCoordinator control/dispatch path, and the
 * output-ring producer role; the Kotlin owner thread only ingests, enqueues
 * commands, reads, and snapshots. No AudioTrack/AAudio/OpenSL/Oboe, no
 * audible output, no product/editor/app wiring, no export route changes, no
 * streaming/cache, no iOS. Writer-local EOS only; zero-fill never enters
 * the identity checksums.
 *
 * The coordinator dispatches to one background [Thread] per accepted run to
 * keep the Flutter UI thread responsive; runs are serialized by an active
 * flag and never overlap. Detach-safe: after [disposeAll] no MethodChannel
 * reply is ever delivered; an in-flight driver run finishes naturally on
 * its own thread and destroys its own native session.
 */
class AndroidAsyncRuntimeQueueRealDecoderSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AsyncRtQueueRealDec"
        private const val METHOD_NAME = "runAsyncRuntimeQueueRealDecoderSmoke"
        private const val MAX_DURATION_SEC = 2.0
        private const val FAIL_MARKER =
            AndroidAsyncRuntimeQueueRealDecoderDriver.FAIL_MARKER
        private const val PROOF_BOUNDARY =
            AndroidAsyncRuntimeQueueRealDecoderDriver.PROOF_BOUNDARY

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
        // sourcePath and on budget/seek geometry outside the window.
        val config = AndroidAsyncRuntimeQueueRealDecoderDriver.RunConfig(
            sourcePath = args?.get("sourcePath") as? String ?: "",
            durationSec = ((args?.get("durationSec") as? Number)?.toDouble() ?: 1.0)
                .coerceAtMost(MAX_DURATION_SEC),
            seekTargetSec = (args?.get("seekTargetSec") as? Number)?.toDouble() ?: 0.35,
            preSeekBudgetSec =
                (args?.get("preSeekBudgetSec") as? Number)?.toDouble() ?: 0.25,
            postSeekBudgetSec =
                (args?.get("postSeekBudgetSec") as? Number)?.toDouble() ?: 0.30,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 2_048,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 1_024,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_ASYNC_RUNTIME_QUEUE_REAL_DECODER_SMOKE_BUSY",
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
                        AndroidAsyncRuntimeQueueRealDecoderDriver().run(config)
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
        } catch (t: Throwable) {
            // Fail closed if the diagnostic thread cannot be created or
            // started: release the run slot and reply exactly once.
            Log.e(TAG, "$METHOD_NAME thread startup failed", t)
            active.set(false)
            postReply(
                replied,
                result,
                makeFailedMap(
                    "thread_startup_failed:${t.javaClass.simpleName}:${t.message}"
                ),
            )
        }
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
        r: AndroidAsyncRuntimeQueueRealDecoderDriver.RunResult,
    ): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to r.formatProbeOk,
            "decoderEosReachedOk" to r.decoderEosReachedOk,
            "asyncWorkerOwnershipOk" to r.asyncWorkerOwnershipOk,
            "controlCommandSerializationOk" to r.controlCommandSerializationOk,
            "realDecoderIngestOk" to r.realDecoderIngestOk,
            "sourceBackpressureRetryOk" to r.sourceBackpressureRetryOk,
            "outputBackpressureOk" to r.outputBackpressureOk,
            "checksumIdentityOk" to r.checksumIdentityOk,
            "frameAccountingOk" to r.frameAccountingOk,
            "seekEpochReanchorOk" to r.seekEpochReanchorOk,
            "noOwnerThreadDispatchOk" to r.noOwnerThreadDispatchOk,
            "foreignThreadRejectedOk" to r.foreignThreadRejectedOk,
            "workerJoinOnDestroyOk" to r.workerJoinOnDestroyOk,
            "idempotentDestroyOk" to r.idempotentDestroyOk,
            "canonicalProofBoundaryOk" to r.canonicalProofBoundaryOk,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to r.sampleRate,
            "channelCount" to r.channelCount,
            "pcmEncoding" to r.pcmEncoding,
            "expectedFrames" to r.expectedFrames,
            "preSeekFrames" to r.preSeekFrames,
            "postSeekFrames" to r.postSeekFrames,
            "seekTargetFrame" to r.seekTargetFrame,
            "totalFramesExtracted" to r.totalFramesExtracted,
            "totalFramesAccepted" to r.totalFramesAccepted,
            "totalFramesRendered" to r.totalFramesRendered,
            "totalFramesPushed" to r.totalFramesPushed,
            "totalOutputFramesRead" to r.totalOutputFramesRead,
            "framesTruncatedAtSeekBoundary" to r.framesTruncatedAtSeekBoundary,
            "framesDiscardedAfterBudget" to r.framesDiscardedAfterBudget,
            "decoderBenignFormatChangeCount" to r.decoderBenignFormatChangeCount,
            "commandsEnqueued" to r.commandsEnqueued,
            "commandsProcessed" to r.commandsProcessed,
            "commandErrors" to r.commandErrors,
            "dispatchCount" to r.dispatchCount,
            "silenceCount" to r.silenceCount,
            "backpressureCount" to r.backpressureCount,
            "writerBackpressureRejects" to r.writerBackpressureRejects,
            "providerUnderrunEvents" to r.providerUnderrunEvents,
            "providerFramesZeroFilled" to r.providerFramesZeroFilled,
            "providerForwardSkipFrames" to r.providerForwardSkipFrames,
            "providerRewindRejects" to r.providerRewindRejects,
            "workerThreadDistinct" to r.workerThreadDistinct,
            "ownerDispatchCalls" to r.ownerDispatchCalls,
            "kotlinAcceptedChecksumHex" to r.kotlinAcceptedChecksumHex,
            "nativeAcceptedChecksumHex" to r.nativeAcceptedChecksumHex,
            "nativeOutputReadChecksumHex" to r.nativeOutputReadChecksumHex,
            "maxFramesPerMix" to r.maxFramesPerMix,
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
            "decoderEosReachedOk" to false,
            "asyncWorkerOwnershipOk" to false,
            "controlCommandSerializationOk" to false,
            "realDecoderIngestOk" to false,
            "sourceBackpressureRetryOk" to false,
            "outputBackpressureOk" to false,
            "checksumIdentityOk" to false,
            "frameAccountingOk" to false,
            "seekEpochReanchorOk" to false,
            "noOwnerThreadDispatchOk" to false,
            "foreignThreadRejectedOk" to false,
            "workerJoinOnDestroyOk" to false,
            "idempotentDestroyOk" to false,
            "canonicalProofBoundaryOk" to false,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to 0,
            "channelCount" to 0,
            "pcmEncoding" to 0,
            "expectedFrames" to 0L,
            "preSeekFrames" to 0L,
            "postSeekFrames" to 0L,
            "seekTargetFrame" to -1L,
            "totalFramesExtracted" to 0L,
            "totalFramesAccepted" to 0L,
            "totalFramesRendered" to -1L,
            "totalFramesPushed" to -1L,
            "totalOutputFramesRead" to 0L,
            "framesTruncatedAtSeekBoundary" to 0L,
            "framesDiscardedAfterBudget" to 0L,
            "decoderBenignFormatChangeCount" to 0L,
            "commandsEnqueued" to -1L,
            "commandsProcessed" to -1L,
            "commandErrors" to -1L,
            "dispatchCount" to -1L,
            "silenceCount" to -1L,
            "backpressureCount" to -1L,
            "writerBackpressureRejects" to -1L,
            "providerUnderrunEvents" to -1L,
            "providerFramesZeroFilled" to -1L,
            "providerForwardSkipFrames" to -1L,
            "providerRewindRejects" to -1L,
            "workerThreadDistinct" to false,
            "ownerDispatchCalls" to -1L,
            "kotlinAcceptedChecksumHex" to "",
            "nativeAcceptedChecksumHex" to "",
            "nativeOutputReadChecksumHex" to "",
            "maxFramesPerMix" to 0L,
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
