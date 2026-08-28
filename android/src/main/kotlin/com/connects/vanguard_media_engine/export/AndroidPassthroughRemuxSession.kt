package com.connects.vanguard_media_engine.export

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File

// -- AndroidPassthroughRemuxSession (Phase 2-Unit AD) --------------------------
//
// One-shot native handler for a single `exportPassthroughRemux` MethodChannel
// call. Remuxes one readable local source media file to one caller-supplied
// output path on a background thread, sharing the
// AndroidEditorExportCoordinator export lock with `exportTimeline`.
//
// Execution boundary (what this Unit DOES do, unlike Unit Z's metadata-only
// capability probe): calls AndroidAudioRemuxer.remux(), which starts a real
// MediaMuxer and reads/writes real samples via MediaExtractor. What it still
// does NOT do: allocate a MediaCodec, bypass or touch the production
// `exportTimeline` pipeline, touch the native C++ passthrough remux sink
// node, or touch ConnectsApp -- see [NON_CLAIMS] / `proofBoundary` in the
// success payload.
//
// Cancellation: [requestCancel] is honored before the remux call starts and
// after it returns (temp is deleted, EXPORT_CANCELLED). AndroidAudioRemuxer's
// remux() call itself is not cancellable mid-flight -- once started, a
// requested cancellation is only observed after remux() returns, so
// cancellation during remux is delayed rather than immediate.
class AndroidPassthroughRemuxSession(private val context: Context) {

    @Volatile private var cancelRequested = false

    /** Requests cancellation of the in-flight remux. Thread-safe, non-blocking. */
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
                Log.e(TAG, "unhandled exception in passthrough remux session: $t", t)
                onError("EXPORT_FAILED", "exportPassthroughRemux: ${t.message ?: t.javaClass.simpleName}")
            }
        }.start()
    }

    // ----------------------------------------------------------------------

    private data class VideoProbe(
        val width: Int,
        val height: Int,
        val rotationDegrees: Int,
        val durationUs: Long,
        val hasAudioTrack: Boolean,
    )

    private fun run(
        args: Map<*, *>?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String?) -> Unit,
    ) {
        // -- 1. Argument validation --------------------------------------
        if (args == null) {
            onError("INVALID_ARG", "exportPassthroughRemux: arguments required")
            return
        }
        val sourcePath = (args["sourcePath"] as? String)?.trim()
        if (sourcePath.isNullOrEmpty()) {
            onError("INVALID_ARG", "exportPassthroughRemux: sourcePath required")
            return
        }
        val outputPath = (args["outputPath"] as? String)?.trim()
        if (outputPath.isNullOrEmpty()) {
            onError("INVALID_ARG", "exportPassthroughRemux: outputPath required")
            return
        }
        val diagnosticHoldBeforeRemuxMs = ((args["diagnosticHoldBeforeRemuxMs"] as? Number)?.toLong() ?: 0L)
            .coerceIn(0L, MAX_DIAGNOSTIC_HOLD_MS)

        // -- 2. Source readability -----------------------------------------
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists() || !sourceFile.canRead()) {
            onError("FILE_UNREADABLE", "exportPassthroughRemux: cannot read source: $sourcePath")
            return
        }

        // -- 3. Output path preparation -------------------------------------
        val outputFile = File(outputPath)
        val outputParent = outputFile.parentFile
        if (outputParent != null && !outputParent.exists() && !outputParent.mkdirs()) {
            onError("OUTPUT_UNWRITABLE", "exportPassthroughRemux: cannot create output directory: ${outputParent.path}")
            return
        }
        if (outputParent != null && outputParent.exists() && !outputParent.canWrite()) {
            onError("OUTPUT_UNWRITABLE", "exportPassthroughRemux: output directory not writable: ${outputParent.path}")
            return
        }
        if (outputFile.exists()) {
            onError("OUTPUT_EXISTS", "exportPassthroughRemux: output already exists: $outputPath")
            return
        }

        // Mandatory empty ROI sidecar path, derived the same way as the
        // production exportTimeline route (AndroidTimelineRoiSidecarEmitter),
        // so passthrough remux output carries the same output contract.
        val roiSidecarPath = AndroidTimelineRoiSidecarEmitter.sidecarPathForVideoPath(outputPath)
        val roiSidecarTempPath = AndroidTimelineRoiSidecarEmitter.tempPathForSidecarPath(roiSidecarPath)
        val roiSidecarFile = File(roiSidecarPath)
        if (roiSidecarFile.exists()) {
            onError("OUTPUT_EXISTS", "exportPassthroughRemux: ROI sidecar already exists: $roiSidecarPath")
            return
        }

        val tempPath = "$outputPath.vgptmp"
        val tempFile = File(tempPath)
        if (tempFile.exists() && !tempFile.delete()) {
            onError("OUTPUT_UNWRITABLE", "exportPassthroughRemux: cannot clear stale temp file: $tempPath")
            return
        }
        val roiSidecarTempFile = File(roiSidecarTempPath)
        if (roiSidecarTempFile.exists() && !roiSidecarTempFile.delete()) {
            onError("OUTPUT_UNWRITABLE", "exportPassthroughRemux: cannot clear stale ROI sidecar temp file: $roiSidecarTempPath")
            return
        }

        var sidecarFinalized = false

        fun deleteOwnedTemps() {
            try { tempFile.takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            try { roiSidecarTempFile.takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            if (sidecarFinalized) {
                try { roiSidecarFile.takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            }
        }

        if (cancelRequested) {
            deleteOwnedTemps()
            onError("EXPORT_CANCELLED", "exportPassthroughRemux: cancelled before remux started")
            return
        }

        // -- 4. Metadata probe (track formats only -- no readSampleData) ---
        val probe = probeSource(sourcePath)
        if (probe == null) {
            onError("UNSUPPORTED_SOURCE", "exportPassthroughRemux: no readable video track in $sourcePath")
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
            deleteOwnedTemps()
            onError("EXPORT_CANCELLED", "exportPassthroughRemux: cancelled before remux started")
            return
        }

        // -- 6. Remux (execution boundary: real MediaMuxer + real samples) --
        val remux = AndroidAudioRemuxer.remux(
            videoPath = sourcePath,
            audioPath = if (probe.hasAudioTrack) sourcePath else null,
            finalPath = tempPath,
        )

        if (cancelRequested) {
            deleteOwnedTemps()
            onError("EXPORT_CANCELLED", "exportPassthroughRemux: cancelled")
            return
        }

        if (!remux.success || remux.outputSizeBytes <= 0L) {
            deleteOwnedTemps()
            onError("EXPORT_FAILED", "exportPassthroughRemux: remux failed: ${remux.reason}")
            return
        }

        // -- 7. Finalize: re-check cancellation and racing writers, then stage
        // and finalize the mandatory empty ROI sidecar before renaming the
        // temp video to the requested output. Sidecar-first ordering: the
        // video rename only happens after sidecar finalization succeeds, so a
        // finalized video is never left behind without a sidecar. --
        if (cancelRequested) {
            deleteOwnedTemps()
            onError("EXPORT_CANCELLED", "exportPassthroughRemux: cancelled after remux")
            return
        }
        if (outputFile.exists()) {
            deleteOwnedTemps()
            onError("OUTPUT_EXISTS", "exportPassthroughRemux: output already exists: $outputPath")
            return
        }
        if (roiSidecarFile.exists()) {
            deleteOwnedTemps()
            onError("OUTPUT_EXISTS", "exportPassthroughRemux: ROI sidecar already exists: $roiSidecarPath")
            return
        }

        if (!AndroidTimelineRoiSidecarEmitter.stageEmptySidecar(roiSidecarTempPath)) {
            deleteOwnedTemps()
            onError("EXPORT_FAILED", "exportPassthroughRemux: failed to stage ROI sidecar at $roiSidecarTempPath")
            return
        }
        if (!AndroidTimelineRoiSidecarEmitter.finalizeSidecar(roiSidecarTempPath, roiSidecarPath)) {
            deleteOwnedTemps()
            onError("EXPORT_FAILED", "exportPassthroughRemux: failed to finalize ROI sidecar at $roiSidecarPath")
            return
        }
        sidecarFinalized = true

        if (!tempFile.renameTo(outputFile)) {
            deleteOwnedTemps()
            onError("EXPORT_FAILED", "exportPassthroughRemux: failed to finalize output at $outputPath")
            return
        }

        onSuccess(
            mapOf(
                "success" to true,
                "path" to outputPath,
                "outputPath" to outputPath,
                "sourcePath" to sourcePath,
                "width" to probe.width,
                "height" to probe.height,
                "rotationDegrees" to probe.rotationDegrees,
                "durationSeconds" to probe.durationUs / 1_000_000.0,
                "videoSamples" to remux.videoSamples,
                "audioSamples" to remux.audioSamples,
                "outputSizeBytes" to remux.outputSizeBytes,
                "hasAudioTrack" to probe.hasAudioTrack,
                "exportRoiSidecarPath" to roiSidecarPath,
                "roiSidecarPath" to roiSidecarPath,
                "proofBoundary" to PROOF_BOUNDARY,
                "nonClaims" to NON_CLAIMS,
                "diagnosticHoldBeforeRemuxMs" to diagnosticHoldBeforeRemuxMs,
            ),
        )
    }

    /// Metadata-only probe: track formats only, never readSampleData(). Returns
    /// null when no readable video track is found (including a failure to open
    /// the extractor at all).
    private fun probeSource(sourcePath: String): VideoProbe? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(sourcePath)
            var width: Int? = null
            var height: Int? = null
            var rotationDegrees = 0
            var durationUs = 0L
            var hasAudioTrack = false
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && width == null) {
                    width = format.getInteger(MediaFormat.KEY_WIDTH)
                    height = format.getInteger(MediaFormat.KEY_HEIGHT)
                    rotationDegrees = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                        format.getInteger(MediaFormat.KEY_ROTATION)
                    } else {
                        0
                    }
                    durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                        format.getLong(MediaFormat.KEY_DURATION)
                    } else {
                        0L
                    }
                } else if (mime.startsWith("audio/")) {
                    hasAudioTrack = true
                }
            }
            if (width == null || height == null) return null
            return VideoProbe(
                width = width,
                height = height,
                rotationDegrees = rotationDegrees,
                durationUs = durationUs,
                hasAudioTrack = hasAudioTrack,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "probeSource failed for $sourcePath: $t")
            return null
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val TAG = "VGPassthroughRemuxSession"
        private const val MAX_DIAGNOSTIC_HOLD_MS = 5000L
        private const val DIAGNOSTIC_HOLD_STEP_MS = 50L
        private const val PROOF_BOUNDARY =
            "native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass"

        private val NON_CLAIMS = mapOf(
            "mediaCodecAllocated" to false,
            "productionExportTimelineBypass" to false,
            "cppPassthroughRemuxSinkNode" to false,
            "connectAppTouched" to false,
        )
    }
}
