package com.connects.vanguard_media_engine.diagnostics

import android.graphics.Color
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.abs

/**
 * ANDROID-DUET-VULKAN-GREENSCREEN-EXPORT-PIXEL-PROOF (diagnostic only).
 *
 * Physical proof that the EXISTING Android Vulkan export session
 * (android_vulkan_export_jni.cpp's VulkanExportSession registry) can render
 * Duet green-screen composition frames into a MediaCodec encoder input
 * surface via its two new diagnostic-only entrypoints --
 * [VanguardNativeBridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame]
 * and [VanguardNativeBridge.uploadAndroidTimelineVulkanExportMaskTextureR8]
 * -- then decodes the produced MP4 back and asserts real, per-frame,
 * decoded center-pixel color. Never touches AndroidDuetExportSession or the
 * production Duet preview session, never creates a second swapchain owner,
 * and never wires into ConnectsApp/Universal Editor.
 *
 * Deterministic content: background and camera HardwareBuffers are each a
 * single solid color, sourced from an [ImageReader] configured with
 * [HardwareBuffer.USAGE_CPU_WRITE_RARELY] plus
 * [HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE] and painted via
 * [Surface.lockCanvas] -- a real CPU write into a real GPU-sampled buffer,
 * not a hollow/uninitialized buffer. The green-screen mask is a 63x63
 * (non-multiple-of-4) R8 texture re-uploaded per frame with an alpha ladder
 * of 0, 255, 128, 64.
 *
 * Expected composited color per frame follows the camera-mask fragment
 * shader's actual math (greenscreen_blend.frag,
 * VANGUARD_DUET_CAMERA_MASK variant): the sampled mask alpha is eroded by
 * one texel (a no-op on our uniform-fill mask) then shaped with
 * smoothstep(0.52, 0.78, erodedAlpha) before blending camera over source.
 * For our ladder (0, 1.0, 0.502, 0.251 normalized) every value falls
 * cleanly outside the [0.52, 0.78] transition band, so each frame's
 * expected result is unambiguous: alpha=255 shows the camera color,
 * alpha in {0, 128, 64} shows the background color.
 */
object AndroidDuetVulkanGreenScreenExportPixelProofSmokeHarness {
    private const val TAG = "VanguardDuetGreenScreenExportPixelProof"
    const val PROOF_BOUNDARY =
        "android_duet_vulkan_export_session_greenscreen_render_entrypoint_deterministic_decoded_pixel_proof"

    private const val MASK_WIDTH = 63
    private const val MASK_HEIGHT = 63
    private val ALPHA_LADDER = intArrayOf(0, 255, 128, 64)

    // See class doc: smoothstep(0.52, 0.78, .) on a uniform mask maps every
    // ladder value to a hard 0 or 1 -- only alpha=255 shows the camera layer.
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

    private const val PIXEL_TOLERANCE = 36
    private const val MISMATCHED_MASK_HANDLE = 999_999_999L
    private const val FRAME_COUNT = 4

    private class SolidHardwareBuffer(
        val hardwareBuffer: HardwareBuffer,
        private val image: Image,
        private val reader: ImageReader,
    ) {
        fun closeAll() {
            try { hardwareBuffer.close() } catch (_: Throwable) {}
            try { image.close() } catch (_: Throwable) {}
            try { reader.close() } catch (_: Throwable) {}
        }
    }

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
        var codec: MediaCodec? = null
        var encoderSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var sessionId: String? = null
        var nativeBridge: VanguardNativeBridge? = null
        var maskTextureHandle = 0L

        var muxerStarted = false
        var videoTrackIndex = -1
        var writtenVideoSamples = 0
        var renderedFrames = 0
        var muxerStoppedCleanly = false
        // Set true only once the try block's own rename-on-pass/delete-on-fail
        // logic has already resolved tmpPath, so the `finally` block's tmp
        // cleanup below never races a successful pass (e.g. a rare renameTo
        // failure must not delete a still-valid tmp output).
        var tmpPathResolved = false
        var frameRenderError: String? = null
        val negativeLanes = LinkedHashMap<String, Any?>()

        try {
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

            // ── Negative lanes 2 & 3 use a throwaway dummy buffer pair, never ──
            // actually imported since both lanes fail before AHB import.
            val dummyBackground = createSolidHardwareBuffer(4, 4, Color.BLACK)
            val dummyCamera = createSolidHardwareBuffer(4, 4, Color.WHITE)
            try {
                if (dummyBackground != null && dummyCamera != null) {
                    // Negative lane 2: mismatched (unregistered) mask handle.
                    val raw = nativeBridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame(
                        sessionId, dummyBackground.hardwareBuffer, dummyCamera.hardwareBuffer,
                        width, height,
                        0, 0, width, height,
                        0, 0, width, height,
                        4, 4, 4, 4,
                        MISMATCHED_MASK_HANDLE,
                        0, false, 0, false,
                        0, 0L, -1,
                    )
                    val pass = raw.startsWith("status=FAIL;") && raw.contains("reason=mask_texture_unknown")
                    negativeLanes["mismatchedMaskHandle"] = mapOf("pass" to pass, "raw" to raw)

                    // Negative lane 3: non-cardinal camera rotation.
                    val rotationRaw = nativeBridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame(
                        sessionId, dummyBackground.hardwareBuffer, dummyCamera.hardwareBuffer,
                        width, height,
                        0, 0, width, height,
                        0, 0, width, height,
                        4, 4, 4, 4,
                        0L,
                        0, false, /*cameraRotationDegrees=*/45, false,
                        0, 0L, -1,
                    )
                    val rotationPass = rotationRaw.startsWith("status=FAIL;") &&
                        rotationRaw.contains("reason=vulkan_rotation_unsupported:camera:45")
                    negativeLanes["nonCardinalRotation"] = mapOf("pass" to rotationPass, "raw" to rotationRaw)
                } else {
                    negativeLanes["mismatchedMaskHandle"] = mapOf("pass" to false, "raw" to "dummy_buffer_creation_failed")
                    negativeLanes["nonCardinalRotation"] = mapOf("pass" to false, "raw" to "dummy_buffer_creation_failed")
                }
            } finally {
                dummyBackground?.closeAll()
                dummyCamera?.closeAll()
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

            // ── Real green-screen frames: create-then-update the R8 mask, ──
            // fill deterministic solid background/camera buffers, render.
            for (frameIdx in 0 until FRAME_COUNT) {
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

                val bgBuffer = createSolidHardwareBuffer(width, height, BACKGROUND_COLORS[frameIdx])
                val camBuffer = createSolidHardwareBuffer(width, height, CAMERA_COLORS[frameIdx])
                if (bgBuffer == null || camBuffer == null) {
                    bgBuffer?.closeAll()
                    camBuffer?.closeAll()
                    frameRenderError = "solid_buffer_creation_failed:frame=$frameIdx"
                    break
                }

                val cameraRotation = if (frameIdx == 1) 90 else 0
                val cameraMirror = frameIdx == 1

                val renderRaw = nativeBridge.renderAndroidTimelineVulkanExportDuetGreenScreenFrame(
                    sessionId,
                    bgBuffer.hardwareBuffer,
                    camBuffer.hardwareBuffer,
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
                bgBuffer.closeAll()
                camBuffer.closeAll()

                if (renderRaw.startsWith("status=OK;")) {
                    renderedFrames++
                } else {
                    frameRenderError = "render_failed:frame=$frameIdx:$renderRaw"
                    break
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

            // ── Decode the produced MP4 back and assert per-frame center pixel ──
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

            // Proof gates only -- atomic finalization (the rename itself, plus
            // the resulting file state) is checked separately below and is
            // itself required for an overall pass, not assumed from isPass.
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

            // A PASS requires the rename to have actually succeeded, the
            // final output to exist with real bytes, and the tmp file to be
            // gone -- not merely that the proof gates above were satisfied.
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
                "presentModeExposed" to false,
                "presentMode" to null,
                "negativeLanes" to negativeLanes,
                "perFramePixelResults" to perFramePixelResults,
                "pixelToleranceExpected" to PIXEL_TOLERANCE,
                "interFrameVariationOk" to interFrameVariationOk,
                "claims" to buildList {
                    add("existing_vulkan_export_session_green_screen_render_entrypoint")
                    add("r8_mask_upload_entrypoint")
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
                    "synthetic_rgba_imports_only_external_ycbcr_camera_sampling_not_covered",
                    "fixed_offline_frame_clock_only",
                ),
            )
        } catch (t: Throwable) {
            Log.e(TAG, "AndroidDuetVulkanGreenScreenExportPixelProofSmokeHarness uncaught exception", t)
            return failResult(
                "exception:${t.javaClass.simpleName}:${t.message}",
                width, height, renderedFrames, writtenVideoSamples, outputPath, negativeLanes,
            )
        } finally {
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
                // Only reached via an early return (session setup failure) or
                // an uncaught exception -- the normal-completion path above
                // has already rename-on-pass/delete-on-fail'd tmpPath.
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

    private fun createSolidHardwareBuffer(width: Int, height: Int, color: Int): SolidHardwareBuffer? {
        var reader: ImageReader? = null
        var image: Image? = null
        try {
            reader = ImageReader.newInstance(
                width,
                height,
                PixelFormat.RGBA_8888,
                2,
                HardwareBuffer.USAGE_CPU_WRITE_RARELY or HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
            val surface = reader.surface
            val canvas = surface.lockCanvas(null)
            canvas.drawColor(color)
            surface.unlockCanvasAndPost(canvas)

            var attempt = 0
            while (image == null && attempt < 50) {
                image = reader.acquireLatestImage()
                if (image == null) {
                    Thread.sleep(2L)
                    attempt++
                }
            }
            val acquiredImage = image ?: run {
                reader.close()
                return null
            }
            val hwb = acquiredImage.hardwareBuffer
            if (hwb == null) {
                acquiredImage.close()
                reader.close()
                return null
            }
            return SolidHardwareBuffer(hwb, acquiredImage, reader)
        } catch (t: Throwable) {
            Log.w(TAG, "createSolidHardwareBuffer failed: ${t.javaClass.simpleName}: ${t.message}")
            try { image?.close() } catch (_: Throwable) {}
            try { reader?.close() } catch (_: Throwable) {}
            return null
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
        "presentModeExposed" to false,
        "presentMode" to null,
        "negativeLanes" to negativeLanes,
        "perFramePixelResults" to emptyList<Map<String, Any?>>(),
        "pixelToleranceExpected" to PIXEL_TOLERANCE,
        "interFrameVariationOk" to false,
        "claims" to emptyList<String>(),
        "nonClaims" to emptyList<String>(),
    )
}
