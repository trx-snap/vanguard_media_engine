package com.connects.vanguard_media_engine.export

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.io.File
import java.nio.ByteOrder

// ── AndroidAacEncoder (Export/Audio Unit B) ───────────────────────────────────
//
// Encodes 16-bit interleaved PCM (mono/stereo) to AAC-LC inside an .m4a
// container using MediaCodec + MediaMuxer.
//
// MediaCodec/MediaMuxer constraints observed:
//   - The muxer track is added only on INFO_OUTPUT_FORMAT_CHANGED and the
//     muxer starts immediately after addTrack, before any writeSampleData.
//   - EOS is signalled via BUFFER_FLAG_END_OF_STREAM and the final drain is
//     bounded by a deadline; the EOS output flag is observed before success.
//   - stop() is only called when the muxer started and samples were written;
//     release() for codec and muxer always runs in finally.
//   - The partial output file is deleted on failure.

/// Structured AAC encode outcome.
data class AndroidAacEncodeResult(
    val success: Boolean,
    val reason: String,
    val outputPath: String,
    val outputSizeBytes: Long,
    val encodedSamples: Int,
)

object AndroidAacEncoder {

    private const val TAG = "VanguardAacEnc"
    private const val BIT_RATE = 128_000
    private const val DEQUEUE_TIMEOUT_US = 10_000L
    private const val ENCODE_DEADLINE_MS = 30_000L

    fun encodePcm16ToM4a(
        pcm: ShortArray,
        sampleRate: Int,
        channelCount: Int,
        outputPath: String,
    ): AndroidAacEncodeResult {
        if (pcm.isEmpty() || sampleRate <= 0 || channelCount !in 1..2 || outputPath.isBlank()) {
            return failure("invalid_encode_args", outputPath)
        }

        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var muxerStoppedCleanly = false
        var muxTrackIndex = -1
        var encodedSamples = 0
        var failureReason: String? = null

        try {
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channelCount,
            ).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            }

            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec = enc
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()

            val mx = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mx

            val info = MediaCodec.BufferInfo()
            val totalShorts = pcm.size
            var shortsFed = 0
            var framesFed = 0L
            var inputDone = false
            var eosObserved = false
            val deadlineMs = System.currentTimeMillis() + ENCODE_DEADLINE_MS

            while (!eosObserved) {
                if (System.currentTimeMillis() > deadlineMs) {
                    failureReason = "aac_encode_timeout"
                    return failure(failureReason, outputPath)
                }

                if (!inputDone) {
                    val inIdx = enc.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val ptsUs = framesFed * 1_000_000L / sampleRate
                        if (shortsFed >= totalShorts) {
                            enc.queueInputBuffer(inIdx, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val inBuf = enc.getInputBuffer(inIdx)!!
                            inBuf.clear()
                            inBuf.order(ByteOrder.nativeOrder())
                            val capacityShorts = inBuf.remaining() / 2
                            // Whole frames only — keeps channels interleaved.
                            val remainingShorts = totalShorts - shortsFed
                            val chunkShorts = minOf(capacityShorts, remainingShorts)
                                .let { it - (it % channelCount) }
                            if (chunkShorts <= 0) {
                                enc.queueInputBuffer(inIdx, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                inBuf.asShortBuffer().put(pcm, shortsFed, chunkShorts)
                                enc.queueInputBuffer(inIdx, 0, chunkShorts * 2, ptsUs, 0)
                                shortsFed += chunkShorts
                                framesFed += chunkShorts / channelCount
                            }
                        }
                    }
                }

                val outIdx = enc.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        if (muxTrackIndex < 0) {
                            muxTrackIndex = mx.addTrack(enc.outputFormat)
                            mx.start()
                            muxerStarted = true
                        }
                    }
                    outIdx >= 0 -> {
                        val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        if (!isConfig && info.size > 0 && muxerStarted && muxTrackIndex >= 0) {
                            val outBuf = enc.getOutputBuffer(outIdx)!!
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            mx.writeSampleData(muxTrackIndex, outBuf, info)
                            encodedSamples++
                        }
                        enc.releaseOutputBuffer(outIdx, false)
                        if (isEos) eosObserved = true
                    }
                    // INFO_TRY_AGAIN_LATER — loop; bounded by deadline.
                }
            }

            if (!muxerStarted || encodedSamples <= 0) {
                failureReason = "no_aac_samples_written"
                return failure(failureReason, outputPath)
            }

            mx.stop()
            muxerStoppedCleanly = true

            val outputFile = File(outputPath)
            val outputSize = if (outputFile.exists()) outputFile.length() else 0L
            if (outputSize <= 0L) {
                failureReason = "output_file_empty_or_missing"
                return failure(failureReason, outputPath)
            }

            Log.i(TAG, "encode OK — samples=$encodedSamples bytes=$outputSize → $outputPath")
            return AndroidAacEncodeResult(
                success = true,
                reason = "success",
                outputPath = outputPath,
                outputSizeBytes = outputSize,
                encodedSamples = encodedSamples,
            )
        } catch (t: Throwable) {
            failureReason = "exception:${t.javaClass.simpleName}"
            Log.e(TAG, "encode failed: $t")
            return failure(failureReason, outputPath)
        } finally {
            if (muxerStarted && !muxerStoppedCleanly) {
                try { muxer?.stop() } catch (_: Throwable) {}
            }
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
            if (failureReason != null) {
                try {
                    val f = File(outputPath)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    private fun failure(reason: String, outputPath: String): AndroidAacEncodeResult =
        AndroidAacEncodeResult(
            success = false,
            reason = reason,
            outputPath = outputPath,
            outputSizeBytes = 0L,
            encodedSamples = 0,
        )
}
