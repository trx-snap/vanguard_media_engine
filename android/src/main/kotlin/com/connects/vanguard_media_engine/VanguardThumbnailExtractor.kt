package com.connects.vanguard_media_engine

// ── VanguardThumbnailExtractor (Phase B3 — Android Media Fundamentals) ────────
//
// Android equivalent of iOS VanguardThumbnailPipeline (AVAssetImageGenerator).
//
// Pipeline:
//   MediaMetadataRetriever.getFrameAtTime(timeUs, OPTION_CLOSEST_SYNC)
//   → Bitmap → optional scale (when maxWidth/maxHeight specified) → compress(JPEG) → ByteArray
//
// Design decisions:
//   1. Object singleton — stateless, thread-safe, no context needed.
//   2. DEFAULT_JPEG_QUALITY = 72 preserves existing Android retriever behavior when omitted.
//   3. When maxWidth/maxHeight are null, raw decoded dimensions are preserved without forced scaling.
//   4. OPTION_CLOSEST_SYNC prefers I-frames for speed — matches iOS
//      AVAssetImageGeneratorApertureModeCleanAperture default behaviour.
//   5. Blocking by design — always called from a background Thread in the plugin.
//   6. Each Bitmap is immediately recycled after compression to cap heap usage.

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min

internal object VanguardThumbnailExtractor {

    private const val TAG = "VanguardThumb"
    private const val DEFAULT_JPEG_QUALITY = 72

    /**
     * Extracts [count] evenly-spaced JPEG thumbnail frames from [videoPath].
     *
     * Frame timestamps are distributed as `i / (count - 1) * durationSeconds`,
     * so the first frame is always at t=0 and the last at the clip end.
     * If [count] == 1, a single frame at t=0 is returned.
     *
     * @param videoPath     Absolute path to the source video (mp4 / any MediaCodec-supported).
     * @param count         Number of thumbnails to extract (typically 8–10 for a filmstrip).
     * @param durationSeconds Clip duration in seconds — passed from Dart to avoid a
     *   redundant retriever call; used to compute evenly-spaced timestamps.
     * @param maxWidth      Optional max width constraint (null preserves full frame width).
     * @param maxHeight     Optional max height constraint (null preserves full frame height).
     * @param jpegQuality   Optional compression quality 0.0–1.0 (null defaults to 72).
     * @return List of JPEG [ByteArray] frames. May be shorter than [count] if some
     *   frames could not be extracted (e.g. corrupt GOP). Never returns null.
     *   Returns emptyList() on fatal error.
     */
    fun extract(
        videoPath: String,
        count: Int,
        durationSeconds: Double,
        maxWidth: Int? = null,
        maxHeight: Int? = null,
        jpegQuality: Double? = null,
    ): List<ByteArray> {
        if (count <= 0) return emptyList()

        val clampedWidth = maxWidth?.coerceIn(1, 3840)
        val clampedHeight = maxHeight?.coerceIn(1, 3840)
        val qualityInt = if (jpegQuality != null) {
            (jpegQuality.coerceIn(0.1, 1.0) * 100).toInt()
        } else {
            DEFAULT_JPEG_QUALITY
        }

        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(videoPath)
            (0 until count).mapNotNull { i ->
                // Distribute timestamps evenly across the clip duration.
                val fraction = if (count > 1) i.toDouble() / (count - 1).toDouble() else 0.0
                val timeUs   = (fraction * durationSeconds * 1_000_000L).toLong()

                val rawBitmap: Bitmap = retriever.getFrameAtTime(
                    timeUs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                ) ?: run {
                    Log.w(TAG, "getFrameAtTime returned null at ${timeUs / 1_000}ms — skipping")
                    return@mapNotNull null
                }

                val srcWidth = rawBitmap.width
                val srcHeight = rawBitmap.height
                val finalBitmap: Bitmap
                if (clampedWidth != null && clampedHeight != null &&
                    (srcWidth > clampedWidth || srcHeight > clampedHeight)
                ) {
                    val scale = min(
                        clampedWidth.toDouble() / srcWidth.toDouble(),
                        clampedHeight.toDouble() / srcHeight.toDouble(),
                    )
                    val targetWidth = max(1, (srcWidth * scale).toInt())
                    val targetHeight = max(1, (srcHeight * scale).toInt())
                    finalBitmap = Bitmap.createScaledBitmap(rawBitmap, targetWidth, targetHeight, true)
                    rawBitmap.recycle()
                } else if (clampedWidth != null && clampedHeight == null && srcWidth > clampedWidth) {
                    val scale = clampedWidth.toDouble() / srcWidth.toDouble()
                    val targetWidth = max(1, (srcWidth * scale).toInt())
                    val targetHeight = max(1, (srcHeight * scale).toInt())
                    finalBitmap = Bitmap.createScaledBitmap(rawBitmap, targetWidth, targetHeight, true)
                    rawBitmap.recycle()
                } else if (clampedHeight != null && clampedWidth == null && srcHeight > clampedHeight) {
                    val scale = clampedHeight.toDouble() / srcHeight.toDouble()
                    val targetWidth = max(1, (srcWidth * scale).toInt())
                    val targetHeight = max(1, (srcHeight * scale).toInt())
                    finalBitmap = Bitmap.createScaledBitmap(rawBitmap, targetWidth, targetHeight, true)
                    rawBitmap.recycle()
                } else {
                    finalBitmap = rawBitmap
                }

                // Compress to JPEG and immediately recycle the Bitmap to avoid
                // holding multiple full-resolution frames in heap simultaneously.
                ByteArrayOutputStream().use { out ->
                    finalBitmap.compress(Bitmap.CompressFormat.JPEG, qualityInt, out)
                    finalBitmap.recycle()
                    out.toByteArray()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "extract failed for $videoPath: $e")
            emptyList()
        } finally {
            // Always release — MediaMetadataRetriever holds a native codec reference.
            try { retriever.release() } catch (_: Exception) {}
        }
    }
}
