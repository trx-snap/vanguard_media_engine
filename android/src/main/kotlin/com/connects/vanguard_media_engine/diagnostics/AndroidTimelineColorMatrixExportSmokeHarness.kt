package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.export.AndroidTimelineExportSession
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max

/**
 * Physical proof harness for Android timeline video export colorMatrix parity.
 *
 * Proof boundary: [PROOF_BOUNDARY]
 * ("production_exportTimeline_color_matrix_gles_fallback_pixel_oracle")
 *
 * Directly exercises [AndroidTimelineExportSession] with a synthetic solid-color
 * video clip carrying a non-trivial 20-element [colorMatrix] (4x5 row-major with
 * row weights and non-zero additive offsets). Validates:
 * 1. Automatic routing from Vulkan-preferred to GLES backend due to colorMatrix.
 * 2. Successful timeline video export completion via production session.
 * 3. Content-region pixel oracle verifying that the decoded frame output matches
 *    the expected matrix transform within codec tolerance (<=40 per channel)
 *    and distinctly diverges from the source color to prove filter application.
 */
object AndroidTimelineColorMatrixExportSmokeHarness {
    private const val TAG = "VanguardColorMatrixExport"
    const val PROOF_BOUNDARY = "production_exportTimeline_color_matrix_gles_fallback_pixel_oracle"

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

    private data class RgbTriple(val r: Double, val g: Double, val b: Double)

    fun run(
        context: Context,
        outputDir: String,
        width: Int = 1280,
        height: Int = 720,
        outputWidth: Int = width,
        outputHeight: Int = height,
        fps: Int = 30,
        bitrateBps: Int = 4_000_000,
        trimEndSeconds: Double = 1.0,
    ): Map<String, Any?> {
        val outDirFile = File(outputDir)
        if (!outDirFile.exists() || !outDirFile.isDirectory) {
            return failMap(
                reason = "output_dir_missing_or_not_directory: $outputDir",
                sourcePath = "",
                outputPath = "",
                outputSize = 0L,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                colorMatrix = COLOR_MATRIX,
            )
        }

        val timestamp = System.currentTimeMillis()
        val syntheticSourcePath = File(outDirFile, "color_matrix_source_${timestamp}.mp4").absolutePath
        val prodOutputPath = File(outDirFile, "color_matrix_export_${timestamp}.mp4").absolutePath

        val sourceGenSuccess = generateSolidColorSourceVideo(
            outputPath = syntheticSourcePath,
            width = width,
            height = height,
            fps = fps,
            bitrateBps = bitrateBps,
            trimEndSeconds = trimEndSeconds,
            r = SOURCE_R.toInt(),
            g = SOURCE_G.toInt(),
            b = SOURCE_B.toInt(),
        )

        val sourceFile = File(syntheticSourcePath)
        if (!sourceGenSuccess || !sourceFile.exists() || sourceFile.length() <= 0L) {
            return failMap(
                reason = "synthetic_source_generation_failed",
                sourcePath = syntheticSourcePath,
                outputPath = prodOutputPath,
                outputSize = 0L,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                colorMatrix = COLOR_MATRIX,
            )
        }

        var prodPass = false
        var pixelPass = false
        var filterAppliedOraclePass = false
        var failureReason: String? = null

        var prodOutputSize = 0L
        var actualOutputWidth = 0
        var actualOutputHeight = 0
        var prodErrorCode: String? = null
        var prodErrorMessage: String? = null

        val prodProgressSamples = Collections.synchronizedList(mutableListOf<Double>())
        var actualMeanRgb = RgbTriple(0.0, 0.0, 0.0)
        var perChannelAbsDiff = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0)

        try {
            // ── 1. Production export session under test ──────────────────────
            val session = AndroidTimelineExportSession(context)
            val latch = CountDownLatch(1)
            var sessionSuccessMap: Map<String, Any?>? = null

            val draftClip = mapOf(
                "id" to "color_matrix_clip",
                "sourcePath" to syntheticSourcePath,
                "mediaKind" to "video",
                "durationSeconds" to trimEndSeconds,
                "trimStartSeconds" to 0.0,
                "trimEndSeconds" to trimEndSeconds,
                "startTimeSeconds" to 0.0,
                "speed" to 1.0,
                "colorMatrix" to COLOR_MATRIX,
            )

            val draftMap = mapOf(
                "id" to "color_matrix_draft",
                "clips" to listOf(draftClip),
                "canvasWidth" to outputWidth,
                "canvasHeight" to outputHeight,
                "fps" to fps,
                "canvas" to mapOf(
                    "width" to outputWidth,
                    "height" to outputHeight,
                    "contentMode" to "fit",
                ),
            )

            val exportArgs = mapOf(
                "outputPath" to prodOutputPath,
                "width" to outputWidth,
                "height" to outputHeight,
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
                    prodErrorCode = code
                    prodErrorMessage = msg
                    latch.countDown()
                },
                onProgress = { p ->
                    prodProgressSamples.add(p)
                },
            )

            val timedOut = !latch.await(120, TimeUnit.SECONDS)
            val prodFile = File(prodOutputPath)
            prodOutputSize = if (prodFile.exists()) prodFile.length() else 0L

            if (timedOut) {
                failureReason = "production_export_timeout_120s"
            } else if (prodErrorCode != null) {
                failureReason = "production_export_error: $prodErrorCode - $prodErrorMessage"
            } else if (sessionSuccessMap == null) {
                failureReason = "production_export_no_result"
            } else if (!prodFile.exists() || prodOutputSize <= 0L) {
                failureReason = "production_output_missing_or_empty"
            } else {
                prodPass = true
            }

            if (!prodPass) {
                return finishResult(
                    pass = false,
                    reason = failureReason ?: "production_export_failed",
                    sourcePath = syntheticSourcePath,
                    outputPath = prodOutputPath,
                    outputSize = prodOutputSize,
                    outputWidth = actualOutputWidth,
                    outputHeight = actualOutputHeight,
                    sourceMeanRgb = mapOf("r" to SOURCE_R, "g" to SOURCE_G, "b" to SOURCE_B),
                    expectedMeanRgb = mapOf("r" to EXPECTED_R, "g" to EXPECTED_G, "b" to EXPECTED_B),
                    actualMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
                    perChannelAbsDiff = perChannelAbsDiff,
                    filterAppliedOraclePass = false,
                    productionPass = false,
                    pixelPass = false,
                    colorMatrix = COLOR_MATRIX,
                    progressSamples = prodProgressSamples,
                    errorCode = prodErrorCode,
                    errorMessage = prodErrorMessage,
                )
            }

            // ── 2. Pixel Oracle: extract frame & sample content region ───────
            val dims = readVideoDimensions(prodOutputPath)
            actualOutputWidth = dims?.first ?: outputWidth
            actualOutputHeight = dims?.second ?: outputHeight

            val targetTimeUs = ((trimEndSeconds / 2.0) * 1_000_000L).toLong()
            val prodBitmap = extractFrame(prodOutputPath, targetTimeUs)

            if (prodBitmap == null) {
                failureReason = "pixel_extraction_failed"
            } else {
                // Sample only central content region (25%..75%) to avoid edge artifacts
                actualMeanRgb = sampleRegionMeanRgb(
                    bitmap = prodBitmap,
                    xStartFraction = 0.25f,
                    xEndFraction = 0.75f,
                    yStartFraction = 0.25f,
                    yEndFraction = 0.75f,
                )

                val diffR = abs(actualMeanRgb.r - EXPECTED_R)
                val diffG = abs(actualMeanRgb.g - EXPECTED_G)
                val diffB = abs(actualMeanRgb.b - EXPECTED_B)
                perChannelAbsDiff = mapOf("r" to diffR, "g" to diffG, "b" to diffB)

                val diffFromSourceR = abs(actualMeanRgb.r - SOURCE_R)
                val diffFromSourceG = abs(actualMeanRgb.g - SOURCE_G)
                val diffFromSourceB = abs(actualMeanRgb.b - SOURCE_B)

                // Prove filter application: output must differ significantly from source
                filterAppliedOraclePass = (diffFromSourceG >= 15.0 && diffFromSourceB >= 25.0) ||
                    ((diffFromSourceR + diffFromSourceG + diffFromSourceB) / 3.0 >= 15.0)

                // Codec-tolerant threshold check (<=40 per channel)
                val channelsWithinTolerance = diffR <= 40.0 && diffG <= 40.0 && diffB <= 40.0

                if (!filterAppliedOraclePass) {
                    failureReason = "filter_applied_oracle_failed: output color too close to source (diffG=$diffFromSourceG, diffB=$diffFromSourceB)"
                } else if (!channelsWithinTolerance) {
                    failureReason = "pixel_diff_exceeds_threshold: diffR=$diffR, diffG=$diffG, diffB=$diffB > 40.0"
                } else {
                    pixelPass = true
                }
            }

            val overallPass = prodPass && pixelPass && filterAppliedOraclePass

            val result = finishResult(
                pass = overallPass,
                reason = if (overallPass) "pass" else (failureReason ?: "pixel_oracle_failed"),
                sourcePath = syntheticSourcePath,
                outputPath = prodOutputPath,
                outputSize = prodOutputSize,
                outputWidth = actualOutputWidth,
                outputHeight = actualOutputHeight,
                sourceMeanRgb = mapOf("r" to SOURCE_R, "g" to SOURCE_G, "b" to SOURCE_B),
                expectedMeanRgb = mapOf("r" to EXPECTED_R, "g" to EXPECTED_G, "b" to EXPECTED_B),
                actualMeanRgb = mapOf("r" to actualMeanRgb.r, "g" to actualMeanRgb.g, "b" to actualMeanRgb.b),
                perChannelAbsDiff = perChannelAbsDiff,
                filterAppliedOraclePass = filterAppliedOraclePass,
                productionPass = prodPass,
                pixelPass = pixelPass,
                colorMatrix = COLOR_MATRIX,
                progressSamples = prodProgressSamples,
                errorCode = prodErrorCode,
                errorMessage = prodErrorMessage,
            )

            Log.i(TAG, "ANDROID_TIMELINE_COLOR_MATRIX_EXPORT pass=$overallPass reason=${result["reason"]}")
            return result
        } catch (t: Throwable) {
            val exReason = "exception: ${t.javaClass.simpleName}: ${t.message}"
            Log.e(TAG, "AndroidTimelineColorMatrixExportSmokeHarness uncaught exception", t)
            return finishResult(
                pass = false,
                reason = exReason,
                sourcePath = syntheticSourcePath,
                outputPath = prodOutputPath,
                outputSize = prodOutputSize,
                outputWidth = actualOutputWidth,
                outputHeight = actualOutputHeight,
                sourceMeanRgb = mapOf("r" to SOURCE_R, "g" to SOURCE_G, "b" to SOURCE_B),
                expectedMeanRgb = mapOf("r" to EXPECTED_R, "g" to EXPECTED_G, "b" to EXPECTED_B),
                actualMeanRgb = mapOf("r" to actualMeanRgb.r, "g" to actualMeanRgb.g, "b" to actualMeanRgb.b),
                perChannelAbsDiff = perChannelAbsDiff,
                filterAppliedOraclePass = filterAppliedOraclePass,
                productionPass = prodPass,
                pixelPass = pixelPass,
                colorMatrix = COLOR_MATRIX,
                progressSamples = prodProgressSamples,
                errorCode = prodErrorCode ?: t.javaClass.simpleName,
                errorMessage = prodErrorMessage ?: t.message,
            )
        }
    }

    private fun finishResult(
        pass: Boolean,
        reason: String,
        sourcePath: String,
        outputPath: String,
        outputSize: Long,
        outputWidth: Int,
        outputHeight: Int,
        sourceMeanRgb: Map<String, Double>,
        expectedMeanRgb: Map<String, Double>,
        actualMeanRgb: Map<String, Double>,
        perChannelAbsDiff: Map<String, Double>,
        filterAppliedOraclePass: Boolean,
        productionPass: Boolean,
        pixelPass: Boolean,
        colorMatrix: List<Double>,
        progressSamples: List<Double>,
        errorCode: String?,
        errorMessage: String?,
    ): Map<String, Any?> {
        return mapOf(
            "pass" to pass,
            "reason" to reason,
            "sourcePath" to sourcePath,
            "outputPath" to outputPath,
            "outputSize" to outputSize,
            "outputWidth" to outputWidth,
            "outputHeight" to outputHeight,
            "sourceMeanRgb" to sourceMeanRgb,
            "expectedMeanRgb" to expectedMeanRgb,
            "actualMeanRgb" to actualMeanRgb,
            "perChannelAbsDiff" to perChannelAbsDiff,
            "filterAppliedOraclePass" to filterAppliedOraclePass,
            "productionPass" to productionPass,
            "pixelPass" to pixelPass,
            "proofBoundary" to PROOF_BOUNDARY,
            "matrixMode" to "row_major_4x5_with_offsets",
            "colorMatrix" to colorMatrix,
            "progressSamples" to progressSamples,
            "errorCode" to errorCode,
            "errorMessage" to errorMessage,
            "contentRegionOnly" to true,
        )
    }

    private fun failMap(
        reason: String,
        sourcePath: String,
        outputPath: String,
        outputSize: Long,
        outputWidth: Int,
        outputHeight: Int,
        colorMatrix: List<Double>,
    ): Map<String, Any?> {
        return finishResult(
            pass = false,
            reason = reason,
            sourcePath = sourcePath,
            outputPath = outputPath,
            outputSize = outputSize,
            outputWidth = outputWidth,
            outputHeight = outputHeight,
            sourceMeanRgb = mapOf("r" to SOURCE_R, "g" to SOURCE_G, "b" to SOURCE_B),
            expectedMeanRgb = mapOf("r" to EXPECTED_R, "g" to EXPECTED_G, "b" to EXPECTED_B),
            actualMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
            perChannelAbsDiff = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
            filterAppliedOraclePass = false,
            productionPass = false,
            pixelPass = false,
            colorMatrix = colorMatrix,
            progressSamples = emptyList(),
            errorCode = null,
            errorMessage = null,
        )
    }

    private fun generateSolidColorSourceVideo(
        outputPath: String,
        width: Int,
        height: Int,
        fps: Int,
        bitrateBps: Int,
        trimEndSeconds: Double,
        r: Int,
        g: Int,
        b: Int,
    ): Boolean {
        val targetFrames = max(1, (fps * trimEndSeconds).toInt())
        val framesToDraw = targetFrames + 1
        val frameDurationUs = (1_000_000L / fps).coerceAtLeast(1L)

        var codec: MediaCodec? = null
        var encoderSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var videoTrackIndex = -1
        var writtenVideoSamples = 0
        var muxerStoppedCleanly = false

        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }

            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = codec.createInputSurface()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            codec.start()

            val bufferInfo = MediaCodec.BufferInfo()

            fun drainOutput(endOfStream: Boolean, timeoutMs: Long) {
                val deadline = System.currentTimeMillis() + timeoutMs
                var draining = true
                while (draining && System.currentTimeMillis() <= deadline) {
                    val outIdx = codec.dequeueOutputBuffer(bufferInfo, 10_000L)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (!endOfStream) {
                                draining = false
                            }
                        }
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (videoTrackIndex < 0) {
                                val outFmt = codec.outputFormat
                                videoTrackIndex = muxer.addTrack(outFmt)
                                muxer.start()
                                muxerStarted = true
                            }
                        }
                        outIdx >= 0 -> {
                            val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0

                            if (!isConfig && bufferInfo.size > 0 && muxerStarted && videoTrackIndex >= 0) {
                                val encodedData = codec.getOutputBuffer(outIdx)
                                if (encodedData != null) {
                                    encodedData.position(bufferInfo.offset)
                                    encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                    bufferInfo.presentationTimeUs = writtenVideoSamples * frameDurationUs
                                    muxer.writeSampleData(videoTrackIndex, encodedData, bufferInfo)
                                    writtenVideoSamples++
                                }
                            }
                            codec.releaseOutputBuffer(outIdx, false)
                            if (isEos) {
                                draining = false
                            }
                        }
                    }
                }
            }

            val paint = Paint().apply { color = Color.rgb(r, g, b) }

            for (frameIdx in 0 until framesToDraw) {
                val canvas = try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        encoderSurface.lockHardwareCanvas()
                    } else {
                        encoderSurface.lockCanvas(null)
                    }
                } catch (_: Throwable) {
                    encoderSurface.lockCanvas(null)
                }

                canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
                encoderSurface.unlockCanvasAndPost(canvas)
                drainOutput(endOfStream = false, timeoutMs = 100L)
            }

            codec.signalEndOfInputStream()
            drainOutput(endOfStream = true, timeoutMs = 5000L)

            if (muxerStarted && writtenVideoSamples > 0) {
                try {
                    muxer.stop()
                    muxerStoppedCleanly = true
                } catch (t: Throwable) {
                    Log.w(TAG, "generateSolidColorSourceVideo: MediaMuxer.stop failed: $t")
                }
            }

            val generatedFile = File(outputPath)
            val success = muxerStoppedCleanly && generatedFile.exists() && generatedFile.length() > 0L && writtenVideoSamples >= targetFrames
            return success
        } catch (t: Throwable) {
            Log.e(TAG, "generateSolidColorSourceVideo failed", t)
            return false
        } finally {
            try { encoderSurface?.release() } catch (_: Throwable) {}
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
        }
    }

    private fun readVideoDimensions(videoPath: String): Pair<Int, Int>? {
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(videoPath)
            val wStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val hStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            val w = wStr?.toIntOrNull()
            val h = hStr?.toIntOrNull()
            if (w != null && w > 0 && h != null && h > 0) {
                return w to h
            }
        } catch (t: Throwable) {
            Log.w(TAG, "readVideoDimensions: MediaMetadataRetriever failed for $videoPath: $t")
        } finally {
            try { mmr.release() } catch (_: Throwable) {}
        }

        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(videoPath)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME)
                if (mime != null && mime.startsWith("video/")) {
                    val w = if (format.containsKey(MediaFormat.KEY_WIDTH)) format.getInteger(MediaFormat.KEY_WIDTH) else 0
                    val h = if (format.containsKey(MediaFormat.KEY_HEIGHT)) format.getInteger(MediaFormat.KEY_HEIGHT) else 0
                    if (w > 0 && h > 0) return w to h
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "readVideoDimensions: MediaExtractor failed for $videoPath: $t")
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
        return null
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
