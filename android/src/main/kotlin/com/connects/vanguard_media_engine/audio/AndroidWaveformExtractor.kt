package com.connects.vanguard_media_engine.audio

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import java.nio.ByteBuffer
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
    private const val POLL_TIMEOUT_US = 0L
    private const val DRAIN_WAIT_TIMEOUT_US = 2_500L
    private const val DECODE_DEADLINE_MS = 120_000L
    private const val CHUNK_SIZE = 4096

    fun extract(
        path: String?,
        samplesPerSecond: Int?,
        maxDurationSeconds: Double?,
        context: Context? = null,
    ): AndroidWaveformResult {
        return try {
            val invalidArg = validateArgs(path, samplesPerSecond, maxDurationSeconds)
            if (invalidArg != null) return invalidArg

            // 1. Fast-Path: In-Process C++ NDK Extractor (Route 2)
            // Demuxes via AMediaExtractor and decodes directly via dr_mp3 / Helix AAC in CPU cache.
            // Takes ~50-300ms instead of 12-15s.
            try {
                val tStart = System.currentTimeMillis()
                val outDuration = DoubleArray(1)
                val nativeSamples = VanguardNativeBridge.nativeExtractWaveform(
                    path!!,
                    samplesPerSecond!!,
                    maxDurationSeconds!!,
                    outDuration
                )
                val tEnd = System.currentTimeMillis()
                if (nativeSamples != null && nativeSamples.isNotEmpty()) {
                    val dur = if (outDuration[0] > 0.0) outDuration[0] else (nativeSamples.size.toDouble() / samplesPerSecond)
                    Log.i(TAG, "extract: fast-path native extraction succeeded in ${tEnd - tStart} ms for $path (dur=${dur}s, points=${nativeSamples.size})")
                    return AndroidWaveformResult.Success(
                        samples = nativeSamples,
                        durationSeconds = dur,
                        samplesPerSecond = samplesPerSecond,
                        pointCount = nativeSamples.size,
                    )
                } else {
                    Log.w(TAG, "extract: fast-path native extraction returned empty/null in ${tEnd - tStart} ms for $path, falling back to MediaCodec")
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Native waveform extraction unavailable, falling back to MediaCodec: $t")
            }

            // 2. Resilient Fallback: Standard MediaCodec decode path
            val fallbackStart = System.currentTimeMillis()
            val fallbackResult = decode(path!!, samplesPerSecond!!, maxDurationSeconds!!, context)
            val fallbackEnd = System.currentTimeMillis()
            Log.i(TAG, "extract: fallback MediaCodec completed in ${fallbackEnd - fallbackStart} ms for $path")
            fallbackResult
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

    private fun computeWindowTarget(sampleRate: Int, samplesPerSecond: Int, channelCount: Int): Int {
        val computed = Math.round(sampleRate.toDouble() / samplesPerSecond.toDouble()).toInt() * channelCount
        return if (computed < 1) 1 else computed
    }

    private fun runDecodeLoop(
        extractor: MediaExtractor,
        dec: MediaCodec,
        inputFormat: MediaFormat,
        samplesPerSecond: Int,
        durationSeconds: Double,
    ): AndroidWaveformResult {
        return try {
            val mime = if (inputFormat.containsKey(MediaFormat.KEY_MIME)) {
                inputFormat.getString(MediaFormat.KEY_MIME) ?: ""
            } else ""
            val canBatch = mime.equals("audio/mpeg", ignoreCase = true)

            var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channelCount = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
            var windowTarget = computeWindowTarget(sampleRate, samplesPerSecond, channelCount)

            val estimatedPoints = (durationSeconds * samplesPerSecond).toInt() + 32
            var samplesOut = FloatArray(if (estimatedPoints > 64) estimatedPoints else 64)
            var samplesCount = 0

            fun appendRms(rms: Float) {
                if (samplesCount >= samplesOut.size) {
                    samplesOut = samplesOut.copyOf(samplesOut.size * 2)
                }
                samplesOut[samplesCount++] = rms.coerceIn(0f, 1f)
            }

            var sumSquaresLong = 0L
            var sumSquaresFloat = 0.0
            var count = 0
            val shortChunk = ShortArray(CHUNK_SIZE)
            val floatChunk = FloatArray(CHUNK_SIZE)

            fun processPcm16(outBuf: ByteBuffer) {
                val sb = outBuf.asShortBuffer()
                while (sb.hasRemaining()) {
                    val toRead = Math.min(sb.remaining(), CHUNK_SIZE)
                    sb.get(shortChunk, 0, toRead)
                    for (i in 0 until toRead) {
                        val s = shortChunk[i].toLong()
                        sumSquaresLong += s * s
                        count++
                        if (count >= windowTarget) {
                            val meanSquare = sumSquaresLong.toDouble() / (windowTarget.toDouble() * 1073741824.0)
                            val rms = Math.sqrt(meanSquare).toFloat()
                            appendRms(rms)
                            sumSquaresLong = 0L
                            count = 0
                        }
                    }
                }
            }

            fun processPcmFloat(outBuf: ByteBuffer) {
                val fb = outBuf.asFloatBuffer()
                while (fb.hasRemaining()) {
                    val toRead = Math.min(fb.remaining(), CHUNK_SIZE)
                    fb.get(floatChunk, 0, toRead)
                    for (i in 0 until toRead) {
                        val v = floatChunk[i].coerceIn(-1.0f, 1.0f)
                        sumSquaresFloat += (v * v).toDouble()
                        count++
                        if (count >= windowTarget) {
                            val rms = Math.sqrt(sumSquaresFloat / windowTarget.toDouble()).toFloat()
                            appendRms(rms)
                            sumSquaresFloat = 0.0
                            count = 0
                        }
                    }
                }
            }

            fun updateFormat() {
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
                windowTarget = computeWindowTarget(sampleRate, samplesPerSecond, channelCount)
            }

            val info = MediaCodec.BufferInfo()

            fun handleOutputBuffer(outIdx: Int): Boolean {
                val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                try {
                    if (info.size > 0) {
                        val outBuf = dec.getOutputBuffer(outIdx) ?: throw IllegalStateException("null output buffer")
                        outBuf.position(info.offset)
                        outBuf.limit(info.offset + info.size)
                        outBuf.order(ByteOrder.nativeOrder())
                        when (pcmEncoding) {
                            AudioFormat.ENCODING_PCM_16BIT -> processPcm16(outBuf)
                            AudioFormat.ENCODING_PCM_FLOAT -> processPcmFloat(outBuf)
                            else -> throw IllegalStateException("unsupported PCM encoding: $pcmEncoding")
                        }
                    }
                } finally {
                    dec.releaseOutputBuffer(outIdx, false)
                }
                return isEos
            }

            var inputDone = false
            var outputDone = false
            val deadlineMs = System.currentTimeMillis() + DECODE_DEADLINE_MS

            while (!outputDone) {
                if (System.currentTimeMillis() > deadlineMs) {
                    return AndroidWaveformResult.Failure(
                        "READER_FAILED", "decode exceeded deadline of ${DECODE_DEADLINE_MS}ms")
                }

                var progressed = false

                // 1. Drain input buffers (feed as many as decoder can accept without blocking)
                while (!inputDone) {
                    val inIdx = dec.dequeueInputBuffer(POLL_TIMEOUT_US)
                    if (inIdx < 0) break
                    val inBuf = dec.getInputBuffer(inIdx) ?: throw IllegalStateException("null input buffer")

                    if (canBatch) {
                        var offset = 0
                        var firstSampleTime = -1L
                        val capacity = inBuf.capacity()

                        while (offset == 0 || offset + 2048 <= capacity) {
                            inBuf.position(offset)
                            inBuf.limit(capacity)
                            val size = extractor.readSampleData(inBuf, offset)
                            if (size < 0) {
                                inputDone = true
                                break
                            }
                            if (firstSampleTime < 0L) {
                                firstSampleTime = extractor.sampleTime
                            }
                            offset += size
                            extractor.advance()
                        }

                        if (inputDone && offset == 0) {
                            dec.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        } else {
                            val flags = if (inputDone) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
                            dec.queueInputBuffer(
                                inIdx,
                                0,
                                offset,
                                if (firstSampleTime >= 0L) firstSampleTime else 0L,
                                flags
                            )
                        }
                    } else {
                        val size = extractor.readSampleData(inBuf, 0)
                        if (size < 0) {
                            dec.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                    progressed = true
                }

                // 2. Drain output buffers (process all available decoded frames without blocking)
                while (!outputDone) {
                    val outIdx = dec.dequeueOutputBuffer(info, POLL_TIMEOUT_US)
                    when {
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            progressed = true
                            updateFormat()
                        }
                        outIdx >= 0 -> {
                            progressed = true
                            if (handleOutputBuffer(outIdx)) {
                                outputDone = true
                                break
                            }
                        }
                        else -> break // No more output buffers available right now
                    }
                }

                // 3. If neither input nor output made progress, wait briefly for decoder output
                if (!progressed && !outputDone) {
                    val outIdx = dec.dequeueOutputBuffer(info, DRAIN_WAIT_TIMEOUT_US)
                    when {
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            updateFormat()
                        }
                        outIdx >= 0 -> {
                            if (handleOutputBuffer(outIdx)) {
                                outputDone = true
                            }
                        }
                    }
                }
            }

            if (count > 0 && count >= windowTarget / 2.0) {
                val rms = if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                    Math.sqrt(sumSquaresFloat / count.toDouble()).toFloat()
                } else {
                    val meanSquare = sumSquaresLong.toDouble() / (count.toDouble() * 1073741824.0)
                    Math.sqrt(meanSquare).toFloat()
                }
                appendRms(rms)
            }

            val finalSamples = if (samplesCount == samplesOut.size) {
                samplesOut
            } else {
                samplesOut.copyOf(samplesCount)
            }

            AndroidWaveformResult.Success(
                samples = finalSamples,
                durationSeconds = durationSeconds,
                samplesPerSecond = samplesPerSecond,
                pointCount = samplesCount,
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
