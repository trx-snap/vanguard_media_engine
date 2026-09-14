package com.connects.vanguard_media_engine.diagnostics

import android.graphics.Color
import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * ANDROID-DUET-VULKAN-GREENSCREEN-EXPORT-EXTERNAL-YCBCR-PIXEL-PROOF (diagnostic only).
 *
 * Physical proof that the EXISTING Android Vulkan export session
 * (android_vulkan_export_jni.cpp's VulkanExportSession registry) can sample real
 * hardware-decoded external-format/YCbCr frames, not only synthetic RGBA
 * HardwareBuffers, via the green-screen export entrypoints:
 * [VanguardNativeBridge.uploadAndroidTimelineVulkanExportMaskTextureR8] and
 * [VanguardNativeBridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame],
 * encoding to MediaCodec AVC encoder and asserting decoded center-pixel colors.
 *
 * Architecture:
 *   1. Generates two temporary deterministic MP4 fixtures at runtime using MediaCodec
 *      encoder input Surface: one background/source clip and one camera clip.
 *      Each clip has FRAME_COUNT=4 solid-color frames matching the background/camera
 *      color ladder. Deleted during cleanup.
 *   2. Decodes both temporary MP4 clips through hardware decoders into ImageReader.PRIVATE
 *      with HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE. Uses hardware decoder selection.
 *   3. For each frame index: acquires one decoded source Image and one decoded camera Image,
 *      awaits fences where available (API 33+), gets each image.hardwareBuffer, uploads
 *      the R8 mask via native bridge, renders through renderAndroidTimelineVulkanExportDuetGreenScreenFrame,
 *      then closes HardwareBuffers and Images after native returns. Uses no CPU bitmap/Canvas
 *      HardwareBuffer for the render inputs.
 *   4. Asserts decoded output center-pixel values against expected colors with PIXEL_TOLERANCE=64,
 *      asserts renderedFrames == writtenVideoSamples, asserts negative lanes, cleans up tmp artifacts.
 *
 * Never wires into AndroidDuetExportSession, AndroidDuetSessionCoordinator,
 * ConnectsApp, Universal Editor, or production Duet preview.
 */
object AndroidDuetVulkanGreenScreenExportExternalYcbcrPixelProofSmokeHarness {
    private const val TAG = "VanguardDuetExportYcbcrPixelProof"
    const val PROOF_BOUNDARY =
        "android_duet_vulkan_export_session_greenscreen_external_ycbcr_decoded_pixel_proof"

    private const val MASK_WIDTH = 63
    private const val MASK_HEIGHT = 63
    private val ALPHA_LADDER = intArrayOf(0, 255, 128, 64)

    // Smoothstep(0.52, 0.78, .) on a uniform mask maps every ladder value to
    // a hard 0 or 1: only alpha=255 shows the camera layer.
    private val EXPECTED_SHOWS_CAMERA = booleanArrayOf(false, true, false, false)

    private val BACKGROUND_COLORS = intArrayOf(
        Color.rgb(20, 40, 200),
        Color.rgb(200, 40, 20),
        Color.rgb(20, 200, 40),
        Color.rgb(200, 200, 20),
    )
    private val CAMERA_COLORS = intArrayOf(
        Color.rgb(120, 20, 120),
        Color.rgb(240, 130, 10),
        Color.rgb(120, 20, 120),
        Color.rgb(120, 20, 120),
    )

    private const val PIXEL_TOLERANCE = 64
    private const val MISMATCHED_MASK_HANDLE = 999_999_999L
    private const val FRAME_COUNT = 4

    private const val IMAGE_READER_MAX_IMAGES = 3
    private const val DEQUEUE_TIMEOUT_US = 10_000L
    private const val IMAGE_ACQUIRE_TIMEOUT_MS = 2_000L
    private const val MAX_NO_OUTPUT_ATTEMPTS = 400
    private const val FENCE_WAIT_MS = 1_000L

    fun runSmoke(
        outputPath: String,
        width: Int = 360,
        height: Int = 640,
        frameDurationUs: Long = 33333L,
        bitrate: Int = 1_500_000,
    ): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return failResult("api_below_29", width, height, 0, 0, outputPath, emptyMap())
        }
        if (width <= 0 || height <= 0 || frameDurationUs <= 0 || bitrate <= 0 || outputPath.isBlank()) {
            return failResult("invalid_args", width, height, 0, 0, outputPath, emptyMap())
        }

        val tmpPath = "$outputPath.tmp"
        val timestamp = System.currentTimeMillis()
        val bgFixturePath = "${outputPath}_bg_fixture_$timestamp.mp4"
        val camFixturePath = "${outputPath}_cam_fixture_$timestamp.mp4"

        var codec: MediaCodec? = null
        var encoderSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var sessionId: String? = null
        var nativeBridge: VanguardNativeBridge? = null
        var maskTextureHandle = 0L

        var bgPipeline: DecodePipeline? = null
        var camPipeline: DecodePipeline? = null

        var muxerStarted = false
        var videoTrackIndex = -1
        var writtenVideoSamples = 0
        var renderedFrames = 0
        var muxerStoppedCleanly = false
        var tmpPathResolved = false
        var frameRenderError: String? = null
        val negativeLanes = LinkedHashMap<String, Any?>()

        var bgBufferFormat = -1
        var camBufferFormat = -1

        try {
            // ── Phase 1: generate deterministic solid-color MP4 fixtures ──────
            val bgFixtureError = generateSolidColorFixtureVideo(
                bgFixturePath, width, height, BACKGROUND_COLORS, frameDurationUs, bitrate,
            )
            if (bgFixtureError != null) {
                return failResult("bg_fixture_generation_failed:$bgFixtureError", width, height, 0, 0, outputPath, negativeLanes)
            }

            val camFixtureError = generateSolidColorFixtureVideo(
                camFixturePath, width, height, CAMERA_COLORS, frameDurationUs, bitrate,
            )
            if (camFixtureError != null) {
                return failResult("cam_fixture_generation_failed:$camFixtureError", width, height, 0, 0, outputPath, negativeLanes)
            }

            // ── Phase 2: setup export MediaCodec encoder & Vulkan session ─────
            val fps = (1_000_000L / frameDurationUs).toInt().coerceAtLeast(1)
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }

            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = codec.createInputSurface()
            muxer = MediaMuxer(tmpPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            codec.start()

            val diagnostics = VanguardDiagnostics()
            nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )

            val createResult = nativeBridge.createAndroidTimelineVulkanExportSession(
                encoderSurface,
                width,
                height,
            )
            if (!createResult.startsWith("status=OK;")) {
                return failResult(
                    "session_create_failed;nativeResult=${createResult.take(80)}",
                    width, height, renderedFrames, writtenVideoSamples, outputPath, negativeLanes,
                )
            }
            sessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
            if (sessionId == null) {
                return failResult(
                    "session_id_parse_failed", width, height, renderedFrames, writtenVideoSamples,
                    outputPath, negativeLanes,
                )
            }

            // ── Negative lane 1: invalid mask stride (before any AHB import) ──
            run {
                val badStrideBuffer = buildMaskBuffer(0)
                val raw = nativeBridge.uploadAndroidTimelineVulkanExportMaskTextureR8(
                    sessionId, 0L, badStrideBuffer, MASK_WIDTH, MASK_HEIGHT, /*rowStrideBytes=*/10,
                )
                val pass = raw.startsWith("status=FAIL;") && raw.contains("reason=invalid_stride")
                negativeLanes["invalidMaskStride"] = mapOf("pass" to pass, "raw" to raw)
            }

            // ── Phase 3: prepare hardware decoders into ImageReader.PRIVATE ────
            val bp = DecodePipeline("background", bgFixturePath, width, height).also { bgPipeline = it }
            val bgPrepError = bp.prepare()
            if (bgPrepError != null) {
                return failResult("bg_decoder_prepare_failed:$bgPrepError", width, height, 0, 0, outputPath, negativeLanes)
            }

            val cp = DecodePipeline("camera", camFixturePath, width, height).also { camPipeline = it }
            val camPrepError = cp.prepare()
            if (camPrepError != null) {
                return failResult("cam_decoder_prepare_failed:$camPrepError", width, height, 0, 0, outputPath, negativeLanes)
            }

            val bufferInfo = MediaCodec.BufferInfo()
            val nonNullCodec = codec
            val nonNullMuxer = muxer

            fun drainOutput(endOfStream: Boolean, timeoutMs: Long) {
                val deadline = System.currentTimeMillis() + timeoutMs
                var draining = true
                while (draining && System.currentTimeMillis() <= deadline) {
                    val outIdx = nonNullCodec.dequeueOutputBuffer(bufferInfo, 10_000L)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (!endOfStream) draining = false
                        }
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (videoTrackIndex < 0) {
                                videoTrackIndex = nonNullMuxer.addTrack(nonNullCodec.outputFormat)
                                nonNullMuxer.start()
                                muxerStarted = true
                            }
                        }
                        outIdx >= 0 -> {
                            val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            if (!isConfig && bufferInfo.size > 0 && muxerStarted && videoTrackIndex >= 0) {
                                val encodedData = nonNullCodec.getOutputBuffer(outIdx)
                                if (encodedData != null) {
                                    encodedData.position(bufferInfo.offset)
                                    encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                    bufferInfo.presentationTimeUs = writtenVideoSamples * frameDurationUs
                                    nonNullMuxer.writeSampleData(videoTrackIndex, encodedData, bufferInfo)
                                    writtenVideoSamples++
                                }
                            }
                            nonNullCodec.releaseOutputBuffer(outIdx, false)
                            if (isEos) draining = false
                        }
                    }
                }
            }

            // ── Phase 4: decode external YCbCr frames and render green-screen ──
            for (frameIdx in 0 until FRAME_COUNT) {
                val bgOutcome = bp.nextFrame(FRAME_COUNT)
                val bgFrame = (bgOutcome as? StepOutcome.Frame)?.frame
                if (bgFrame == null) {
                    val detail = (bgOutcome as? StepOutcome.Failed)?.reason ?: "eos"
                    frameRenderError = "bg_next_frame_failed:frame=$frameIdx:$detail"
                    break
                }

                val camOutcome = cp.nextFrame(FRAME_COUNT)
                val camFrame = (camOutcome as? StepOutcome.Frame)?.frame
                if (camFrame == null) {
                    bp.releaseFrame(bgFrame)
                    val detail = (camOutcome as? StepOutcome.Failed)?.reason ?: "eos"
                    frameRenderError = "cam_next_frame_failed:frame=$frameIdx:$detail"
                    break
                }

                val bgHwb = bgFrame.image.hardwareBuffer
                val camHwb = camFrame.image.hardwareBuffer
                if (bgHwb == null || camHwb == null) {
                    try { bgHwb?.close() } catch (_: Throwable) {}
                    try { camHwb?.close() } catch (_: Throwable) {}
                    bp.releaseFrame(bgFrame)
                    cp.releaseFrame(camFrame)
                    frameRenderError = "hardware_buffer_null:frame=$frameIdx"
                    break
                }

                try {
                    if (frameIdx == 0) {
                        bgBufferFormat = bgHwb.format
                        camBufferFormat = camHwb.format

                        // Negative lane 2: mismatched (unregistered) mask handle.
                        val rawMismatched = nativeBridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame(
                            sessionId, bgHwb, camHwb,
                            width, height,
                            0, 0, width, height,
                            0, 0, width, height,
                            width, height, width, height,
                            MISMATCHED_MASK_HANDLE,
                            0, false, 0, false,
                            0, 0L, -1,
                        )
                        val passMismatched = rawMismatched.startsWith("status=FAIL;") &&
                            rawMismatched.contains("reason=mask_texture_unknown")
                        negativeLanes["mismatchedMaskHandle"] = mapOf("pass" to passMismatched, "raw" to rawMismatched)

                        // Negative lane 3: non-cardinal camera rotation.
                        val rawRotation = nativeBridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame(
                            sessionId, bgHwb, camHwb,
                            width, height,
                            0, 0, width, height,
                            0, 0, width, height,
                            width, height, width, height,
                            0L,
                            0, false, /*cameraRotationDegrees=*/45, false,
                            0, 0L, -1,
                        )
                        val passRotation = rawRotation.startsWith("status=FAIL;") &&
                            rawRotation.contains("reason=vulkan_rotation_unsupported:camera:45")
                        negativeLanes["nonCardinalRotation"] = mapOf("pass" to passRotation, "raw" to rawRotation)
                    }

                    val alpha = ALPHA_LADDER[frameIdx]
                    val maskBuffer = buildMaskBuffer(alpha)
                    val uploadRaw = if (frameIdx == 0) {
                        nativeBridge.uploadAndroidTimelineVulkanExportMaskTextureR8(
                            sessionId, 0L, maskBuffer, MASK_WIDTH, MASK_HEIGHT, 0,
                        )
                    } else {
                        nativeBridge.uploadAndroidTimelineVulkanExportMaskTextureR8(
                            sessionId, maskTextureHandle, maskBuffer, MASK_WIDTH, MASK_HEIGHT, 0,
                        )
                    }
                    if (!uploadRaw.startsWith("status=OK;")) {
                        frameRenderError = "mask_upload_failed:frame=$frameIdx:$uploadRaw"
                        break
                    }
                    if (frameIdx == 0) {
                        maskTextureHandle = uploadRaw.substringAfter("textureHandle=").substringBefore(";").toLongOrNull() ?: 0L
                        if (maskTextureHandle <= 0L) {
                            frameRenderError = "mask_handle_parse_failed:$uploadRaw"
                            break
                        }
                    }

                    val cameraRotation = if (frameIdx == 1) 90 else 0
                    val cameraMirror = frameIdx == 1

                    val renderRaw = nativeBridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame(
                        sessionId,
                        bgHwb,
                        camHwb,
                        width, height,
                        0, 0, width, height,
                        0, 0, width, height,
                        width, height, width, height,
                        maskTextureHandle,
                        0, false,
                        cameraRotation, cameraMirror,
                        0,
                        frameIdx * frameDurationUs,
                        frameIdx,
                    )

                    if (renderRaw.startsWith("status=OK;")) {
                        renderedFrames++
                    } else {
                        frameRenderError = "render_failed:frame=$frameIdx:$renderRaw"
                        break
                    }
                } finally {
                    // Close HardwareBuffers first, then Images.
                    try { bgHwb.close() } catch (_: Throwable) {}
                    try { camHwb.close() } catch (_: Throwable) {}
                    bp.releaseFrame(bgFrame)
                    cp.releaseFrame(camFrame)
                }

                drainOutput(endOfStream = false, timeoutMs = 200L)
            }

            if (renderedFrames == FRAME_COUNT && frameRenderError == null) {
                codec.signalEndOfInputStream()
                drainOutput(endOfStream = true, timeoutMs = 5000L)
            }

            if (muxerStarted && writtenVideoSamples > 0) {
                try {
                    muxer.stop()
                    muxerStoppedCleanly = true
                } catch (t: Throwable) {
                    Log.w(TAG, "MediaMuxer.stop failed: $t")
                }
            }

            val tmpFile = File(tmpPath)
            val outputSize = if (tmpFile.exists()) tmpFile.length() else 0L

            val mainRenderOk = renderedFrames == FRAME_COUNT &&
                writtenVideoSamples == FRAME_COUNT &&
                frameRenderError == null &&
                muxerStoppedCleanly &&
                tmpFile.exists() &&
                outputSize > 0L

            // ── Phase 5: decode produced MP4 and assert per-frame center pixel ──
            val perFramePixelResults = mutableListOf<Map<String, Any?>>()
            var decodeOk = false
            var interFrameVariationOk = false
            if (mainRenderOk) {
                val decodedColors = mutableListOf<IntArray?>()
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(tmpPath)
                    for (frameIdx in 0 until FRAME_COUNT) {
                        val timeUs = frameIdx * frameDurationUs + frameDurationUs / 2
                        val bitmap = try {
                            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                        } catch (t: Throwable) {
                            null
                        }
                        if (bitmap == null) {
                            perFramePixelResults.add(mapOf("frameIndex" to frameIdx, "pass" to false, "reason" to "decode_failed"))
                            decodedColors.add(null)
                            continue
                        }
                        val cx = (bitmap.width / 2).coerceIn(0, bitmap.width - 1)
                        val cy = (bitmap.height / 2).coerceIn(0, bitmap.height - 1)
                        val pixel = bitmap.getPixel(cx, cy)
                        val actual = intArrayOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel))
                        bitmap.recycle()
                        decodedColors.add(actual)

                        val expectedColor = if (EXPECTED_SHOWS_CAMERA[frameIdx]) CAMERA_COLORS[frameIdx] else BACKGROUND_COLORS[frameIdx]
                        val expected = intArrayOf(Color.red(expectedColor), Color.green(expectedColor), Color.blue(expectedColor))
                        val diffs = IntArray(3) { i -> abs(actual[i] - expected[i]) }
                        val framePass = diffs.all { it <= PIXEL_TOLERANCE }
                        perFramePixelResults.add(
                            mapOf(
                                "frameIndex" to frameIdx,
                                "pass" to framePass,
                                "expectedShowsCamera" to EXPECTED_SHOWS_CAMERA[frameIdx],
                                "expectedRgb" to expected.toList(),
                                "actualRgb" to actual.toList(),
                                "diffs" to diffs.toList(),
                            )
                        )
                    }
                } finally {
                    try { retriever.release() } catch (_: Throwable) {}
                }

                decodeOk = perFramePixelResults.size == FRAME_COUNT && perFramePixelResults.all { it["pass"] == true }

                var maxCombinedDiff = 0
                for (i in decodedColors.indices) {
                    val a = decodedColors[i] ?: continue
                    for (j in i + 1 until decodedColors.size) {
                        val b = decodedColors[j] ?: continue
                        val combined = abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])
                        if (combined > maxCombinedDiff) maxCombinedDiff = combined
                    }
                }
                interFrameVariationOk = maxCombinedDiff > (PIXEL_TOLERANCE * 2)
            }

            val negativeLanesOk = negativeLanes.size == 3 &&
                negativeLanes.values.all { (it as? Map<*, *>)?.get("pass") == true }

            val proofGatesPass = mainRenderOk && decodeOk && interFrameVariationOk && negativeLanesOk &&
                renderedFrames == writtenVideoSamples

            var renameSucceeded = false
            if (proofGatesPass) {
                renameSucceeded = File(tmpPath).renameTo(File(outputPath))
            } else {
                try { if (tmpFile.exists()) tmpFile.delete() } catch (_: Throwable) {}
            }
            tmpPathResolved = true

            val tmpExists = tmpFile.exists()
            val outputFile = File(outputPath)
            val outputExists = outputFile.exists()
            val outputSizeAfter = if (outputExists) outputFile.length() else 0L

            val finalizationOk = renameSucceeded && outputExists && outputSizeAfter > 0L && !tmpExists
            val isPass = proofGatesPass && finalizationOk

            val finalOutputSize = if (isPass) outputSizeAfter else outputSize

            val reason = when {
                isPass -> "pass"
                frameRenderError != null -> frameRenderError
                !negativeLanesOk -> "negative_lane_failed"
                !mainRenderOk -> "main_render_incomplete;rendered=$renderedFrames;written=$writtenVideoSamples"
                !decodeOk -> "decoded_pixel_assertion_failed"
                !interFrameVariationOk -> "insufficient_inter_frame_variation"
                !proofGatesPass -> "unknown_failure"
                !renameSucceeded -> "output_rename_failed"
                !outputExists -> "output_missing_after_rename"
                outputSizeAfter <= 0L -> "output_empty_after_rename"
                tmpExists -> "tmp_not_removed_after_rename"
                else -> "unknown_finalization_failure"
            }

            return mapOf(
                "pass" to isPass,
                "reason" to reason,
                "proofBoundary" to PROOF_BOUNDARY,
                "outputPath" to (if (isPass) outputPath else tmpPath),
                "outputSize" to finalOutputSize,
                "outputExists" to outputExists,
                "tmpExists" to tmpExists,
                "width" to width,
                "height" to height,
                "frameCount" to FRAME_COUNT,
                "renderedFrames" to renderedFrames,
                "writtenVideoSamples" to writtenVideoSamples,
                "renderedEqualsWritten" to (renderedFrames == writtenVideoSamples),
                "maskWidth" to MASK_WIDTH,
                "maskHeight" to MASK_HEIGHT,
                "alphaLadder" to ALPHA_LADDER.toList(),
                "bgDecoderName" to bp.decoderName,
                "camDecoderName" to cp.decoderName,
                "bgBufferFormat" to bgBufferFormat,
                "camBufferFormat" to camBufferFormat,
                "negativeLanes" to negativeLanes,
                "perFramePixelResults" to perFramePixelResults,
                "pixelToleranceExpected" to PIXEL_TOLERANCE,
                "interFrameVariationOk" to interFrameVariationOk,
                "claims" to buildList {
                    add("existing_vulkan_export_session_green_screen_render_entrypoint")
                    add("r8_mask_upload_entrypoint")
                    add("hardware_decoded_private_ycbcr_source_and_camera_inputs")
                    add("deterministic_decoded_pixel_mp4_proof")
                    add("rendered_equals_written_samples")
                    if (isPass) add("clean_tmp_cleanup")
                },
                "nonClaims" to listOf(
                    "no_live_camera",
                    "no_ml_matte",
                    "no_persisted_camera_or_mask_media",
                    "no_audio",
                    "no_av_sync",
                    "no_connectsapp_or_universal_editor_wiring",
                    "no_static_or_image_background_export",
                    "no_production_duet_export_wiring",
                    "fixed_offline_frame_clock_only",
                ),
            )
        } catch (t: Throwable) {
            Log.e(TAG, "AndroidDuetVulkanGreenScreenExportExternalYcbcrPixelProofSmokeHarness uncaught exception", t)
            return failResult(
                "exception:${t.javaClass.simpleName}:${t.message}",
                width, height, renderedFrames, writtenVideoSamples, outputPath, negativeLanes,
            )
        } finally {
            // Close decoder pipelines before deleting fixture files so file handles are released.
            try { bgPipeline?.close() } catch (_: Throwable) {}
            try { camPipeline?.close() } catch (_: Throwable) {}

            try {
                val fBg = File(bgFixturePath)
                if (fBg.exists()) fBg.delete()
            } catch (_: Throwable) {}
            try {
                val fCam = File(camFixturePath)
                if (fCam.exists()) fCam.delete()
            } catch (_: Throwable) {}

            val bridge = nativeBridge
            val sid = sessionId
            if (bridge != null && sid != null) {
                if (maskTextureHandle > 0L) {
                    try { bridge.releaseAndroidTimelineVulkanExportOverlayTexture(sid, maskTextureHandle) } catch (_: Throwable) {}
                }
                try { bridge.destroyAndroidTimelineVulkanExportSession(sid) } catch (_: Throwable) {}
            }
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
            try { encoderSurface?.release() } catch (_: Throwable) {}
            if (!tmpPathResolved) {
                try {
                    val leftoverTmp = File(tmpPath)
                    if (leftoverTmp.exists()) leftoverTmp.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    private fun buildMaskBuffer(alpha: Int): ByteBuffer {
        val buf = ByteBuffer.allocateDirect(MASK_WIDTH * MASK_HEIGHT)
        val byteVal = (alpha and 0xFF).toByte()
        for (i in 0 until MASK_WIDTH * MASK_HEIGHT) buf.put(i, byteVal)
        buf.position(0)
        return buf
    }

    private fun generateSolidColorFixtureVideo(
        outputPath: String,
        width: Int,
        height: Int,
        colors: IntArray,
        frameDurationUs: Long,
        bitrate: Int,
    ): String? {
        val fps = (1_000_000L / frameDurationUs).toInt().coerceAtLeast(1)
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
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }

            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = codec.createInputSurface()
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            codec.start()

            val bufferInfo = MediaCodec.BufferInfo()
            val nonNullCodec = codec
            val nonNullMuxer = muxer

            fun drainOutput(endOfStream: Boolean, timeoutMs: Long) {
                val deadline = System.currentTimeMillis() + timeoutMs
                var draining = true
                while (draining && System.currentTimeMillis() <= deadline) {
                    val outIdx = nonNullCodec.dequeueOutputBuffer(bufferInfo, 10_000L)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (!endOfStream) draining = false
                        }
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (videoTrackIndex < 0) {
                                videoTrackIndex = nonNullMuxer.addTrack(nonNullCodec.outputFormat)
                                nonNullMuxer.start()
                                muxerStarted = true
                            }
                        }
                        outIdx >= 0 -> {
                            val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            if (!isConfig && bufferInfo.size > 0 && muxerStarted && videoTrackIndex >= 0) {
                                val encodedData = nonNullCodec.getOutputBuffer(outIdx)
                                if (encodedData != null) {
                                    encodedData.position(bufferInfo.offset)
                                    encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                    bufferInfo.presentationTimeUs = writtenVideoSamples * frameDurationUs
                                    nonNullMuxer.writeSampleData(videoTrackIndex, encodedData, bufferInfo)
                                    writtenVideoSamples++
                                }
                            }
                            nonNullCodec.releaseOutputBuffer(outIdx, false)
                            if (isEos) draining = false
                        }
                    }
                }
            }

            for (frameIdx in colors.indices) {
                val canvas = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    try { encoderSurface.lockHardwareCanvas() } catch (_: Throwable) { encoderSurface.lockCanvas(null) }
                } else {
                    encoderSurface.lockCanvas(null)
                }
                canvas.drawColor(colors[frameIdx])
                encoderSurface.unlockCanvasAndPost(canvas)
                drainOutput(endOfStream = false, timeoutMs = 200L)
                try { Thread.sleep(40L) } catch (_: Throwable) {}
            }

            codec.signalEndOfInputStream()
            drainOutput(endOfStream = true, timeoutMs = 5000L)

            if (muxerStarted && writtenVideoSamples > 0) {
                try {
                    muxer.stop()
                    muxerStoppedCleanly = true
                } catch (t: Throwable) {
                    Log.w(TAG, "generateSolidColorFixtureVideo: MediaMuxer.stop failed: $t")
                }
            }

            val file = File(outputPath)
            val success = muxerStoppedCleanly && file.exists() && file.length() > 0L && writtenVideoSamples == colors.size
            return if (success) null else "fixture_generation_incomplete;samples=$writtenVideoSamples;expected=${colors.size}"
        } catch (t: Throwable) {
            Log.e(TAG, "generateSolidColorFixtureVideo failed", t)
            return "fixture_generation_exception:${t.javaClass.simpleName}:${t.message}"
        } finally {
            try { encoderSurface?.release() } catch (_: Throwable) {}
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
        }
    }

    private class DecodedFrame(
        val image: Image,
        val ptsUs: Long,
        val timestampNs: Long,
        val frameIndex: Int,
        val fenceWaited: Boolean,
    )

    private sealed class StepOutcome {
        class Frame(val frame: DecodedFrame) : StepOutcome()
        object Eos : StepOutcome()
        class Failed(val reason: String) : StepOutcome()
    }

    private class DecodePipeline(
        val label: String,
        val videoPath: String,
        val targetWidth: Int,
        val targetHeight: Int,
    ) {
        var decoderName: String? = null
            private set
        var framesProduced: Int = 0
            private set
        var openImages: Int = 0
            private set

        private var extractor: MediaExtractor? = null
        private var codec: MediaCodec? = null
        private var imageReader: ImageReader? = null
        private var surface: Surface? = null
        private var handlerThread: HandlerThread? = null
        private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES)
        private var inputDone = false
        private var outputDone = false
        private val closed = AtomicBoolean(false)

        fun prepare(): String? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                return "api_level_below_29;sdk=${Build.VERSION.SDK_INT}"
            }
            return try {
                val ex = MediaExtractor().also { extractor = it }
                ex.setDataSource(videoPath)
                var trackIndex = -1
                var format: MediaFormat? = null
                for (i in 0 until ex.trackCount) {
                    val trackFmt = ex.getTrackFormat(i)
                    val mime = trackFmt.getString(MediaFormat.KEY_MIME) ?: ""
                    if (mime.startsWith("video/")) {
                        trackIndex = i
                        format = trackFmt
                        break
                    }
                }
                if (trackIndex < 0 || format == null) {
                    return "no_video_track_found;$videoPath"
                }
                ex.selectTrack(trackIndex)

                val mime = format.getString(MediaFormat.KEY_MIME)
                    ?: return "track_mime_missing"
                val name = selectHardwareDecoderName(mime)
                    ?: return "no_hardware_decoder_available;mime=$mime"
                decoderName = name

                val ht = HandlerThread("VgDuetGreenScreenExportYcbcr-$label").also {
                    handlerThread = it
                    it.start()
                }

                val reader = ImageReader.newInstance(
                    targetWidth,
                    targetHeight,
                    ImageFormat.PRIVATE,
                    IMAGE_READER_MAX_IMAGES,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                ).also { imageReader = it }

                reader.setOnImageAvailableListener(
                    { r ->
                        try {
                            val img = r.acquireNextImage()
                            if (img != null && !imageQueue.offer(img)) {
                                img.close()
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "acquireNextImage failed for $label: $e")
                        }
                    },
                    Handler(ht.looper),
                )
                surface = reader.surface
                format.setInteger(MediaFormat.KEY_ROTATION, 0)
                val dec = MediaCodec.createByCodecName(name).also { codec = it }
                dec.configure(format, reader.surface, null, 0)
                dec.start()
                null
            } catch (t: Throwable) {
                Log.e(TAG, "DecodePipeline.prepare failed for $label", t)
                "codec_configure_failed;reason=${t.javaClass.simpleName}:${t.message}"
            }
        }

        fun nextFrame(maxFrames: Int): StepOutcome {
            if (closed.get()) return StepOutcome.Failed("pipeline_closed")
            val dec = codec ?: return StepOutcome.Failed("codec_missing")
            if (outputDone) return StepOutcome.Eos
            var noOutputAttempts = 0
            val info = MediaCodec.BufferInfo()
            while (true) {
                if (framesProduced >= maxFrames) {
                    return StepOutcome.Failed("max_frames_reached;maxFrames=$maxFrames")
                }
                feedInput(dec)
                val outIdx = dec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                if (outIdx >= 0) {
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val renderable = info.size > 0
                    dec.releaseOutputBuffer(outIdx, renderable)
                    if (isEos) outputDone = true
                    if (renderable) {
                        val image = imageQueue.poll(IMAGE_ACQUIRE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                            ?: return StepOutcome.Failed("image_acquire_timeout")
                        val fenceWaited = awaitFence(image)
                        val frameIndex = framesProduced
                        framesProduced++
                        openImages++
                        return StepOutcome.Frame(
                            DecodedFrame(image, info.presentationTimeUs, image.timestamp, frameIndex, fenceWaited),
                        )
                    }
                    if (isEos) return StepOutcome.Eos
                    noOutputAttempts = 0
                    continue
                }
                noOutputAttempts++
                if (noOutputAttempts >= MAX_NO_OUTPUT_ATTEMPTS) {
                    return StepOutcome.Failed("decoder_stalled;attempts=$noOutputAttempts")
                }
            }
        }

        fun releaseFrame(frame: DecodedFrame) {
            try {
                frame.image.close()
            } catch (_: Throwable) {}
            openImages--
        }

        private fun feedInput(dec: MediaCodec) {
            val ex = extractor ?: return
            while (!inputDone) {
                val inIdx = dec.dequeueInputBuffer(0)
                if (inIdx < 0) return
                val buf = dec.getInputBuffer(inIdx)
                if (buf == null) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                    return
                }
                val size = ex.readSampleData(buf, 0)
                if (size < 0) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    dec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0)
                    ex.advance()
                }
            }
        }

        private fun awaitFence(image: Image): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
            return try {
                val fence = image.fence
                try {
                    if (fence.isValid) {
                        fence.await(java.time.Duration.ofMillis(FENCE_WAIT_MS))
                    } else {
                        true
                    }
                } finally {
                    try { fence.close() } catch (_: Throwable) {}
                }
            } catch (t: Throwable) {
                Log.w(TAG, "SyncFence exception for $label: $t")
                false
            }
        }

        private fun selectHardwareDecoderName(mime: String): String? {
            return try {
                val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
                list.codecInfos.firstOrNull { info ->
                    !info.isEncoder &&
                        info.isHardwareAccelerated &&
                        info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
                }?.name
            } catch (t: Throwable) {
                Log.w(TAG, "selectHardwareDecoderName failed for mime=$mime: $t")
                null
            }
        }

        fun close() {
            if (!closed.compareAndSet(false, true)) return
            while (true) {
                val img = imageQueue.poll() ?: break
                try { img.close() } catch (_: Throwable) {}
            }
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            codec = null
            try { surface?.release() } catch (_: Throwable) {}
            surface = null
            try { imageReader?.close() } catch (_: Throwable) {}
            imageReader = null
            try { handlerThread?.quitSafely() } catch (_: Throwable) {}
            handlerThread = null
            try { extractor?.release() } catch (_: Throwable) {}
            extractor = null
        }
    }

    private fun failResult(
        reason: String,
        width: Int,
        height: Int,
        renderedFrames: Int,
        writtenVideoSamples: Int,
        outputPath: String,
        negativeLanes: Map<String, Any?>,
    ): Map<String, Any?> = mapOf(
        "pass" to false,
        "reason" to reason,
        "proofBoundary" to PROOF_BOUNDARY,
        "outputPath" to outputPath,
        "outputSize" to 0L,
        "outputExists" to File(outputPath).exists(),
        "tmpExists" to File("$outputPath.tmp").exists(),
        "width" to width,
        "height" to height,
        "frameCount" to FRAME_COUNT,
        "renderedFrames" to renderedFrames,
        "writtenVideoSamples" to writtenVideoSamples,
        "renderedEqualsWritten" to (renderedFrames == writtenVideoSamples),
        "maskWidth" to MASK_WIDTH,
        "maskHeight" to MASK_HEIGHT,
        "alphaLadder" to ALPHA_LADDER.toList(),
        "negativeLanes" to negativeLanes,
        "perFramePixelResults" to emptyList<Map<String, Any?>>(),
        "pixelToleranceExpected" to PIXEL_TOLERANCE,
        "interFrameVariationOk" to false,
        "claims" to emptyList<String>(),
        "nonClaims" to emptyList<String>(),
    )
}
