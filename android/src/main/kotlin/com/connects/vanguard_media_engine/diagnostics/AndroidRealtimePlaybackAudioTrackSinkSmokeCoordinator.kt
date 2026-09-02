package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackAudioTrackSink
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-AUDIOTRACK-SINK (Y2):
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating the production
 * [VanguardRealtimePlaybackAudioTrackSink] adapter driven by the authoritative
 * Kotlin transport state machine ([VanguardRealtimePlaybackTransportStateMachine]):
 * - Sample rate = 48000, channel count = 2, maxFramesPerMix = 256,
 *   track count = 2, declaredFrameCount = 12000 (tail is non-window-aligned).
 * - Drains mixed PCM16 into a muted android.media.AudioTrack MODE_STREAM sink.
 * - Asserts audioTrackInitOk, mutedOutputOk, transportCompletedOk,
 *   checksumIdentityOk, sinkWriteAccountingOk, playbackHeadAdvancedOk,
 *   audioTrackReleasedOk, and lifecycleOk.
 * - Asserts framesReadFromTransport == framesWrittenToSink == declaredFrameCount
 *   and releaseCount == 1.
 *
 * Proof boundary non-claims:
 * muted diagnostic AudioTrack sink only, synthetic PCM expected from Y1 transport,
 * no MediaCodec, no MediaExtractor, no audio focus, no route change, no
 * dead-object recovery, no presentation clock, no A/V sync, no audible output
 * claim, no product/editor/app wiring, no iOS, no native C++ changes.
 */
class AndroidRealtimePlaybackAudioTrackSinkSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY2AudioTrackSink"
        const val METHOD_NAME = "runRealtimePlaybackAudioTrackSinkSmoke"

        const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_PHYSICAL_SMOKE_FAIL"
        const val START_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_SMOKE_START"
        const val JSON_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_JSON"

        const val PROOF_BOUNDARY =
            VanguardRealtimePlaybackAudioTrackSink.PROOF_BOUNDARY

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
                "P4_REALTIME_PLAYBACK_AUDIOTRACK_SINK_SMOKE_BUSY",
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

            val config = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = sampleRate,
                channelCount = channelCount,
                maxFramesPerMix = maxFramesPerMix,
                trackCount = trackCount,
                declaredFrameCount = declaredFrameCount,
            )
            sm = VanguardRealtimePlaybackTransportStateMachine(
                config = config,
                threadName = "Y2AudioTrackSinkSmokeSM",
            )
            activeStateMachine = sm

            val sink = VanguardRealtimePlaybackAudioTrackSink()
            val sinkConfig = VanguardRealtimePlaybackAudioTrackSink.Config(
                stateMachine = sm,
                sampleRate = sampleRate,
                channelCount = channelCount,
                maxFramesPerMix = maxFramesPerMix,
                declaredFrameCount = declaredFrameCount,
                deadlineMs = 20000L,
                cancelled = { disposed.get() },
            )
            val sinkResult = sink.run(sinkConfig)

            val lanes = mutableMapOf<String, Any?>()
            lanes.putAll(sinkResult.lanes)

            val metrics = mutableMapOf<String, Any?>()
            metrics.putAll(sinkResult.metrics)

            val audioTrackInitOk = sinkResult.lanes["audioTrackInitOk"] == true
            val mutedOutputOk = sinkResult.mutedOutputOk
            val transportCompletedOk = sinkResult.transportCompletedOk
            val checksumIdentityOk = sinkResult.checksumIdentityOk
            val sinkWriteAccountingOk = sinkResult.sinkWriteAccountingOk &&
                sinkResult.framesReadFromTransport == declaredFrameCount &&
                sinkResult.framesWrittenToSink == declaredFrameCount &&
                sinkResult.framesReadFromTransport == sinkResult.framesWrittenToSink
            val playbackHeadAdvancedOk = sinkResult.playbackHeadAdvancedOk
            val audioTrackReleasedOk = sinkResult.audioTrackReleasedOk && sinkResult.releaseCount == 1
            val lifecycleOk = sinkResult.lifecycleOk && sinkResult.releaseCount == 1

            lanes["audioTrackInitOk"] = audioTrackInitOk
            lanes["mutedOutputOk"] = mutedOutputOk
            lanes["transportCompletedOk"] = transportCompletedOk
            lanes["checksumIdentityOk"] = checksumIdentityOk
            lanes["sinkWriteAccountingOk"] = sinkWriteAccountingOk
            lanes["playbackHeadAdvancedOk"] = playbackHeadAdvancedOk
            lanes["audioTrackReleasedOk"] = audioTrackReleasedOk
            lanes["lifecycleOk"] = lifecycleOk

            val pass = sinkResult.pass &&
                audioTrackInitOk &&
                mutedOutputOk &&
                transportCompletedOk &&
                checksumIdentityOk &&
                sinkWriteAccountingOk &&
                playbackHeadAdvancedOk &&
                audioTrackReleasedOk &&
                lifecycleOk

            lanes["canonical"] = pass

            val status = if (pass) "pass" else sinkResult.status.ifBlank { "fail" }
            val marker = if (pass) PASS_MARKER else FAIL_MARKER
            val failureReason = if (pass) "" else sinkResult.failureReason.ifBlank { "sink_smoke_failed" }
            val lastError = if (pass) null else failureReason

            return mapOf(
                "pass" to pass,
                "status" to status,
                "marker" to marker,
                "proofBoundary" to PROOF_BOUNDARY,
                "nativeProofBoundary" to PROOF_BOUNDARY,
                "failureReason" to failureReason,
                "details" to "Y2 realtime playback AudioTrack sink harness pass=$pass",
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
            "transportCompletedOk" to false,
            "checksumIdentityOk" to false,
            "sinkWriteAccountingOk" to false,
            "playbackHeadAdvancedOk" to false,
            "audioTrackReleasedOk" to false,
            "lifecycleOk" to false,
            "canonical" to false,
        ),
        "metrics" to mapOf(
            "failureReason" to reason,
            "releaseCount" to 0,
            "framesReadFromTransport" to 0L,
            "framesWrittenToSink" to 0L,
            "declaredFrameCount" to 12000L,
            "sampleRate" to 48000,
            "channelCount" to 2,
            "maxFramesPerMix" to 256,
        ),
        "lastError" to reason,
        "raw" to "pass=false;status=fail;marker=$FAIL_MARKER;reason=$reason",
    )
}
