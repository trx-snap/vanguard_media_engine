package com.connects.vanguard_media_engine.audio

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import java.nio.ByteOrder

// ── AndroidWaveformExtractor (Phase 5-Unit W / Phase 4-Unit E) ────────────────
//
// Android parity with VGWaveformExtractor.m (iOS AVAssetReader RMS waveform
// extraction). Owns all decode/validation logic for the `extractWaveform`
// MethodChannel route; the plugin only parses args, runs this synchronous
// call on a background thread, and posts the reply.
//
// Pipeline: MediaExtractor (first audio/ track) → MediaCodec decoder →
// streaming per-sample RMS accumulation. Full PCM is never buffered — only
// the emitted Float RMS points are retained, bounding memory for long files.
//
// Window size = round(sampleRate / samplesPerSecond) * channelCount, minimum
// 1 individual channel sample. Full windows emit sqrt(sum / target); a final
// partial window emits only when it is at least half full, using its own
// sample count as the denominator (mirrors the iOS algorithm).
object AndroidWaveformExtractor {

    private const val TAG = "VGWaveformExtractor"
    private const val DEQUEUE_TIMEOUT_US = 10_000L
    private const val DECODE_DEADLINE_MS = 120_000L

    fun extract(
        path: String?,
        samplesPerSecond: Int?,
        maxDurationSeconds: Double?,
        context: Context? = null,
    ): AndroidWaveformResult {
        return try {
            val invalidArg = validateArgs(path, samplesPerSecond, maxDurationSeconds)
            if (invalidArg != null) return invalidArg
            decode(path!!, samplesPerSecond!!, maxDurationSeconds!!, context)
        } catch (t: Throwable) {
            Log.e(TAG, "extract: unexpected failure: $t")
            AndroidWaveformResult.Failure("WAVEFORM_ERROR", t.message ?: t.javaClass.simpleName)
        }
    }

    private fun validateArgs(
        path: String?,
        samplesPerSecond: Int?,
        maxDurationSeconds: Double?,
    ): AndroidWaveformResult.Failure? {
        if (path.isNullOrBlank()) {
            return AndroidWaveformResult.Failure("INVALID_ARG", "path is required and must be non-empty")
        }
        if (samplesPerSecond == null || samplesPerSecond < 1 || samplesPerSecond > 1000) {
            return AndroidWaveformResult.Failure("INVALID_ARG", "samplesPerSecond must be in range [1, 1000]")
        }
        if (maxDurationSeconds == null || !maxDurationSeconds.isFinite() || maxDurationSeconds <= 0.0) {
            return AndroidWaveformResult.Failure("INVALID_ARG", "maxDurationSeconds must be a finite number > 0")
        }
        return null
    }

    private fun decode(
        path: String,
        samplesPerSecond: Int,
        maxDurationSeconds: Double,
        context: Context?,
    ): AndroidWaveformResult {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            try {
                AndroidUriDataSourceHelper.setExtractorDataSource(extractor, path, context)
            } catch (t: Throwable) {
                return AndroidWaveformResult.Failure(
                    "READER_SETUP_FAILED", "setDataSource failed: ${t.message ?: t.javaClass.simpleName}")
            }

            var audioTrackIndex = -1
            var audioFormat: MediaFormat? = null
            try {
                for (i in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(i)
                    if (format.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                        audioTrackIndex = i
                        audioFormat = format
                        break
                    }
                }
            } catch (t: Throwable) {
                return AndroidWaveformResult.Failure(
                    "READER_SETUP_FAILED", "track inspection failed: ${t.message ?: t.javaClass.simpleName}")
            }
            if (audioTrackIndex < 0 || audioFormat == null) {
                return AndroidWaveformResult.Failure("NO_AUDIO_TRACK", "no audio track found in $path")
            }

            val durationSeconds = readDurationSeconds(audioFormat)
            if (durationSeconds <= 0.0) {
                return AndroidWaveformResult.Failure("ZERO_DURATION", "audio duration is zero or unavailable")
            }
            if (durationSeconds > maxDurationSeconds) {
                return AndroidWaveformResult.Failure(
                    "DURATION_EXCEEDED",
                    "duration $durationSeconds exceeds maxDurationSeconds $maxDurationSeconds")
            }

            val mime = audioFormat.getString(MediaFormat.KEY_MIME)
                ?: return AndroidWaveformResult.Failure("READER_SETUP_FAILED", "missing mime type")

            val dec: MediaCodec
            try {
                extractor.selectTrack(audioTrackIndex)
                dec = MediaCodec.createDecoderByType(mime)
                codec = dec
                dec.configure(audioFormat, null, null, 0)
                dec.start()
            } catch (t: Throwable) {
                return AndroidWaveformResult.Failure(
                    "READER_SETUP_FAILED", "decoder setup failed: ${t.message ?: t.javaClass.simpleName}")
            }

            return runDecodeLoop(extractor, dec, audioFormat, samplesPerSecond, durationSeconds)
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    private fun runDecodeLoop(
        extractor: MediaExtractor,
        dec: MediaCodec,
        inputFormat: MediaFormat,
        samplesPerSecond: Int,
        durationSeconds: Double,
    ): AndroidWaveformResult {
        return try {
            var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channelCount = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT

            val samplesOut = mutableListOf<Float>()
            var sumSquares = 0.0
            var count = 0

            fun windowTarget(): Int {
                val computed = Math.round(sampleRate.toDouble() / samplesPerSecond.toDouble()).toInt() * channelCount
                return if (computed < 1) 1 else computed
            }

            fun accumulate(v: Float) {
                sumSquares += (v * v).toDouble()
                count++
                val target = windowTarget()
                if (count >= target) {
                    val rms = Math.sqrt(sumSquares / target).toFloat().coerceIn(0f, 1f)
                    samplesOut.add(rms)
                    sumSquares = 0.0
                    count = 0
                }
            }

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            val deadlineMs = System.currentTimeMillis() + DECODE_DEADLINE_MS
            while (!outputDone) {
                if (System.currentTimeMillis() > deadlineMs) {
                    return AndroidWaveformResult.Failure(
                        "READER_FAILED", "decode exceeded deadline of ${DECODE_DEADLINE_MS}ms")
                }
                if (!inputDone) {
                    val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val inBuf = dec.getInputBuffer(inIdx) ?: throw IllegalStateException("null input buffer")
                        val size = extractor.readSampleData(inBuf, 0)
                        if (size < 0) {
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
                            throw IllegalStateException("unsupported PCM encoding: $pcmEncoding")
                        }
                    }
                    outIdx >= 0 -> {
                        val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        try {
                            if (info.size > 0) {
                                val outBuf = dec.getOutputBuffer(outIdx) ?: throw IllegalStateException("null output buffer")
                                outBuf.position(info.offset)
                                outBuf.limit(info.offset + info.size)
                                outBuf.order(ByteOrder.nativeOrder())
                                when (pcmEncoding) {
                                    AudioFormat.ENCODING_PCM_16BIT -> {
                                        val sb = outBuf.asShortBuffer()
                                        while (sb.hasRemaining()) accumulate(sb.get() / 32768.0f)
                                    }
                                    AudioFormat.ENCODING_PCM_FLOAT -> {
                                        val fb = outBuf.asFloatBuffer()
                                        while (fb.hasRemaining()) accumulate(fb.get().coerceIn(-1.0f, 1.0f))
                                    }
                                    else -> throw IllegalStateException("unsupported PCM encoding: $pcmEncoding")
                                }
                            }
                        } finally {
                            dec.releaseOutputBuffer(outIdx, false)
                        }
                        if (isEos) outputDone = true
                    }
                    // INFO_TRY_AGAIN_LATER (or other negative index) — loop again.
                }
            }

            val finalTarget = windowTarget()
            if (count > 0 && count >= finalTarget / 2.0) {
                val rms = Math.sqrt(sumSquares / count).toFloat().coerceIn(0f, 1f)
                samplesOut.add(rms)
            }

            AndroidWaveformResult.Success(
                samples = samplesOut.toFloatArray(),
                durationSeconds = durationSeconds,
                samplesPerSecond = samplesPerSecond,
                pointCount = samplesOut.size,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "runDecodeLoop failed: $t")
            AndroidWaveformResult.Failure("READER_FAILED", t.message ?: t.javaClass.simpleName)
        }
    }

    /// Reads duration in seconds from [MediaFormat.KEY_DURATION] (microseconds).
    /// Returns 0.0 when missing or unreadable so callers uniformly map to
    /// ZERO_DURATION.
    private fun readDurationSeconds(format: MediaFormat): Double {
        return try {
            if (format.containsKey(MediaFormat.KEY_DURATION)) {
                val durationUs = format.getLong(MediaFormat.KEY_DURATION)
                if (durationUs > 0) durationUs / 1_000_000.0 else 0.0
            } else {
                0.0
            }
        } catch (t: Throwable) {
            0.0
        }
    }
}

/// Structured [AndroidWaveformExtractor.extract] outcome.
sealed class AndroidWaveformResult {
    data class Success(
        val samples: FloatArray,
        val durationSeconds: Double,
        val samplesPerSecond: Int,
        val pointCount: Int,
    ) : AndroidWaveformResult() {
        override fun equals(other: Any?): Boolean = this === other
        override fun hashCode(): Int = System.identityHashCode(this)
    }

    data class Failure(
        val code: String,
        val message: String,
    ) : AndroidWaveformResult()
}
