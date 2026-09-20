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
//   - EOS is signalled via BUFFER_FLAG_END_OF_STREAM and the whole feed +
//     drain loop is bounded by one deadline scaled from the PCM duration
//     (30 s floor, 600 s cap — see encodeDeadlineWindowMs); the EOS output
//     flag is observed before success.
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

    // Duration-scaled, bounded overall encode deadline, derived from the
    // PCM buffer's own duration (pcm.size / channelCount / sampleRate):
    //   deadline = clamp(BASE + pcmSec * PER_PCM_SEC, BASE, MAX)
    // BASE keeps the previous 30 s floor for short mixes. PER_PCM_SEC
    // (250 ms per PCM second, i.e. the encoder must sustain at least ~4x
    // realtime beyond the base) gives a 16 min mixed buffer 270 s and a
    // 3600 s buffer the MAX of 600 s, so a hung encoder still fails closed.
    private const val ENCODE_DEADLINE_BASE_MS = 30_000L
    private const val ENCODE_DEADLINE_MS_PER_PCM_SEC = 250.0
    private const val ENCODE_DEADLINE_MAX_MS = 600_000L

    /// Overall encode deadline window in ms for a PCM buffer of
    /// [totalShorts] interleaved samples at [sampleRate]/[channelCount].
    /// Long math for the frame count; the clamp bounds any oversized input.
    private fun encodeDeadlineWindowMs(totalShorts: Int, sampleRate: Int, channelCount: Int): Long {
        val frames = totalShorts.toLong() / channelCount.toLong()
        val pcmSec = frames.toDouble() / sampleRate.toDouble()
        val scaledMs = (pcmSec * ENCODE_DEADLINE_MS_PER_PCM_SEC).toLong()
            .coerceIn(0L, ENCODE_DEADLINE_MAX_MS - ENCODE_DEADLINE_BASE_MS)
        return ENCODE_DEADLINE_BASE_MS + scaledMs
    }

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
            val deadlineWindowMs = encodeDeadlineWindowMs(totalShorts, sampleRate, channelCount)
            val deadlineMs = System.currentTimeMillis() + deadlineWindowMs

            while (!eosObserved) {
                if (System.currentTimeMillis() > deadlineMs) {
                    Log.e(
                        TAG,
                        "encode timeout — deadlineMs=$deadlineWindowMs framesFed=$framesFed " +
                            "totalShorts=$totalShorts rate=$sampleRate ch=$channelCount",
                    )
                    failureReason = "aac_encode_timeout:${deadlineWindowMs}ms"
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
