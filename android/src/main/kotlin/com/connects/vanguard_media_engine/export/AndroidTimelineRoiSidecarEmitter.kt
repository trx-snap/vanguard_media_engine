package com.connects.vanguard_media_engine.export

import java.io.File
import java.nio.charset.StandardCharsets

// ── AndroidTimelineRoiSidecarEmitter (Export Unit D) ──────────────────────────
//
// Emits a mandatory empty ROI sidecar JSON file alongside a successful Android
// `exportTimeline` output. Android Unit C performs a pass-1 MediaCodec video
// re-encode rather than a passthrough/remux export, so there is no source ROI
// content to carry forward -- this emitter always writes the empty-ROI
// literal. The `rois` vs `samples` schema divergence from the Dart
// `VGROISidecar` model is intentionally deferred to a later slice.
object AndroidTimelineRoiSidecarEmitter {

    private const val EMPTY_SIDECAR_JSON = "{\"version\":1,\"rois\":[]}"

    /**
     * Derives the ROI sidecar path for [videoPath] using extension
     * replacement, matching ConnectsApp's `_roiSidecarPathForVideoPath`:
     * `/tmp/out.mp4` -> `/tmp/out.roi.json`.
     */
    fun sidecarPathForVideoPath(videoPath: String): String {
        val lastSeparator = videoPath.lastIndexOf('/')
        val lastDot = videoPath.lastIndexOf('.')
        if (lastDot <= lastSeparator) {
            return "$videoPath.roi.json"
        }
        return "${videoPath.substring(0, lastDot)}.roi.json"
    }

    /** Derives the staging temp path for a final sidecar path. */
    fun tempPathForSidecarPath(sidecarPath: String): String = "$sidecarPath.vgtmp"

    /**
     * Writes the empty-ROI literal to [tempPath] and verifies the staged
     * content by re-reading it back byte-for-byte. Returns true only if the
     * staged file's bytes exactly match the expected literal.
     */
    fun stageEmptySidecar(tempPath: String): Boolean {
        return try {
            val tempFile = File(tempPath)
            tempFile.parentFile?.mkdirs()
            val bytes = EMPTY_SIDECAR_JSON.toByteArray(StandardCharsets.UTF_8)
            tempFile.writeBytes(bytes)
            val readBack = tempFile.readBytes()
            readBack.contentEquals(bytes)
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Finalizes the staged sidecar by renaming [tempPath] to [finalPath].
     * Ensures the final path's parent directory exists first.
     */
    fun finalizeSidecar(tempPath: String, finalPath: String): Boolean {
        return try {
            val finalFile = File(finalPath)
            finalFile.parentFile?.mkdirs()
            File(tempPath).renameTo(finalFile)
        } catch (_: Throwable) {
            false
        }
    }
}
