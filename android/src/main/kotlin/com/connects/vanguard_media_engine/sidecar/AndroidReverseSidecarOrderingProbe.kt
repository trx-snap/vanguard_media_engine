package com.connects.vanguard_media_engine.sidecar

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * P5-REVERSE-SIDECAR-ORDERING-CONTENT-PROOF.
 *
 * Diagnostic probe helper owned by [AndroidReverseSidecarCoordinator].
 * Compares sampled frame luma signatures between an existing reverse sidecar MP4
 * and its source video to prove reversed frame ordering at the pixel level.
 */
object AndroidReverseSidecarOrderingProbe {
    private const val TAG = "ReverseOrderingProbe"
    private const val GRID_SIZE = 8
    private const val MARGIN_FRACTION = 0.10f
    private const val MAX_DURATION_SECONDS = 5.0
    private const val MAX_FRAMES = 150
    private const val MAX_FPS = 120.0
    private const val AMBIGUOUS_THRESHOLD = 0.008
    private const val AMBIGUOUS_DIFF_THRESHOLD = 0.005
    private const val TOLERANT_DISTANCE_MARGIN = 0.008

    fun probe(args: Map<*, *>?): Map<String, Any?> {
        val sourcePath = (args?.get("sourcePath") as? String)?.trim()
        val sidecarPath = (args?.get("sidecarPath") as? String)?.trim()
        val trimStart = (args?.get("trimStart") as? Number)?.toDouble()
        val trimEnd = (args?.get("trimEnd") as? Number)?.toDouble()
        val frameCount = (args?.get("frameCount") as? Number)?.toInt()
        val fps = (args?.get("fps") as? Number)?.toDouble() ?: 30.0

        if (sourcePath.isNullOrBlank() || sidecarPath.isNullOrBlank()) {
            return failureMap("invalid_path_args", frameCount ?: 0, fps)
        }

        val sourceFile = File(sourcePath)
        if (!sourceFile.exists() || !sourceFile.canRead() || sourceFile.length() <= 0L) {
            return failureMap("source_file_unreadable", frameCount ?: 0, fps)
        }

        val sidecarFile = File(sidecarPath)
        if (!sidecarFile.exists() || !sidecarFile.canRead() || sidecarFile.length() <= 0L) {
            return failureMap("sidecar_file_unreadable", frameCount ?: 0, fps)
        }

        if (trimStart == null || trimEnd == null || trimEnd <= trimStart || (trimEnd - trimStart) > MAX_DURATION_SECONDS) {
            return failureMap("invalid_trim_bounds", frameCount ?: 0, fps)
        }

        if (frameCount == null || frameCount < 4 || frameCount > MAX_FRAMES) {
            return failureMap("invalid_frame_count", frameCount ?: 0, fps)
        }

        if (fps <= 0.0 || fps > MAX_FPS) {
            return failureMap("invalid_fps", frameCount, fps)
        }

        // 1. Inspect sidecar sample count and PTS monotonicity via MediaExtractor
        var sidecarSampleCount = 0
        var sidecarPtsMonotonic = true
        var lastPtsUs = -1L

        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(sidecarPath)
            var videoTrackIndex = -1
            for (t in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(t)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/")) {
                    videoTrackIndex = t
                    break
                }
            }
            if (videoTrackIndex < 0) {
                return failureMap("no_video_track_in_sidecar", frameCount, fps)
            }
            extractor.selectTrack(videoTrackIndex)
            while (true) {
                val sampleTimeUs = extractor.sampleTime
                if (sampleTimeUs < 0) break
                sidecarSampleCount++
                if (lastPtsUs >= 0L && sampleTimeUs <= lastPtsUs) {
                    sidecarPtsMonotonic = false
                }
                lastPtsUs = sampleTimeUs
                if (!extractor.advance()) break
            }
        } catch (t: Throwable) {
            Log.e(TAG, "extractor inspection failed for $sidecarPath", t)
            return failureMap("extractor_failed: ${t.message}", frameCount, fps)
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }

        if (sidecarSampleCount == 0) {
            sidecarPtsMonotonic = false
        }

        // 2. Sample frames using MediaMetadataRetriever
        val sourceRetriever = MediaMetadataRetriever()
        val sidecarRetriever = MediaMetadataRetriever()
        try {
            sourceRetriever.setDataSource(sourcePath)
            sidecarRetriever.setDataSource(sidecarPath)
        } catch (t: Throwable) {
            Log.e(TAG, "retriever initialization failed", t)
            try { sourceRetriever.release() } catch (_: Throwable) {}
            try { sidecarRetriever.release() } catch (_: Throwable) {}
            return failureMap("retriever_init_failed: ${t.message}", frameCount, fps, sidecarSampleCount, sidecarPtsMonotonic)
        }

        val indices = listOf(
            0,
            frameCount / 4,
            (frameCount * 3) / 4,
            frameCount - 1
        ).distinct()

        val frameStep = (trimEnd - trimStart) / frameCount.toDouble()

        var probeCount = 0
        var reverseWins = 0
        var totalRevDist = 0.0
        var totalFwdDist = 0.0

        try {
            // Sample first reference source frame to get source content aspect ratio
            var refAspectW = 1
            var refAspectH = 1
            val firstRefSeconds = (trimEnd - frameStep * 0.5).coerceIn(trimStart, trimEnd)
            val firstRefUs = (firstRefSeconds * 1_000_000.0).roundToLong().coerceAtLeast(0L)
            val refBm = sourceRetriever.getFrameAtTime(firstRefUs, MediaMetadataRetriever.OPTION_CLOSEST)
            if (refBm != null) {
                refAspectW = refBm.width
                refAspectH = refBm.height
                refBm.recycle()
            }

            for (i in indices) {
                val sidecarTimeUs = (i * 1_000_000.0 / fps).roundToLong().coerceAtLeast(0L)
                val revSourceSeconds = (trimEnd - frameStep * (i + 0.5)).coerceIn(trimStart, trimEnd)
                val revSourceUs = (revSourceSeconds * 1_000_000.0).roundToLong().coerceAtLeast(0L)
                val fwdSourceSeconds = (trimStart + frameStep * (i + 0.5)).coerceIn(trimStart, trimEnd)
                val fwdSourceUs = (fwdSourceSeconds * 1_000_000.0).roundToLong().coerceAtLeast(0L)

                var sidecarBm: Bitmap? = null
                var revBm: Bitmap? = null
                var fwdBm: Bitmap? = null

                var sidecarSig: DoubleArray? = null
                var revSig: DoubleArray? = null
                var fwdSig: DoubleArray? = null

                try {
                    sidecarBm = sidecarRetriever.getFrameAtTime(sidecarTimeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                    if (sidecarBm != null) {
                        sidecarSig = computeLumaSignature(sidecarBm, refAspectW, refAspectH)
                    }
                } finally {
                    sidecarBm?.recycle()
                }

                try {
                    revBm = sourceRetriever.getFrameAtTime(revSourceUs, MediaMetadataRetriever.OPTION_CLOSEST)
                    if (revBm != null) {
                        sidecarSig?.let {
                            // Update aspect ratio from real source bitmap if needed
                            refAspectW = revBm.width
                            refAspectH = revBm.height
                        }
                        revSig = computeLumaSignature(revBm, revBm.width, revBm.height)
                    }
                } finally {
                    revBm?.recycle()
                }

                try {
                    fwdBm = sourceRetriever.getFrameAtTime(fwdSourceUs, MediaMetadataRetriever.OPTION_CLOSEST)
                    if (fwdBm != null) {
                        fwdSig = computeLumaSignature(fwdBm, fwdBm.width, fwdBm.height)
                    }
                } finally {
                    fwdBm?.recycle()
                }

                if (sidecarSig != null && revSig != null && fwdSig != null) {
                    val revDist = signatureDistance(sidecarSig, revSig)
                    val fwdDist = signatureDistance(sidecarSig, fwdSig)

                    totalRevDist += revDist
                    totalFwdDist += fwdDist
                    probeCount++

                    if (revDist < fwdDist) {
                        reverseWins++
                    }

                    Log.i(
                        TAG,
                        "probe index=$i sidecarUs=$sidecarTimeUs revUs=$revSourceUs fwdUs=$fwdSourceUs " +
                            "revDist=$revDist fwdDist=$fwdDist revWins=${revDist < fwdDist}"
                    )
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "probe frame extraction failed", t)
            return failureMap("frame_extraction_failed: ${t.message}", frameCount, fps, sidecarSampleCount, sidecarPtsMonotonic)
        } finally {
            try { sourceRetriever.release() } catch (_: Throwable) {}
            try { sidecarRetriever.release() } catch (_: Throwable) {}
        }

        val avgReverseDistance = if (probeCount > 0) totalRevDist / probeCount else 0.0
        val avgForwardDistance = if (probeCount > 0) totalFwdDist / probeCount else 0.0

        val isAmbiguous = avgForwardDistance < AMBIGUOUS_THRESHOLD ||
                abs(avgForwardDistance - avgReverseDistance) < AMBIGUOUS_DIFF_THRESHOLD

        val meaningfullyLower = (avgForwardDistance - avgReverseDistance) >= TOLERANT_DISTANCE_MARGIN

        val pass = probeCount >= 3 &&
                sidecarPtsMonotonic &&
                reverseWins >= 3 &&
                !isAmbiguous &&
                meaningfullyLower

        val reason = when {
            probeCount < 3 -> "insufficient_probe_samples"
            !sidecarPtsMonotonic -> "sidecar_pts_not_monotonic"
            isAmbiguous -> "ambiguous_content"
            reverseWins < 3 -> "reverse_wins_insufficient"
            !meaningfullyLower -> "reverse_distance_margin_insufficient"
            else -> null
        }

        Log.i(
            TAG,
            "probe summary: pass=$pass reason=$reason probeCount=$probeCount reverseWins=$reverseWins " +
                "avgRevDist=$avgReverseDistance avgFwdDist=$avgForwardDistance " +
                "sidecarSamples=$sidecarSampleCount sidecarPtsMonotonic=$sidecarPtsMonotonic"
        )

        return mapOf(
            "pass" to pass,
            "reason" to reason,
            "frameCount" to frameCount,
            "fps" to fps,
            "probeCount" to probeCount,
            "reverseWins" to reverseWins,
            "avgReverseDistance" to avgReverseDistance,
            "avgForwardDistance" to avgForwardDistance,
            "sidecarSampleCount" to sidecarSampleCount,
            "sidecarPtsMonotonic" to sidecarPtsMonotonic,
            "proofBoundary" to "AndroidReverseSidecarOrderingProbe",
        )
    }

    private fun computeLumaSignature(
        bitmap: Bitmap,
        contentAspectW: Int,
        contentAspectH: Int
    ): DoubleArray {
        val width = bitmap.width
        val height = bitmap.height

        val scale = minOf(
            width.toFloat() / contentAspectW.coerceAtLeast(1),
            height.toFloat() / contentAspectH.coerceAtLeast(1)
        )
        val activeW = (contentAspectW * scale).toInt().coerceIn(1, width)
        val activeH = (contentAspectH * scale).toInt().coerceIn(1, height)
        val offsetX = ((width - activeW) / 2).coerceIn(0, width - 1)
        val offsetY = ((height - activeH) / 2).coerceIn(0, height - 1)

        val marginX = (activeW * MARGIN_FRACTION).toInt()
        val marginY = (activeH * MARGIN_FRACTION).toInt()
        val usableW = (activeW - 2 * marginX).coerceAtLeast(1)
        val usableH = (activeH - 2 * marginY).coerceAtLeast(1)

        val raw = DoubleArray(GRID_SIZE * GRID_SIZE)
        var idx = 0

        for (gy in 0 until GRID_SIZE) {
            for (gx in 0 until GRID_SIZE) {
                val cx = (offsetX + marginX + (gx + 0.5f) * usableW / GRID_SIZE)
                    .toInt().coerceIn(0, width - 1)
                val cy = (offsetY + marginY + (gy + 0.5f) * usableH / GRID_SIZE)
                    .toInt().coerceIn(0, height - 1)

                var sumLuma = 0.0
                var sampleCount = 0
                for (dy in -1..1) {
                    for (dx in -1..1) {
                        val px = (cx + dx).coerceIn(0, width - 1)
                        val py = (cy + dy).coerceIn(0, height - 1)
                        val pixel = bitmap.getPixel(px, py)
                        val r = Color.red(pixel)
                        val g = Color.green(pixel)
                        val b = Color.blue(pixel)
                        sumLuma += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                        sampleCount++
                    }
                }
                raw[idx++] = sumLuma / sampleCount
            }
        }

        // Mean-centering to eliminate global brightness / color space conversion offset
        val mean = raw.average()
        return DoubleArray(raw.size) { raw[it] - mean }
    }

    private fun signatureDistance(a: DoubleArray, b: DoubleArray): Double {
        var sumDiff = 0.0
        for (k in a.indices) {
            sumDiff += abs(a[k] - b[k])
        }
        return sumDiff / a.size
    }

    private fun failureMap(
        reason: String,
        frameCount: Int = 0,
        fps: Double = 0.0,
        sidecarSampleCount: Int = 0,
        sidecarPtsMonotonic: Boolean = false,
    ): Map<String, Any?> = mapOf(
        "pass" to false,
        "reason" to reason,
        "frameCount" to frameCount,
        "fps" to fps,
        "probeCount" to 0,
        "reverseWins" to 0,
        "avgReverseDistance" to 0.0,
        "avgForwardDistance" to 0.0,
        "sidecarSampleCount" to sidecarSampleCount,
        "sidecarPtsMonotonic" to sidecarPtsMonotonic,
        "proofBoundary" to "AndroidReverseSidecarOrderingProbe",
    )
}
