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
    private const val PROOF_BOUNDARY_GLES_PARITY = "production_exportTimeline_vulkan_vs_direct_gles_pixel_parity"
    private const val PROOF_BOUNDARY_ROTATION_REGION = "production_exportTimeline_vulkan_rotation_region_oracle"

    fun run(
        context: Context,
        sourcePath: String? = null,
        outputDir: String,
        useSyntheticSource: Boolean = sourcePath.isNullOrBlank(),
        width: Int = 1280,
        height: Int = 720,
        outputWidth: Int = width,
        outputHeight: Int = height,
        fps: Int = 30,
        bitrateBps: Int = 4_000_000,
        trimEndSeconds: Double = 1.0,
        sourceRotationDegrees: Int = 0,
        oracleMode: String = "gles_pixel_parity",
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
                oracleMode = oracleMode,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
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
                oracleMode = oracleMode,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
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
                    oracleMode = oracleMode,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
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
                    oracleMode = oracleMode,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
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
                    oracleMode = oracleMode,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
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
                oracleMode = oracleMode,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
            )
        }

        val prodOutputPath = File(outDirFile, "vulkan_production_wiring_${timestamp}_production.mp4").absolutePath
        val glesOutputPath = if (oracleMode == "rotation_region") "" else File(outDirFile, "vulkan_production_wiring_${timestamp}_gles_baseline.mp4").absolutePath
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

        var glesBaselineSkipped = false
        var rotationRegionOraclePass = false
        var prodOutputWidth = 0
        var prodOutputHeight = 0
        var sampledRegions: Map<String, Any?> = emptyMap()

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
                    oracleMode = oracleMode,
                    glesBaselineSkipped = glesBaselineSkipped,
                    rotationRegionOraclePass = rotationRegionOraclePass,
                    prodOutputWidth = prodOutputWidth,
                    prodOutputHeight = prodOutputHeight,
                    sampledRegions = sampledRegions,
                )
            }

            // ── Lane B: Direct GLES baseline ────────────────────────────────
            if (oracleMode != "rotation_region") {
                val glesEncoder = AndroidTimelineVideoEncoder(
                    outputPath = glesOutputPath,
                    width = outputWidth,
                    height = outputHeight,
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
                        oracleMode = oracleMode,
                        glesBaselineSkipped = false,
                        rotationRegionOraclePass = false,
                        prodOutputWidth = prodOutputWidth,
                        prodOutputHeight = prodOutputHeight,
                        sampledRegions = sampledRegions,
                    )
                }
            } else {
                glesPass = true
                glesBaselineSkipped = true
            }

            // ── Lane C: Pixel sanity / parity / region oracle ───────────────
            val targetTimeUs = if (trimEndSeconds < 0.6) {
                (trimEndSeconds * 500_000.0).toLong().coerceAtLeast(0L)
            } else {
                500_000L
            }

            val prodBitmap = extractFrame(prodOutputPath, targetTimeUs)
            val prodDimensions = readVideoDimensions(prodOutputPath) ?: (prodBitmap?.let { it.width to it.height })
            prodOutputWidth = prodDimensions?.first ?: 0
            prodOutputHeight = prodDimensions?.second ?: 0

            if (prodBitmap == null) {
                failureReason = "pixel_extraction_failed_production"
            } else if (oracleMode == "rotation_region") {
                val pRgb = computeMeanRgb(prodBitmap)
                prodMeanRgb = mapOf("r" to pRgb.r, "g" to pRgb.g, "b" to pRgb.b)
                val prodAvg = (pRgb.r + pRgb.g + pRgb.b) / 3.0
                val prodNonBlank = prodAvg in 3.0..252.0

                val dimensionsMatch = (prodOutputWidth == outputWidth && prodOutputHeight == outputHeight)

                val tlRgb = sampleRegionMeanRgb(prodBitmap, 0.15f, 0.35f, 0.15f, 0.35f)
                val trRgb = sampleRegionMeanRgb(prodBitmap, 0.65f, 0.85f, 0.15f, 0.35f)
                val blRgb = sampleRegionMeanRgb(prodBitmap, 0.15f, 0.35f, 0.65f, 0.85f)
                val brRgb = sampleRegionMeanRgb(prodBitmap, 0.65f, 0.85f, 0.65f, 0.85f)

                val tlColor = classifyColor(tlRgb)
                val trColor = classifyColor(trRgb)
                val blColor = classifyColor(blRgb)
                val brColor = classifyColor(brRgb)

                val expected = expectedQuadrantColors(sourceRotationDegrees)

                sampledRegions = mapOf(
                    "TL" to mapOf("r" to tlRgb.r, "g" to tlRgb.g, "b" to tlRgb.b, "classified" to tlColor, "expected" to expected["TL"]),
                    "TR" to mapOf("r" to trRgb.r, "g" to trRgb.g, "b" to trRgb.b, "classified" to trColor, "expected" to expected["TR"]),
                    "BL" to mapOf("r" to blRgb.r, "g" to blRgb.g, "b" to blRgb.b, "classified" to blColor, "expected" to expected["BL"]),
                    "BR" to mapOf("r" to brRgb.r, "g" to brRgb.g, "b" to brRgb.b, "classified" to brColor, "expected" to expected["BR"]),
                )

                val matchTL = tlColor == expected["TL"]
                val matchTR = trColor == expected["TR"]
                val matchBL = blColor == expected["BL"]
                val matchBR = brColor == expected["BR"]
                rotationRegionOraclePass = matchTL && matchTR && matchBL && matchBR

                if (!dimensionsMatch) {
                    failureReason = "production_output_dimensions_mismatch:expected=${outputWidth}x${outputHeight}:actual=${prodOutputWidth}x${prodOutputHeight}"
                } else if (!prodNonBlank) {
                    failureReason = "pixel_production_blank_sentinel: avg=$prodAvg"
                } else if (!rotationRegionOraclePass) {
                    failureReason = "rotation_region_oracle_mismatch:expected=$expected:actual=TL:$tlColor,TR:$trColor,BL:$blColor,BR:$brColor"
                } else {
                    pixelPass = true
                }
            } else {
                val glesBitmap = extractFrame(glesOutputPath, targetTimeUs)
                if (glesBitmap == null) {
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
            }

            val overallPass = if (oracleMode == "rotation_region") {
                prodPass && pixelPass && rotationRegionOraclePass
            } else {
                prodPass && glesPass && pixelPass
            }

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
                oracleMode = oracleMode,
                glesBaselineSkipped = glesBaselineSkipped,
                rotationRegionOraclePass = rotationRegionOraclePass,
                prodOutputWidth = prodOutputWidth,
                prodOutputHeight = prodOutputHeight,
                sampledRegions = sampledRegions,
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
                oracleMode = oracleMode,
                glesBaselineSkipped = (oracleMode == "rotation_region"),
                rotationRegionOraclePass = false,
                prodOutputWidth = prodOutputWidth,
                prodOutputHeight = prodOutputHeight,
                sampledRegions = sampledRegions,
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

            val halfW = width / 2f
            val halfH = height / 2f
            val paintTL = Paint().apply { color = Color.rgb(220, 40, 40) }   // Red
            val paintTR = Paint().apply { color = Color.rgb(40, 200, 40) }  // Green
            val paintBL = Paint().apply { color = Color.rgb(40, 60, 220) }  // Blue
            val paintBR = Paint().apply { color = Color.rgb(230, 220, 40) } // Yellow

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

                canvas.drawRect(0f, 0f, halfW, halfH, paintTL)
                canvas.drawRect(halfW, 0f, width.toFloat(), halfH, paintTR)
                canvas.drawRect(0f, halfH, halfW, height.toFloat(), paintBL)
                canvas.drawRect(halfW, halfH, width.toFloat(), height.toFloat(), paintBR)

                val boxW = width / 6f
                val boxH = height / 6f
                val shiftX = if (framesToDraw > 1) (frameIdx.toFloat() / (framesToDraw - 1)) * (width - boxW) else 0f
                val boxY = (height - boxH) / 2f
                val boxPaint = Paint().apply { color = Color.rgb(240, 240, 240) }
                canvas.drawRect(shiftX, boxY, shiftX + boxW, boxY + boxH, boxPaint)

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

        val stepX = max(1, (endX - startX) / 16)
        val stepY = max(1, (endY - startY) / 16)

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

    private fun classifyColor(rgb: RgbTriple): String {
        val r = rgb.r
        val g = rgb.g
        val b = rgb.b
        return when {
            r > 130.0 && g > 120.0 && b < 100.0 && (r + g) > (2.0 * b + 80.0) -> "YELLOW"
            r > 130.0 && r > g + 40.0 && r > b + 40.0 -> "RED"
            g > 120.0 && g > r + 30.0 && g > b + 30.0 -> "GREEN"
            b > 130.0 && b > r + 30.0 && b > g + 30.0 -> "BLUE"
            else -> "UNKNOWN(r=${r.toInt()},g=${g.toInt()},b=${b.toInt()})"
        }
    }

    private fun expectedQuadrantColors(rotationDegrees: Int): Map<String, String> {
        return when (rotationDegrees) {
            90 -> mapOf("TL" to "BLUE", "TR" to "RED", "BL" to "YELLOW", "BR" to "GREEN")
            270 -> mapOf("TL" to "GREEN", "TR" to "YELLOW", "BL" to "RED", "BR" to "BLUE")
            180 -> mapOf("TL" to "YELLOW", "TR" to "BLUE", "BL" to "GREEN", "BR" to "RED")
            else -> mapOf("TL" to "RED", "TR" to "GREEN", "BL" to "BLUE", "BR" to "YELLOW")
        }
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
        oracleMode: String = "gles_pixel_parity",
        glesBaselineSkipped: Boolean = false,
        rotationRegionOraclePass: Boolean = false,
        prodOutputWidth: Int = 0,
        prodOutputHeight: Int = 0,
        sampledRegions: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> {
        val proofBoundary = when (oracleMode) {
            "rotation_region" -> PROOF_BOUNDARY_ROTATION_REGION
            else -> PROOF_BOUNDARY_GLES_PARITY
        }
        val statusStr = if (pass) "PASS" else "FAIL"
        Log.i(
            TAG,
            "ANDROID_VULKAN_EXPORT_PRODUCTION_WIRING_RESULT status=$statusStr;reason=$reason;oracleMode=$oracleMode;sourceMode=$sourceMode;sourceRotationDegrees=$sourceRotationDegrees;sourceMetadataRotationDegrees=$sourceMetadataRotationDegrees;productionOutputWidth=$prodOutputWidth;productionOutputHeight=$prodOutputHeight;productionBytes=$prodSize;glesBytes=$glesSize;meanAbsDiff=$meanAbsDiff;rotationRegionOraclePass=$rotationRegionOraclePass",
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
            "proofBoundary" to proofBoundary,
            "oracleMode" to oracleMode,
            "glesBaselineSkipped" to glesBaselineSkipped,
            "rotationRegionOraclePass" to rotationRegionOraclePass,
            "productionOutputWidth" to prodOutputWidth,
            "productionOutputHeight" to prodOutputHeight,
            "sampledRegions" to sampledRegions,
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
        oracleMode: String = "gles_pixel_parity",
        outputWidth: Int = 0,
        outputHeight: Int = 0,
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
            oracleMode = oracleMode,
            glesBaselineSkipped = (oracleMode == "rotation_region"),
            rotationRegionOraclePass = false,
            prodOutputWidth = outputWidth,
            prodOutputHeight = outputHeight,
            sampledRegions = emptyMap(),
        )
    }
}
