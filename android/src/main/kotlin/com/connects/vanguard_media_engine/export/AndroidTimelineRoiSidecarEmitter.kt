package com.connects.vanguard_media_engine.export

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets

// ── AndroidTimelineRoiSidecarEmitter (Export Unit D / Phase 5-Unit M) ─────────
//
// Emits a mandatory empty ROI sidecar JSON file alongside a successful Android
// `exportTimeline` / `exportPassthroughRemux` output. Neither Android export
// route currently produces detected ROI samples, so this emitter always
// writes a schema-valid, sample-less sidecar -- one that a Dart caller can
// parse as a `VGROISidecar` (coordinateSpace "export_output_normalized",
// zero samples, zero coverage, finalized true).
object AndroidTimelineRoiSidecarEmitter {

    private const val EMPTY_RECORDING_SESSION_ID = "android-empty-export"

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
     * Writes a `VGROISidecar`-compatible empty-samples sidecar to [tempPath],
     * describing an export of [width]x[height] pixels and [durationSeconds]
     * seconds, and verifies the staged content by re-reading it back
     * byte-for-byte. Returns true only if the staged file's bytes exactly
     * match the freshly-built literal.
     */
    fun stageEmptySidecar(tempPath: String, width: Int, height: Int, durationSeconds: Double): Boolean {
        return try {
            val tempFile = File(tempPath)
            tempFile.parentFile?.mkdirs()
            val bytes = buildEmptySidecarJson(width, height, durationSeconds)
                .toByteArray(StandardCharsets.UTF_8)
            tempFile.writeBytes(bytes)
            val readBack = tempFile.readBytes()
            readBack.contentEquals(bytes)
        } catch (_: Throwable) {
            false
        }
    }

    private fun buildEmptySidecarJson(width: Int, height: Int, durationSeconds: Double): String {
        val durationMs = Math.round(durationSeconds * 1000.0).coerceAtLeast(0L)
        val videoIdentity = JSONObject()
            .put("durationMs", durationMs)
            .put("width", width)
            .put("height", height)
            .put("hash", JSONObject.NULL)
        val coverage = JSONObject()
            .put("coveragePercent", 0.0)
            .put("missingIntervals", JSONArray())
        val root = JSONObject()
            .put("version", 1)
            .put("sourceType", "export")
            .put("platform", "android")
            .put("coordinateSpace", "export_output_normalized")
            .put("recordingSessionId", EMPTY_RECORDING_SESSION_ID)
            .put("videoIdentity", videoIdentity)
            .put("coverage", coverage)
            .put("samples", JSONArray())
            .put("finalized", true)
        return root.toString()
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
