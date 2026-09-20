package com.connects.vanguard_media_engine.export

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import java.nio.ByteOrder

// ── AndroidAudioPcmDecoder (Export/Audio Unit B) ──────────────────────────────
//
// Decodes a local audio file (or the first audio track of a video file) to
// 16-bit interleaved PCM, bounded by sourceTrimStart/duration in source-file
// seconds.
//
// Pipeline: MediaExtractor (first audio track, seek to trim start)
//   → MediaCodec decoder → PCM 16-bit interleaved ShortArray.
//
// Handling:
//   - INFO_OUTPUT_FORMAT_CHANGED refreshes sampleRate / channelCount / PCM
//     encoding.
//   - ENCODING_PCM_16BIT is consumed directly; ENCODING_PCM_FLOAT is clamped
//     and converted to 16-bit; other encodings return a structured
//     "unsupported_pcm_encoding" failure.
//   - Frames before the trim start or past the requested duration are dropped
//     at frame precision.
//   - The drain loop is bounded by an overall deadline scaled from the
//     requested duration (30 s floor, 600 s cap — see
//     decodeDeadlineWindowMs); codec stop/release and extractor release
//     always run in finally.

/// Structured PCM decode outcome. [pcm] is 16-bit interleaved samples
/// ([frameCount] * [channelCount] shorts) on success, null on failure.
data class AndroidAudioPcmDecodeResult(
    val success: Boolean,
    val reason: String,
    val pcm: ShortArray?,
    val sampleRate: Int,
    val channelCount: Int,
    val frameCount: Int,
) {
    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)
}

object AndroidAudioPcmDecoder {

    private const val TAG = "VanguardAudioPcmDec"
    private const val DEQUEUE_TIMEOUT_US = 10_000L

    // Duration-scaled, bounded overall decode deadline:
    //   deadline = clamp(BASE + durationSec * PER_SOURCE_SEC, BASE, MAX)
    // BASE keeps the previous 30 s floor for short clips. PER_SOURCE_SEC
    // (250 ms per requested source second, i.e. the decoder must sustain
    // at least ~4x realtime beyond the base) gives a 16 min track 270 s
    // and a 3600 s request the MAX of 600 s, so a stalled/broken codec
    // still fails closed rather than hanging the export.
    private const val DECODE_DEADLINE_BASE_MS = 30_000L
    private const val DECODE_DEADLINE_MS_PER_SOURCE_SEC = 250.0
    private const val DECODE_DEADLINE_MAX_MS = 600_000L

    /// Overall decode deadline window for a [durationSec] request, in ms.
    /// Infinity/NaN/oversized durations are bounded by the clamp (the
    /// Double->Long narrowing saturates; NaN narrows to 0 -> BASE).
    private fun decodeDeadlineWindowMs(durationSec: Double): Long {
        val scaledMs = (durationSec * DECODE_DEADLINE_MS_PER_SOURCE_SEC).toLong()
            .coerceIn(0L, DECODE_DEADLINE_MAX_MS - DECODE_DEADLINE_BASE_MS)
        return DECODE_DEADLINE_BASE_MS + scaledMs
    }

    /// [context] is an optional Context used ONLY when [sourcePath] is a
    /// `content://` URI (AndroidUriDataSourceHelper); POSIX paths never
    /// touch it. A `content://` source with a null Context fails closed as
    /// `exception:IllegalArgumentException` through the existing catch --
    /// the extractor/codec releases in `finally` are unchanged.
    fun decode(
        sourcePath: String,
        sourceTrimStartSec: Double,
        durationSec: Double,
        context: Context? = null,
    ): AndroidAudioPcmDecodeResult {
        if (durationSec <= 0.0 || sourceTrimStartSec < 0.0) {
            return failure("invalid_decode_range")
        }

        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            AndroidUriDataSourceHelper.setExtractorDataSource(extractor, sourcePath, context)

            var audioTrackIndex = -1
            var audioFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    audioTrackIndex = i
                    audioFormat = format
                    break
                }
            }
            if (audioTrackIndex < 0 || audioFormat == null) {
                return failure("no_audio_track")
            }
            extractor.selectTrack(audioTrackIndex)

            val trimStartUs = (sourceTrimStartSec * 1_000_000.0).toLong()
            val trimEndUs = trimStartUs + (durationSec * 1_000_000.0).toLong()
            if (trimStartUs > 0L) {
                extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }

            val mime = audioFormat.getString(MediaFormat.KEY_MIME)!!
            val dec = MediaCodec.createDecoderByType(mime)
            codec = dec
            dec.configure(audioFormat, null, null, 0)
            dec.start()

            var sampleRate = audioFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channelCount = audioFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT

            val chunks = mutableListOf<ShortArray>()
            var collectedFrames = 0
            val maxFramesGuess = { (durationSec * sampleRate).toLong() + sampleRate }

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            val deadlineWindowMs = decodeDeadlineWindowMs(durationSec)
            val deadlineMs = System.currentTimeMillis() + deadlineWindowMs

            while (!outputDone) {
                if (System.currentTimeMillis() > deadlineMs) {
                    Log.e(
                        TAG,
                        "decode timeout — durationSec=$durationSec deadlineMs=$deadlineWindowMs " +
                            "collectedFrames=$collectedFrames ← $sourcePath",
                    )
                    return failure("decoder_timeout:${deadlineWindowMs}ms")
                }

                if (!inputDone) {
                    val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val inBuf = dec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(inBuf, 0)
                        if (size < 0 || extractor.sampleTime > trimEndUs) {
                            dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIdx = dec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val outFormat = dec.outputFormat
                        sampleRate = outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channelCount = outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        pcmEncoding = if (outFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            outFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } else {
                            AudioFormat.ENCODING_PCM_16BIT
                        }
                        if (pcmEncoding != AudioFormat.ENCODING_PCM_16BIT &&
                            pcmEncoding != AudioFormat.ENCODING_PCM_FLOAT
                        ) {
                            return failure("unsupported_pcm_encoding:$pcmEncoding")
                        }
                    }
                    outIdx >= 0 -> {
                        val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        if (info.size > 0 && collectedFrames < maxFramesGuess()) {
                            val outBuf = dec.getOutputBuffer(outIdx)!!
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            outBuf.order(ByteOrder.nativeOrder())

                            val samples: ShortArray = when (pcmEncoding) {
                                AudioFormat.ENCODING_PCM_16BIT -> {
                                    val sb = outBuf.asShortBuffer()
                                    ShortArray(sb.remaining()).also { sb.get(it) }
                                }
                                else -> { // ENCODING_PCM_FLOAT — clamp and convert.
                                    val fb = outBuf.asFloatBuffer()
                                    ShortArray(fb.remaining()) {
                                        val f = fb.get().coerceIn(-1.0f, 1.0f)
                                        (f * Short.MAX_VALUE).toInt().toShort()
                                    }
                                }
                            }

                            val kept = trimToRange(
                                samples = samples,
                                bufferPtsUs = info.presentationTimeUs,
                                trimStartUs = trimStartUs,
                                trimEndUs = trimEndUs,
                                sampleRate = sampleRate,
                                channelCount = channelCount,
                            )
                            if (kept.isNotEmpty()) {
                                chunks.add(kept)
                                collectedFrames += kept.size / channelCount
                            }
                        }
                        dec.releaseOutputBuffer(outIdx, false)
                        if (isEos) outputDone = true
                    }
                    // INFO_TRY_AGAIN_LATER — loop; the deadline bounds the wait.
                }
            }

            if (collectedFrames <= 0) {
                return failure("no_pcm_frames_decoded")
            }

            // Cap at the requested duration in frames.
            val requestedFrames = (durationSec * sampleRate).toLong()
                .coerceAtMost(collectedFrames.toLong()).toInt()
            val pcm = ShortArray(requestedFrames * channelCount)
            var offset = 0
            for (chunk in chunks) {
                if (offset >= pcm.size) break
                val toCopy = minOf(chunk.size, pcm.size - offset)
                System.arraycopy(chunk, 0, pcm, offset, toCopy)
                offset += toCopy
            }

            Log.i(TAG, "decode OK — frames=$requestedFrames rate=$sampleRate ch=$channelCount ← $sourcePath")
            return AndroidAudioPcmDecodeResult(
                success = true,
                reason = "success",
                pcm = pcm,
                sampleRate = sampleRate,
                channelCount = channelCount,
                frameCount = requestedFrames,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "decode failed: $t")
            return failure("exception:${t.javaClass.simpleName}")
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    /// Frame-precision trim: keeps only frames whose PTS falls inside
    /// [trimStartUs, trimEndUs), computed from the buffer's start PTS.
    private fun trimToRange(
        samples: ShortArray,
        bufferPtsUs: Long,
        trimStartUs: Long,
        trimEndUs: Long,
        sampleRate: Int,
        channelCount: Int,
    ): ShortArray {
        val bufferFrames = samples.size / channelCount
        if (bufferFrames == 0) return ShortArray(0)
        val usPerFrame = 1_000_000.0 / sampleRate

        var firstKeep = 0
        if (bufferPtsUs < trimStartUs) {
            firstKeep = Math.ceil((trimStartUs - bufferPtsUs) / usPerFrame).toInt()
        }
        var lastKeepExclusive = bufferFrames
        val bufferEndUs = bufferPtsUs + (bufferFrames * usPerFrame).toLong()
        if (bufferEndUs > trimEndUs) {
            lastKeepExclusive = Math.ceil((trimEndUs - bufferPtsUs) / usPerFrame)
                .toInt().coerceIn(0, bufferFrames)
        }
        if (firstKeep >= lastKeepExclusive) return ShortArray(0)
        if (firstKeep == 0 && lastKeepExclusive == bufferFrames) return samples
        return samples.copyOfRange(firstKeep * channelCount, lastKeepExclusive * channelCount)
    }

    private fun failure(reason: String): AndroidAudioPcmDecodeResult =
        AndroidAudioPcmDecodeResult(
            success = false,
            reason = reason,
            pcm = null,
            sampleRate = 0,
            channelCount = 0,
            frameCount = 0,
        )
}
