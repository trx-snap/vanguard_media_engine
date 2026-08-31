package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-GRAPH-TRANSPORT-CLOCK sub-slice G2b: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the Kotlin-owned
 * MediaCodec/MediaExtractor streaming decode into the native decoder
 * ring-ingest diagnostic session ([AndroidAudioStreamingPcmDecoder], sub-slice G2).
 *
 * Honest non-claims (Proof Boundary):
 * - Kotlin-owned MediaCodec/MediaExtractor streaming decode to JNI decoder
 *   ring-ingest proof only; C++ never owns MediaCodec/MediaExtractor and does
 *   no file IO; no AudioTrack, no AAudio, no OpenSL, no Oboe, no audible or
 *   realtime playback, no graph scheduler, no mix bus, no coordinator, no
 *   closed-loop sink, no source-node wiring, no resample, no downmix
 *   (1-2 channels only), no export reroute, no pass-2 graph reroute,
 *   no streaming, no cache, no iOS, no product/editor UI.
 *   Writer-local EOS only. Single owner thread on the decode side.
 * - The coordinator dispatches to one background [Thread] per accepted run to
 *   keep the Flutter UI thread responsive; runs are serialized by an active
 *   flag and never overlap.
 * - Detach-safe: after [disposeAll] no MethodChannel reply is ever delivered;
 *   an in-flight decoder run finishes naturally on its own thread (MediaCodec
 *   is never forcibly stopped from another thread).
 */
class AndroidAudioDecoderRingIngestSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioDecoderRingIngest"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioDecoderRingIngestSmoke"
        private const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_AUDIO_DECODER_RING_INGEST_SMOKE_FAIL"
        private const val PROOF_BOUNDARY =
            "kotlin_owned_mediacodec_mediaextractor_streaming_decode_to_jni_decoder_ring_ingest_proof_only_no_cpp_os_decoder_no_mediacodec_or_mediaextractor_ownership_in_cpp_no_cpp_file_io_no_wall_clock_read_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_no_audio_track_no_aaudio_no_opensl_no_oboe_no_audible_or_realtime_playback_no_graph_scheduler_no_mix_bus_no_coordinator_no_closed_loop_sink_no_source_node_wiring_no_resample_no_downmix_channels_1_or_2_only_no_export_reroute_no_pass2_graph_reroute_no_streaming_no_cache_no_ios_no_product_no_editor_ui_writer_local_eos_only_native_zero_steady_state_allocation_only_jvm_heap_non_claim"

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
            // Detached: never reply after disposeAll(); the engine-side channel
            // is already torn down.
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }
        val sourcePath = args?.get("sourcePath") as? String
        if (sourcePath.isNullOrBlank()) {
            result.error(
                "P4_AUDIO_DECODER_RING_INGEST_SMOKE_FAILED",
                "runAndroidDagPhase4AudioDecoderRingIngestSmoke: 'sourcePath' required",
                null,
            )
            return true
        }
        val durationSec = (args["durationSec"] as? Number)?.toDouble() ?: 1.0
        val seekTargetSec = (args["seekTargetSec"] as? Number)?.toDouble() ?: 0.35
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_AUDIO_DECODER_RING_INGEST_SMOKE_BUSY",
                "runAndroidDagPhase4AudioDecoderRingIngestSmoke: diagnostic already running",
                null,
            )
            return true
        }
        runSmoke(sourcePath, durationSec, seekTargetSec, result)
        return true
    }

    /**
     * Marks the coordinator disposed. An in-flight decoder run is allowed to
     * finish naturally (its reply is dropped); MediaCodec is never stopped
     * from another thread.
     */
    fun disposeAll() {
        disposed.set(true)
    }

    private fun runSmoke(
        sourcePath: String,
        durationSec: Double,
        seekTargetSec: Double,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val decodeResult = AndroidAudioStreamingPcmDecoder().run(
                    AndroidAudioStreamingPcmDecoder.DecodeConfig(
                        sourcePath = sourcePath,
                        durationSec = durationSec,
                        seekTargetSec = seekTargetSec,
                    )
                )
                postReply(replied, result, toPayload(decodeResult))
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

    private fun toPayload(r: AndroidAudioStreamingPcmDecoder.DecodeResult): Map<String, Any?> {
        val metrics = mapOf<String, Any?>(
            "sampleRate" to r.sampleRate,
            "channelCount" to r.channelCount,
            "pcmEncoding" to r.pcmEncoding,
            "totalFramesAccepted" to r.totalFramesAccepted,
            "totalFramesDrained" to r.totalFramesDrained,
            "postSeekFramesAccepted" to r.postSeekFramesAccepted,
            "postSeekFramesDrained" to r.postSeekFramesDrained,
            "kotlinAcceptedChecksumHex" to r.kotlinAcceptedChecksumHex,
            "nativeAcceptedChecksumHex" to r.nativeAcceptedChecksumHex,
            "nativeDrainedChecksumHex" to r.nativeDrainedChecksumHex,
            "observedPartialWrite" to r.observedPartialWrite,
            "observedRingFull" to r.observedRingFull,
            "syntheticProbeChunk" to r.syntheticProbeChunk,
            "midStreamFormatChangeRejected" to r.midStreamFormatChangeRejected,
            "seekAckObserved" to r.seekAckObserved,
            "discardedFramesOnSeek" to r.discardedFramesOnSeek,
            "newStartFrame" to r.newStartFrame,
        )
        return mapOf(
            "pass" to r.pass,
            "status" to r.status,
            "marker" to r.marker,
            "proofBoundary" to r.proofBoundary,
            "failureReason" to r.failureReason,
            "details" to r.details,
            "sampleRate" to r.sampleRate,
            "channelCount" to r.channelCount,
            "pcmEncoding" to r.pcmEncoding,
            "totalFramesAccepted" to r.totalFramesAccepted,
            "totalFramesDrained" to r.totalFramesDrained,
            "postSeekFramesAccepted" to r.postSeekFramesAccepted,
            "postSeekFramesDrained" to r.postSeekFramesDrained,
            "kotlinAcceptedChecksumHex" to r.kotlinAcceptedChecksumHex,
            "nativeAcceptedChecksumHex" to r.nativeAcceptedChecksumHex,
            "nativeDrainedChecksumHex" to r.nativeDrainedChecksumHex,
            "observedPartialWrite" to r.observedPartialWrite,
            "observedRingFull" to r.observedRingFull,
            "syntheticProbeChunk" to r.syntheticProbeChunk,
            "eosAlreadyEosStatus" to r.eosAlreadyEosStatus,
            "eosAwaitingSeekAckStatus" to r.eosAwaitingSeekAckStatus,
            "eosPostAckStatus" to r.eosPostAckStatus,
            "midStreamFormatChangeRejected" to r.midStreamFormatChangeRejected,
            "seekAckObserved" to r.seekAckObserved,
            "discardedFramesOnSeek" to r.discardedFramesOnSeek,
            "newStartFrame" to r.newStartFrame,
            "metrics" to metrics,
            "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
        )
    }

    // Same key shape as toPayload so the Dart harness sees a stable map even
    // when the decoder throws before producing a DecodeResult.
    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val metrics = mapOf<String, Any?>(
            "sampleRate" to 0,
            "channelCount" to 0,
            "pcmEncoding" to 0,
            "totalFramesAccepted" to 0L,
            "totalFramesDrained" to 0L,
            "postSeekFramesAccepted" to 0L,
            "postSeekFramesDrained" to 0L,
            "kotlinAcceptedChecksumHex" to "",
            "nativeAcceptedChecksumHex" to "",
            "nativeDrainedChecksumHex" to "",
            "observedPartialWrite" to false,
            "observedRingFull" to false,
            "syntheticProbeChunk" to false,
            "midStreamFormatChangeRejected" to false,
            "seekAckObserved" to false,
            "discardedFramesOnSeek" to 0L,
            "newStartFrame" to -1L,
        )
        return mapOf(
            "pass" to false,
            "status" to "fail",
            "marker" to FAIL_MARKER,
            "proofBoundary" to PROOF_BOUNDARY,
            "failureReason" to reason,
            "details" to "",
            "sampleRate" to 0,
            "channelCount" to 0,
            "pcmEncoding" to 0,
            "totalFramesAccepted" to 0L,
            "totalFramesDrained" to 0L,
            "postSeekFramesAccepted" to 0L,
            "postSeekFramesDrained" to 0L,
            "kotlinAcceptedChecksumHex" to "",
            "nativeAcceptedChecksumHex" to "",
            "nativeDrainedChecksumHex" to "",
            "observedPartialWrite" to false,
            "observedRingFull" to false,
            "syntheticProbeChunk" to false,
            "eosAlreadyEosStatus" to "",
            "eosAwaitingSeekAckStatus" to "",
            "eosPostAckStatus" to "",
            "midStreamFormatChangeRejected" to false,
            "seekAckObserved" to false,
            "discardedFramesOnSeek" to 0L,
            "newStartFrame" to -1L,
            "metrics" to metrics,
            "lastError" to reason,
        )
    }
}
