package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaMetadataRetriever
import android.util.Log
import com.connects.vanguard_media_engine.export.AndroidTimelineExportSession
import com.connects.vanguard_media_engine.export.AndroidTimelineRoiSidecarEmitter
import java.io.File
import java.io.FileOutputStream
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max

/**
 * Physical proof harness for Android timeline still-image export colorMatrix
 * parity (GLES 2D still-image draw path).
 *
 * Proof boundary: [PROOF_BOUNDARY]
 * ("production_exportTimeline_still_image_color_matrix_gles_pixel_oracle")
 *
 * Directly exercises [AndroidTimelineExportSession] with synthetic solid-color
 * still-image clip fixtures (PNG for lane A, JPEG for lane B) generated
 * on-device via [Bitmap]/[Canvas]/[Paint]. AndroidExportRenderBackendSelector
 * rejects non-video clips from its Vulkan safe scope, so a still-image clip
 * always renders via the GLES fallback (renderBackend == "gles") -- this
 * harness proves the GLES 2D still-image draw path itself applies the
 * 20-element 4x5 colorMatrix, not a Vulkan-native path.
 *
 * Lane A: a still image carrying a non-trivial colorMatrix (row weights +
 * additive offsets) -- proves the matrix is actually applied to the 2D draw.
 * Lane B: a still image with no colorMatrix (regression) -- proves the
 * pre-existing passthrough behavior for images without a filter is
 * unaffected by this slice.
 */
object AndroidStillImageColorMatrixExportSmokeHarness {
    private const val TAG = "VanguardStillImageColorMatrixExport"
    const val PROOF_BOUNDARY = "production_exportTimeline_still_image_color_matrix_gles_pixel_oracle"

    const val SOURCE_R = 96.0
    const val SOURCE_G = 64.0
    const val SOURCE_B = 32.0

    val COLOR_MATRIX: List<Double> = listOf(
        0.5, 0.2, 0.1, 0.0, 20.0,
        0.2, 0.8, 0.1, 0.0, 30.0,
        0.1, 0.3, 0.7, 0.0, 40.0,
        0.0, 0.0, 0.0, 1.0,  0.0,
    )

    val EXPECTED_R: Double = 0.5 * SOURCE_R + 0.2 * SOURCE_G + 0.1 * SOURCE_B + 20.0 // 84.0
    val EXPECTED_G: Double = 0.2 * SOURCE_R + 0.8 * SOURCE_G + 0.1 * SOURCE_B + 30.0 // 103.6
    val EXPECTED_B: Double = 0.1 * SOURCE_R + 0.3 * SOURCE_G + 0.7 * SOURCE_B + 40.0 // 91.2

    private const val CHANNEL_TOLERANCE = 40.0
    private const val REGRESSION_TOLERANCE = 40.0

    private data class RgbTriple(val r: Double, val g: Double, val b: Double)

    private data class LaneOutcome(
        val pass: Boolean,
        val reason: String,
        val map: Map<String, Any?>,
        val ownedFiles: List<String>,
    )

    fun run(
        context: Context,
        outputDir: String,
        width: Int = 1280,
        height: Int = 720,
        fps: Int = 30,
        bitrateBps: Int = 4_000_000,
        durationSeconds: Double = 1.0,
    ): Map<String, Any?> {
        val outDirFile = File(outputDir)
        if (!outDirFile.exists() || !outDirFile.isDirectory) {
            return mapOf(
                "pass" to false,
                "reason" to "output_dir_missing_or_not_directory: $outputDir",
                "proofBoundary" to PROOF_BOUNDARY,
                "renderBackend" to null,
                "colorMatrix" to COLOR_MATRIX,
                "laneA" to null,
                "laneB" to null,
                "laneAPass" to false,
                "laneBPass" to false,
            )
        }

        val timestamp = System.currentTimeMillis()
        val ownedFiles = mutableListOf<String>()

        try {
            val laneA = runLane(
                context = context,
                laneId = "laneA",
                outDirFile = outDirFile,
                timestamp = timestamp,
                width = width,
                height = height,
                fps = fps,
                bitrateBps = bitrateBps,
                durationSeconds = durationSeconds,
                sourceExtension = "png",
                compressFormat = Bitmap.CompressFormat.PNG,
                colorMatrix = COLOR_MATRIX,
                expectMatrixApplied = true,
            )
            ownedFiles.addAll(laneA.ownedFiles)

            val laneB = runLane(
                context = context,
                laneId = "laneB",
                outDirFile = outDirFile,
                timestamp = timestamp,
                width = width,
                height = height,
                fps = fps,
                bitrateBps = bitrateBps,
                durationSeconds = durationSeconds,
                sourceExtension = "jpg",
                compressFormat = Bitmap.CompressFormat.JPEG,
                colorMatrix = null,
                expectMatrixApplied = false,
            )
            ownedFiles.addAll(laneB.ownedFiles)

            val overallPass = laneA.pass && laneB.pass
            val reason = if (overallPass) {
                "pass"
            } else if (!laneA.pass) {
                "laneA_failed: ${laneA.reason}"
            } else {
                "laneB_failed: ${laneB.reason}"
            }

            val renderBackend = laneA.map["renderBackend"] as? String

            val result = mapOf(
                "pass" to overallPass,
                "reason" to reason,
                "proofBoundary" to PROOF_BOUNDARY,
                "renderBackend" to renderBackend,
                "colorMatrix" to COLOR_MATRIX,
                "expectedMeanRgb" to mapOf("r" to EXPECTED_R, "g" to EXPECTED_G, "b" to EXPECTED_B),
                "sourceMeanRgb" to mapOf("r" to SOURCE_R, "g" to SOURCE_G, "b" to SOURCE_B),
                "laneA" to laneA.map,
                "laneB" to laneB.map,
                "laneAPass" to laneA.pass,
                "laneBPass" to laneB.pass,
            )

            Log.i(TAG, "ANDROID_STILL_IMAGE_COLOR_MATRIX_EXPORT pass=$overallPass reason=$reason")
            return result
        } finally {
            for (path in ownedFiles) {
                try {
                    val f = File(path)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    /// Runs a single production export lane: generates a synthetic solid-color
    /// still-image source fixture, exercises [AndroidTimelineExportSession]
    /// with a single-clip image draft, and validates the result against a
    /// pixel oracle. When [expectMatrixApplied] is true, the sampled output
    /// must match [COLOR_MATRIX]'s transform of the source color and diverge
    /// from the source; when false, the sampled output must remain close to
    /// the source color (regression: unfiltered still-image passthrough).
    private fun runLane(
        context: Context,
        laneId: String,
        outDirFile: File,
        timestamp: Long,
        width: Int,
        height: Int,
        fps: Int,
        bitrateBps: Int,
        durationSeconds: Double,
        sourceExtension: String,
        compressFormat: Bitmap.CompressFormat,
        colorMatrix: List<Double>?,
        expectMatrixApplied: Boolean,
    ): LaneOutcome {
        val sourcePath = File(outDirFile, "still_color_matrix_source_${laneId}_${timestamp}.$sourceExtension").absolutePath
        val outputPath = File(outDirFile, "still_color_matrix_export_${laneId}_${timestamp}.mp4").absolutePath
        val sidecarPath = AndroidTimelineRoiSidecarEmitter.sidecarPathForVideoPath(outputPath)
        val ownedFiles = mutableListOf(sourcePath, outputPath, sidecarPath)

        val sourceGenSuccess = generateSolidColorStillImage(
            outputPath = sourcePath,
            width = width,
            height = height,
            r = SOURCE_R.toInt(),
            g = SOURCE_G.toInt(),
            b = SOURCE_B.toInt(),
            format = compressFormat,
        )

        val sourceFile = File(sourcePath)
        if (!sourceGenSuccess || !sourceFile.exists() || sourceFile.length() <= 0L) {
            return LaneOutcome(
                pass = false,
                reason = "synthetic_source_generation_failed",
                map = laneMap(
                    pass = false,
                    reason = "synthetic_source_generation_failed",
                    sourcePath = sourcePath,
                    outputPath = outputPath,
                    outputSize = 0L,
                    outputWidth = 0,
                    outputHeight = 0,
                    actualMeanRgb = RgbTriple(0.0, 0.0, 0.0),
                    oraclePass = false,
                    renderBackend = null,
                    errorCode = null,
                    errorMessage = null,
                    expectMatrixApplied = expectMatrixApplied,
                ),
                ownedFiles = ownedFiles,
            )
        }

        val session = AndroidTimelineExportSession(context)
        val latch = CountDownLatch(1)
        var sessionSuccessMap: Map<String, Any?>? = null
        var errorCode: String? = null
        var errorMessage: String? = null
        val progressSamples = Collections.synchronizedList(mutableListOf<Double>())

        val draftClip = mutableMapOf<String, Any?>(
            "id" to "still_color_matrix_clip_$laneId",
            "sourcePath" to sourcePath,
            "mediaKind" to "image",
            "trimStartSeconds" to 0.0,
            "trimEndSeconds" to durationSeconds,
            "speed" to 1.0,
        )
        if (colorMatrix != null) {
            draftClip["colorMatrix"] = colorMatrix
        }

        val draftMap = mapOf(
            "id" to "still_color_matrix_draft_$laneId",
            "clips" to listOf(draftClip),
            "canvasWidth" to width,
            "canvasHeight" to height,
            "fps" to fps,
            "canvas" to mapOf(
                "width" to width,
                "height" to height,
                "contentMode" to "fit",
            ),
        )

        val exportArgs = mapOf(
            "outputPath" to outputPath,
            "width" to width,
            "height" to height,
            "fps" to fps,
            "bitrateBps" to bitrateBps,
            "draft" to draftMap,
        )

        session.start(
            args = exportArgs,
            onSuccess = { res ->
                sessionSuccessMap = res
                latch.countDown()
            },
            onError = { code, msg ->
                errorCode = code
                errorMessage = msg
                latch.countDown()
            },
            onProgress = { p -> progressSamples.add(p) },
        )

        val timedOut = !latch.await(120, TimeUnit.SECONDS)
        val outFile = File(outputPath)
        val outputSize = if (outFile.exists()) outFile.length() else 0L
        val renderBackend = sessionSuccessMap?.get("renderBackend") as? String

        var failureReason: String? = null
        if (timedOut) {
            failureReason = "production_export_timeout_120s"
        } else if (errorCode != null) {
            failureReason = "production_export_error: $errorCode - $errorMessage"
        } else if (sessionSuccessMap == null) {
            failureReason = "production_export_no_result"
        } else if (!outFile.exists() || outputSize <= 0L) {
            failureReason = "production_output_missing_or_empty"
        }

        if (failureReason != null) {
            return LaneOutcome(
                pass = false,
                reason = failureReason,
                map = laneMap(
                    pass = false,
                    reason = failureReason,
                    sourcePath = sourcePath,
                    outputPath = outputPath,
                    outputSize = outputSize,
                    outputWidth = 0,
                    outputHeight = 0,
                    actualMeanRgb = RgbTriple(0.0, 0.0, 0.0),
                    oraclePass = false,
                    renderBackend = renderBackend,
                    errorCode = errorCode,
                    errorMessage = errorMessage,
                    expectMatrixApplied = expectMatrixApplied,
                    progressSamples = progressSamples,
                ),
                ownedFiles = ownedFiles,
            )
        }

        val dims = readVideoDimensions(outputPath)
        val actualOutputWidth = dims?.first ?: width
        val actualOutputHeight = dims?.second ?: height

        val targetTimeUs = ((durationSeconds / 2.0) * 1_000_000L).toLong()
        val bitmap = extractFrame(outputPath, targetTimeUs)

        if (bitmap == null) {
            val reason = "pixel_extraction_failed"
            return LaneOutcome(
                pass = false,
                reason = reason,
                map = laneMap(
                    pass = false,
                    reason = reason,
                    sourcePath = sourcePath,
                    outputPath = outputPath,
                    outputSize = outputSize,
                    outputWidth = actualOutputWidth,
                    outputHeight = actualOutputHeight,
                    actualMeanRgb = RgbTriple(0.0, 0.0, 0.0),
                    oraclePass = false,
                    renderBackend = renderBackend,
                    errorCode = errorCode,
                    errorMessage = errorMessage,
                    expectMatrixApplied = expectMatrixApplied,
                    progressSamples = progressSamples,
                ),
                ownedFiles = ownedFiles,
            )
        }

        val actualMeanRgb = sampleRegionMeanRgb(
            bitmap = bitmap,
            xStartFraction = 0.25f,
            xEndFraction = 0.75f,
            yStartFraction = 0.25f,
            yEndFraction = 0.75f,
        )

        val oracleReasonAndPass = if (expectMatrixApplied) {
            val diffR = abs(actualMeanRgb.r - EXPECTED_R)
            val diffG = abs(actualMeanRgb.g - EXPECTED_G)
            val diffB = abs(actualMeanRgb.b - EXPECTED_B)
            val diffFromSourceG = abs(actualMeanRgb.g - SOURCE_G)
            val diffFromSourceB = abs(actualMeanRgb.b - SOURCE_B)
            val filterAppliedOraclePass = diffFromSourceG >= 15.0 && diffFromSourceB >= 25.0
            val channelsWithinTolerance = diffR <= CHANNEL_TOLERANCE && diffG <= CHANNEL_TOLERANCE && diffB <= CHANNEL_TOLERANCE
            when {
                !filterAppliedOraclePass -> false to "filter_applied_oracle_failed: output color too close to source (diffG=$diffFromSourceG, diffB=$diffFromSourceB)"
                !channelsWithinTolerance -> false to "pixel_diff_exceeds_threshold: diffR=$diffR, diffG=$diffG, diffB=$diffB > $CHANNEL_TOLERANCE"
                else -> true to "pass"
            }
        } else {
            val diffR = abs(actualMeanRgb.r - SOURCE_R)
            val diffG = abs(actualMeanRgb.g - SOURCE_G)
            val diffB = abs(actualMeanRgb.b - SOURCE_B)
            val withinTolerance = diffR <= REGRESSION_TOLERANCE && diffG <= REGRESSION_TOLERANCE && diffB <= REGRESSION_TOLERANCE
            if (withinTolerance) {
                true to "pass"
            } else {
                false to "regression_pixel_diff_exceeds_threshold: diffR=$diffR, diffG=$diffG, diffB=$diffB > $REGRESSION_TOLERANCE"
            }
        }

        val renderBackendPass = renderBackend == "gles"
        val overallPass = oracleReasonAndPass.first && renderBackendPass
        val reason = if (overallPass) {
            "pass"
        } else if (!renderBackendPass) {
            "render_backend_not_gles: renderBackend=$renderBackend"
        } else {
            oracleReasonAndPass.second
        }

        return LaneOutcome(
            pass = overallPass,
            reason = reason,
            map = laneMap(
                pass = overallPass,
                reason = reason,
                sourcePath = sourcePath,
                outputPath = outputPath,
                outputSize = outputSize,
                outputWidth = actualOutputWidth,
                outputHeight = actualOutputHeight,
                actualMeanRgb = actualMeanRgb,
                oraclePass = oracleReasonAndPass.first,
                renderBackend = renderBackend,
                errorCode = errorCode,
                errorMessage = errorMessage,
                expectMatrixApplied = expectMatrixApplied,
                progressSamples = progressSamples,
            ),
            ownedFiles = ownedFiles,
        )
    }

    private fun laneMap(
        pass: Boolean,
        reason: String,
        sourcePath: String,
        outputPath: String,
        outputSize: Long,
        outputWidth: Int,
        outputHeight: Int,
        actualMeanRgb: RgbTriple,
        oraclePass: Boolean,
        renderBackend: String?,
        errorCode: String?,
        errorMessage: String?,
        expectMatrixApplied: Boolean,
        progressSamples: List<Double> = emptyList(),
    ): Map<String, Any?> {
        return mapOf(
            "pass" to pass,
            "reason" to reason,
            "sourcePath" to sourcePath,
            "outputPath" to outputPath,
            "outputSize" to outputSize,
            "outputWidth" to outputWidth,
            "outputHeight" to outputHeight,
            "actualMeanRgb" to mapOf("r" to actualMeanRgb.r, "g" to actualMeanRgb.g, "b" to actualMeanRgb.b),
            "oraclePass" to oraclePass,
            "renderBackend" to renderBackend,
            "errorCode" to errorCode,
            "errorMessage" to errorMessage,
            "expectMatrixApplied" to expectMatrixApplied,
            "progressSamples" to progressSamples,
        )
    }

    private fun generateSolidColorStillImage(
        outputPath: String,
        width: Int,
        height: Int,
        r: Int,
        g: Int,
        b: Int,
        format: Bitmap.CompressFormat,
    ): Boolean {
        var bitmap: Bitmap? = null
        var fos: FileOutputStream? = null
        return try {
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val paint = Paint().apply { color = Color.rgb(r, g, b) }
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
            fos = FileOutputStream(outputPath)
            val quality = if (format == Bitmap.CompressFormat.JPEG) 95 else 100
            val compressed = bitmap.compress(format, quality, fos)
            fos.flush()
            compressed
        } catch (t: Throwable) {
            Log.e(TAG, "generateSolidColorStillImage failed for $outputPath: $t", t)
            false
        } finally {
            try { fos?.close() } catch (_: Throwable) {}
            try { bitmap?.recycle() } catch (_: Throwable) {}
        }
    }

    private fun readVideoDimensions(videoPath: String): Pair<Int, Int>? {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(videoPath)
            val wStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val hStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            val w = wStr?.toIntOrNull()
            val h = hStr?.toIntOrNull()
            if (w != null && w > 0 && h != null && h > 0) w to h else null
        } catch (t: Throwable) {
            Log.w(TAG, "readVideoDimensions: MediaMetadataRetriever failed for $videoPath: $t")
            null
        } finally {
            try { mmr.release() } catch (_: Throwable) {}
        }
    }

    private fun extractFrame(videoPath: String, timeUs: Long): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(videoPath)
            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to extract frame from $videoPath at ${timeUs}us: $t")
            null
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    private fun sampleRegionMeanRgb(
        bitmap: Bitmap,
        xStartFraction: Float,
        xEndFraction: Float,
        yStartFraction: Float,
        yEndFraction: Float,
    ): RgbTriple {
        val w = bitmap.width
        val h = bitmap.height
        val startX = (w * xStartFraction).toInt().coerceIn(0, w - 1)
        val endX = (w * xEndFraction).toInt().coerceIn(startX + 1, w)
        val startY = (h * yStartFraction).toInt().coerceIn(0, h - 1)
        val endY = (h * yEndFraction).toInt().coerceIn(startY + 1, h)

        val stepX = max(1, (endX - startX) / 32)
        val stepY = max(1, (endY - startY) / 32)

        var totalR = 0.0
        var totalG = 0.0
        var totalB = 0.0
        var count = 0L

        var y = startY
        while (y < endY) {
            var x = startX
            while (x < endX) {
                val pixel = bitmap.getPixel(x, y)
                totalR += Color.red(pixel)
                totalG += Color.green(pixel)
                totalB += Color.blue(pixel)
                count++
                x += stepX
            }
            y += stepY
        }

        if (count == 0L) return RgbTriple(0.0, 0.0, 0.0)
        return RgbTriple(totalR / count, totalG / count, totalB / count)
    }
}
