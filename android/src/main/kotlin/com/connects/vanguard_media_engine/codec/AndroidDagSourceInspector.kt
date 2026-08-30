package com.connects.vanguard_media_engine.codec

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build

/**
 * Vanguard Android True-DAG Phase 4B2C: Source Inspector.
 *
 * Encapsulates all source-level preflight and track-selection logic:
 *   - file existence / readability preflight
 *   - API level check (>= 29)
 *   - MediaExtractor creation, setDataSource, first-video-track selection
 *   - mime / width / height / durationUs extraction
 *   - rotationDegrees: primary read from MediaFormat.KEY_ROTATION; falls back
 *     to MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION only when KEY_ROTATION
 *     is absent. 0 is valid and is NOT treated as "absent". Normalised to
 *     cardinal 0/90/180/270; non-cardinal becomes 0. Retriever always released.
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
     * Rotation from MediaFormat.KEY_ROTATION or MediaMetadataRetriever fallback.
     * Normalised to cardinal 0/90/180/270; non-cardinal values become 0.
     * Applied to display dimensions and render transform in Phase 4B2C.
     */
    val rotationDegrees: Int,
    /**
     * Phase 7.8I-Android: true if any track on the source has an "audio/" mime,
     * regardless of which track is selected on [extractor] (always the first
     * "video/" track). Used to gate editor-preview original-audio playback
     * without changing video track selection.
     */
    val hasAudio: Boolean = false,
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

            // 4. Find first video track. Scans every track (rather than stopping at the
            // first video match) so hasAudio below reflects the whole source, while still
            // selecting only the first "video/*" track — video selection is unchanged.
            var trackIndex = -1
            var format: MediaFormat? = null
            var hasAudio = false
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    hasAudio = true
                }
                if (trackIndex < 0 && mime.startsWith("video/")) {
                    trackIndex = i
                    format = f
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
            // rotationDegrees: primary from KEY_ROTATION; fall back to MediaMetadataRetriever
            // only when KEY_ROTATION key is entirely absent (0 is a valid value, not absent).
            // Normalise to cardinal 0/90/180/270; non-cardinal becomes 0.
            val rotationDegrees = run {
                val raw: Int = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                    format.getInteger(MediaFormat.KEY_ROTATION)
                } else {
                    // KEY_ROTATION absent: attempt MMR fallback.
                    val mmr = MediaMetadataRetriever()
                    try {
                        mmr.setDataSource(videoPath)
                        val rotStr = mmr.extractMetadata(
                            MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                        rotStr?.toIntOrNull() ?: 0
                    } catch (_: Throwable) {
                        0
                    } finally {
                        try { mmr.release() } catch (_: Throwable) {}
                    }
                }
                // Normalize to cardinal; non-cardinal (e.g. 45) becomes 0.
                val normalized = ((raw % 360) + 360) % 360
                when (normalized) {
                    0, 90, 180, 270 -> normalized
                    else -> 0
                }
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
                hasAudio = hasAudio,
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
