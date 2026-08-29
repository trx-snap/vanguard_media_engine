package com.connects.vanguard_media_engine.audio_extraction

// ── AndroidAudioExtractionSession (Phase 5-Unit V / Phase 4-Unit D) ───────────
//
// One-shot native handler for a single beginAudioExtraction operation. Mirrors
// the iOS VGAudioOnlyExporter execution contract: runs entirely on its own
// background daemon thread, never touches a MethodChannel directly, and
// completes exactly once via the [start] completion callback regardless of
// success, failure, or cancellation.
//
// Stream-copy only (Unit V scope): the source audio track must already be AAC
// (audio/mp4a-latm) -- any other codec is rejected as invalidArgument rather
// than silently re-encoded or producing corrupt output.
//
// Trim policy: [trimStartSeconds, trimEndSeconds) in source time. Output PTS
// is rebased so the first kept sample is 0, matching the legacy
// VanguardAudioExtractor / iOS CMTimeRange behaviour.
//
// Temp/output safety: writes to "outputPath + .vgatmp" and only renames to the
// final [outputPath] after the muxer has fully finalized and the temp file is
// non-empty. Never overwrites an existing final output. Any failure or
// cancellation deletes the temp file and leaves the final path untouched.

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/** Terminal result of an [AndroidAudioExtractionSession] run. */
sealed class AndroidAudioExtractionResult {
    data class Success(val outputPath: String) : AndroidAudioExtractionResult()

    /** [code] is one of the normalized error codes shared with the Dart layer. */
    data class Failure(val code: String, val message: String?) : AndroidAudioExtractionResult()
}

class AndroidAudioExtractionSession(
    private val operationId: String,
    private val sourcePath: String,
    private val outputPath: String,
    private val trimStartSeconds: Double?,
    private val trimEndSeconds: Double?,
) {
    companion object {
        // Unit V scope: stream-copy only supports AAC source audio tracks.
        private const val AAC_MIME = "audio/mp4a-latm"
        private const val BUFFER_SIZE_BYTES = 1 * 1024 * 1024
    }

    @Volatile private var cancelRequested = false

    /** True once this session has reached a terminal state (its thread has finished running). */
    @Volatile var isFinished: Boolean = false
        private set

    /** Requests cancellation. Thread-safe, non-blocking -- only sets a flag. */
    fun requestCancel() {
        cancelRequested = true
    }

    /** Starts the extraction on a background daemon thread. Completes [completion] exactly once. */
    fun start(completion: (AndroidAudioExtractionResult) -> Unit) {
        val thread = Thread({
            val result: AndroidAudioExtractionResult = try {
                runExtraction()
            } catch (t: Throwable) {
                AndroidAudioExtractionResult.Failure(
                    "internalFailure", t.message ?: t.javaClass.simpleName)
            }
            isFinished = true
            completion(result)
        }, "VGAudioExtraction-$operationId")
        thread.isDaemon = true
        thread.start()
    }

    // ─────────────────────────────────────────────────────────────────────────

    private fun runExtraction(): AndroidAudioExtractionResult {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists() || !sourceFile.canRead()) {
            return AndroidAudioExtractionResult.Failure(
                "invalidArgument", "sourcePath does not exist or is not readable: $sourcePath")
        }
        val finalFile = File(outputPath)
        if (finalFile.exists()) {
            return AndroidAudioExtractionResult.Failure(
                "writeFailure", "outputPath already exists: $outputPath")
        }
        val parentDir = finalFile.absoluteFile.parentFile
        if (parentDir == null) {
            return AndroidAudioExtractionResult.Failure(
                "writeFailure", "outputPath has no parent directory: $outputPath")
        }
        if (!parentDir.exists() && !parentDir.mkdirs() && !parentDir.exists()) {
            return AndroidAudioExtractionResult.Failure(
                "writeFailure", "Failed to create output directory: ${parentDir.absolutePath}")
        }
        if (!parentDir.isDirectory || !parentDir.canWrite()) {
            return AndroidAudioExtractionResult.Failure(
                "writeFailure", "Output directory is not writable: ${parentDir.absolutePath}")
        }
        val tempFile = File("$outputPath.vgatmp")
        if (tempFile.exists() && !tempFile.delete()) {
            return AndroidAudioExtractionResult.Failure(
                "writeFailure", "Failed to delete stale temp file: ${tempFile.absolutePath}")
        }

        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var samplesWritten = 0
        var tempConsumed = false

        try {
            try {
                extractor.setDataSource(sourcePath)
            } catch (t: Throwable) {
                return AndroidAudioExtractionResult.Failure(
                    "readFailure", "Failed to open source: ${t.message}")
            }

            var audioTrackIndex = -1
            var selectedFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val fmt = try {
                    extractor.getTrackFormat(i)
                } catch (t: Throwable) {
                    return AndroidAudioExtractionResult.Failure(
                        "readFailure", "Failed to read source track format: ${t.message}")
                }
                val trackMime = fmt.getString(MediaFormat.KEY_MIME)
                if (trackMime != null && trackMime.startsWith("audio/")) {
                    audioTrackIndex = i
                    selectedFormat = fmt
                    break
                }
            }
            val format = selectedFormat
            if (audioTrackIndex < 0 || format == null) {
                return AndroidAudioExtractionResult.Failure(
                    "noAudioTrack", "No audio track found in $sourcePath")
            }
            val trackMime = format.getString(MediaFormat.KEY_MIME)
            if (trackMime != AAC_MIME) {
                return AndroidAudioExtractionResult.Failure(
                    "invalidArgument",
                    "Unsupported audio codec for extraction: ${trackMime ?: "unknown"}")
            }

            try {
                extractor.selectTrack(audioTrackIndex)
            } catch (t: Throwable) {
                return AndroidAudioExtractionResult.Failure(
                    "readFailure", "Failed to select source audio track: ${t.message}")
            }

            val trimStartUs = ((trimStartSeconds ?: 0.0) * 1_000_000.0).toLong().coerceAtLeast(0L)
            val trimEndUs = trimEndSeconds?.let { (it * 1_000_000.0).toLong() } ?: Long.MAX_VALUE

            if (trimStartUs > 0L) {
                extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }

            val createdMuxer: MediaMuxer
            try {
                createdMuxer =
                    MediaMuxer(tempFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            } catch (t: Throwable) {
                return AndroidAudioExtractionResult.Failure(
                    "writeFailure", "Failed to create muxer output: ${t.message}")
            }
            muxer = createdMuxer
            val muxTrack: Int
            try {
                muxTrack = createdMuxer.addTrack(format)
            } catch (t: IllegalArgumentException) {
                return AndroidAudioExtractionResult.Failure(
                    "invalidArgument", "Unsupported track format for muxing: ${t.message}")
            } catch (t: Throwable) {
                return AndroidAudioExtractionResult.Failure(
                    "writeFailure", "Failed to add track to muxer: ${t.message}")
            }
            try {
                createdMuxer.start()
            } catch (t: Throwable) {
                return AndroidAudioExtractionResult.Failure(
                    "writeFailure", "Failed to start muxer: ${t.message}")
            }
            muxerStarted = true

            fun advanceTrackOrFail(): AndroidAudioExtractionResult.Failure? = try {
                extractor.advance()
                null
            } catch (t: Throwable) {
                AndroidAudioExtractionResult.Failure(
                    "readFailure", "Failed to advance source track: ${t.message}")
            }

            val buffer = ByteBuffer.allocate(BUFFER_SIZE_BYTES)
            val info = MediaCodec.BufferInfo()
            var firstKeptPts = -1L
            var lastWrittenPts = -1L

            while (true) {
                if (cancelRequested) {
                    return AndroidAudioExtractionResult.Failure("cancelled", "Extraction cancelled")
                }
                val size = try {
                    extractor.readSampleData(buffer, 0)
                } catch (t: Throwable) {
                    return AndroidAudioExtractionResult.Failure(
                        "readFailure", "Failed to read sample data: ${t.message}")
                }
                if (size < 0) break // natural EOS

                val sampleTimeUs = try {
                    extractor.sampleTime
                } catch (t: Throwable) {
                    return AndroidAudioExtractionResult.Failure(
                        "readFailure", "Failed to read sample time: ${t.message}")
                }
                if (sampleTimeUs < 0L || sampleTimeUs < trimStartUs) {
                    advanceTrackOrFail()?.let { return it }
                    continue
                }
                if (sampleTimeUs >= trimEndUs) break

                if (firstKeptPts < 0L) firstKeptPts = sampleTimeUs
                val outputPts = sampleTimeUs - firstKeptPts

                // Enforce strictly increasing output PTS -- skip any non-increasing sample
                // rather than writing a malformed/duplicate timestamp into the muxer.
                if (outputPts <= lastWrittenPts) {
                    advanceTrackOrFail()?.let { return it }
                    continue
                }

                info.offset = 0
                info.size = size
                info.presentationTimeUs = outputPts
                info.flags = extractor.sampleFlags
                try {
                    createdMuxer.writeSampleData(muxTrack, buffer, info)
                } catch (t: Throwable) {
                    return AndroidAudioExtractionResult.Failure(
                        "writeFailure", "Failed to write sample data: ${t.message}")
                }
                lastWrittenPts = outputPts
                samplesWritten++
                advanceTrackOrFail()?.let { return it }
            }

            if (cancelRequested) {
                return AndroidAudioExtractionResult.Failure("cancelled", "Extraction cancelled")
            }
            if (samplesWritten == 0) {
                return AndroidAudioExtractionResult.Failure(
                    "invalidArgument", "No audio samples found in the requested trim range")
            }

            try {
                createdMuxer.stop()
            } catch (t: Throwable) {
                muxerStarted = false
                return AndroidAudioExtractionResult.Failure(
                    "writeFailure", "Failed to finalize muxer: ${t.message}")
            }
            muxerStarted = false
            try { createdMuxer.release() } catch (_: Throwable) {}
            muxer = null

            if (cancelRequested) {
                return AndroidAudioExtractionResult.Failure("cancelled", "Extraction cancelled")
            }
            if (tempFile.length() <= 0L) {
                return AndroidAudioExtractionResult.Failure(
                    "writeFailure", "Temp output file is empty")
            }
            if (finalFile.exists()) {
                return AndroidAudioExtractionResult.Failure(
                    "writeFailure", "outputPath already exists: $outputPath")
            }
            if (!tempFile.renameTo(finalFile)) {
                return AndroidAudioExtractionResult.Failure(
                    "writeFailure", "Failed to move temp output to final path")
            }
            tempConsumed = true
            return AndroidAudioExtractionResult.Success(outputPath)
        } catch (t: Throwable) {
            return AndroidAudioExtractionResult.Failure(
                "internalFailure", t.message ?: t.javaClass.simpleName)
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
            val activeMuxer = muxer
            if (activeMuxer != null) {
                // Only call stop() if it was started and produced at least one sample --
                // calling stop() on a muxer with zero written samples is a wrong-state
                // crash risk. Any such wrong-state stop during cleanup is swallowed.
                if (muxerStarted && samplesWritten > 0) {
                    try { activeMuxer.stop() } catch (_: Throwable) {}
                }
                try { activeMuxer.release() } catch (_: Throwable) {}
            }
            if (!tempConsumed && tempFile.exists()) {
                try { tempFile.delete() } catch (_: Throwable) {}
            }
        }
    }
}
