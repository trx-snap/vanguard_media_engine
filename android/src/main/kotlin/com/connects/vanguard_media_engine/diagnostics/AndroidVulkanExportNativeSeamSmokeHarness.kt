package com.connects.vanguard_media_engine.diagnostics

import android.hardware.HardwareBuffer
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.io.File

object AndroidVulkanExportNativeSeamSmokeHarness {
    private const val TAG = "VanguardVulkanExportSmoke"
    private const val RESULT_MARKER = "ANDROID_VULKAN_EXPORT_NATIVE_SEAM_RESULT"
    private const val PROOF_BOUNDARY = "media_codec_input_surface_vulkan_export_native_seam"

    fun runSmoke(
        width: Int = 64,
        height: Int = 64,
        frameCount: Int = 10,
        frameDurationUs: Long = 33333L,
        bitrate: Int = 1_000_000,
        outputPath: String,
    ): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val raw = failureRaw("api_below_29", width, height, frameCount, 0, 0, outputPath)
            Log.i(TAG, "$RESULT_MARKER $raw")
            return makeResult(
                pass = false,
                raw = raw,
                width = width,
                height = height,
                frameCount = frameCount,
                encodedFrames = 0,
                frameDurationUs = frameDurationUs,
                outputPath = outputPath,
                outputSize = 0L,
            )
        }

        if (width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0 || bitrate <= 0 || outputPath.isBlank()) {
            val raw = failureRaw("invalid_args", width, height, frameCount, 0, 0, outputPath)
            Log.i(TAG, "$RESULT_MARKER $raw")
            return makeResult(
                pass = false,
                raw = raw,
                width = width,
                height = height,
                frameCount = frameCount,
                encodedFrames = 0,
                frameDurationUs = frameDurationUs,
                outputPath = outputPath,
                outputSize = 0L,
            )
        }

        var hardwareBuffer: HardwareBuffer? = null
        var codec: MediaCodec? = null
        var encoderSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var sessionId: String? = null
        var nativeBridge: VanguardNativeBridge? = null

        var muxerStarted = false
        var videoTrackIndex = -1
        var writtenVideoSamples = 0
        var renderedFrames = 0
        var muxerStoppedCleanly = false
        var isPass = false
        var raw = failureRaw("not_run", width, height, frameCount, 0, 0, outputPath)

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
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
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
                raw = failureRaw(
                    "session_create_failed;nativeResult=${createResult.take(80)}",
                    width,
                    height,
                    frameCount,
                    renderedFrames,
                    writtenVideoSamples,
                    outputPath,
                )
                return makeResult(
                    pass = false,
                    raw = raw,
                    width = width,
                    height = height,
                    frameCount = frameCount,
                    encodedFrames = 0,
                    frameDurationUs = frameDurationUs,
                    outputPath = outputPath,
                    outputSize = 0L,
                )
            }

            sessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
            if (sessionId == null) {
                raw = failureRaw(
                    "session_id_parse_failed",
                    width,
                    height,
                    frameCount,
                    renderedFrames,
                    writtenVideoSamples,
                    outputPath,
                )
                return makeResult(
                    pass = false,
                    raw = raw,
                    width = width,
                    height = height,
                    frameCount = frameCount,
                    encodedFrames = 0,
                    frameDurationUs = frameDurationUs,
                    outputPath = outputPath,
                    outputSize = 0L,
                )
            }

            hardwareBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            val bufferInfo = MediaCodec.BufferInfo()
            var frameRenderError: String? = null

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

            for (frameIdx in 0 until frameCount) {
                val ptsUs = frameIdx * frameDurationUs
                val renderStr = nativeBridge.renderAndroidTimelineVulkanExportFrame(
                    sessionId = sessionId,
                    hardwareBuffer = hardwareBuffer,
                    width = width,
                    height = height,
                    timelinePtsUs = ptsUs,
                    frameIndex = frameIdx,
                )
                if (renderStr.startsWith("status=OK;")) {
                    renderedFrames++
                } else {
                    frameRenderError = renderStr
                    break
                }
                drainOutput(endOfStream = false, timeoutMs = 200L)
            }

            if (renderedFrames == frameCount && frameRenderError == null) {
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

            val outputFile = File(outputPath)
            val outputSize = if (outputFile.exists()) outputFile.length() else 0L

            isPass = renderedFrames == frameCount &&
                writtenVideoSamples == frameCount &&
                frameRenderError == null &&
                muxerStoppedCleanly &&
                outputFile.exists() &&
                outputSize > 0L

            raw = if (isPass) {
                "status=PASS;session=success;renderedFrames=$renderedFrames;" +
                    "writtenSamples=$writtenVideoSamples;frameCount=$frameCount;width=$width;height=$height;" +
                    "outputSize=$outputSize;outputPath=$outputPath;proofBoundary=$PROOF_BOUNDARY"
            } else {
                val reason = when {
                    frameRenderError != null -> "render_failed;detail=${frameRenderError.take(60)}"
                    renderedFrames < frameCount -> "insufficient_rendered_frames;rendered=$renderedFrames"
                    videoTrackIndex < 0 -> "format_not_changed_timeout"
                    writtenVideoSamples < frameCount -> "insufficient_written_samples;written=$writtenVideoSamples"
                    !muxerStoppedCleanly -> "muxer_stop_failed"
                    !outputFile.exists() || outputSize == 0L -> "output_file_empty_or_missing"
                    else -> "unknown_failure"
                }
                "status=FAIL;reason=$reason;renderedFrames=$renderedFrames;" +
                    "writtenSamples=$writtenVideoSamples;frameCount=$frameCount;width=$width;height=$height;" +
                    "outputPath=$outputPath;proofBoundary=$PROOF_BOUNDARY"
            }

            return makeResult(
                pass = isPass,
                raw = raw,
                width = width,
                height = height,
                frameCount = frameCount,
                encodedFrames = writtenVideoSamples,
                frameDurationUs = frameDurationUs,
                outputPath = outputPath,
                outputSize = outputSize,
            )
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = failureRaw(
                "exception:$reason",
                width,
                height,
                frameCount,
                renderedFrames,
                writtenVideoSamples,
                outputPath,
            )
            Log.e(TAG, "$RESULT_MARKER exception=$reason", throwable)
            return makeResult(
                pass = false,
                raw = raw,
                width = width,
                height = height,
                frameCount = frameCount,
                encodedFrames = writtenVideoSamples,
                frameDurationUs = frameDurationUs,
                outputPath = outputPath,
                outputSize = 0L,
            )
        } finally {
            Log.i(TAG, "$RESULT_MARKER $raw")
            val bridge = nativeBridge
            val sid = sessionId
            if (bridge != null && sid != null) {
                try { bridge.destroyAndroidTimelineVulkanExportSession(sid) } catch (_: Throwable) {}
            }
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
            try { encoderSurface?.release() } catch (_: Throwable) {}
            try { hardwareBuffer?.close() } catch (_: Throwable) {}
            if (!isPass) {
                try {
                    val f = File(outputPath)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    private fun makeResult(
        pass: Boolean,
        raw: String,
        width: Int,
        height: Int,
        frameCount: Int,
        encodedFrames: Int,
        frameDurationUs: Long,
        outputPath: String,
        outputSize: Long,
    ): Map<String, Any?> = mapOf(
        "pass" to pass,
        "raw" to raw,
        "width" to width,
        "height" to height,
        "frameCount" to frameCount,
        "encodedFrames" to encodedFrames,
        "frameDurationUs" to frameDurationUs,
        "outputPath" to outputPath,
        "outputSize" to outputSize,
        "proofBoundary" to PROOF_BOUNDARY,
    )

    private fun failureRaw(
        reason: String,
        width: Int,
        height: Int,
        frameCount: Int,
        renderedFrames: Int,
        writtenSamples: Int,
        outputPath: String,
    ): String =
        "status=FAIL;reason=$reason;renderedFrames=$renderedFrames;" +
            "writtenSamples=$writtenSamples;frameCount=$frameCount;width=$width;height=$height;" +
            "outputPath=$outputPath;proofBoundary=$PROOF_BOUNDARY"
}
