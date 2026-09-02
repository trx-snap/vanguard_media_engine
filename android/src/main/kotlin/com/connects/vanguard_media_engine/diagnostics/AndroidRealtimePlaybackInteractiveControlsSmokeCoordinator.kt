package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackInteractiveControlsSink
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-INTERACTIVE-CONTROLS (Y3):
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating the production
 * [VanguardRealtimePlaybackInteractiveControlsSink] adapter driven by the authoritative
 * Kotlin transport state machine ([VanguardRealtimePlaybackTransportStateMachine]):
 * - Sample rate = 48000, channel count = 2, maxFramesPerMix = 256,
 *   track count = 2, declaredFrameCount = 12000 (tail is non-window-aligned),
 *   pauseHoldMs = 150, preControlFrames = 4096, seekTargetFrame = 6000, deadlineMs = 20000.
 * - Drains mixed PCM16 into a muted android.media.AudioTrack MODE_STREAM sink.
 * - Executes interactive pause/resume and seek sequences verifying synchronization
 *   between state machine and AudioTrack sink.
 * - Asserts all required lanes: audioTrackInitOk, mutedOutputOk, initialDrainOk,
 *   pauseCommandOk, sinkPausedOk, pauseHoldFrozenOk, resumeCommandOk, sinkResumedOk,
 *   activeBeforeSeekOk, seekCommandOk, sinkFlushAtSeekOk, postSeekDrainOk,
 *   transportCompletedOk, checksumIdentityOk, sinkWriteAccountingOk,
 *   audioTrackReleasedOk, lifecycleOk, and canonical.
 *
 * Proof boundary non-claims:
 * muted diagnostic AudioTrack interactive controls only, synthetic PCM from Y1 transport,
 * no MediaCodec, no MediaExtractor, no audio focus, no route change, no
 * dead-object recovery, no production presentation clock, no A/V sync, no audible output,
 * no product/editor/app wiring, no iOS, no streaming/cache, no native C++ changes.
 */
class AndroidRealtimePlaybackInteractiveControlsSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY3InteractiveControls"
        const val METHOD_NAME = "runRealtimePlaybackInteractiveControlsSmoke"

        const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_PHYSICAL_SMOKE_FAIL"
        const val START_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_SMOKE_START"
        const val JSON_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_JSON"

        const val PROOF_BOUNDARY =
            VanguardRealtimePlaybackInteractiveControlsSink.PROOF_BOUNDARY

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    @Volatile
    private var activeStateMachine: VanguardRealtimePlaybackTransportStateMachine? = null

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) return false

        if (disposed.get()) {
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }

        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_REALTIME_PLAYBACK_INTERACTIVE_CONTROLS_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }

        runSmoke(result)
        return true
    }

    fun disposeAll() {
        disposed.set(true)
        try {
            activeStateMachine?.dispose()
        } catch (_: Throwable) {}
        activeStateMachine = null
    }

    private fun runSmoke(result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val payload = executeSmoke()
                postReply(replied, result, payload)
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME uncaught failure", t)
                val failPayload = buildFailurePayload(
                    "uncaught_exception:${t.javaClass.simpleName}:${t.message}"
                )
                postReply(replied, result, failPayload)
            } finally {
                active.set(false)
            }
        }.start()
    }

    private fun postReply(
        replied: AtomicBoolean,
        result: MethodChannel.Result,
        payload: Map<String, Any?>,
    ) {
        if (disposed.get() || !replied.compareAndSet(false, true)) return
        mainHandler.post {
            if (disposed.get()) return@post
            result.success(payload)
        }
    }

    private fun executeSmoke(): Map<String, Any?> {
        var sm: VanguardRealtimePlaybackTransportStateMachine? = null
        try {
            val sampleRate = 48000
            val channelCount = 2
            val maxFramesPerMix = 256
            val trackCount = 2
            val declaredFrameCount = 12000L
            val pauseHoldMs = 150L
            val preControlFrames = 4096L
            val seekTargetFrame = 6000L
            val deadlineMs = 20000L

            val config = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = sampleRate,
                channelCount = channelCount,
                maxFramesPerMix = maxFramesPerMix,
                trackCount = trackCount,
                declaredFrameCount = declaredFrameCount,
            )
            sm = VanguardRealtimePlaybackTransportStateMachine(
                config = config,
                threadName = "Y3InteractiveControlsSmokeSM",
            )
            activeStateMachine = sm

            val sink = VanguardRealtimePlaybackInteractiveControlsSink()
            val sinkConfig = VanguardRealtimePlaybackInteractiveControlsSink.Config(
                stateMachine = sm,
                sampleRate = sampleRate,
                channelCount = channelCount,
                maxFramesPerMix = maxFramesPerMix,
                declaredFrameCount = declaredFrameCount,
                pauseHoldMs = pauseHoldMs,
                preControlFrames = preControlFrames,
                seekTargetFrame = seekTargetFrame,
                deadlineMs = deadlineMs,
                cancelled = { disposed.get() },
            )
            val sinkResult = sink.run(sinkConfig)

            val lanes = mutableMapOf<String, Any?>()
            lanes.putAll(sinkResult.lanes)

            val metrics = mutableMapOf<String, Any?>()
            metrics.putAll(sinkResult.metrics)

            val audioTrackInitOk = sinkResult.lanes["audioTrackInitOk"] == true
            val mutedOutputOk = sinkResult.mutedOutputOk
            val initialDrainOk = sinkResult.initialDrainOk
            val pauseCommandOk = sinkResult.pauseCommandOk
            val sinkPausedOk = sinkResult.sinkPausedOk
            val pauseHoldFrozenOk = sinkResult.pauseHoldFrozenOk
            val resumeCommandOk = sinkResult.resumeCommandOk
            val sinkResumedOk = sinkResult.sinkResumedOk
            val activeBeforeSeekOk = sinkResult.activeBeforeSeekOk
            val seekCommandOk = sinkResult.seekCommandOk
            val sinkFlushAtSeekOk = sinkResult.sinkFlushAtSeekOk
            val postSeekDrainOk = sinkResult.postSeekDrainOk
            val transportCompletedOk = sinkResult.transportCompletedOk
            val checksumIdentityOk = sinkResult.checksumIdentityOk
            val sinkWriteAccountingOk = sinkResult.sinkWriteAccountingOk &&
                sinkResult.totalFramesWrittenToSink == sinkResult.expectedFramesWrittenToSink &&
                sinkResult.framesWrittenPreSeek >= preControlFrames &&
                sinkResult.framesWrittenPostSeek == (declaredFrameCount - seekTargetFrame)
            val audioTrackReleasedOk = sinkResult.audioTrackReleasedOk && sinkResult.releaseCount == 1
            val lifecycleOk = sinkResult.lifecycleOk && sinkResult.releaseCount == 1

            lanes["audioTrackInitOk"] = audioTrackInitOk
            lanes["mutedOutputOk"] = mutedOutputOk
            lanes["initialDrainOk"] = initialDrainOk
            lanes["pauseCommandOk"] = pauseCommandOk
            lanes["sinkPausedOk"] = sinkPausedOk
            lanes["pauseHoldFrozenOk"] = pauseHoldFrozenOk
            lanes["resumeCommandOk"] = resumeCommandOk
            lanes["sinkResumedOk"] = sinkResumedOk
            lanes["activeBeforeSeekOk"] = activeBeforeSeekOk
            lanes["seekCommandOk"] = seekCommandOk
            lanes["sinkFlushAtSeekOk"] = sinkFlushAtSeekOk
            lanes["postSeekDrainOk"] = postSeekDrainOk
            lanes["transportCompletedOk"] = transportCompletedOk
            lanes["checksumIdentityOk"] = checksumIdentityOk
            lanes["sinkWriteAccountingOk"] = sinkWriteAccountingOk
            lanes["audioTrackReleasedOk"] = audioTrackReleasedOk
            lanes["lifecycleOk"] = lifecycleOk

            val pauseHoldDispatchDelta = (metrics["pauseHoldDispatchDelta"] as? Number)?.toLong() ?: -1L
            val pauseHoldPushedDelta = (metrics["pauseHoldPushedDelta"] as? Number)?.toLong() ?: -1L
            val seekGenerationBefore = (metrics["seekGenerationBefore"] as? Number)?.toLong() ?: -1L
            val seekGenerationAfter = (metrics["seekGenerationAfter"] as? Number)?.toLong() ?: -1L
            val transportState = (metrics["transportState"] as? String) ?: ""

            val pass = sinkResult.pass &&
                audioTrackInitOk &&
                mutedOutputOk &&
                initialDrainOk &&
                pauseCommandOk &&
                sinkPausedOk &&
                pauseHoldFrozenOk &&
                resumeCommandOk &&
                sinkResumedOk &&
                activeBeforeSeekOk &&
                seekCommandOk &&
                sinkFlushAtSeekOk &&
                postSeekDrainOk &&
                transportCompletedOk &&
                checksumIdentityOk &&
                sinkWriteAccountingOk &&
                audioTrackReleasedOk &&
                lifecycleOk &&
                sinkResult.proofBoundary == PROOF_BOUNDARY &&
                sinkResult.releaseCount == 1 &&
                sinkResult.totalFramesWrittenToSink == sinkResult.expectedFramesWrittenToSink &&
                sinkResult.framesWrittenPreSeek >= preControlFrames &&
                sinkResult.framesWrittenPostSeek == (declaredFrameCount - seekTargetFrame) &&
                sinkFlushAtSeekOk &&
                pauseHoldDispatchDelta == 0L &&
                pauseHoldPushedDelta == 0L &&
                seekGenerationAfter == seekGenerationBefore + 1L &&
                transportState == "COMPLETED" &&
                sinkResult.kotlinSinkChecksumHex.isNotEmpty() &&
                sinkResult.kotlinSinkChecksumHex.equals(sinkResult.nativeDrainedChecksumHex, ignoreCase = true)

            lanes["canonical"] = pass

            val status = if (pass) "pass" else sinkResult.status.ifBlank { "fail" }
            val marker = if (pass) PASS_MARKER else FAIL_MARKER
            val failureReason = if (pass) "" else sinkResult.failureReason.ifBlank { "interactive_controls_smoke_failed" }
            val lastError = if (pass) null else failureReason

            return mapOf(
                "pass" to pass,
                "status" to status,
                "marker" to marker,
                "proofBoundary" to PROOF_BOUNDARY,
                "nativeProofBoundary" to PROOF_BOUNDARY,
                "failureReason" to failureReason,
                "details" to "Y3 realtime playback interactive controls harness pass=$pass",
                "lanes" to lanes,
                "metrics" to metrics,
                "lastError" to lastError,
                "raw" to "pass=$pass;status=$status;marker=$marker",
            )
        } catch (e: Throwable) {
            return buildFailurePayload("execute_smoke_exception:${e.javaClass.simpleName}:${e.message}")
        } finally {
            try {
                sm?.dispose()
            } catch (_: Throwable) {}
            activeStateMachine = null
        }
    }

    private fun buildFailurePayload(reason: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "status" to "fail",
        "marker" to FAIL_MARKER,
        "proofBoundary" to PROOF_BOUNDARY,
        "nativeProofBoundary" to PROOF_BOUNDARY,
        "failureReason" to reason,
        "details" to reason,
        "lanes" to mapOf(
            "audioTrackInitOk" to false,
            "mutedOutputOk" to false,
            "initialDrainOk" to false,
            "pauseCommandOk" to false,
            "sinkPausedOk" to false,
            "pauseHoldFrozenOk" to false,
            "resumeCommandOk" to false,
            "sinkResumedOk" to false,
            "activeBeforeSeekOk" to false,
            "seekCommandOk" to false,
            "sinkFlushAtSeekOk" to false,
            "postSeekDrainOk" to false,
            "transportCompletedOk" to false,
            "checksumIdentityOk" to false,
            "sinkWriteAccountingOk" to false,
            "audioTrackReleasedOk" to false,
            "lifecycleOk" to false,
            "canonical" to false,
        ),
        "metrics" to mapOf(
            "failureReason" to reason,
            "releaseCount" to 0,
            "framesReadFromTransport" to 0L,
            "framesWrittenPreSeek" to 0L,
            "sinkFramesDiscardedAtSeek" to 0L,
            "framesWrittenPostSeek" to 0L,
            "totalFramesWrittenToSink" to 0L,
            "expectedFramesWrittenToSink" to 0L,
            "playbackHeadAtPause" to 0L,
            "playbackHeadAtSeek" to 0L,
            "playbackHeadFinal" to 0L,
            "pauseSnapshotDispatchCount" to 0L,
            "pauseSnapshotPushedFrames" to 0L,
            "pauseHoldDispatchDelta" to 0L,
            "pauseHoldPushedDelta" to 0L,
            "activeProbeAttempts" to 0,
            "activeProbeDrainedFrames" to 0L,
            "seekGenerationBefore" to 0L,
            "seekGenerationAfter" to 0L,
            "seekReplyPositionFrame" to -1L,
            "seekReplyDiscardedFrames" to -1L,
            "finalReplyPositionFrame" to -1L,
            "finalReplyDiscardedFrames" to -1L,
            "drainIterations" to 0L,
            "partialWriteCount" to 0L,
            "zeroWriteCount" to 0L,
            "flushCount" to 0,
            "declaredFrameCount" to 12000L,
            "sampleRate" to 48000,
            "channelCount" to 2,
            "maxFramesPerMix" to 256,
            "pauseHoldMs" to 150L,
            "preControlFrames" to 4096L,
            "seekTargetFrame" to 6000L,
            "kotlinSinkChecksumHex" to "",
            "nativeDrainedChecksumHex" to "",
            "transportStopCalled" to false,
            "transportStopAccepted" to false,
            "transportState" to "",
        ),
        "lastError" to reason,
        "raw" to "pass=false;status=fail;marker=$FAIL_MARKER;reason=$reason",
    )
}
