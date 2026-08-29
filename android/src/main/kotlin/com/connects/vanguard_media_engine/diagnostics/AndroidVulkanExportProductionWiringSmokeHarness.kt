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
import kotlin.math.min

object AndroidVulkanExportProductionWiringSmokeHarness {
    private const val TAG = "VanguardVulkanExportWiring"
    private const val PROOF_BOUNDARY_GLES_PARITY = "production_exportTimeline_vulkan_vs_direct_gles_pixel_parity"
    private const val PROOF_BOUNDARY_ROTATION_REGION = "production_exportTimeline_vulkan_rotation_region_oracle"
    private const val PROOF_BOUNDARY_FIT_REGION = "production_exportTimeline_vulkan_fit_region_oracle"
    private const val PROOF_BOUNDARY_MULTICLIP_FIT_ROTATION = "production_exportTimeline_vulkan_multiclip_fit_rotation_oracle"

    data class ExpectedFitRect(val x: Int, val y: Int, val width: Int, val height: Int) {
        fun toMap(): Map<String, Int> = mapOf("x" to x, "y" to y, "width" to width, "height" to height)
    }

    private data class FitRegionEvaluation(
        val fitRegionOraclePass: Boolean,
        val blackBarOraclePass: Boolean,
        val nonBlank: Boolean,
        val meanRgb: RgbTriple,
        val sampledRegions: Map<String, Any?>,
        val failureReason: String?,
    )

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
        scenarioMode: String = "single_clip",
    ): Map<String, Any?> {
        if (scenarioMode == "multi_clip_fit_rotation") {
            return runMultiClipFitRotation(
                context = context,
                outputDir = outputDir,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                fps = fps,
                bitrateBps = bitrateBps,
                oracleMode = oracleMode,
            )
        }

        val outDirFile = File(outputDir)
        val sourceMode = if (useSyntheticSource) "synthetic" else "provided"

        val computedExpectedFitRect = computeExpectedFitRect(
            outputWidth = outputWidth,
            outputHeight = outputHeight,
            sourceWidth = width,
            sourceHeight = height,
            rotationDegrees = sourceRotationDegrees,
        )
        val expectedFitRectMap = computedExpectedFitRect?.toMap() ?: emptyMap()

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
                expectedFitRect = expectedFitRectMap,
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
                expectedFitRect = expectedFitRectMap,
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
                    expectedFitRect = expectedFitRectMap,
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
                    expectedFitRect = expectedFitRectMap,
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
                    expectedFitRect = expectedFitRectMap,
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
                expectedFitRect = expectedFitRectMap,
            )
        }

        val prodOutputPath = File(outDirFile, "vulkan_production_wiring_${timestamp}_production.mp4").absolutePath
        val glesOutputPath = if (oracleMode == "rotation_region" || oracleMode == "fit_region") "" else File(outDirFile, "vulkan_production_wiring_${timestamp}_gles_baseline.mp4").absolutePath
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
        var fitRegionOraclePass = false
        var blackBarOraclePass = false
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
                    fitRegionOraclePass = fitRegionOraclePass,
                    blackBarOraclePass = blackBarOraclePass,
                    expectedFitRect = expectedFitRectMap,
                    prodOutputWidth = prodOutputWidth,
                    prodOutputHeight = prodOutputHeight,
                    sampledRegions = sampledRegions,
                )
            }

            // ── Lane B: Direct GLES baseline ────────────────────────────────
            if (oracleMode != "rotation_region" && oracleMode != "fit_region") {
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
                        fitRegionOraclePass = false,
                        blackBarOraclePass = false,
                        expectedFitRect = expectedFitRectMap,
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
            } else if (oracleMode == "fit_region") {
                val eval = evaluateFitRegionOracle(
                    bitmap = prodBitmap,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
                    fitRect = computedExpectedFitRect ?: ExpectedFitRect(0, 0, outputWidth, outputHeight),
                    rotationDegrees = sourceRotationDegrees,
                )
                prodMeanRgb = mapOf("r" to eval.meanRgb.r, "g" to eval.meanRgb.g, "b" to eval.meanRgb.b)
                fitRegionOraclePass = eval.fitRegionOraclePass
                blackBarOraclePass = eval.blackBarOraclePass
                sampledRegions = eval.sampledRegions

                val dimensionsMatch = (prodOutputWidth == outputWidth && prodOutputHeight == outputHeight)
                if (computedExpectedFitRect == null) {
                    failureReason = "expected_fit_rect_computation_failed"
                } else if (!dimensionsMatch) {
                    failureReason = "production_output_dimensions_mismatch:expected=${outputWidth}x${outputHeight}:actual=${prodOutputWidth}x${prodOutputHeight}"
                } else if (eval.failureReason != null) {
                    failureReason = eval.failureReason
                } else {
                    pixelPass = true
                }
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

            val overallPass = when (oracleMode) {
                "fit_region" -> prodPass && pixelPass && fitRegionOraclePass && blackBarOraclePass
                "rotation_region" -> prodPass && pixelPass && rotationRegionOraclePass
                else -> prodPass && glesPass && pixelPass
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
                fitRegionOraclePass = fitRegionOraclePass,
                blackBarOraclePass = blackBarOraclePass,
                expectedFitRect = expectedFitRectMap,
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
                glesBaselineSkipped = (oracleMode == "rotation_region" || oracleMode == "fit_region"),
                rotationRegionOraclePass = false,
                fitRegionOraclePass = false,
                blackBarOraclePass = false,
                expectedFitRect = expectedFitRectMap,
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
        return samplePixelRectMeanRgb(bitmap, startX, endX, startY, endY)
    }

    private fun samplePixelRectMeanRgb(
        bitmap: Bitmap,
        startX: Int,
        endX: Int,
        startY: Int,
        endY: Int,
    ): RgbTriple {
        val w = bitmap.width
        val h = bitmap.height
        val clX0 = startX.coerceIn(0, w - 1)
        val clX1 = endX.coerceIn(clX0 + 1, w)
        val clY0 = startY.coerceIn(0, h - 1)
        val clY1 = endY.coerceIn(clY0 + 1, h)

        val stepX = max(1, (clX1 - clX0) / 16)
        val stepY = max(1, (clY1 - clY0) / 16)

        var totalR = 0.0
        var totalG = 0.0
        var totalB = 0.0
        var count = 0L

        var y = clY0
        while (y < clY1) {
            var x = clX0
            while (x < clX1) {
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

    private fun computeExpectedFitRect(
        outputWidth: Int,
        outputHeight: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        rotationDegrees: Int,
    ): ExpectedFitRect? {
        if (outputWidth <= 0 || outputHeight <= 0 || sourceWidth <= 0 || sourceHeight <= 0) {
            return null
        }
        val (displayWidth, displayHeight) = when (rotationDegrees) {
            0, 180 -> sourceWidth to sourceHeight
            90, 270 -> sourceHeight to sourceWidth
            else -> return null
        }

        val scale = min(
            outputWidth.toDouble() / displayWidth.toDouble(),
            outputHeight.toDouble() / displayHeight.toDouble(),
        )
        var fitWidth = Math.round(displayWidth * scale).toInt().coerceIn(1, outputWidth)
        var fitHeight = Math.round(displayHeight * scale).toInt().coerceIn(1, outputHeight)
        fitWidth = forceEvenWherePossible(fitWidth, outputWidth)
        fitHeight = forceEvenWherePossible(fitHeight, outputHeight)

        val fitX = (outputWidth - fitWidth) / 2
        val fitY = (outputHeight - fitHeight) / 2
        if (fitX < 0 || fitY < 0 || fitX + fitWidth > outputWidth || fitY + fitHeight > outputHeight) {
            return null
        }
        return ExpectedFitRect(fitX, fitY, fitWidth, fitHeight)
    }

    private fun forceEvenWherePossible(value: Int, maxValue: Int): Int {
        if (value % 2 == 0) return value
        val decremented = value - 1
        if (decremented >= 1) return decremented
        val incremented = value + 1
        return if (incremented <= maxValue) incremented else value
    }

    private fun evaluateFitRegionOracle(
        bitmap: Bitmap,
        outputWidth: Int,
        outputHeight: Int,
        fitRect: ExpectedFitRect,
        rotationDegrees: Int,
    ): FitRegionEvaluation {
        val pRgb = computeMeanRgb(bitmap)
        val avg = (pRgb.r + pRgb.g + pRgb.b) / 3.0
        val nonBlank = avg in 3.0..252.0

        val fitX = fitRect.x
        val fitY = fitRect.y
        val fitW = fitRect.width
        val fitH = fitRect.height

        val tlStartX = fitX + (fitW * 0.15f).toInt()
        val tlEndX = fitX + (fitW * 0.35f).toInt()
        val tlStartY = fitY + (fitH * 0.15f).toInt()
        val tlEndY = fitY + (fitH * 0.35f).toInt()
        val tlRgb = samplePixelRectMeanRgb(bitmap, tlStartX, tlEndX, tlStartY, tlEndY)

        val trStartX = fitX + (fitW * 0.65f).toInt()
        val trEndX = fitX + (fitW * 0.85f).toInt()
        val trStartY = fitY + (fitH * 0.15f).toInt()
        val trEndY = fitY + (fitH * 0.35f).toInt()
        val trRgb = samplePixelRectMeanRgb(bitmap, trStartX, trEndX, trStartY, trEndY)

        val blStartX = fitX + (fitW * 0.15f).toInt()
        val blEndX = fitX + (fitW * 0.35f).toInt()
        val blStartY = fitY + (fitH * 0.65f).toInt()
        val blEndY = fitY + (fitH * 0.85f).toInt()
        val blRgb = samplePixelRectMeanRgb(bitmap, blStartX, blEndX, blStartY, blEndY)

        val brStartX = fitX + (fitW * 0.65f).toInt()
        val brEndX = fitX + (fitW * 0.85f).toInt()
        val brStartY = fitY + (fitH * 0.65f).toInt()
        val brEndY = fitY + (fitH * 0.85f).toInt()
        val brRgb = samplePixelRectMeanRgb(bitmap, brStartX, brEndX, brStartY, brEndY)

        val tlColor = classifyColor(tlRgb)
        val trColor = classifyColor(trRgb)
        val blColor = classifyColor(blRgb)
        val brColor = classifyColor(brRgb)

        val expected = expectedQuadrantColors(rotationDegrees)

        val matchTL = tlColor == expected["TL"]
        val matchTR = trColor == expected["TR"]
        val matchBL = blColor == expected["BL"]
        val matchBR = brColor == expected["BR"]
        val fitRegionOraclePass = matchTL && matchTR && matchBL && matchBR

        val regions = mutableMapOf<String, Any?>(
            "TL" to mapOf("r" to tlRgb.r, "g" to tlRgb.g, "b" to tlRgb.b, "classified" to tlColor, "expected" to expected["TL"]),
            "TR" to mapOf("r" to trRgb.r, "g" to trRgb.g, "b" to trRgb.b, "classified" to trColor, "expected" to expected["TR"]),
            "BL" to mapOf("r" to blRgb.r, "g" to blRgb.g, "b" to blRgb.b, "classified" to blColor, "expected" to expected["BL"]),
            "BR" to mapOf("r" to brRgb.r, "g" to brRgb.g, "b" to brRgb.b, "classified" to brColor, "expected" to expected["BR"]),
        )

        fun isBlack(rgb: RgbTriple): Boolean {
            val a = (rgb.r + rgb.g + rgb.b) / 3.0
            return rgb.r < 35.0 && rgb.g < 35.0 && rgb.b < 35.0 && a < 25.0
        }

        var barsPass = true

        // Left bar
        if (fitX > 0) {
            val startX = (fitX * 0.25f).toInt()
            val endX = (fitX * 0.75f).toInt().coerceAtLeast(startX + 1)
            val startY = (outputHeight * 0.25f).toInt()
            val endY = (outputHeight * 0.75f).toInt().coerceAtLeast(startY + 1)
            val rgb = samplePixelRectMeanRgb(bitmap, startX, endX, startY, endY)
            val pass = isBlack(rgb)
            if (!pass) barsPass = false
            regions["barLeft"] = mapOf("r" to rgb.r, "g" to rgb.g, "b" to rgb.b, "isBlack" to pass)
        }

        // Right bar
        if (fitX + fitW < outputWidth) {
            val barWidth = outputWidth - (fitX + fitW)
            val startX = ((fitX + fitW) + barWidth * 0.25f).toInt()
            val endX = ((fitX + fitW) + barWidth * 0.75f).toInt().coerceAtLeast(startX + 1)
            val startY = (outputHeight * 0.25f).toInt()
            val endY = (outputHeight * 0.75f).toInt().coerceAtLeast(startY + 1)
            val rgb = samplePixelRectMeanRgb(bitmap, startX, endX, startY, endY)
            val pass = isBlack(rgb)
            if (!pass) barsPass = false
            regions["barRight"] = mapOf("r" to rgb.r, "g" to rgb.g, "b" to rgb.b, "isBlack" to pass)
        }

        // Top bar
        if (fitY > 0) {
            val startX = (outputWidth * 0.25f).toInt()
            val endX = (outputWidth * 0.75f).toInt().coerceAtLeast(startX + 1)
            val startY = (fitY * 0.25f).toInt()
            val endY = (fitY * 0.75f).toInt().coerceAtLeast(startY + 1)
            val rgb = samplePixelRectMeanRgb(bitmap, startX, endX, startY, endY)
            val pass = isBlack(rgb)
            if (!pass) barsPass = false
            regions["barTop"] = mapOf("r" to rgb.r, "g" to rgb.g, "b" to rgb.b, "isBlack" to pass)
        }

        // Bottom bar
        if (fitY + fitH < outputHeight) {
            val barHeight = outputHeight - (fitY + fitH)
            val startX = (outputWidth * 0.25f).toInt()
            val endX = (outputWidth * 0.75f).toInt().coerceAtLeast(startX + 1)
            val startY = ((fitY + fitH) + barHeight * 0.25f).toInt()
            val endY = ((fitY + fitH) + barHeight * 0.75f).toInt().coerceAtLeast(startY + 1)
            val rgb = samplePixelRectMeanRgb(bitmap, startX, endX, startY, endY)
            val pass = isBlack(rgb)
            if (!pass) barsPass = false
            regions["barBottom"] = mapOf("r" to rgb.r, "g" to rgb.g, "b" to rgb.b, "isBlack" to pass)
        }

        val failureReason = when {
            !nonBlank -> "pixel_production_blank_sentinel: avg=$avg"
            !barsPass -> "black_bar_oracle_mismatch:barsPass=false"
            !fitRegionOraclePass -> "fit_region_oracle_mismatch:expected=$expected:actual=TL:$tlColor,TR:$trColor,BL:$blColor,BR:$brColor"
            else -> null
        }

        return FitRegionEvaluation(
            fitRegionOraclePass = fitRegionOraclePass,
            blackBarOraclePass = barsPass,
            nonBlank = nonBlank,
            meanRgb = pRgb,
            sampledRegions = regions,
            failureReason = failureReason,
        )
    }

    private fun readVideoDurationSeconds(videoPath: String): Double? {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(videoPath)
            val durStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            val durMs = durStr?.toLongOrNull()
            if (durMs != null && durMs > 0) durMs / 1000.0 else null
        } catch (t: Throwable) {
            Log.w(TAG, "readVideoDurationSeconds: MediaMetadataRetriever failed for $videoPath: $t")
            null
        } finally {
            try { mmr.release() } catch (_: Throwable) {}
        }
    }

    private fun runMultiClipFitRotation(
        context: Context,
        outputDir: String,
        outputWidth: Int,
        outputHeight: Int,
        fps: Int,
        bitrateBps: Int,
        oracleMode: String,
    ): Map<String, Any?> {
        val outDirFile = File(outputDir)
        if (!outDirFile.exists() || !outDirFile.isDirectory) {
            return failMap(
                reason = "output_dir_missing_or_not_directory: $outputDir",
                sourceMode = "synthetic",
                sourcePath = "",
                generatedSourcePath = null,
                generatedSourceSize = 0L,
                sourceRotationDegrees = 0,
                prodPath = "",
                glesPath = "",
                oracleMode = oracleMode,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                scenarioMode = "multi_clip_fit_rotation",
            )
        }

        val timestamp = System.currentTimeMillis()
        val genPathA = File(outDirFile, "vulkan_multiclip_${timestamp}_clip_a_synthetic.mp4").absolutePath
        val genPathB = File(outDirFile, "vulkan_multiclip_${timestamp}_clip_b_synthetic.mp4").absolutePath
        var genASize = 0L
        var genBSize = 0L

        val prodOutputPath = File(outDirFile, "vulkan_multiclip_${timestamp}_production.mp4").absolutePath
        val prodSidecarPath = AndroidTimelineRoiSidecarEmitter.sidecarPathForVideoPath(prodOutputPath)

        var prodPass = false
        var pixelPass = false
        var multiClipFitRegionOraclePass = false
        var failureReason: String? = null

        var prodOutputSize = 0L
        var prodSidecarExists = false
        var prodErrorCode: String? = null
        var prodErrorMessage: String? = null

        val prodProgressSamples = Collections.synchronizedList(mutableListOf<Double>())
        var prodOutputWidth = 0
        var prodOutputHeight = 0
        var outputDurationSeconds = 0.0
        var clipResults: List<Map<String, Any?>> = emptyList()
        var sampledRegionsCombined: Map<String, Any?> = emptyMap()

        try {
            // Step 1: Generate synthetic source A (640x640, rot 0, duration 1.0s)
            val genSuccessA = generateSyntheticSourceVideo(
                outputPath = genPathA,
                width = 640,
                height = 640,
                fps = fps,
                bitrateBps = bitrateBps,
                trimEndSeconds = 1.0,
                sourceRotationDegrees = 0,
            )
            val fileA = File(genPathA)
            if (!genSuccessA || !fileA.exists() || fileA.length() <= 0L) {
                return failMap(
                    reason = "synthetic_source_generation_failed_clip_A",
                    sourceMode = "synthetic",
                    sourcePath = genPathA,
                    generatedSourcePath = genPathA,
                    generatedSourceSize = 0L,
                    sourceRotationDegrees = 0,
                    prodPath = "",
                    glesPath = "",
                    oracleMode = oracleMode,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
                    scenarioMode = "multi_clip_fit_rotation",
                    generatedSourcePaths = listOf(genPathA),
                    generatedSourceSizes = listOf(0L),
                )
            }
            genASize = fileA.length()

            // Step 2: Generate synthetic source B (640x360, rot 90, duration 1.0s)
            val genSuccessB = generateSyntheticSourceVideo(
                outputPath = genPathB,
                width = 640,
                height = 360,
                fps = fps,
                bitrateBps = bitrateBps,
                trimEndSeconds = 1.0,
                sourceRotationDegrees = 90,
            )
            val fileB = File(genPathB)
            if (!genSuccessB || !fileB.exists() || fileB.length() <= 0L) {
                return failMap(
                    reason = "synthetic_source_generation_failed_clip_B",
                    sourceMode = "synthetic",
                    sourcePath = genPathB,
                    generatedSourcePath = genPathB,
                    generatedSourceSize = 0L,
                    sourceRotationDegrees = 90,
                    prodPath = "",
                    glesPath = "",
                    oracleMode = oracleMode,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
                    scenarioMode = "multi_clip_fit_rotation",
                    generatedSourcePaths = listOf(genPathA, genPathB),
                    generatedSourceSizes = listOf(genASize, 0L),
                )
            }
            genBSize = fileB.length()

            // Step 3: Run production AndroidTimelineExportSession
            val session = AndroidTimelineExportSession(context)
            val latch = CountDownLatch(1)
            var sessionSuccessMap: Map<String, Any?>? = null

            val draftClipA = mapOf(
                "id" to "vulkan_multiclip_clip_A",
                "sourcePath" to genPathA,
                "mediaKind" to "video",
                "durationSeconds" to 1.0,
                "trimStartSeconds" to 0.0,
                "trimEndSeconds" to 1.0,
                "startTimeSeconds" to 0.0,
                "speed" to 1.0,
            )
            val draftClipB = mapOf(
                "id" to "vulkan_multiclip_clip_B",
                "sourcePath" to genPathB,
                "mediaKind" to "video",
                "durationSeconds" to 1.0,
                "trimStartSeconds" to 0.0,
                "trimEndSeconds" to 1.0,
                "startTimeSeconds" to 1.0,
                "speed" to 1.0,
            )
            val draftMap = mapOf(
                "id" to "vulkan_multiclip_draft",
                "clips" to listOf(draftClipA, draftClipB),
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
                    sourceMode = "synthetic",
                    sourcePath = "$genPathA,$genPathB",
                    generatedSourcePath = genPathA,
                    generatedSourceSize = genASize + genBSize,
                    sourceRotationDegrees = 0,
                    sourceMetadataRotationDegrees = 0,
                    prodPass = prodPass,
                    glesPass = true,
                    pixelPass = pixelPass,
                    prodPath = prodOutputPath,
                    glesPath = "",
                    prodSize = prodOutputSize,
                    glesSize = 0L,
                    prodSidecarPath = prodSidecarPath,
                    prodSidecarExists = prodSidecarExists,
                    prodErrorCode = prodErrorCode,
                    prodErrorMessage = prodErrorMessage,
                    prodProgressSamples = prodProgressSamples,
                    glesProgressSamples = emptyList(),
                    prodMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
                    glesMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
                    meanAbsDiff = -1.0,
                    oracleMode = oracleMode,
                    glesBaselineSkipped = true,
                    rotationRegionOraclePass = false,
                    fitRegionOraclePass = false,
                    blackBarOraclePass = false,
                    expectedFitRect = emptyMap(),
                    prodOutputWidth = prodOutputWidth,
                    prodOutputHeight = prodOutputHeight,
                    sampledRegions = emptyMap(),
                    scenarioMode = "multi_clip_fit_rotation",
                    multiClipFitRegionOraclePass = false,
                    clipResults = emptyList(),
                    generatedSourcePaths = listOf(genPathA, genPathB),
                    generatedSourceSizes = listOf(genASize, genBSize),
                    outputDurationSeconds = 0.0,
                )
            }

            // Step 4: Validate output dimensions and duration
            val prodDimensions = readVideoDimensions(prodOutputPath)
            prodOutputWidth = prodDimensions?.first ?: 0
            prodOutputHeight = prodDimensions?.second ?: 0
            val dimensionsMatch = (prodOutputWidth == outputWidth && prodOutputHeight == outputHeight)

            val measuredDuration = readVideoDurationSeconds(prodOutputPath)
                ?: (sessionSuccessMap?.get("durationSeconds") as? Number)?.toDouble()
                ?: 0.0
            outputDurationSeconds = measuredDuration
            val durationValid = abs(outputDurationSeconds - 2.0) <= 0.15

            // Step 5: Extract frame A (~500,000us) and frame B (~1,500,000us)
            val bitmapA = extractFrame(prodOutputPath, 500_000L)
            val bitmapB = extractFrame(prodOutputPath, 1_500_000L)

            val expectedFitRectA = computeExpectedFitRect(
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                sourceWidth = 640,
                sourceHeight = 640,
                rotationDegrees = 0,
            )
            val expectedFitRectB = computeExpectedFitRect(
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                sourceWidth = 640,
                sourceHeight = 360,
                rotationDegrees = 90,
            )

            if (bitmapA == null) {
                failureReason = "pixel_extraction_failed_clip_A"
            } else if (bitmapB == null) {
                failureReason = "pixel_extraction_failed_clip_B"
            } else if (expectedFitRectA == null || expectedFitRectB == null) {
                failureReason = "expected_fit_rect_computation_failed"
            } else {
                val evalA = evaluateFitRegionOracle(
                    bitmap = bitmapA,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
                    fitRect = expectedFitRectA,
                    rotationDegrees = 0,
                )
                val evalB = evaluateFitRegionOracle(
                    bitmap = bitmapB,
                    outputWidth = outputWidth,
                    outputHeight = outputHeight,
                    fitRect = expectedFitRectB,
                    rotationDegrees = 90,
                )

                val clipAData = mapOf(
                    "clipIndex" to 0,
                    "clipId" to "clip_A_640x640_rot0",
                    "sourcePath" to genPathA,
                    "sourceWidth" to 640,
                    "sourceHeight" to 640,
                    "sourceRotationDegrees" to 0,
                    "sampleTimeUs" to 500_000L,
                    "expectedFitRect" to expectedFitRectA.toMap(),
                    "fitRegionOraclePass" to evalA.fitRegionOraclePass,
                    "blackBarOraclePass" to evalA.blackBarOraclePass,
                    "nonBlank" to evalA.nonBlank,
                    "meanRgb" to mapOf("r" to evalA.meanRgb.r, "g" to evalA.meanRgb.g, "b" to evalA.meanRgb.b),
                    "sampledRegions" to evalA.sampledRegions,
                )

                val clipBData = mapOf(
                    "clipIndex" to 1,
                    "clipId" to "clip_B_640x360_rot90",
                    "sourcePath" to genPathB,
                    "sourceWidth" to 640,
                    "sourceHeight" to 360,
                    "sourceRotationDegrees" to 90,
                    "sampleTimeUs" to 1_500_000L,
                    "expectedFitRect" to expectedFitRectB.toMap(),
                    "fitRegionOraclePass" to evalB.fitRegionOraclePass,
                    "blackBarOraclePass" to evalB.blackBarOraclePass,
                    "nonBlank" to evalB.nonBlank,
                    "meanRgb" to mapOf("r" to evalB.meanRgb.r, "g" to evalB.meanRgb.g, "b" to evalB.meanRgb.b),
                    "sampledRegions" to evalB.sampledRegions,
                )

                clipResults = listOf(clipAData, clipBData)
                sampledRegionsCombined = mapOf(
                    "clipA" to evalA.sampledRegions,
                    "clipB" to evalB.sampledRegions,
                )

                multiClipFitRegionOraclePass = evalA.fitRegionOraclePass && evalA.blackBarOraclePass &&
                    evalB.fitRegionOraclePass && evalB.blackBarOraclePass

                if (!dimensionsMatch) {
                    failureReason = "production_output_dimensions_mismatch:expected=${outputWidth}x${outputHeight}:actual=${prodOutputWidth}x${prodOutputHeight}"
                } else if (!durationValid) {
                    failureReason = "production_output_duration_mismatch:expected=2.0s(+/-0.15s):actual=${outputDurationSeconds}s"
                } else if (!evalA.nonBlank) {
                    failureReason = "pixel_production_blank_clip_A: ${evalA.failureReason}"
                } else if (!evalB.nonBlank) {
                    failureReason = "pixel_production_blank_clip_B: ${evalB.failureReason}"
                } else if (!evalA.blackBarOraclePass) {
                    failureReason = "black_bar_oracle_mismatch_clip_A: ${evalA.failureReason}"
                } else if (!evalB.blackBarOraclePass) {
                    failureReason = "black_bar_oracle_mismatch_clip_B: ${evalB.failureReason}"
                } else if (!evalA.fitRegionOraclePass) {
                    failureReason = "fit_region_oracle_mismatch_clip_A: ${evalA.failureReason}"
                } else if (!evalB.fitRegionOraclePass) {
                    failureReason = "fit_region_oracle_mismatch_clip_B: ${evalB.failureReason}"
                } else {
                    pixelPass = true
                }
            }

            val overallPass = prodPass && pixelPass && multiClipFitRegionOraclePass
            val meanRgbA = (clipResults.getOrNull(0)?.get("meanRgb") as? Map<String, Double>) ?: mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0)

            return finishResult(
                pass = overallPass,
                reason = if (overallPass) "pass" else (failureReason ?: "pixel_lane_failed"),
                sourceMode = "synthetic",
                sourcePath = "$genPathA,$genPathB",
                generatedSourcePath = genPathA,
                generatedSourceSize = genASize + genBSize,
                sourceRotationDegrees = 0,
                sourceMetadataRotationDegrees = 0,
                prodPass = prodPass,
                glesPass = true,
                pixelPass = pixelPass,
                prodPath = prodOutputPath,
                glesPath = "",
                prodSize = prodOutputSize,
                glesSize = 0L,
                prodSidecarPath = prodSidecarPath,
                prodSidecarExists = prodSidecarExists,
                prodErrorCode = prodErrorCode,
                prodErrorMessage = prodErrorMessage,
                prodProgressSamples = prodProgressSamples,
                glesProgressSamples = emptyList(),
                prodMeanRgb = meanRgbA,
                glesMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
                meanAbsDiff = -1.0,
                oracleMode = oracleMode,
                glesBaselineSkipped = true,
                rotationRegionOraclePass = false,
                fitRegionOraclePass = multiClipFitRegionOraclePass,
                blackBarOraclePass = multiClipFitRegionOraclePass,
                expectedFitRect = expectedFitRectA?.toMap() ?: emptyMap(),
                prodOutputWidth = prodOutputWidth,
                prodOutputHeight = prodOutputHeight,
                sampledRegions = sampledRegionsCombined,
                scenarioMode = "multi_clip_fit_rotation",
                multiClipFitRegionOraclePass = multiClipFitRegionOraclePass,
                clipResults = clipResults,
                generatedSourcePaths = listOf(genPathA, genPathB),
                generatedSourceSizes = listOf(genASize, genBSize),
                outputDurationSeconds = outputDurationSeconds,
            )
        } catch (t: Throwable) {
            val exReason = "exception: ${t.javaClass.simpleName}: ${t.message}"
            Log.e(TAG, "AndroidVulkanExportProductionWiringSmokeHarness multiclip uncaught exception", t)
            return finishResult(
                pass = false,
                reason = exReason,
                sourceMode = "synthetic",
                sourcePath = "$genPathA,$genPathB",
                generatedSourcePath = genPathA,
                generatedSourceSize = genASize + genBSize,
                sourceRotationDegrees = 0,
                sourceMetadataRotationDegrees = 0,
                prodPass = prodPass,
                glesPass = true,
                pixelPass = pixelPass,
                prodPath = prodOutputPath,
                glesPath = "",
                prodSize = prodOutputSize,
                glesSize = 0L,
                prodSidecarPath = prodSidecarPath,
                prodSidecarExists = prodSidecarExists,
                prodErrorCode = prodErrorCode,
                prodErrorMessage = prodErrorMessage,
                prodProgressSamples = prodProgressSamples,
                glesProgressSamples = emptyList(),
                prodMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
                glesMeanRgb = mapOf("r" to 0.0, "g" to 0.0, "b" to 0.0),
                meanAbsDiff = -1.0,
                oracleMode = oracleMode,
                glesBaselineSkipped = true,
                rotationRegionOraclePass = false,
                fitRegionOraclePass = false,
                blackBarOraclePass = false,
                expectedFitRect = emptyMap(),
                prodOutputWidth = prodOutputWidth,
                prodOutputHeight = prodOutputHeight,
                sampledRegions = sampledRegionsCombined,
                scenarioMode = "multi_clip_fit_rotation",
                multiClipFitRegionOraclePass = false,
                clipResults = clipResults,
                generatedSourcePaths = listOf(genPathA, genPathB),
                generatedSourceSizes = listOf(genASize, genBSize),
                outputDurationSeconds = outputDurationSeconds,
            )
        } finally {
            try { File(genPathA).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            try { File(genPathB).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
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
        fitRegionOraclePass: Boolean = false,
        blackBarOraclePass: Boolean = false,
        expectedFitRect: Map<String, Int> = emptyMap(),
        prodOutputWidth: Int = 0,
        prodOutputHeight: Int = 0,
        sampledRegions: Map<String, Any?> = emptyMap(),
        scenarioMode: String = "single_clip",
        multiClipFitRegionOraclePass: Boolean = false,
        clipResults: List<Map<String, Any?>> = emptyList(),
        generatedSourcePaths: List<String> = if (generatedSourcePath != null) listOf(generatedSourcePath) else emptyList(),
        generatedSourceSizes: List<Long> = if (generatedSourceSize > 0) listOf(generatedSourceSize) else emptyList(),
        outputDurationSeconds: Double = 0.0,
    ): Map<String, Any?> {
        val proofBoundary = when {
            scenarioMode == "multi_clip_fit_rotation" -> PROOF_BOUNDARY_MULTICLIP_FIT_ROTATION
            oracleMode == "fit_region" -> PROOF_BOUNDARY_FIT_REGION
            oracleMode == "rotation_region" -> PROOF_BOUNDARY_ROTATION_REGION
            else -> PROOF_BOUNDARY_GLES_PARITY
        }
        val statusStr = if (pass) "PASS" else "FAIL"
        Log.i(
            TAG,
            "ANDROID_VULKAN_EXPORT_PRODUCTION_WIRING_RESULT status=$statusStr;reason=$reason;scenarioMode=$scenarioMode;oracleMode=$oracleMode;sourceMode=$sourceMode;sourceRotationDegrees=$sourceRotationDegrees;sourceMetadataRotationDegrees=$sourceMetadataRotationDegrees;productionOutputWidth=$prodOutputWidth;productionOutputHeight=$prodOutputHeight;productionBytes=$prodSize;glesBytes=$glesSize;meanAbsDiff=$meanAbsDiff;rotationRegionOraclePass=$rotationRegionOraclePass;fitRegionOraclePass=$fitRegionOraclePass;blackBarOraclePass=$blackBarOraclePass;multiClipFitRegionOraclePass=$multiClipFitRegionOraclePass;expectedFitRect=$expectedFitRect",
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
            "scenarioMode" to scenarioMode,
            "sourceMode" to sourceMode,
            "sourcePath" to sourcePath,
            "generatedSourcePath" to generatedSourcePath,
            "generatedSourcePaths" to generatedSourcePaths,
            "generatedSourceSize" to generatedSourceSize,
            "generatedSourceSizes" to generatedSourceSizes,
            "sourceRotationDegrees" to sourceRotationDegrees,
            "sourceMetadataRotationDegrees" to sourceMetadataRotationDegrees,
            "productionPass" to prodPass,
            "glesPass" to glesPass,
            "pixelPass" to pixelPass,
            "multiClipFitRegionOraclePass" to multiClipFitRegionOraclePass,
            "clipResults" to clipResults,
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
            "fitRegionOraclePass" to fitRegionOraclePass,
            "blackBarOraclePass" to blackBarOraclePass,
            "expectedFitRect" to expectedFitRect,
            "productionOutputWidth" to prodOutputWidth,
            "productionOutputHeight" to prodOutputHeight,
            "sampledRegions" to sampledRegions,
            "outputDurationSeconds" to outputDurationSeconds,
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
        expectedFitRect: Map<String, Int> = emptyMap(),
        scenarioMode: String = "single_clip",
        generatedSourcePaths: List<String> = if (generatedSourcePath != null) listOf(generatedSourcePath) else emptyList(),
        generatedSourceSizes: List<Long> = if (generatedSourceSize > 0) listOf(generatedSourceSize) else emptyList(),
    ): Map<String, Any?> {
        return finishResult(
            pass = false,
            reason = reason,
            sourceMode = sourceMode,
            sourcePath = sourcePath,
            generatedSourcePath = generatedSourcePath,
            generatedSourcePaths = generatedSourcePaths,
            generatedSourceSize = generatedSourceSize,
            generatedSourceSizes = generatedSourceSizes,
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
            glesBaselineSkipped = (oracleMode == "rotation_region" || oracleMode == "fit_region" || scenarioMode == "multi_clip_fit_rotation"),
            rotationRegionOraclePass = false,
            fitRegionOraclePass = false,
            blackBarOraclePass = false,
            expectedFitRect = expectedFitRect,
            prodOutputWidth = outputWidth,
            prodOutputHeight = outputHeight,
            sampledRegions = emptyMap(),
            scenarioMode = scenarioMode,
            multiClipFitRegionOraclePass = false,
            clipResults = emptyList(),
            outputDurationSeconds = 0.0,
        )
    }
}
