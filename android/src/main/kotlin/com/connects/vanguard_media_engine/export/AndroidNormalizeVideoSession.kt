package com.connects.vanguard_media_engine.export

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.io.File
import java.nio.ByteBuffer

// -- AndroidNormalizeVideoSession (Phase 5-Unit AA / Phase 2-Unit AI) ----------
//
// One-shot native handler for a single `normalizeVideo` MethodChannel call.
// Remuxes one readable local source video (first video track + optional
// first audio track) into one caller-supplied output path on a background
// thread, sharing the AndroidEditorExportCoordinator export lock with
// `exportTimeline` / `exportPassthroughRemux`.
//
// This is a single-source-file remux: unlike [AndroidAudioRemuxer] (which
// merges a separate video file and audio file), video and audio here both
// come from the same [inputPath], so a single MediaExtractor with both
// tracks selected is used and samples are interleaved by
// [MediaExtractor.getSampleTrackIndex]. Container-level rotation is
// preserved via [MediaMuxer.setOrientationHint] rather than by baking pixels
// -- see [run] step 4.
//
// Non-claims: single video + optional single audio track only. Timed
// metadata, subtitle tracks, and any additional tracks beyond the first
// video/audio are dropped -- this is not a general-purpose container copier.
// No ROI sidecar is emitted (unlike exportTimeline/exportPassthroughRemux).
// No faststart guarantee (moov is not repositioned). No selective metadata
// filtering equivalent to iOS's AVMetadataItemFilter.forSharing() --
// MediaMuxer only ever writes the track headers it was given plus the
// orientation hint; it never calls setLocation(), so no GPS metadata is
// written either way.
//
// Cancellation: [requestCancel] is honored before the remux call starts and
// after it returns (temp is deleted, EXPORT_CANCELLED). The remux itself is
// not cancellable mid-flight -- once started, a requested cancellation is
// only observed after remux returns, matching the existing
// AndroidPassthroughRemuxSession (Phase 2-Unit AD) limitation.
//
// Diagnostic hold: an optional `diagnosticHoldBeforeRemuxMs` arg (coerced to
// 0..5000ms) sleeps in small chunks before remux starts, honoring
// cancellation mid-hold. Harness concurrency proof only, same seam as
// AndroidPassthroughRemuxSession.
class AndroidNormalizeVideoSession(private val context: Context) {

    @Volatile private var cancelRequested = false

    /** Requests cancellation of the in-flight normalize. Thread-safe, non-blocking. */
    fun requestCancel() {
        cancelRequested = true
    }

    fun start(
        args: Map<*, *>?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (code: String, message: String?) -> Unit,
    ) {
        Thread {
            try {
                run(args, onSuccess, onError)
            } catch (t: Throwable) {
                Log.e(TAG, "unhandled exception in normalize video session: $t", t)
                onError("EXPORT_FAILED", "normalizeVideo: ${t.message ?: t.javaClass.simpleName}")
            }
        }.start()
    }

    // ------------------------------------------------------------------

    private fun run(
        args: Map<*, *>?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String?) -> Unit,
    ) {
        // -- 1. Argument validation --------------------------------------
        if (args == null) {
            onError("INVALID_ARG", "normalizeVideo: arguments required")
            return
        }
        val inputPath = (args["inputPath"] as? String)?.trim()
        if (inputPath.isNullOrEmpty()) {
            onError("INVALID_ARG", "normalizeVideo: inputPath required")
            return
        }
        val outputPath = (args["outputPath"] as? String)?.trim()
        if (outputPath.isNullOrEmpty()) {
            onError("INVALID_ARG", "normalizeVideo: outputPath required")
            return
        }
        val diagnosticHoldBeforeRemuxMs = ((args["diagnosticHoldBeforeRemuxMs"] as? Number)?.toLong() ?: 0L)
            .coerceIn(0L, MAX_DIAGNOSTIC_HOLD_MS)

        // -- 2. Source readability ---------------------------------------
        val inputFile = File(inputPath)
        if (!inputFile.exists() || !inputFile.canRead()) {
            onError("FILE_UNREADABLE", "normalizeVideo: cannot read source: $inputPath")
            return
        }

        // -- 3. Output path preparation. Fail closed rather than overwrite --
        val outputFile = File(outputPath)
        val outputParent = outputFile.parentFile
        if (outputParent != null && !outputParent.exists() && !outputParent.mkdirs()) {
            onError("EXPORT_FAILED", "normalizeVideo: cannot create output directory: ${outputParent.path}")
            return
        }
        if (outputFile.exists()) {
            onError("OUTPUT_EXISTS", "normalizeVideo: output already exists: $outputPath")
            return
        }

        val tempPath = "$outputPath.vgnormtmp"
        val tempFile = File(tempPath)
        if (tempFile.exists() && !tempFile.delete()) {
            onError("EXPORT_FAILED", "normalizeVideo: cannot clear stale temp file: $tempPath")
            return
        }

        fun deleteOwnedTemp() {
            try { tempFile.takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
        }

        if (cancelRequested) {
            deleteOwnedTemp()
            onError("EXPORT_CANCELLED", "normalizeVideo: cancelled before normalize started")
            return
        }

        // -- 4. Probe source tracks + rotation ---------------------------
        val probe = probeSource(inputPath)
        if (probe == null) {
            onError("EXPORT_UNAVAILABLE", "normalizeVideo: no readable video track in $inputPath")
            return
        }
        val normalizedRotationDegrees = ((probe.rotationDegrees % 360) + 360) % 360
        if (!CARDINAL_ROTATIONS.contains(normalizedRotationDegrees)) {
            onError(
                "EXPORT_UNAVAILABLE",
                "normalizeVideo: unsupported non-cardinal rotation ${probe.rotationDegrees} in $inputPath",
            )
            return
        }

        if (cancelRequested) {
            deleteOwnedTemp()
            onError("EXPORT_CANCELLED", "normalizeVideo: cancelled before normalize started")
            return
        }

        // -- 5. Optional diagnostic hold (harness concurrency proof only) --
        var remaining = diagnosticHoldBeforeRemuxMs
        while (remaining > 0 && !cancelRequested) {
            val step = remaining.coerceAtMost(DIAGNOSTIC_HOLD_STEP_MS)
            Thread.sleep(step)
            remaining -= step
        }

        if (cancelRequested) {
            deleteOwnedTemp()
            onError("EXPORT_CANCELLED", "normalizeVideo: cancelled before normalize started")
            return
        }

        // -- 6. Remux (execution boundary: real MediaMuxer + real samples) --
        val remux = remuxNormalize(
            inputPath = inputPath,
            finalPath = tempPath,
            rotationDegrees = normalizedRotationDegrees,
        )

        if (cancelRequested) {
            deleteOwnedTemp()
            onError("EXPORT_CANCELLED", "normalizeVideo: cancelled")
            return
        }

        if (!remux.success || remux.outputSizeBytes <= 0L) {
            deleteOwnedTemp()
            onError("EXPORT_FAILED", "normalizeVideo: remux failed: ${remux.reason}")
            return
        }

        // -- 7. Finalize: re-check cancellation and racing writers, then --
        // rename the temp output to the requested output path.
        if (cancelRequested) {
            deleteOwnedTemp()
            onError("EXPORT_CANCELLED", "normalizeVideo: cancelled after remux")
            return
        }
        if (outputFile.exists()) {
            deleteOwnedTemp()
            onError("OUTPUT_EXISTS", "normalizeVideo: output already exists: $outputPath")
            return
        }
        if (!tempFile.renameTo(outputFile)) {
            deleteOwnedTemp()
            onError("EXPORT_FAILED", "normalizeVideo: failed to finalize output at $outputPath")
            return
        }

        onSuccess(
            mapOf(
                "success" to true,
                "path" to outputPath,
                "outputPath" to outputPath,
                "inputPath" to inputPath,
                "rotationDegrees" to normalizedRotationDegrees,
                "videoSamples" to remux.videoSamples,
                "audioSamples" to remux.audioSamples,
                "outputSizeBytes" to remux.outputSizeBytes,
                "hasAudioTrack" to probe.hasAudioTrack,
                "proofBoundary" to PROOF_BOUNDARY,
                "nonClaims" to NON_CLAIMS,
                "diagnosticHoldBeforeRemuxMs" to diagnosticHoldBeforeRemuxMs,
            ),
        )
    }

    // ------------------------------------------------------------------

    private data class SourceProbe(
        val rotationDegrees: Int,
        val hasAudioTrack: Boolean,
    )

    /// Metadata-only probe: track formats only, never readSampleData(). Returns
    /// null when no readable video track is found (including a failure to open
    /// the extractor at all).
    private fun probeSource(inputPath: String): SourceProbe? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(inputPath)
            var hasVideoTrack = false
            var rotationDegrees = 0
            var hasAudioTrack = false
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && !hasVideoTrack) {
                    hasVideoTrack = true
                    rotationDegrees = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                        format.getInteger(MediaFormat.KEY_ROTATION)
                    } else {
                        0
                    }
                } else if (mime.startsWith("audio/")) {
                    hasAudioTrack = true
                }
            }
            if (!hasVideoTrack) return null
            return SourceProbe(rotationDegrees = rotationDegrees, hasAudioTrack = hasAudioTrack)
        } catch (t: Throwable) {
            Log.e(TAG, "probeSource failed for $inputPath: $t")
            return null
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    /// Structured remux outcome. [reason] is "success" or a machine-readable
    /// failure cause.
    private data class NormalizeRemuxResult(
        val success: Boolean,
        val reason: String,
        val videoSamples: Int,
        val audioSamples: Int,
        val outputSizeBytes: Long,
    )

    /// Stream-copies the first video track and (optional) first audio track of
    /// a single [inputPath] into [finalPath] via one MediaExtractor with both
    /// tracks selected, interleaved by [MediaExtractor.getSampleTrackIndex].
    /// Sets [MediaMuxer.setOrientationHint] to [rotationDegrees] before
    /// start() so the container-level rotation is preserved without a pixel
    /// bake. Not cancellable mid-flight -- see class doc comment.
    private fun remuxNormalize(
        inputPath: String,
        finalPath: String,
        rotationDegrees: Int,
    ): NormalizeRemuxResult {
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var muxerStoppedCleanly = false
        var videoSamples = 0
        var audioSamples = 0
        var failureReason: String? = null

        try {
            extractor.setDataSource(inputPath)

            var videoTrackIndex = -1
            var audioTrackIndex = -1
            var videoFormat: MediaFormat? = null
            var audioFormat: MediaFormat? = null
            var maxInputSize = 0
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && videoTrackIndex == -1) {
                    videoTrackIndex = i
                    videoFormat = format
                } else if (mime.startsWith("audio/") && audioTrackIndex == -1) {
                    audioTrackIndex = i
                    audioFormat = format
                } else {
                    continue
                }
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxInputSize = maxOf(maxInputSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }
            if (videoTrackIndex == -1 || videoFormat == null) {
                failureReason = "no_video_track"
                return failed(failureReason, videoSamples, audioSamples)
            }

            val bufferSize = maxInputSize.coerceIn(MIN_COPY_BUFFER_BYTES, MAX_COPY_BUFFER_BYTES)

            extractor.selectTrack(videoTrackIndex)
            if (audioTrackIndex != -1) extractor.selectTrack(audioTrackIndex)

            val mx = MediaMuxer(finalPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mx
            val muxVideoTrack = mx.addTrack(videoFormat)
            val muxAudioTrack = audioFormat?.let { mx.addTrack(it) } ?: -1
            mx.setOrientationHint(rotationDegrees)
            mx.start()
            muxerStarted = true

            val buffer = ByteBuffer.allocate(bufferSize)
            val info = MediaCodec.BufferInfo()
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val sourceTrack = extractor.sampleTrackIndex
                val muxTrack = when (sourceTrack) {
                    videoTrackIndex -> muxVideoTrack
                    audioTrackIndex -> muxAudioTrack
                    else -> {
                        // Unselected track somehow surfaced a sample -- skip it.
                        extractor.advance()
                        continue
                    }
                }
                info.offset = 0
                info.size = size
                info.presentationTimeUs = extractor.sampleTime.coerceAtLeast(0L)
                info.flags = extractor.sampleFlags
                mx.writeSampleData(muxTrack, buffer, info)
                if (sourceTrack == videoTrackIndex) videoSamples++ else audioSamples++
                extractor.advance()
            }

            if (videoSamples <= 0) {
                failureReason = "no_video_samples_written"
                return failed(failureReason, videoSamples, audioSamples)
            }
            if (audioTrackIndex != -1 && audioSamples <= 0) {
                failureReason = "no_audio_samples_written"
                return failed(failureReason, videoSamples, audioSamples)
            }

            mx.stop()
            muxerStoppedCleanly = true

            val outputFile = File(finalPath)
            val outputSize = if (outputFile.exists()) outputFile.length() else 0L
            if (outputSize <= 0L) {
                failureReason = "output_file_empty_or_missing"
                return failed(failureReason, videoSamples, audioSamples)
            }

            Log.i(TAG, "normalize remux OK — video=$videoSamples audio=$audioSamples bytes=$outputSize → $finalPath")
            return NormalizeRemuxResult(
                success = true,
                reason = "success",
                videoSamples = videoSamples,
                audioSamples = audioSamples,
                outputSizeBytes = outputSize,
            )
        } catch (t: Throwable) {
            failureReason = "exception:${t.javaClass.simpleName}"
            Log.e(TAG, "normalize remux failed: $t")
            return failed(failureReason, videoSamples, audioSamples)
        } finally {
            if (muxerStarted && !muxerStoppedCleanly) {
                try { muxer?.stop() } catch (_: Throwable) {}
            }
            try { muxer?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
            if (failureReason != null) {
                try {
                    val f = File(finalPath)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    private fun failed(reason: String, videoSamples: Int, audioSamples: Int): NormalizeRemuxResult =
        NormalizeRemuxResult(
            success = false,
            reason = reason,
            videoSamples = videoSamples,
            audioSamples = audioSamples,
            outputSizeBytes = 0L,
        )

    companion object {
        private const val TAG = "VGNormalizeVideoSession"
        private const val MIN_COPY_BUFFER_BYTES = 1024 * 1024
        private const val MAX_COPY_BUFFER_BYTES = 16 * 1024 * 1024
        private const val MAX_DIAGNOSTIC_HOLD_MS = 5000L
        private const val DIAGNOSTIC_HOLD_STEP_MS = 50L
        private val CARDINAL_ROTATIONS = setOf(0, 90, 180, 270)
        private const val PROOF_BOUNDARY =
            "native_normalize_video_execution_session_no_codec_no_exporttimeline_bypass"

        private val NON_CLAIMS = mapOf(
            "mediaCodecAllocated" to false,
            "roiSidecarEmitted" to false,
            "faststartGuaranteed" to false,
            "selectiveMetadataFiltering" to false,
            "productionExportTimelineBypass" to false,
            "connectAppTouched" to false,
        )
    }
}
