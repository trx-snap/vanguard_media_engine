package com.connects.vanguard_media_engine.codec

import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build

/**
 * Vanguard Android True-DAG Phase 4B2B3A: Source Inspector.
 *
 * Encapsulates all source-level preflight and track-selection logic:
 *   - file existence / readability preflight
 *   - API level check (>= 29)
 *   - MediaExtractor creation, setDataSource, first-video-track selection
 *   - mime / width / height / durationUs extraction
 *   - optional rotationDegrees read-out (for future use; not applied)
 *
 * On failure the helper releases any extractor it created and returns pass=false.
 * On success it hands extractor ownership to the caller; the caller is responsible
 * for releasing it (via cleanupResources).
 */
data class AndroidDagSourceInspectionResult(
    val pass: Boolean,
    val failureReason: String?,
    /** Non-null on success; caller owns release responsibility. */
    val extractor: MediaExtractor?,
    val format: MediaFormat?,
    val mime: String,
    val width: Int,
    val height: Int,
    val durationUs: Long,
    /**
     * Rotation from MediaFormat.KEY_ROTATION, if present. Stored for future use.
     * Not applied to rendering, shader, or dimension swapping in this phase.
     */
    val rotationDegrees: Int,
)

class AndroidDagSourceInspector {

    fun inspect(videoPath: String): AndroidDagSourceInspectionResult {
        // 1. File existence / readability preflight — must happen before setDataSource()
        //    because setDataSource() can hang on some Android versions for missing paths.
        val file = java.io.File(videoPath)
        if (!file.exists() || !file.canRead()) {
            return failure("file_not_found_or_not_readable")
        }

        // 2. API level guard
        if (Build.VERSION.SDK_INT < 29) {
            return failure("api_below_29")
        }

        // 3. Create extractor; any exception from here on releases it before returning.
        val ex = MediaExtractor()
        try {
            ex.setDataSource(videoPath)

            // 4. Find first video track
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }

            if (trackIndex < 0 || format == null) {
                ex.release()
                return failure("no_video_track_found")
            }

            ex.selectTrack(trackIndex)

            // 5. Extract metadata
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val width = format.getInteger(MediaFormat.KEY_WIDTH)
            val height = format.getInteger(MediaFormat.KEY_HEIGHT)
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                format.getLong(MediaFormat.KEY_DURATION)
            } else {
                0L
            }
            // rotationDegrees: read for future use; NOT applied to layout/rendering/shader.
            val rotationDegrees = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                format.getInteger(MediaFormat.KEY_ROTATION)
            } else {
                0
            }

            return AndroidDagSourceInspectionResult(
                pass = true,
                failureReason = null,
                extractor = ex,   // ownership transferred to caller
                format = format,
                mime = mime,
                width = width,
                height = height,
                durationUs = durationUs,
                rotationDegrees = rotationDegrees,
            )
        } catch (t: Throwable) {
            try { ex.release() } catch (_: Throwable) {}
            return failure("inspect_exception:${t.javaClass.simpleName}")
        }
    }

    private fun failure(reason: String) = AndroidDagSourceInspectionResult(
        pass = false,
        failureReason = reason,
        extractor = null,
        format = null,
        mime = "",
        width = 0,
        height = 0,
        durationUs = 0L,
        rotationDegrees = 0,
    )
}
