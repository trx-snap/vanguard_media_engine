package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
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
import com.connects.vanguard_media_engine.export.AndroidTimelineRoiSidecarEmitter
import com.connects.vanguard_media_engine.export.AndroidTimelineVideoEncoder
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max

object AndroidVulkanExportProductionWiringSmokeHarness {
    private const val TAG = "VanguardVulkanExportWiring"
    private const val PROOF_BOUNDARY = "production_exportTimeline_vulkan_vs_direct_gles_pixel_parity"

    fun run(
        context: Context,
        sourcePath: String? = null,
        outputDir: String,
        useSyntheticSource: Boolean = sourcePath.isNullOrBlank(),
        width: Int = 1280,
        height: Int = 720,
        fps: Int = 30,
        bitrateBps: Int = 4_000_000,
        trimEndSeconds: Double = 1.0,
        sourceRotationDegrees: Int = 0,
    ): Map<String, Any?> {
        val outDirFile = File(outputDir)
        val sourceMode = if (useSyntheticSource) "synthetic" else "provided"

        if (sourceRotationDegrees !in setOf(0, 90, 180, 270)) {
            return failMap(
                reason = "invalid_source_rotation_degrees: $sourceRotationDegrees",
                sourceMode = sourceMode,
                sourcePath = sourcePath ?: "",
                generatedSourcePath = null,
                generatedSourceSize = 0L,
                sourceRotationDegrees = sourceRotationDegrees,
                prodPath = "",
                glesPath = "",
            )
        }

        if (!outDirFile.exists() || !outDirFile.isDirectory) {
            return failMap(
                reason = "output_dir_missing_or_not_directory: $outputDir",
                sourceMode = sourceMode,
                sourcePath = sourcePath ?: "",
                generatedSourcePath = null,
                generatedSourceSize = 0L,
                sourceRotationDegrees = sourceRotationDegrees,
                prodPath = "",
                glesPath = "",
            )
        }

        val timestamp = System.currentTimeMillis()
        var generatedSourcePath: String? = null
        var generatedSourceSize = 0L
        val effectiveSourcePath: String

        if (useSyntheticSource) {
            val genPath = File(outDirFile, "vulkan_production_wiring_${timestamp}_synthetic_source.mp4").absolutePath
            generatedSourcePath = genPath
            val genSuccess = generateSyntheticSourceVideo(
                outputPath = genPath,
                width = width,
                height = height,
                fps = fps,
                bitrateBps = bitrateBps,
                trimEndSeconds = trimEndSeconds,
                sourceRotationDegrees = sourceRotationDegrees,
            )
            val genFile = File(genPath)
            if (!genSuccess || !genFile.exists() || genFile.length() <= 0L) {
                try { if (genFile.exists()) genFile.delete() } catch (_: Throwable) {}
                return failMap(
                    reason = "synthetic_source_generation_failed",
                    sourceMode = sourceMode,
                    sourcePath = genPath,
                    generatedSourcePath = genPath,
                    generatedSourceSize = 0L,
                    sourceRotationDegrees = sourceRotationDegrees,
                    prodPath = "",
                    glesPath = "",
                )
            }
            generatedSourceSize = genFile.length()
            effectiveSourcePath = genPath
        } else {
            if (sourcePath.isNullOrBlank()) {
                return failMap(
                    reason = "source_path_required_for_provided_mode",
                    sourceMode = sourceMode,
                    sourcePath = "",
                    generatedSourcePath = null,
                    generatedSourceSize = 0L,
                    sourceRotationDegrees = sourceRotationDegrees,
                    prodPath = "",
                    glesPath = "",
                )
            }
            val sourceFile = File(sourcePath)
            if (!sourceFile.exists() || !sourceFile.canRead()) {
                return failMap(
                    reason = "source_file_missing_or_unreadable: $sourcePath",
                    sourceMode = sourceMode,
                    sourcePath = sourcePath,
                    generatedSourcePath = null,
                    generatedSourceSize = 0L,
                    sourceRotationDegrees = sourceRotationDegrees,
                    prodPath = "",
                    glesPath = "",
                )
            }
            effectiveSourcePath = sourcePath
        }

        val sourceMetadataRotationDegrees = readSourceMetadataRotationDegrees(effectiveSourcePath)
        if (sourceRotationDegrees != 0 && sourceMetadataRotationDegrees != sourceRotationDegrees) {
            return failMap(
                reason = "source_rotation_metadata_mismatch:expected=$sourceRotationDegrees:actual=$sourceMetadataRotationDegrees",
                sourceMode = sourceMode,
                sourcePath = effectiveSourcePath,
                generatedSourcePath = generatedSourcePath,
                generatedSourceSize = generatedSourceSize,
                sourceRotationDegrees = sourceRotationDegrees,
                sourceMetadataRotationDegrees = sourceMetadataRotationDegrees,
                prodPath = "",
                glesPath = "",
            )
        }

        val prodOutputPath = File(outDirFile, "vulkan_production_wiring_${timestamp}_production.mp4").absolutePath
        val glesOutputPath = File(outDirFile, "vulkan_production_wiring_${timestamp}_gles_baseline.mp4").absolutePath
        val prodSidecarPath = AndroidTimelineRoiSidecarEmitter.sidecarPathForVideoPath(prodOutputPath)

        var prodPass = false
        var glesPass = false
        var pixelPass = false
        var failureReason: String? = null

        var prodOutputSize = 0L
        var glesOutputSize = 0L
        var prodSidecarExists = false
        var prodErrorCode: String? = null
        var prodErrorMessage: String? = null

        val prodProgressSamples = Collections.synchronizedList(mutableListOf<Double>())
        val glesProgressSamples = Collections.synchronizedList(mutableListOf<Double>())

        var prodMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0)
        var glesMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0)
        var meanAbsDiff = -1.0

        try {
            // ── Lane A: Production route under test ──────────────────────────
            val session = AndroidTimelineExportSession(context)
            val latch = CountDownLatch(1)
            var sessionSuccessMap: Map<String, Any?>? = null

            val draftClip = mapOf(
                "id" to "vulkan_prod_clip",
                "sourcePath" to effectiveSourcePath,
                "mediaKind" to "video",
                "durationSeconds" to trimEndSeconds,
                "trimStartSeconds" to 0.0,
                "trimEndSeconds" to trimEndSeconds,
                "startTimeSeconds" to 0.0,
                "speed" to 1.0,
            )

            val draftMap = mapOf(
                "id" to "vulkan_prod_draft",
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
                "outputPath" to prodOutputPath,
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
            val prodSidecarFile = File(prodSidecarPath)
            prodOutputSize = if (prodFile.exists()) prodFile.length() else 0L
            prodSidecarExists = prodSidecarFile.exists()

            if (timedOut) {
                failureReason = "production_export_timeout_120s"
            } else if (prodErrorCode != null) {
                failureReason = "production_export_error: $prodErrorCode - $prodErrorMessage"
            } else if (sessionSuccessMap == null) {
                failureReason = "production_export_no_result"
            } else if (!prodFile.exists() || prodOutputSize <= 0L) {
                failureReason = "production_output_missing_or_empty"
            } else if (!prodSidecarExists) {
                failureReason = "production_sidecar_missing"
            } else {
                prodPass = true
            }

            if (!prodPass) {
                return finishResult(
                    pass = false,
                    reason = failureReason ?: "production_lane_failed",
                    sourceMode = sourceMode,
                    sourcePath = effectiveSourcePath,
                    generatedSourcePath = generatedSourcePath,
                    generatedSourceSize = generatedSourceSize,
                    sourceRotationDegrees = sourceRotationDegrees,
                    sourceMetadataRotationDegrees = sourceMetadataRotationDegrees,
                    prodPass = prodPass,
                    glesPass = glesPass,
                    pixelPass = pixelPass,
                    prodPath = prodOutputPath,
                    glesPath = glesOutputPath,
                    prodSize = prodOutputSize,
                    glesSize = glesOutputSize,
                    prodSidecarPath = prodSidecarPath,
                    prodSidecarExists = prodSidecarExists,
                    prodErrorCode = prodErrorCode,
                    prodErrorMessage = prodErrorMessage,
                    prodProgressSamples = prodProgressSamples,
                    glesProgressSamples = glesProgressSamples,
                    prodMeanRgb = prodMeanRgb,
                    glesMeanRgb = glesMeanRgb,
                    meanAbsDiff = meanAbsDiff,
                )
            }

            // ── Lane B: Direct GLES baseline ────────────────────────────────
            val glesEncoder = AndroidTimelineVideoEncoder(
                outputPath = glesOutputPath,
                width = width,
                height = height,
                fps = fps,
                bitrateBps = bitrateBps,
            )

            val clipInput = AndroidTimelineVideoEncoder.ClipInput(
                sourcePath = effectiveSourcePath,
                trimStartSeconds = 0.0,
                trimEndSeconds = trimEndSeconds,
                decodedWidth = width,
                decodedHeight = height,
                rotationDegrees = sourceRotationDegrees,
                mediaKind = "video",
            )

            val glesResult = glesEncoder.encode(listOf(clipInput)) { p ->
                glesProgressSamples.add(p)
            }

            val glesFile = File(glesOutputPath)
            glesOutputSize = if (glesFile.exists()) glesFile.length() else 0L

            if (!glesResult.success) {
                failureReason = "gles_encode_failed: ${glesResult.reason}"
            } else if (!glesFile.exists() || glesOutputSize <= 0L) {
                failureReason = "gles_output_missing_or_empty"
            } else if (glesResult.writtenVideoSamples <= 0) {
                failureReason = "gles_no_video_samples_written"
            } else {
                glesPass = true
            }

            if (!glesPass) {
                return finishResult(
                    pass = false,
                    reason = failureReason ?: "gles_lane_failed",
                    sourceMode = sourceMode,
                    sourcePath = effectiveSourcePath,
                    generatedSourcePath = generatedSourcePath,
                    generatedSourceSize = generatedSourceSize,
                    sourceRotationDegrees = sourceRotationDegrees,
                    sourceMetadataRotationDegrees = sourceMetadataRotationDegrees,
                    prodPass = prodPass,
                    glesPass = glesPass,
                    pixelPass = pixelPass,
                    prodPath = prodOutputPath,
                    glesPath = glesOutputPath,
                    prodSize = prodOutputSize,
                    glesSize = glesOutputSize,
                    prodSidecarPath = prodSidecarPath,
                    prodSidecarExists = prodSidecarExists,
                    prodErrorCode = prodErrorCode,
                    prodErrorMessage = prodErrorMessage,
                    prodProgressSamples = prodProgressSamples,
                    glesProgressSamples = glesProgressSamples,
                    prodMeanRgb = prodMeanRgb,
                    glesMeanRgb = glesMeanRgb,
                    meanAbsDiff = meanAbsDiff,
                )
            }

            // ── Lane C: Pixel sanity / parity ───────────────────────────────
            val targetTimeUs = if (trimEndSeconds < 0.6) {
                (trimEndSeconds * 500_000.0).toLong().coerceAtLeast(0L)
            } else {
                500_000L
            }

            val prodBitmap = extractFrame(prodOutputPath, targetTimeUs)
            val glesBitmap = extractFrame(glesOutputPath, targetTimeUs)

            if (prodBitmap == null) {
                failureReason = "pixel_extraction_failed_production"
            } else if (glesBitmap == null) {
                failureReason = "pixel_extraction_failed_gles"
            } else {
                val pRgb = computeMeanRgb(prodBitmap)
                val gRgb = computeMeanRgb(glesBitmap)

                prodMeanRgb = mapOf("r" to pRgb.r, "g" to pRgb.g, "b" to pRgb.b)
                glesMeanRgb = mapOf("r" to gRgb.r, "g" to gRgb.g, "b" to gRgb.b)

                val diff = (abs(pRgb.r - gRgb.r) + abs(pRgb.g - gRgb.g) + abs(pRgb.b - gRgb.b)) / 3.0
                meanAbsDiff = diff

                val prodAvg = (pRgb.r + pRgb.g + pRgb.b) / 3.0
                val glesAvg = (gRgb.r + gRgb.g + gRgb.b) / 3.0

                val prodNonBlank = prodAvg in 3.0..252.0
                val glesNonBlank = glesAvg in 3.0..252.0
                val diffAcceptable = diff <= 30.0

                if (!prodNonBlank) {
                    failureReason = "pixel_production_blank_sentinel: avg=$prodAvg"
                } else if (!glesNonBlank) {
                    failureReason = "pixel_gles_blank_sentinel: avg=$glesAvg"
                } else if (!diffAcceptable) {
                    failureReason = "pixel_diff_exceeds_threshold: diff=$diff > 30.0"
                } else {
                    pixelPass = true
                }
            }

            val overallPass = prodPass && glesPass && pixelPass
            return finishResult(
                pass = overallPass,
                reason = if (overallPass) "pass" else (failureReason ?: "pixel_lane_failed"),
                sourceMode = sourceMode,
                sourcePath = effectiveSourcePath,
                generatedSourcePath = generatedSourcePath,
                generatedSourceSize = generatedSourceSize,
                sourceRotationDegrees = sourceRotationDegrees,
                sourceMetadataRotationDegrees = sourceMetadataRotationDegrees,
                prodPass = prodPass,
                glesPass = glesPass,
                pixelPass = pixelPass,
                prodPath = prodOutputPath,
                glesPath = glesOutputPath,
                prodSize = prodOutputSize,
                glesSize = glesOutputSize,
                prodSidecarPath = prodSidecarPath,
                prodSidecarExists = prodSidecarExists,
                prodErrorCode = prodErrorCode,
                prodErrorMessage = prodErrorMessage,
                prodProgressSamples = prodProgressSamples,
                glesProgressSamples = glesProgressSamples,
                prodMeanRgb = prodMeanRgb,
                glesMeanRgb = glesMeanRgb,
                meanAbsDiff = meanAbsDiff,
            )
        } catch (t: Throwable) {
            val exReason = "exception: ${t.javaClass.simpleName}: ${t.message}"
            Log.e(TAG, "AndroidVulkanExportProductionWiringSmokeHarness uncaught exception", t)
            return finishResult(
                pass = false,
                reason = exReason,
                sourceMode = sourceMode,
                sourcePath = effectiveSourcePath,
                generatedSourcePath = generatedSourcePath,
                generatedSourceSize = generatedSourceSize,
                sourceRotationDegrees = sourceRotationDegrees,
                sourceMetadataRotationDegrees = sourceMetadataRotationDegrees,
                prodPass = prodPass,
                glesPass = glesPass,
                pixelPass = pixelPass,
                prodPath = prodOutputPath,
                glesPath = glesOutputPath,
                prodSize = prodOutputSize,
                glesSize = glesOutputSize,
                prodSidecarPath = prodSidecarPath,
                prodSidecarExists = prodSidecarExists,
                prodErrorCode = prodErrorCode,
                prodErrorMessage = prodErrorMessage,
                prodProgressSamples = prodProgressSamples,
                glesProgressSamples = glesProgressSamples,
                prodMeanRgb = prodMeanRgb,
                glesMeanRgb = glesMeanRgb,
                meanAbsDiff = meanAbsDiff,
            )
        } finally {
            if (useSyntheticSource && generatedSourcePath != null) {
                try {
                    val genFile = File(generatedSourcePath)
                    if (genFile.exists()) {
                        genFile.delete()
                    }
                } catch (_: Throwable) {}
            }
        }
    }

    private fun generateSyntheticSourceVideo(
        outputPath: String,
        width: Int,
        height: Int,
        fps: Int,
        bitrateBps: Int,
        trimEndSeconds: Double,
        sourceRotationDegrees: Int = 0,
    ): Boolean {
        if (sourceRotationDegrees !in setOf(0, 90, 180, 270)) {
            Log.e(TAG, "generateSyntheticSourceVideo: non-cardinal rotationDegrees: $sourceRotationDegrees")
            return false
        }

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
            muxer.setOrientationHint(sourceRotationDegrees)
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

                val bandHeight = height / 3f
                val paint1 = Paint().apply { color = Color.rgb(40, 90, 200) }
                val paint2 = Paint().apply { color = Color.rgb(50, 180, 80) }
                val paint3 = Paint().apply { color = Color.rgb(210, 80, 40) }

                canvas.drawRect(0f, 0f, width.toFloat(), bandHeight, paint1)
                canvas.drawRect(0f, bandHeight, width.toFloat(), bandHeight * 2f, paint2)
                canvas.drawRect(0f, bandHeight * 2f, width.toFloat(), height.toFloat(), paint3)

                val boxW = width / 4f
                val boxH = height / 4f
                val shiftX = if (framesToDraw > 1) (frameIdx.toFloat() / (framesToDraw - 1)) * (width - boxW) else 0f
                val boxY = (height - boxH) / 2f
                val boxPaint = Paint().apply { color = Color.rgb(240, 210, 40) }
                canvas.drawRect(shiftX, boxY, shiftX + boxW, boxY + boxH, boxPaint)

                val barPaint = Paint().apply { color = Color.rgb(180, 50, 220) }
                val barHeight = 16f
                val barW = if (framesToDraw > 1) ((frameIdx + 1).toFloat() / framesToDraw) * width else width.toFloat()
                canvas.drawRect(0f, height - barHeight, barW, height.toFloat(), barPaint)

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
                    Log.w(TAG, "generateSyntheticSourceVideo: MediaMuxer.stop failed: $t")
                }
            }

            val outFile = File(outputPath)
            return writtenVideoSamples >= targetFrames && muxerStoppedCleanly && outFile.exists() && outFile.length() > 0L
        } catch (t: Throwable) {
            Log.e(TAG, "generateSyntheticSourceVideo failed", t)
            return false
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
            try { encoderSurface?.release() } catch (_: Throwable) {}
        }
    }

    private fun readSourceMetadataRotationDegrees(videoPath: String): Int {
        var rawRotation: Int? = null
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(videoPath)
            val trackCount = extractor.trackCount
            for (i in 0 until trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME)
                if (mime != null && mime.startsWith("video/")) {
                    if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                        rawRotation = format.getInteger(MediaFormat.KEY_ROTATION)
                    }
                    break
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "readSourceMetadataRotationDegrees: MediaExtractor failed for $videoPath: $t")
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }

        if (rawRotation == null) {
            val mmr = MediaMetadataRetriever()
            try {
                mmr.setDataSource(videoPath)
                val rotStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                rawRotation = rotStr?.toIntOrNull()
            } catch (t: Throwable) {
                Log.w(TAG, "readSourceMetadataRotationDegrees: MediaMetadataRetriever fallback failed for $videoPath: $t")
            } finally {
                try { mmr.release() } catch (_: Throwable) {}
            }
        }

        val raw = rawRotation ?: 0
        val normalized = ((raw % 360) + 360) % 360
        return when (normalized) {
            0, 90, 180, 270 -> normalized
            else -> 0
        }
    }

    private data class RgbTriple(val r: Double, val g: Double, val b: Double)

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

    private fun computeMeanRgb(bitmap: Bitmap): RgbTriple {
        val w = bitmap.width
        val h = bitmap.height
        val stepX = max(1, w / 64)
        val stepY = max(1, h / 64)

        var totalR = 0.0
        var totalG = 0.0
        var totalB = 0.0
        var count = 0L

        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val pixel = bitmap.getPixel(x, y)
                val r = Color.red(pixel)
                val g = Color.green(pixel)
                val b = Color.blue(pixel)
                totalR += r
                totalG += g
                totalB += b
                count++
                x += stepX
            }
            y += stepY
        }

        if (count == 0L) return RgbTriple(0.0, 0.0, 0.0)
        return RgbTriple(totalR / count, totalG / count, totalB / count)
    }

    private fun finishResult(
        pass: Boolean,
        reason: String,
        sourceMode: String,
        sourcePath: String,
        generatedSourcePath: String?,
        generatedSourceSize: Long,
        sourceRotationDegrees: Int,
        sourceMetadataRotationDegrees: Int = 0,
        prodPass: Boolean,
        glesPass: Boolean,
        pixelPass: Boolean,
        prodPath: String,
        glesPath: String,
        prodSize: Long,
        glesSize: Long,
        prodSidecarPath: String,
        prodSidecarExists: Boolean,
        prodErrorCode: String?,
        prodErrorMessage: String?,
        prodProgressSamples: List<Double>,
        glesProgressSamples: List<Double>,
        prodMeanRgb: Map<String, Double>,
        glesMeanRgb: Map<String, Double>,
        meanAbsDiff: Double,
    ): Map<String, Any?> {
        val statusStr = if (pass) "PASS" else "FAIL"
        Log.i(
            TAG,
            "ANDROID_VULKAN_EXPORT_PRODUCTION_WIRING_RESULT status=$statusStr;reason=$reason;sourceMode=$sourceMode;sourceRotationDegrees=$sourceRotationDegrees;sourceMetadataRotationDegrees=$sourceMetadataRotationDegrees;productionBytes=$prodSize;glesBytes=$glesSize;meanAbsDiff=$meanAbsDiff",
        )

        if (!pass) {
            // On fail, best-effort delete outputs created by this harness only. Do not delete the input source.
            if (prodPath.isNotEmpty()) {
                try { File(prodPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            }
            if (prodSidecarPath.isNotEmpty()) {
                try { File(prodSidecarPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            }
            if (glesPath.isNotEmpty()) {
                try { File(glesPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            }
        }

        return mapOf(
            "pass" to pass,
            "reason" to reason,
            "sourceMode" to sourceMode,
            "sourcePath" to sourcePath,
            "generatedSourcePath" to generatedSourcePath,
            "generatedSourceSize" to generatedSourceSize,
            "sourceRotationDegrees" to sourceRotationDegrees,
            "sourceMetadataRotationDegrees" to sourceMetadataRotationDegrees,
            "productionPass" to prodPass,
            "glesPass" to glesPass,
            "pixelPass" to pixelPass,
            "productionOutputPath" to prodPath,
            "glesOutputPath" to glesPath,
            "productionOutputSize" to prodSize,
            "glesOutputSize" to glesSize,
            "productionSidecarPath" to prodSidecarPath,
            "productionSidecarExists" to prodSidecarExists,
            "productionErrorCode" to prodErrorCode,
            "productionErrorMessage" to prodErrorMessage,
            "productionProgressSamples" to prodProgressSamples.toList(),
            "glesProgressSamples" to glesProgressSamples.toList(),
            "productionMeanRgb" to prodMeanRgb,
            "glesMeanRgb" to glesMeanRgb,
            "meanAbsDiff" to meanAbsDiff,
            "proofBoundary" to PROOF_BOUNDARY,
        )
    }

    private fun failMap(
        reason: String,
        sourceMode: String,
        sourcePath: String,
        generatedSourcePath: String?,
        generatedSourceSize: Long,
        sourceRotationDegrees: Int = 0,
        sourceMetadataRotationDegrees: Int = 0,
        prodPath: String,
        glesPath: String,
    ): Map<String, Any?> {
        return finishResult(
            pass = false,
            reason = reason,
            sourceMode = sourceMode,
            sourcePath = sourcePath,
            generatedSourcePath = generatedSourcePath,
            generatedSourceSize = generatedSourceSize,
            sourceRotationDegrees = sourceRotationDegrees,
            sourceMetadataRotationDegrees = sourceMetadataRotationDegrees,
            prodPass = false,
            glesPass = false,
            pixelPass = false,
            prodPath = prodPath,
            glesPath = glesPath,
            prodSize = 0L,
            glesSize = 0L,
            prodSidecarPath = "",
            prodSidecarExists = false,
            prodErrorCode = null,
            prodErrorMessage = null,
            prodProgressSamples = emptyList(),
            glesProgressSamples = emptyList(),
            prodMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
            glesMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
            meanAbsDiff = -1.0,
        )
    }
}
