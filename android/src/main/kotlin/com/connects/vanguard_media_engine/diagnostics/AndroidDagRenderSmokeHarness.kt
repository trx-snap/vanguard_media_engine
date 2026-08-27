package com.connects.vanguard_media_engine.diagnostics

import android.graphics.SurfaceTexture
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

object AndroidDagRenderSmokeHarness {
    private const val TAG = "VanguardDagSmoke"
    private const val RESULT_MARKER = "ANDROID_DAG_PHASE2O2B3_NATIVE_RESULT"
    private const val RESULT_MARKER_PHASE2O2B4 = "ANDROID_DAG_PHASE2O2B4_NATIVE_RESULT"

    fun run(width: Int, height: Int): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = smokeFailure("not_run", width, height)

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = smokeFailure("api_below_26", width, height)
                return result(raw, width, height)
            }
            if (width <= 0 || height <= 0) {
                raw = smokeFailure("invalid_dimensions", width, height)
                return result(raw, width, height)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)
            hardwareBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagRenderSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return result(raw, width, height)
        } catch (throwable: Throwable) {
            raw = smokeFailure(
                throwable.javaClass.simpleName.ifEmpty { "unknown_exception" },
                width,
                height,
            )
            return result(raw, width, height)
        } finally {
            Log.i(TAG, "$RESULT_MARKER $raw")
            try {
                hardwareBuffer?.close()
            } catch (_: Throwable) {
            }
            try {
                surface?.release()
            } catch (_: Throwable) {
            }
            try {
                surfaceTexture?.release()
            } catch (_: Throwable) {
            }
        }
    }

    fun runMultiFrame(width: Int, height: Int, frameCount: Int): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = smokeLoopFailure("not_run", width, height, frameCount)

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = smokeLoopFailure("api_below_26", width, height, frameCount)
                return loopResult(raw, width, height, frameCount)
            }
            if (width <= 0 || height <= 0 || frameCount <= 0) {
                raw = smokeLoopFailure("invalid_dimensions", width, height, frameCount)
                return loopResult(raw, width, height, frameCount)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)
            hardwareBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagRenderLoopSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
                frameCount,
            )
            return loopResult(raw, width, height, frameCount)
        } catch (throwable: Throwable) {
            raw = smokeLoopFailure(
                throwable.javaClass.simpleName.ifEmpty { "unknown_exception" },
                width,
                height,
                frameCount,
            )
            return loopResult(raw, width, height, frameCount)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE2O2B4 $raw")
            try {
                hardwareBuffer?.close()
            } catch (_: Throwable) {
            }
            try {
                surface?.release()
            } catch (_: Throwable) {
            }
            try {
                surfaceTexture?.release()
            } catch (_: Throwable) {
            }
        }
    }

    private fun result(raw: String, width: Int, height: Int): Map<String, Any?> = mapOf(
        "pass" to raw.startsWith("status=PASS;"),
        "raw" to raw,
        "width" to width,
        "height" to height,
    )

    private fun loopResult(raw: String, width: Int, height: Int, frameCount: Int): Map<String, Any?> = mapOf(
        "pass" to raw.startsWith("status=PASS;"),
        "raw" to raw,
        "width" to width,
        "height" to height,
        "frameCount" to frameCount,
    )

    private fun smokeFailure(reason: String, width: Int, height: Int): String =
        "status=FAIL;initialize=$reason;attach=not_run;import=not_run;" +
            "renderFrame=not_run;release=not_run;width=$width;height=$height"

    private fun smokeLoopFailure(reason: String, width: Int, height: Int, frameCount: Int): String =
        "status=FAIL;initialize=$reason;attach=not_run;import=not_run;renderedFrames=0;" +
            "frameCount=$frameCount;renderFrame=not_run;failingFrame=-1;release=not_run;width=$width;height=$height"

    // ── Phase 3C: DAG playhead evaluation smoke ───────────────────────────────
    private const val RESULT_MARKER_PHASE3C = "ANDROID_DAG_PHASE3C_NATIVE_RESULT"

    fun runDagEvaluationSmoke(
        width: Int = 64,
        height: Int = 64,
        frameCount: Int = 30,
        frameDurationUs: Long = 33333L,
    ): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = dagEvalFailure("not_run", width, height, frameCount)

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = dagEvalFailure("api_below_26", width, height, frameCount)
                return dagEvalResult(raw, width, height, frameCount)
            }
            if (width <= 0 || height <= 0 || frameCount <= 0 || frameDurationUs <= 0) {
                raw = dagEvalFailure("invalid_params", width, height, frameCount)
                return dagEvalResult(raw, width, height, frameCount)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)
            hardwareBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase3CEvalRenderSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
                frameCount,
                frameDurationUs,
            )
            return dagEvalResult(raw, width, height, frameCount)
        } catch (throwable: Throwable) {
            raw = dagEvalFailure(
                throwable.javaClass.simpleName.ifEmpty { "unknown_exception" },
                width,
                height,
                frameCount,
            )
            return dagEvalResult(raw, width, height, frameCount)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE3C $raw")
            try { hardwareBuffer?.close() } catch (_: Throwable) {}
            try { surface?.release() } catch (_: Throwable) {}
            try { surfaceTexture?.release() } catch (_: Throwable) {}
        }
    }

    private fun dagEvalResult(raw: String, width: Int, height: Int, frameCount: Int): Map<String, Any?> {
        val pass = raw.startsWith("status=PASS;")
        // Parse evaluatedPtsUs from the structured status string if available.
        val evaluatedPtsUs: Long = run {
            val key = "evaluatedPtsUs="
            val idx = raw.indexOf(key)
            if (idx < 0) return@run 0L
            val start = idx + key.length
            val end = raw.indexOf(';', start).let { if (it < 0) raw.length else it }
            raw.substring(start, end).toLongOrNull() ?: 0L
        }
        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "width" to width,
            "height" to height,
            "frameCount" to frameCount,
            "evaluatedPtsUs" to evaluatedPtsUs,
        )
    }

    private fun dagEvalFailure(reason: String, width: Int, height: Int, frameCount: Int): String =
        "status=FAIL;initialize=$reason;attach=not_run;graphBuild=not_run;import=not_run;" +
            "evaluation=not_run;renderedFrames=0;frameCount=$frameCount;evaluatedPtsUs=0;" +
            "renderFrame=not_run;failingFrame=-1;release=not_run;width=$width;height=$height"

    // ── Phase 2Q: direct capability-probe smoke ──────────────────────────────
    private const val RESULT_MARKER_PHASE2Q = "ANDROID_DAG_PHASE2Q_CAPABILITY_PROBE_RESULT"

    fun runCapabilityProbe(): Map<String, Any?> {
        return try {
            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            val report = nativeBridge.probeCapabilities()
            diagnostics.logCapabilities(report)

            val pass = report.vulkanSupported &&
                report.glesSupported &&
                report.selectedBackend == 0 &&
                report.fallbackReason == "none" &&
                report.profileGateStatus == "avp2022_partial_pass" &&
                report.blacklistStatus == "not_blacklisted" &&
                report.gpuVendor.isNotEmpty() &&
                report.gpuRenderer.isNotEmpty() &&
                report.vendorId != 0L &&
                report.deviceId != 0L &&
                report.apiVersion != 0L &&
                report.vulkanDriverVersion != 0L

            val result = mapOf<String, Any?>(
                "pass" to pass,
                "vulkanSupported" to report.vulkanSupported,
                "glesSupported" to report.glesSupported,
                "selectedBackend" to report.selectedBackend,
                "fallbackReason" to report.fallbackReason,
                "gpuVendor" to report.gpuVendor,
                "gpuRenderer" to report.gpuRenderer,
                "vendorId" to report.vendorId,
                "deviceId" to report.deviceId,
                "apiVersion" to report.apiVersion,
                "vulkanDriverVersion" to report.vulkanDriverVersion,
                "profileGateStatus" to report.profileGateStatus,
                "blacklistStatus" to report.blacklistStatus,
            )
            Log.i(TAG, "$RESULT_MARKER_PHASE2Q pass=$pass $report")
            result
        } catch (throwable: Throwable) {
            val simpleName = throwable.javaClass.simpleName.ifEmpty { "UnknownException" }
            val result = mapOf<String, Any?>(
                "pass" to false,
                "vulkanSupported" to false,
                "glesSupported" to false,
                "selectedBackend" to 2,
                "fallbackReason" to "exception:$simpleName",
                "gpuVendor" to "",
                "gpuRenderer" to "",
                "vendorId" to 0L,
                "deviceId" to 0L,
                "apiVersion" to 0L,
                "vulkanDriverVersion" to 0L,
                "profileGateStatus" to "probe_exception",
                "blacklistStatus" to "not_evaluated",
            )
            Log.e(TAG, "$RESULT_MARKER_PHASE2Q exception=$simpleName", throwable)
            result
        }
    }

    // ── Phase 4A: MediaCodec decode → ImageReader → native DAG → Vulkan ─────
    private const val RESULT_MARKER_PHASE4A = "ANDROID_DAG_PHASE4A_NATIVE_RESULT"

    fun runDecoderSmoke(
        videoPath: String,
        frameCount: Int = 10,
    ): Map<String, Any?> {
        return try {
            val adapter = com.connects.vanguard_media_engine.codec
                .AndroidMediaCodecDecodedFrameSmokeAdapter(
                    videoPath  = videoPath,
                    maxFrames  = frameCount,
                )
            adapter.run()
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            val raw = "status=FAIL;decoder=exception:$reason;session=not_run;" +
                "renderedFrames=0;frameCount=$frameCount;width=0;height=0"
            Log.e(TAG, "$RESULT_MARKER_PHASE4A exception=$reason", throwable)
            mapOf(
                "pass"           to false,
                "raw"            to raw,
                "width"          to 0,
                "height"         to 0,
                "frameCount"     to frameCount,
                "renderedFrames" to 0,
            )
        }
    }

    // ── Phase 5: MediaCodec encoder input surface smoke ─────────────────────
    private const val RESULT_MARKER_PHASE5 = "ANDROID_DAG_PHASE5_ENCODER_SURFACE_SMOKE_RESULT"

    fun runEncoderSurfaceSmoke(
        width: Int = 64,
        height: Int = 64,
        frameCount: Int = 10,
        frameDurationUs: Long = 33333L,
        bitrate: Int = 1_000_000,
        outputPath: String,
    ): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val raw = phase5FailureRaw("api_below_29", width, height, frameCount, 0, 0, outputPath)
            Log.i(TAG, "$RESULT_MARKER_PHASE5 $raw")
            return phase5Result(
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
            val raw = phase5FailureRaw("invalid_args", width, height, frameCount, 0, 0, outputPath)
            Log.i(TAG, "$RESULT_MARKER_PHASE5 $raw")
            return phase5Result(
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
        var raw = phase5FailureRaw("not_run", width, height, frameCount, 0, 0, outputPath)

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

            val createResult = nativeBridge.createAndroidDagPhase5EncoderSmokeSession(
                encoderSurface,
                width,
                height,
            )

            if (!createResult.startsWith("status=OK;")) {
                raw = phase5FailureRaw(
                    "session_create_failed;nativeResult=${createResult.take(80)}",
                    width,
                    height,
                    frameCount,
                    renderedFrames,
                    writtenVideoSamples,
                    outputPath,
                )
                return phase5Result(
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
                raw = phase5FailureRaw(
                    "session_id_parse_failed",
                    width,
                    height,
                    frameCount,
                    renderedFrames,
                    writtenVideoSamples,
                    outputPath,
                )
                return phase5Result(
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
                val renderStr = nativeBridge.renderAndroidDagPhase5EncoderSmokeFrame(
                    sessionId = sessionId,
                    hardwareBuffer = hardwareBuffer,
                    width = width,
                    height = height,
                    timelinePtsUs = ptsUs,
                    frameIndex = frameIdx,
                )
                if (renderStr.startsWith("status=PASS;")) {
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
                    "outputSize=$outputSize;outputPath=$outputPath"
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
                    "outputPath=$outputPath"
            }

            return phase5Result(
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
            raw = phase5FailureRaw(
                "exception:$reason",
                width,
                height,
                frameCount,
                renderedFrames,
                writtenVideoSamples,
                outputPath,
            )
            Log.e(TAG, "$RESULT_MARKER_PHASE5 exception=$reason", throwable)
            return phase5Result(
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
            Log.i(TAG, "$RESULT_MARKER_PHASE5 $raw")
            val bridge = nativeBridge
            val sid = sessionId
            if (bridge != null && sid != null) {
                try { bridge.destroyAndroidDagPhase5EncoderSmokeSession(sid) } catch (_: Throwable) {}
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

    private fun phase5Result(
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
    )

    private fun phase5FailureRaw(
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
            "outputPath=$outputPath"
}
