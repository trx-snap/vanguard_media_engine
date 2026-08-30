package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.export.AndroidAudioPcmDecoder
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Android P2-AUDIO-DEC-BRIDGE: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the native
 * DecodedAudioPcmSourceNode DAG audio-source boundary against real decoded
 * PCM from [AndroidAudioPcmDecoder]. Kotlin remains the sole owner of
 * MediaExtractor/MediaCodec OS audio decoding; this coordinator only hands
 * already-decoded PCM chunks across JNI over direct ByteBuffers. No
 * production mixdown/export route changes.
 */
class AndroidAudioDecodeBridgeSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP2AudioDecBridge"
        private const val METHOD_NAME = "runAndroidDagPhase2AudioDecodeBridgeSmoke"
        private const val PROOF_BOUNDARY =
            "native_decoded_pcm_audio_source_bridge_validation_no_mixbus_no_export_route"
        private const val MAX_CHUNK_FRAMES = 8192

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private data class Chunk(
        val buffer: ByteBuffer,
        val frameCount: Int,
        val bufferPtsUs: Long,
        val isEndOfStream: Boolean,
    )

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        runSmoke(args, result)
        return true
    }

    private fun runSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val sourcePath = args?.get("sourcePath") as? String
        val durationSec = (args?.get("durationSec") as? Number)?.toDouble() ?: 1.0

        if (sourcePath.isNullOrBlank()) {
            result.error(
                "P2_AUDIO_DEC_BRIDGE_SMOKE_FAILED",
                "runAndroidDagPhase2AudioDecodeBridgeSmoke: 'sourcePath' required",
                null,
            )
            return
        }

        Thread {
            try {
                val decode = AndroidAudioPcmDecoder.decode(
                    sourcePath = sourcePath,
                    sourceTrimStartSec = 0.0,
                    durationSec = durationSec,
                )

                val decodedPcm = decode.pcm
                if (!decode.success || decodedPcm == null || decode.frameCount <= 0) {
                    mainHandler.post {
                        result.success(makeFailedMap("decode_failed:${decode.reason}"))
                    }
                    return@Thread
                }

                val chunks = buildChunks(
                    pcm = decodedPcm,
                    totalFrames = decode.frameCount,
                    channelCount = decode.channelCount,
                    sampleRate = decode.sampleRate,
                )

                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    lifecycleObserver = VanguardLifecycleObserver(diagnostics),
                    diagnostics = diagnostics,
                    codecAdapter = null,
                )

                // ── Positive lane: exact expected frame count ────────────────
                var positiveSessionId: String? = null
                var positiveCreateRaw = "status=FAIL;reason=not_run"
                var positiveLastIngestRaw = "status=FAIL;reason=not_run"
                var positiveValidateRaw = "status=FAIL;reason=not_run"
                var positiveDestroyRaw = "status=FAIL;reason=not_run"

                try {
                    positiveCreateRaw = nativeBridge.createAndroidDagPhase2AudioDecodeBridgeSession(
                        sourceNodeId = "audio_decode_bridge_source",
                        sampleRate = decode.sampleRate,
                        channelCount = decode.channelCount,
                        expectedFrameCount = decode.frameCount,
                        timelineStartPtsUs = 0L,
                    )
                    positiveSessionId = extractSessionId(positiveCreateRaw)
                    if (positiveSessionId != null && positiveCreateRaw.startsWith("status=PASS")) {
                        positiveLastIngestRaw = ingestChunks(nativeBridge, positiveSessionId, chunks)
                        positiveValidateRaw = nativeBridge.validateAndroidDagPhase2AudioDecodeBridgeSession(
                            sessionId = positiveSessionId,
                        )
                    } else {
                        positiveValidateRaw = "status=FAIL;reason=session_create_failed"
                    }
                } finally {
                    if (positiveSessionId != null) {
                        positiveDestroyRaw = nativeBridge.destroyAndroidDagPhase2AudioDecodeBridgeSession(
                            sessionId = positiveSessionId,
                        )
                    }
                }

                val positiveCreatePass = positiveCreateRaw.startsWith("status=PASS")
                val positiveIngestPass = positiveLastIngestRaw.startsWith("status=PASS") &&
                    positiveLastIngestRaw.contains("isEndOfStream=true")
                val positiveValidatePass = positiveValidateRaw.startsWith("status=PASS")
                val positiveDestroyPass = positiveDestroyRaw.startsWith("status=PASS")
                val positiveLanePass = positiveCreatePass && positiveIngestPass &&
                    positiveValidatePass && positiveDestroyPass

                // ── Negative lane: expected frame count off by one ───────────
                var negativeSessionId: String? = null
                var negativeCreateRaw = "status=FAIL;reason=not_run"
                var negativeIngestRaw = "status=FAIL;reason=not_run"
                var negativeValidateRaw = "status=FAIL;reason=not_run"
                var negativeDestroyRaw = "status=FAIL;reason=not_run"

                try {
                    negativeCreateRaw = nativeBridge.createAndroidDagPhase2AudioDecodeBridgeSession(
                        sourceNodeId = "audio_decode_bridge_source",
                        sampleRate = decode.sampleRate,
                        channelCount = decode.channelCount,
                        expectedFrameCount = decode.frameCount + 1,
                        timelineStartPtsUs = 0L,
                    )
                    negativeSessionId = extractSessionId(negativeCreateRaw)
                    if (negativeSessionId != null && negativeCreateRaw.startsWith("status=PASS")) {
                        negativeIngestRaw = ingestChunks(nativeBridge, negativeSessionId, chunks)
                        negativeValidateRaw = nativeBridge.validateAndroidDagPhase2AudioDecodeBridgeSession(
                            sessionId = negativeSessionId,
                        )
                    } else {
                        negativeValidateRaw = "status=FAIL;reason=session_create_failed"
                    }
                } finally {
                    if (negativeSessionId != null) {
                        negativeDestroyRaw = nativeBridge.destroyAndroidDagPhase2AudioDecodeBridgeSession(
                            sessionId = negativeSessionId,
                        )
                    }
                }

                val negativeCreatePass = negativeCreateRaw.startsWith("status=PASS")
                val negativeIngestPass = negativeIngestRaw.startsWith("status=PASS")
                val negativeValidateFailsAsExpected = negativeValidateRaw.startsWith("status=FAIL") &&
                    negativeValidateRaw.contains("reason=expected_frame_count_mismatch")
                val negativeDestroyPass = negativeDestroyRaw.startsWith("status=PASS")
                val negativeLanePass = negativeCreatePass && negativeIngestPass &&
                    negativeValidateFailsAsExpected && negativeDestroyPass

                val overallPass = positiveLanePass && negativeLanePass

                val payload = mapOf(
                    "pass" to overallPass,
                    "proofBoundary" to PROOF_BOUNDARY,
                    "decodeSampleRate" to decode.sampleRate,
                    "decodeChannelCount" to decode.channelCount,
                    "decodeFrameCount" to decode.frameCount,
                    "positiveCreateRaw" to positiveCreateRaw,
                    "positiveLastIngestRaw" to positiveLastIngestRaw,
                    "positiveValidateRaw" to positiveValidateRaw,
                    "positiveDestroyRaw" to positiveDestroyRaw,
                    "negativeCreateRaw" to negativeCreateRaw,
                    "negativeValidateRaw" to negativeValidateRaw,
                    "negativeDestroyRaw" to negativeDestroyRaw,
                    "nonClaims" to makeNonClaims(),
                )

                mainHandler.post {
                    result.success(payload)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase2AudioDecodeBridgeSmoke failed", t)
                mainHandler.post {
                    result.success(
                        makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}")
                    )
                }
            }
        }.start()
    }

    private fun buildChunks(
        pcm: ShortArray,
        totalFrames: Int,
        channelCount: Int,
        sampleRate: Int,
    ): List<Chunk> {
        val chunks = mutableListOf<Chunk>()
        var offsetFrames = 0
        while (offsetFrames < totalFrames) {
            val chunkFrames = minOf(MAX_CHUNK_FRAMES, totalFrames - offsetFrames)
            val chunkSamples = chunkFrames * channelCount
            val buffer = ByteBuffer.allocateDirect(chunkSamples * 2).order(ByteOrder.nativeOrder())
            buffer.asShortBuffer().put(pcm, offsetFrames * channelCount, chunkSamples)
            val bufferPtsUs = (offsetFrames.toLong() * 1_000_000L) / sampleRate
            offsetFrames += chunkFrames
            chunks.add(Chunk(buffer, chunkFrames, bufferPtsUs, offsetFrames >= totalFrames))
        }
        return chunks
    }

    private fun ingestChunks(
        nativeBridge: VanguardNativeBridge,
        sessionId: String,
        chunks: List<Chunk>,
    ): String {
        var lastRaw = "status=FAIL;reason=not_run"
        for (chunk in chunks) {
            lastRaw = nativeBridge.ingestAndroidDagPhase2AudioDecodeBridgePcm(
                sessionId = sessionId,
                pcm16Buffer = chunk.buffer,
                frameCount = chunk.frameCount,
                bufferPtsUs = chunk.bufferPtsUs,
                isEndOfStream = chunk.isEndOfStream,
            )
        }
        return lastRaw
    }

    private fun extractSessionId(raw: String): String? {
        val parts = raw.split(";")
        for (part in parts) {
            val kv = part.split("=")
            if (kv.size == 2 && kv[0] == "sessionId") {
                return kv[1]
            }
        }
        return null
    }

    private fun makeNonClaims(): Map<String, Boolean> = mapOf(
        "productionMixdownRoute" to false,
        "audioMixBus" to false,
        "exportRoute" to false,
        "appWiring" to false,
        "iOS" to false,
        "mediaCodecInCpp" to false,
    )

    private fun makeFailedMap(reason: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "proofBoundary" to PROOF_BOUNDARY,
        "decodeSampleRate" to 0,
        "decodeChannelCount" to 0,
        "decodeFrameCount" to 0,
        "positiveCreateRaw" to "status=FAIL;reason=$reason",
        "positiveLastIngestRaw" to "status=FAIL;reason=$reason",
        "positiveValidateRaw" to "status=FAIL;reason=$reason",
        "positiveDestroyRaw" to "status=FAIL;reason=$reason",
        "negativeCreateRaw" to "status=FAIL;reason=$reason",
        "negativeValidateRaw" to "status=FAIL;reason=$reason",
        "negativeDestroyRaw" to "status=FAIL;reason=$reason",
        "nonClaims" to makeNonClaims(),
    )
}
