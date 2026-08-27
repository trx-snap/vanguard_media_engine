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

    // ── Phase 1-Unit U: Android GLES backend offscreen EGL lifecycle smoke ──
    private const val RESULT_MARKER_PHASE1U = "ANDROID_GLES_BACKEND_UNIT_U_NATIVE_RESULT"

    fun runGlesBackendSmoke(): Map<String, Any?> {
        var raw = "status=FAIL;clientVersion=0;vendor=;renderer=;version=;initialize=not_run;idempotentInitialize=not_run;clear=not_run;swap=not_run;hasSurface=false;import=not_run;renderFrame=not_run;shutdown=not_run;idempotentShutdown=not_run;proofBoundary=offscreen_egl_pbuffer_no_window_surface;lastError=exception"
        try {
            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1UGlesBackendSmoke()
            return parseGlesBackendResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = "status=FAIL;clientVersion=0;vendor=;renderer=;version=;initialize=exception:$reason;idempotentInitialize=not_run;clear=not_run;swap=not_run;hasSurface=false;import=not_run;renderFrame=not_run;shutdown=not_run;idempotentShutdown=not_run;proofBoundary=offscreen_egl_pbuffer_no_window_surface;lastError=exception:$reason"
            return parseGlesBackendResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1U $raw")
        }
    }

    private fun parseGlesBackendResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val idempotentInitialize = parsed["idempotentInitialize"] ?: "not_run"
        val clear = parsed["clear"] ?: "not_run"
        val swap = parsed["swap"] ?: "not_run"
        val hasSurface = parsed["hasSurface"]?.equals("true", ignoreCase = true) ?: false
        val import = parsed["import"] ?: "not_run"
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "offscreen_egl_pbuffer_no_window_surface"

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "initialize" to initialize,
            "idempotentInitialize" to idempotentInitialize,
            "clear" to clear,
            "swap" to swap,
            "hasSurface" to hasSurface,
            "import" to import,
            "renderFrame" to renderFrame,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
        )
    }

    // ── Phase 1-Unit V: Android GLES backend window-surface attach/detach smoke ──
    private const val RESULT_MARKER_PHASE1V = "ANDROID_GLES_BACKEND_UNIT_V_NATIVE_RESULT"

    fun runGlesSurfaceSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var raw = glesSurfaceFailure("not_run", width, height)

        try {
            if (width <= 0 || height <= 0) {
                raw = glesSurfaceFailure("invalid_dimensions", width, height)
                return parseGlesSurfaceResult(raw)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1VGlesSurfaceSmoke(
                surface,
                width,
                height,
            )
            return parseGlesSurfaceResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesSurfaceFailure("exception:$reason", width, height)
            return parseGlesSurfaceResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1V $raw")
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

    private fun parseGlesSurfaceResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val initialSurfaceKind = parsed["initialSurfaceKind"] ?: "none"
        val firstAttach = parsed["firstAttach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val widthAfterAttach = parsed["widthAfterAttach"]?.toIntOrNull() ?: 0
        val heightAfterAttach = parsed["heightAfterAttach"]?.toIntOrNull() ?: 0
        val doubleAttach = parsed["doubleAttach"] ?: "not_run"
        val doubleAttachLastError = parsed["doubleAttachLastError"] ?: ""
        val resize = parsed["resize"] ?: "not_run"
        val resizeLastError = parsed["resizeLastError"] ?: ""
        val hasSurfaceAfterResize = parsed["hasSurfaceAfterResize"]?.equals("true", ignoreCase = true) ?: false
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val widthAfterDetach = parsed["widthAfterDetach"]?.toIntOrNull() ?: 0
        val heightAfterDetach = parsed["heightAfterDetach"]?.toIntOrNull() ?: 0
        val reattach = parsed["reattach"] ?: "not_run"
        val finalDetach = parsed["finalDetach"] ?: "not_run"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val import = parsed["import"] ?: "not_run"
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_window_surface_attach_detach_no_render"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "initialSurfaceKind" to initialSurfaceKind,
            "firstAttach" to firstAttach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "widthAfterAttach" to widthAfterAttach,
            "heightAfterAttach" to heightAfterAttach,
            "doubleAttach" to doubleAttach,
            "doubleAttachLastError" to doubleAttachLastError,
            "resize" to resize,
            "resizeLastError" to resizeLastError,
            "hasSurfaceAfterResize" to hasSurfaceAfterResize,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "widthAfterDetach" to widthAfterDetach,
            "heightAfterDetach" to heightAfterDetach,
            "reattach" to reattach,
            "finalDetach" to finalDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "import" to import,
            "renderFrame" to renderFrame,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesSurfaceFailure(reason: String, width: Int, height: Int): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;initialSurfaceKind=none;" +
            "firstAttach=$reason;hasSurfaceAfterAttach=false;widthAfterAttach=0;heightAfterAttach=0;" +
            "doubleAttach=not_run;doubleAttachLastError=;resize=not_run;resizeLastError=;" +
            "hasSurfaceAfterResize=false;detach=not_run;surfaceKindAfterDetach=none;widthAfterDetach=0;heightAfterDetach=0;" +
            "reattach=not_run;finalDetach=not_run;shutdown=not_run;idempotentShutdown=not_run;" +
            "import=not_run;renderFrame=not_run;proofBoundary=gles_window_surface_attach_detach_no_render;lastError=$reason"

    // ── Phase 1-Unit W: Android GLES backend window-surface clear/swap presentation diagnostic ──
    private const val RESULT_MARKER_PHASE1W = "ANDROID_GLES_BACKEND_UNIT_W_NATIVE_RESULT"

    fun runGlesWindowPresentSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var raw = glesWindowPresentFailure("not_run", width, height)

        try {
            if (width <= 0 || height <= 0) {
                raw = glesWindowPresentFailure("invalid_dimensions", width, height)
                return parseGlesWindowPresentResult(raw)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1WGlesWindowPresentSmoke(
                surface,
                width,
                height,
            )
            return parseGlesWindowPresentResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesWindowPresentFailure("exception:$reason", width, height)
            return parseGlesWindowPresentResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1W $raw")
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

    private fun parseGlesWindowPresentResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val preAttachPresent = parsed["preAttachPresent"] ?: "not_run"
        val preAttachLastError = parsed["preAttachLastError"] ?: ""
        val attach = parsed["attach"] ?: "not_run"
        val firstPresent = parsed["firstPresent"] ?: "not_run"
        val secondPresent = parsed["secondPresent"] ?: "not_run"
        val invalidColorPresent = parsed["invalidColorPresent"] ?: "not_run"
        val invalidColorLastError = parsed["invalidColorLastError"] ?: ""
        val hasSurfaceAfterPresent = parsed["hasSurfaceAfterPresent"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterPresent = parsed["surfaceKindAfterPresent"] ?: "none"
        val widthAfterPresent = parsed["widthAfterPresent"]?.toIntOrNull() ?: 0
        val heightAfterPresent = parsed["heightAfterPresent"]?.toIntOrNull() ?: 0
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val import = parsed["import"] ?: "not_run"
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_window_clear_swap_no_import_no_renderFrame"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "preAttachPresent" to preAttachPresent,
            "preAttachLastError" to preAttachLastError,
            "attach" to attach,
            "firstPresent" to firstPresent,
            "secondPresent" to secondPresent,
            "invalidColorPresent" to invalidColorPresent,
            "invalidColorLastError" to invalidColorLastError,
            "hasSurfaceAfterPresent" to hasSurfaceAfterPresent,
            "surfaceKindAfterPresent" to surfaceKindAfterPresent,
            "widthAfterPresent" to widthAfterPresent,
            "heightAfterPresent" to heightAfterPresent,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "import" to import,
            "renderFrame" to renderFrame,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesWindowPresentFailure(reason: String, width: Int, height: Int): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;preAttachPresent=not_run;preAttachLastError=;" +
            "attach=$reason;firstPresent=not_run;secondPresent=not_run;invalidColorPresent=not_run;invalidColorLastError=;" +
            "hasSurfaceAfterPresent=false;surfaceKindAfterPresent=none;widthAfterPresent=0;heightAfterPresent=0;" +
            "detach=not_run;surfaceKindAfterDetach=none;shutdown=not_run;idempotentShutdown=not_run;" +
            "import=not_run;renderFrame=not_run;proofBoundary=gles_window_clear_swap_no_import_no_renderFrame;lastError=$reason"

    // ── Phase 1-Unit X: Android GLES backend window-surface shader-quad draw/swap presentation diagnostic ──
    private const val RESULT_MARKER_PHASE1X = "ANDROID_GLES_BACKEND_UNIT_X_NATIVE_RESULT"

    fun runGlesShaderQuadSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var raw = glesShaderQuadFailure("not_run", width, height)

        try {
            if (width <= 0 || height <= 0) {
                raw = glesShaderQuadFailure("invalid_dimensions", width, height)
                return parseGlesShaderQuadResult(raw)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1XGlesShaderQuadSmoke(
                surface,
                width,
                height,
            )
            return parseGlesShaderQuadResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesShaderQuadFailure("exception:$reason", width, height)
            return parseGlesShaderQuadResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1X $raw")
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

    private fun parseGlesShaderQuadResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val preAttachShader = parsed["preAttachShader"] ?: "not_run"
        val preAttachLastError = parsed["preAttachLastError"] ?: ""
        val attach = parsed["attach"] ?: "not_run"
        val firstShaderQuad = parsed["firstShaderQuad"] ?: "not_run"
        val secondShaderQuad = parsed["secondShaderQuad"] ?: "not_run"
        val invalidColorShaderQuad = parsed["invalidColorShaderQuad"] ?: "not_run"
        val invalidColorLastError = parsed["invalidColorLastError"] ?: ""
        val clearAfterShader = parsed["clearAfterShader"] ?: "not_run"
        val hasSurfaceAfterShader = parsed["hasSurfaceAfterShader"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterShader = parsed["surfaceKindAfterShader"] ?: "none"
        val widthAfterShader = parsed["widthAfterShader"]?.toIntOrNull() ?: 0
        val heightAfterShader = parsed["heightAfterShader"]?.toIntOrNull() ?: 0
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val import = parsed["import"] ?: "not_run"
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_window_shader_quad_no_import_no_renderFrame"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "preAttachShader" to preAttachShader,
            "preAttachLastError" to preAttachLastError,
            "attach" to attach,
            "firstShaderQuad" to firstShaderQuad,
            "secondShaderQuad" to secondShaderQuad,
            "invalidColorShaderQuad" to invalidColorShaderQuad,
            "invalidColorLastError" to invalidColorLastError,
            "clearAfterShader" to clearAfterShader,
            "hasSurfaceAfterShader" to hasSurfaceAfterShader,
            "surfaceKindAfterShader" to surfaceKindAfterShader,
            "widthAfterShader" to widthAfterShader,
            "heightAfterShader" to heightAfterShader,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "import" to import,
            "renderFrame" to renderFrame,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesShaderQuadFailure(reason: String, width: Int, height: Int): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;preAttachShader=not_run;preAttachLastError=;" +
            "attach=$reason;firstShaderQuad=not_run;secondShaderQuad=not_run;invalidColorShaderQuad=not_run;invalidColorLastError=;" +
            "clearAfterShader=not_run;hasSurfaceAfterShader=false;surfaceKindAfterShader=none;widthAfterShader=0;heightAfterShader=0;" +
            "detach=not_run;surfaceKindAfterDetach=none;shutdown=not_run;idempotentShutdown=not_run;" +
            "import=not_run;renderFrame=not_run;proofBoundary=gles_window_shader_quad_no_import_no_renderFrame;lastError=$reason"

    // ── Phase 1-Unit Y: Android GLES backend AHardwareBuffer RGBA import foundation smoke ──
    private const val RESULT_MARKER_PHASE1Y = "ANDROID_GLES_IMPORT_UNIT_Y_NATIVE_RESULT"

    fun runGlesImportSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var bufferA: HardwareBuffer? = null
        var bufferB: HardwareBuffer? = null
        var raw = glesImportFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesImportFailure("api_below_26")
                return parseGlesImportResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesImportFailure("invalid_dimensions")
                return parseGlesImportResult(raw)
            }

            bufferA = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
            bufferB = HardwareBuffer.create(
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
            raw = nativeBridge.runAndroidDagPhase1YGlesImportSmoke(
                bufferA,
                bufferB,
                width,
                height,
            )
            return parseGlesImportResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesImportFailure("exception:$reason")
            return parseGlesImportResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1Y $raw")
            try {
                bufferA?.close()
            } catch (_: Throwable) {
            }
            try {
                bufferB?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun parseGlesImportResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val preInitImport = parsed["preInitImport"] ?: "not_run"
        val preInitHandle = parsed["preInitHandle"]?.toLongOrNull() ?: 0L
        val preInitDescriptorZero = parsed["preInitDescriptorZero"]?.equals("true", ignoreCase = true) ?: false
        val initialize = parsed["initialize"] ?: "not_run"
        val nullBufferImport = parsed["nullBufferImport"] ?: "not_run"
        val nullHandleImport = parsed["nullHandleImport"] ?: "not_run"
        val nullDescriptorImport = parsed["nullDescriptorImport"] ?: "not_run"
        val validImportA = parsed["validImportA"] ?: "not_run"
        val handleA = parsed["handleA"]?.toLongOrNull() ?: 0L
        val descriptorWidth = parsed["descriptorWidth"]?.toIntOrNull() ?: 0
        val descriptorHeight = parsed["descriptorHeight"]?.toIntOrNull() ?: 0
        val descriptorLayers = parsed["descriptorLayers"]?.toIntOrNull() ?: 0
        val descriptorFormat = parsed["descriptorFormat"]?.toIntOrNull() ?: 0
        val descriptorUsageSampled = parsed["descriptorUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAAfterImport = parsed["hasAAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val duplicateImport = parsed["duplicateImport"] ?: "not_run"
        val duplicateHandle = parsed["duplicateHandle"]?.toLongOrNull() ?: 0L
        val hasAAfterDuplicate = parsed["hasAAfterDuplicate"]?.equals("true", ignoreCase = true) ?: false
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val validImportB = parsed["validImportB"] ?: "not_run"
        val handleB = parsed["handleB"]?.toLongOrNull() ?: 0L
        val distinctHandles = parsed["distinctHandles"]?.equals("true", ignoreCase = true) ?: false
        val hasBAfterImport = parsed["hasBAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val releaseA = parsed["releaseA"] ?: "not_run"
        val releaseAFence = parsed["releaseAFence"]?.toIntOrNull() ?: -1
        val hasAAfterRelease = parsed["hasAAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val doubleReleaseA = parsed["doubleReleaseA"] ?: "not_run"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val hasBAfterShutdown = parsed["hasBAfterShutdown"]?.equals("true", ignoreCase = true) ?: false
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_ahb_rgba_import_no_renderFrame"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "preInitImport" to preInitImport,
            "preInitHandle" to preInitHandle,
            "preInitDescriptorZero" to preInitDescriptorZero,
            "initialize" to initialize,
            "nullBufferImport" to nullBufferImport,
            "nullHandleImport" to nullHandleImport,
            "nullDescriptorImport" to nullDescriptorImport,
            "validImportA" to validImportA,
            "handleA" to handleA,
            "descriptorWidth" to descriptorWidth,
            "descriptorHeight" to descriptorHeight,
            "descriptorLayers" to descriptorLayers,
            "descriptorFormat" to descriptorFormat,
            "descriptorUsageSampled" to descriptorUsageSampled,
            "hasAAfterImport" to hasAAfterImport,
            "duplicateImport" to duplicateImport,
            "duplicateHandle" to duplicateHandle,
            "hasAAfterDuplicate" to hasAAfterDuplicate,
            "renderFrame" to renderFrame,
            "validImportB" to validImportB,
            "handleB" to handleB,
            "distinctHandles" to distinctHandles,
            "hasBAfterImport" to hasBAfterImport,
            "releaseA" to releaseA,
            "releaseAFence" to releaseAFence,
            "hasAAfterRelease" to hasAAfterRelease,
            "doubleReleaseA" to doubleReleaseA,
            "shutdown" to shutdown,
            "hasBAfterShutdown" to hasBAfterShutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesImportFailure(reason: String): String =
        "status=FAIL;preInitImport=$reason;preInitHandle=0;preInitDescriptorZero=false;" +
            "initialize=not_run;nullBufferImport=not_run;nullHandleImport=not_run;nullDescriptorImport=not_run;" +
            "validImportA=not_run;handleA=0;descriptorWidth=0;descriptorHeight=0;descriptorLayers=0;descriptorFormat=0;" +
            "descriptorUsageSampled=false;hasAAfterImport=false;duplicateImport=not_run;duplicateHandle=0;hasAAfterDuplicate=false;" +
            "renderFrame=not_run;validImportB=not_run;handleB=0;distinctHandles=false;hasBAfterImport=false;" +
            "releaseA=not_run;releaseAFence=-1;hasAAfterRelease=false;doubleReleaseA=not_run;shutdown=not_run;" +
            "hasBAfterShutdown=false;idempotentShutdown=not_run;proofBoundary=gles_ahb_rgba_import_no_renderFrame;lastError=$reason"

    // ── Phase 1-Unit Z: Android GLES backend identity renderFrame textured-quad presentation smoke ──
    private const val RESULT_MARKER_PHASE1Z = "ANDROID_GLES_RENDERFRAME_UNIT_Z_NATIVE_RESULT"

    fun runGlesRenderFrameSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var bufferA: HardwareBuffer? = null
        var bufferB: HardwareBuffer? = null
        var raw = glesRenderFrameFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesRenderFrameFailure("api_below_26")
                return parseGlesRenderFrameResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesRenderFrameFailure("invalid_dimensions")
                return parseGlesRenderFrameResult(raw)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

            bufferA = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
            bufferB = HardwareBuffer.create(
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
            raw = nativeBridge.runAndroidDagPhase1ZGlesRenderFrameSmoke(
                surface,
                bufferA,
                bufferB,
                width,
                height,
            )
            return parseGlesRenderFrameResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesRenderFrameFailure("exception:$reason")
            return parseGlesRenderFrameResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1Z $raw")
            try {
                bufferA?.close()
            } catch (_: Throwable) {
            }
            try {
                bufferB?.close()
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

    private fun parseGlesRenderFrameResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val preInitRender = parsed["preInitRender"] ?: "not_run"
        val preInitLastError = parsed["preInitLastError"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val importA = parsed["importA"] ?: "not_run"
        val handleA = parsed["handleA"]?.toLongOrNull() ?: 0L
        val descriptorWidth = parsed["descriptorWidth"]?.toIntOrNull() ?: 0
        val descriptorHeight = parsed["descriptorHeight"]?.toIntOrNull() ?: 0
        val descriptorLayers = parsed["descriptorLayers"]?.toIntOrNull() ?: 0
        val descriptorFormat = parsed["descriptorFormat"]?.toIntOrNull() ?: 0
        val descriptorUsageSampled = parsed["descriptorUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAAfterImport = parsed["hasAAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val preAttachRender = parsed["preAttachRender"] ?: "not_run"
        val preAttachLastError = parsed["preAttachLastError"] ?: ""
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterAttach = parsed["surfaceKindAfterAttach"] ?: "none"
        val widthAfterAttach = parsed["widthAfterAttach"]?.toIntOrNull() ?: 0
        val heightAfterAttach = parsed["heightAfterAttach"]?.toIntOrNull() ?: 0
        val invalidHandleRender = parsed["invalidHandleRender"] ?: "not_run"
        val invalidHandleLastError = parsed["invalidHandleLastError"] ?: ""
        val firstRenderA = parsed["firstRenderA"] ?: "not_run"
        val firstRenderALastError = parsed["firstRenderALastError"] ?: ""
        val secondRenderA = parsed["secondRenderA"] ?: "not_run"
        val hasSurfaceAfterSecond = parsed["hasSurfaceAfterSecond"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterSecond = parsed["surfaceKindAfterSecond"] ?: "none"
        val widthAfterSecond = parsed["widthAfterSecond"]?.toIntOrNull() ?: 0
        val heightAfterSecond = parsed["heightAfterSecond"]?.toIntOrNull() ?: 0
        val importB = parsed["importB"] ?: "not_run"
        val handleB = parsed["handleB"]?.toLongOrNull() ?: 0L
        val distinctHandles = parsed["distinctHandles"]?.equals("true", ignoreCase = true) ?: false
        val hasBAfterImport = parsed["hasBAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val renderB = parsed["renderB"] ?: "not_run"
        val renderBLastError = parsed["renderBLastError"] ?: ""
        val identityTransformRender = parsed["identityTransformRender"] ?: "not_run"
        val nonIdentityTransformRender = parsed["nonIdentityTransformRender"] ?: "not_run"
        val nonIdentityTransformLastError = parsed["nonIdentityTransformLastError"] ?: ""
        val hasSurfaceAfterTransform = parsed["hasSurfaceAfterTransform"]?.equals("true", ignoreCase = true) ?: false
        val rot180TransformRender = parsed["rot180TransformRender"] ?: "not_run"
        val rot180TransformLastError = parsed["rot180TransformLastError"] ?: ""
        val rot270TransformRender = parsed["rot270TransformRender"] ?: "not_run"
        val rot270TransformLastError = parsed["rot270TransformLastError"] ?: ""
        val mirrorTransformRender = parsed["mirrorTransformRender"] ?: "not_run"
        val mirrorTransformLastError = parsed["mirrorTransformLastError"] ?: ""
        val hasSurfaceAfterAllTransforms = parsed["hasSurfaceAfterAllTransforms"]?.equals("true", ignoreCase = true) ?: false
        val releaseA = parsed["releaseA"] ?: "not_run"
        val releaseAFence = parsed["releaseAFence"]?.toIntOrNull() ?: -1
        val hasAAfterRelease = parsed["hasAAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val hasBAfterReleaseA = parsed["hasBAfterReleaseA"]?.equals("true", ignoreCase = true) ?: false
        val releasedHandleRender = parsed["releasedHandleRender"] ?: "not_run"
        val releasedHandleLastError = parsed["releasedHandleLastError"] ?: ""
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val postDetachRenderB = parsed["postDetachRenderB"] ?: "not_run"
        val postDetachLastError = parsed["postDetachLastError"] ?: ""
        val shutdown = parsed["shutdown"] ?: "not_run"
        val hasBAfterShutdown = parsed["hasBAfterShutdown"]?.equals("true", ignoreCase = true) ?: false
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_renderFrame_rgba_texture_quad_transform_uv_no_yuv_no_fence_sync"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "preInitRender" to preInitRender,
            "preInitLastError" to preInitLastError,
            "initialize" to initialize,
            "importA" to importA,
            "handleA" to handleA,
            "descriptorWidth" to descriptorWidth,
            "descriptorHeight" to descriptorHeight,
            "descriptorLayers" to descriptorLayers,
            "descriptorFormat" to descriptorFormat,
            "descriptorUsageSampled" to descriptorUsageSampled,
            "hasAAfterImport" to hasAAfterImport,
            "preAttachRender" to preAttachRender,
            "preAttachLastError" to preAttachLastError,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "surfaceKindAfterAttach" to surfaceKindAfterAttach,
            "widthAfterAttach" to widthAfterAttach,
            "heightAfterAttach" to heightAfterAttach,
            "invalidHandleRender" to invalidHandleRender,
            "invalidHandleLastError" to invalidHandleLastError,
            "firstRenderA" to firstRenderA,
            "firstRenderALastError" to firstRenderALastError,
            "secondRenderA" to secondRenderA,
            "hasSurfaceAfterSecond" to hasSurfaceAfterSecond,
            "surfaceKindAfterSecond" to surfaceKindAfterSecond,
            "widthAfterSecond" to widthAfterSecond,
            "heightAfterSecond" to heightAfterSecond,
            "importB" to importB,
            "handleB" to handleB,
            "distinctHandles" to distinctHandles,
            "hasBAfterImport" to hasBAfterImport,
            "renderB" to renderB,
            "renderBLastError" to renderBLastError,
            "identityTransformRender" to identityTransformRender,
            "nonIdentityTransformRender" to nonIdentityTransformRender,
            "nonIdentityTransformLastError" to nonIdentityTransformLastError,
            "hasSurfaceAfterTransform" to hasSurfaceAfterTransform,
            "rot180TransformRender" to rot180TransformRender,
            "rot180TransformLastError" to rot180TransformLastError,
            "rot270TransformRender" to rot270TransformRender,
            "rot270TransformLastError" to rot270TransformLastError,
            "mirrorTransformRender" to mirrorTransformRender,
            "mirrorTransformLastError" to mirrorTransformLastError,
            "hasSurfaceAfterAllTransforms" to hasSurfaceAfterAllTransforms,
            "releaseA" to releaseA,
            "releaseAFence" to releaseAFence,
            "hasAAfterRelease" to hasAAfterRelease,
            "hasBAfterReleaseA" to hasBAfterReleaseA,
            "releasedHandleRender" to releasedHandleRender,
            "releasedHandleLastError" to releasedHandleLastError,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "postDetachRenderB" to postDetachRenderB,
            "postDetachLastError" to postDetachLastError,
            "shutdown" to shutdown,
            "hasBAfterShutdown" to hasBAfterShutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesRenderFrameFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;preInitRender=$reason;preInitLastError=;" +
            "initialize=not_run;importA=not_run;handleA=0;descriptorWidth=0;descriptorHeight=0;descriptorLayers=0;descriptorFormat=0;" +
            "descriptorUsageSampled=false;hasAAfterImport=false;preAttachRender=not_run;preAttachLastError=;" +
            "attach=not_run;hasSurfaceAfterAttach=false;surfaceKindAfterAttach=none;widthAfterAttach=0;heightAfterAttach=0;" +
            "invalidHandleRender=not_run;invalidHandleLastError=;firstRenderA=not_run;firstRenderALastError=;" +
            "secondRenderA=not_run;hasSurfaceAfterSecond=false;surfaceKindAfterSecond=none;widthAfterSecond=0;heightAfterSecond=0;" +
            "importB=not_run;handleB=0;distinctHandles=false;hasBAfterImport=false;renderB=not_run;renderBLastError=;" +
            "identityTransformRender=not_run;nonIdentityTransformRender=not_run;nonIdentityTransformLastError=;hasSurfaceAfterTransform=false;" +
            "rot180TransformRender=not_run;rot180TransformLastError=;rot270TransformRender=not_run;rot270TransformLastError=;" +
            "mirrorTransformRender=not_run;mirrorTransformLastError=;hasSurfaceAfterAllTransforms=false;" +
            "releaseA=not_run;releaseAFence=-1;hasAAfterRelease=false;hasBAfterReleaseA=false;releasedHandleRender=not_run;releasedHandleLastError=;" +
            "detach=not_run;surfaceKindAfterDetach=none;postDetachRenderB=not_run;postDetachLastError=;shutdown=not_run;" +
            "hasBAfterShutdown=false;idempotentShutdown=not_run;proofBoundary=gles_renderFrame_rgba_texture_quad_transform_uv_no_yuv_no_fence_sync;lastError=$reason"

    // ── Phase 1-Unit AB: Android GLES backend diagnostic read-pixels physical smoke ──
    private const val RESULT_MARKER_PHASE1AB = "ANDROID_GLES_READ_PIXELS_UNIT_AB_NATIVE_RESULT"

    fun runGlesReadPixelsSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var raw = glesReadPixelsFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesReadPixelsFailure("api_below_26")
                return parseGlesReadPixelsResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesReadPixelsFailure("invalid_dimensions")
                return parseGlesReadPixelsResult(raw)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1ABGlesReadPixelsSmoke(
                surface,
                width,
                height,
            )
            return parseGlesReadPixelsResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesReadPixelsFailure("exception:$reason")
            return parseGlesReadPixelsResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AB $raw")
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

    private fun parseGlesReadPixelsResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val preInitRead = parsed["preInitRead"] ?: "not_run"
        val preInitLastError = parsed["preInitLastError"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val preAttachRead = parsed["preAttachRead"] ?: "not_run"
        val preAttachLastError = parsed["preAttachLastError"] ?: ""
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterAttach = parsed["surfaceKindAfterAttach"] ?: "none"
        val widthAfterAttach = parsed["widthAfterAttach"]?.toIntOrNull() ?: 0
        val heightAfterAttach = parsed["heightAfterAttach"]?.toIntOrNull() ?: 0
        val nullRead = parsed["nullRead"] ?: "not_run"
        val nullReadLastError = parsed["nullReadLastError"] ?: ""
        val zeroRead = parsed["zeroRead"] ?: "not_run"
        val zeroReadLastError = parsed["zeroReadLastError"] ?: ""
        val smallCapacityRead = parsed["smallCapacityRead"] ?: "not_run"
        val smallCapacityLastError = parsed["smallCapacityLastError"] ?: ""
        val outOfBoundsRead = parsed["outOfBoundsRead"] ?: "not_run"
        val outOfBoundsLastError = parsed["outOfBoundsLastError"] ?: ""
        val directClearForReadback = parsed["directClearForReadback"] ?: "not_run"
        val centerRead = parsed["centerRead"] ?: "not_run"
        val centerReadLastError = parsed["centerReadLastError"] ?: ""
        val centerR = parsed["centerR"]?.toIntOrNull() ?: 0
        val centerG = parsed["centerG"]?.toIntOrNull() ?: 0
        val centerB = parsed["centerB"]?.toIntOrNull() ?: 0
        val centerA = parsed["centerA"]?.toIntOrNull() ?: 0
        val centerPixelMatches = parsed["centerPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val fullRead = parsed["fullRead"] ?: "not_run"
        val fullReadLastError = parsed["fullReadLastError"] ?: ""
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val postDetachRead = parsed["postDetachRead"] ?: "not_run"
        val postDetachLastError = parsed["postDetachLastError"] ?: ""
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_diagnostic_read_pixels_rgba_window_surface_no_yuv_no_fence_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "preInitRead" to preInitRead,
            "preInitLastError" to preInitLastError,
            "initialize" to initialize,
            "preAttachRead" to preAttachRead,
            "preAttachLastError" to preAttachLastError,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "surfaceKindAfterAttach" to surfaceKindAfterAttach,
            "widthAfterAttach" to widthAfterAttach,
            "heightAfterAttach" to heightAfterAttach,
            "nullRead" to nullRead,
            "nullReadLastError" to nullReadLastError,
            "zeroRead" to zeroRead,
            "zeroReadLastError" to zeroReadLastError,
            "smallCapacityRead" to smallCapacityRead,
            "smallCapacityLastError" to smallCapacityLastError,
            "outOfBoundsRead" to outOfBoundsRead,
            "outOfBoundsLastError" to outOfBoundsLastError,
            "directClearForReadback" to directClearForReadback,
            "centerRead" to centerRead,
            "centerReadLastError" to centerReadLastError,
            "centerR" to centerR,
            "centerG" to centerG,
            "centerB" to centerB,
            "centerA" to centerA,
            "centerPixelMatches" to centerPixelMatches,
            "fullRead" to fullRead,
            "fullReadLastError" to fullReadLastError,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "postDetachRead" to postDetachRead,
            "postDetachLastError" to postDetachLastError,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesReadPixelsFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;preInitRead=$reason;preInitLastError=;" +
            "initialize=not_run;preAttachRead=not_run;preAttachLastError=;attach=not_run;hasSurfaceAfterAttach=false;" +
            "surfaceKindAfterAttach=none;widthAfterAttach=0;heightAfterAttach=0;nullRead=not_run;nullReadLastError=;" +
            "zeroRead=not_run;zeroReadLastError=;smallCapacityRead=not_run;smallCapacityLastError=;" +
            "outOfBoundsRead=not_run;outOfBoundsLastError=;directClearForReadback=not_run;centerRead=not_run;centerReadLastError=;" +
            "centerR=0;centerG=0;centerB=0;centerA=0;centerPixelMatches=false;fullRead=not_run;fullReadLastError=;" +
            "detach=not_run;surfaceKindAfterDetach=none;postDetachRead=not_run;postDetachLastError=;shutdown=not_run;" +
            "idempotentShutdown=not_run;proofBoundary=gles_diagnostic_read_pixels_rgba_window_surface_no_yuv_no_fence_no_product;lastError=$reason"

    // ── Phase 1-Unit AC: Android GLES renderFrame texture-content readback physical smoke ──
    private const val RESULT_MARKER_PHASE1AC = "ANDROID_GLES_RENDERFRAME_CONTENT_UNIT_AC_NATIVE_RESULT"

    fun runGlesRenderFrameContentSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesRenderFrameContentFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesRenderFrameContentFailure("api_below_26")
                return parseGlesRenderFrameContentResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesRenderFrameContentFailure("invalid_dimensions")
                return parseGlesRenderFrameContentResult(raw)
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
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1ACGlesRenderFrameContentSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesRenderFrameContentResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesRenderFrameContentFailure("exception:$reason")
            return parseGlesRenderFrameContentResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AC $raw")
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

    private fun parseGlesRenderFrameContentResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val bufferDescribe = parsed["bufferDescribe"] ?: "not_run"
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val bufferUsage = parsed["bufferUsage"]?.toLongOrNull() ?: 0L
        val bufferStride = parsed["bufferStride"]?.toIntOrNull() ?: 0
        val bufferFill = parsed["bufferFill"] ?: "not_run"
        val writeFenceFd = parsed["writeFenceFd"]?.toIntOrNull() ?: -1
        val writeFenceWait = parsed["writeFenceWait"] ?: "none"
        val preInitDiagnosticRender = parsed["preInitDiagnosticRender"] ?: "not_run"
        val preInitLastError = parsed["preInitLastError"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterAttach = parsed["surfaceKindAfterAttach"] ?: "none"
        val widthAfterAttach = parsed["widthAfterAttach"]?.toIntOrNull() ?: 0
        val heightAfterAttach = parsed["heightAfterAttach"]?.toIntOrNull() ?: 0
        val importBuffer = parsed["importBuffer"] ?: "not_run"
        val handle = parsed["handle"]?.toLongOrNull() ?: 0L
        val descriptorWidth = parsed["descriptorWidth"]?.toIntOrNull() ?: 0
        val descriptorHeight = parsed["descriptorHeight"]?.toIntOrNull() ?: 0
        val descriptorLayers = parsed["descriptorLayers"]?.toIntOrNull() ?: 0
        val descriptorFormat = parsed["descriptorFormat"]?.toIntOrNull() ?: 0
        val descriptorUsageSampled = parsed["descriptorUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport = parsed["hasAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val invalidHandleDiagnosticRender = parsed["invalidHandleDiagnosticRender"] ?: "not_run"
        val invalidHandleLastError = parsed["invalidHandleLastError"] ?: ""
        val identityDiagnosticRender = parsed["identityDiagnosticRender"] ?: "not_run"
        val identityDiagnosticLastError = parsed["identityDiagnosticLastError"] ?: ""
        val identityCenterRead = parsed["identityCenterRead"] ?: "not_run"
        val identityCenterReadLastError = parsed["identityCenterReadLastError"] ?: ""
        val identityCenterR = parsed["identityCenterR"]?.toIntOrNull() ?: 0
        val identityCenterG = parsed["identityCenterG"]?.toIntOrNull() ?: 0
        val identityCenterB = parsed["identityCenterB"]?.toIntOrNull() ?: 0
        val identityCenterA = parsed["identityCenterA"]?.toIntOrNull() ?: 0
        val identityCenterPixelMatches = parsed["identityCenterPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val rot90DiagnosticRender = parsed["rot90DiagnosticRender"] ?: "not_run"
        val rot90DiagnosticLastError = parsed["rot90DiagnosticLastError"] ?: ""
        val rot90CenterRead = parsed["rot90CenterRead"] ?: "not_run"
        val rot90CenterReadLastError = parsed["rot90CenterReadLastError"] ?: ""
        val rot90CenterR = parsed["rot90CenterR"]?.toIntOrNull() ?: 0
        val rot90CenterG = parsed["rot90CenterG"]?.toIntOrNull() ?: 0
        val rot90CenterB = parsed["rot90CenterB"]?.toIntOrNull() ?: 0
        val rot90CenterA = parsed["rot90CenterA"]?.toIntOrNull() ?: 0
        val rot90CenterPixelMatches = parsed["rot90CenterPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val releaseBuffer = parsed["releaseBuffer"] ?: "not_run"
        val releaseFence = parsed["releaseFence"]?.toIntOrNull() ?: -1
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val postReleaseDiagnosticRender = parsed["postReleaseDiagnosticRender"] ?: "not_run"
        val postReleaseLastError = parsed["postReleaseLastError"] ?: ""
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val postDetachRead = parsed["postDetachRead"] ?: "not_run"
        val postDetachLastError = parsed["postDetachLastError"] ?: ""
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_renderFrame_rgba_texture_content_readback_no_swap_no_yuv_no_fence_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "bufferUsage" to bufferUsage,
            "bufferStride" to bufferStride,
            "bufferFill" to bufferFill,
            "writeFenceFd" to writeFenceFd,
            "writeFenceWait" to writeFenceWait,
            "preInitDiagnosticRender" to preInitDiagnosticRender,
            "preInitLastError" to preInitLastError,
            "initialize" to initialize,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "surfaceKindAfterAttach" to surfaceKindAfterAttach,
            "widthAfterAttach" to widthAfterAttach,
            "heightAfterAttach" to heightAfterAttach,
            "importBuffer" to importBuffer,
            "handle" to handle,
            "descriptorWidth" to descriptorWidth,
            "descriptorHeight" to descriptorHeight,
            "descriptorLayers" to descriptorLayers,
            "descriptorFormat" to descriptorFormat,
            "descriptorUsageSampled" to descriptorUsageSampled,
            "hasAfterImport" to hasAfterImport,
            "invalidHandleDiagnosticRender" to invalidHandleDiagnosticRender,
            "invalidHandleLastError" to invalidHandleLastError,
            "identityDiagnosticRender" to identityDiagnosticRender,
            "identityDiagnosticLastError" to identityDiagnosticLastError,
            "identityCenterRead" to identityCenterRead,
            "identityCenterReadLastError" to identityCenterReadLastError,
            "identityCenterR" to identityCenterR,
            "identityCenterG" to identityCenterG,
            "identityCenterB" to identityCenterB,
            "identityCenterA" to identityCenterA,
            "identityCenterPixelMatches" to identityCenterPixelMatches,
            "rot90DiagnosticRender" to rot90DiagnosticRender,
            "rot90DiagnosticLastError" to rot90DiagnosticLastError,
            "rot90CenterRead" to rot90CenterRead,
            "rot90CenterReadLastError" to rot90CenterReadLastError,
            "rot90CenterR" to rot90CenterR,
            "rot90CenterG" to rot90CenterG,
            "rot90CenterB" to rot90CenterB,
            "rot90CenterA" to rot90CenterA,
            "rot90CenterPixelMatches" to rot90CenterPixelMatches,
            "releaseBuffer" to releaseBuffer,
            "releaseFence" to releaseFence,
            "hasAfterRelease" to hasAfterRelease,
            "postReleaseDiagnosticRender" to postReleaseDiagnosticRender,
            "postReleaseLastError" to postReleaseLastError,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "postDetachRead" to postDetachRead,
            "postDetachLastError" to postDetachLastError,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesRenderFrameContentFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=$reason;bufferWidth=0;bufferHeight=0;" +
            "bufferLayers=0;bufferFormat=0;bufferUsage=0;bufferStride=0;bufferFill=not_run;writeFenceFd=-1;writeFenceWait=none;" +
            "preInitDiagnosticRender=not_run;preInitLastError=;initialize=not_run;attach=not_run;hasSurfaceAfterAttach=false;" +
            "surfaceKindAfterAttach=none;widthAfterAttach=0;heightAfterAttach=0;importBuffer=not_run;handle=0;" +
            "descriptorWidth=0;descriptorHeight=0;descriptorLayers=0;descriptorFormat=0;descriptorUsageSampled=false;" +
            "hasAfterImport=false;invalidHandleDiagnosticRender=not_run;invalidHandleLastError=;identityDiagnosticRender=not_run;" +
            "identityDiagnosticLastError=;identityCenterRead=not_run;identityCenterReadLastError=;identityCenterR=0;identityCenterG=0;" +
            "identityCenterB=0;identityCenterA=0;identityCenterPixelMatches=false;rot90DiagnosticRender=not_run;rot90DiagnosticLastError=;" +
            "rot90CenterRead=not_run;rot90CenterReadLastError=;rot90CenterR=0;rot90CenterG=0;rot90CenterB=0;rot90CenterA=0;" +
            "rot90CenterPixelMatches=false;releaseBuffer=not_run;releaseFence=-1;hasAfterRelease=false;postReleaseDiagnosticRender=not_run;" +
            "postReleaseLastError=;detach=not_run;surfaceKindAfterDetach=none;postDetachRead=not_run;postDetachLastError=;" +
            "shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_renderFrame_rgba_texture_content_readback_no_swap_no_yuv_no_fence_no_product;lastError=$reason"

    // ── Phase 1-Unit AD: Android GLES renderFrame asymmetric UV mapping physical smoke ──
    private const val RESULT_MARKER_PHASE1AD = "ANDROID_GLES_RENDERFRAME_TRANSFORM_MAPPING_UNIT_AD_NATIVE_RESULT"

    fun runGlesRenderFrameTransformMappingSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesRenderFrameTransformMappingFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesRenderFrameTransformMappingFailure("api_below_26")
                return parseGlesRenderFrameTransformMappingResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesRenderFrameTransformMappingFailure("invalid_dimensions")
                return parseGlesRenderFrameTransformMappingResult(raw)
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
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1ADGlesRenderFrameTransformMappingSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesRenderFrameTransformMappingResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesRenderFrameTransformMappingFailure("exception:$reason")
            return parseGlesRenderFrameTransformMappingResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AD $raw")
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

    private fun parseGlesRenderFrameTransformMappingResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val bufferDescribe = parsed["bufferDescribe"] ?: "not_run"
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val bufferUsage = parsed["bufferUsage"]?.toLongOrNull() ?: 0L
        val bufferStride = parsed["bufferStride"]?.toIntOrNull() ?: 0
        val bufferFill = parsed["bufferFill"] ?: "not_run"
        val writeFenceFd = parsed["writeFenceFd"]?.toIntOrNull() ?: -1
        val writeFenceWait = parsed["writeFenceWait"] ?: "none"
        val preInitDiagnosticRender = parsed["preInitDiagnosticRender"] ?: "not_run"
        val preInitLastError = parsed["preInitLastError"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterAttach = parsed["surfaceKindAfterAttach"] ?: "none"
        val widthAfterAttach = parsed["widthAfterAttach"]?.toIntOrNull() ?: 0
        val heightAfterAttach = parsed["heightAfterAttach"]?.toIntOrNull() ?: 0
        val importBuffer = parsed["importBuffer"] ?: "not_run"
        val handle = parsed["handle"]?.toLongOrNull() ?: 0L
        val descriptorWidth = parsed["descriptorWidth"]?.toIntOrNull() ?: 0
        val descriptorHeight = parsed["descriptorHeight"]?.toIntOrNull() ?: 0
        val descriptorLayers = parsed["descriptorLayers"]?.toIntOrNull() ?: 0
        val descriptorFormat = parsed["descriptorFormat"]?.toIntOrNull() ?: 0
        val descriptorUsageSampled = parsed["descriptorUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport = parsed["hasAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val invalidHandleDiagnosticRender = parsed["invalidHandleDiagnosticRender"] ?: "not_run"
        val invalidHandleLastError = parsed["invalidHandleLastError"] ?: ""
        val identityDiagnosticRender = parsed["identityDiagnosticRender"] ?: "not_run"
        val identityDiagnosticLastError = parsed["identityDiagnosticLastError"] ?: ""
        val identityColorsDistinct = parsed["identityColorsDistinct"]?.equals("true", ignoreCase = true) ?: false
        val uv00R = parsed["uv00R"]?.toIntOrNull() ?: 0
        val uv00G = parsed["uv00G"]?.toIntOrNull() ?: 0
        val uv00B = parsed["uv00B"]?.toIntOrNull() ?: 0
        val uv00A = parsed["uv00A"]?.toIntOrNull() ?: 0
        val uv00Label = parsed["uv00Label"] ?: "unknown"
        val uv10R = parsed["uv10R"]?.toIntOrNull() ?: 0
        val uv10G = parsed["uv10G"]?.toIntOrNull() ?: 0
        val uv10B = parsed["uv10B"]?.toIntOrNull() ?: 0
        val uv10A = parsed["uv10A"]?.toIntOrNull() ?: 0
        val uv10Label = parsed["uv10Label"] ?: "unknown"
        val uv01R = parsed["uv01R"]?.toIntOrNull() ?: 0
        val uv01G = parsed["uv01G"]?.toIntOrNull() ?: 0
        val uv01B = parsed["uv01B"]?.toIntOrNull() ?: 0
        val uv01A = parsed["uv01A"]?.toIntOrNull() ?: 0
        val uv01Label = parsed["uv01Label"] ?: "unknown"
        val uv11R = parsed["uv11R"]?.toIntOrNull() ?: 0
        val uv11G = parsed["uv11G"]?.toIntOrNull() ?: 0
        val uv11B = parsed["uv11B"]?.toIntOrNull() ?: 0
        val uv11A = parsed["uv11A"]?.toIntOrNull() ?: 0
        val uv11Label = parsed["uv11Label"] ?: "unknown"
        val identityPass = parsed["identityPass"]?.equals("true", ignoreCase = true) ?: false
        val rot90DiagnosticRender = parsed["rot90DiagnosticRender"] ?: "not_run"
        val rot90DiagnosticLastError = parsed["rot90DiagnosticLastError"] ?: ""
        val rot90Pass = parsed["rot90Pass"]?.equals("true", ignoreCase = true) ?: false
        val rot180DiagnosticRender = parsed["rot180DiagnosticRender"] ?: "not_run"
        val rot180DiagnosticLastError = parsed["rot180DiagnosticLastError"] ?: ""
        val rot180Pass = parsed["rot180Pass"]?.equals("true", ignoreCase = true) ?: false
        val rot270DiagnosticRender = parsed["rot270DiagnosticRender"] ?: "not_run"
        val rot270DiagnosticLastError = parsed["rot270DiagnosticLastError"] ?: ""
        val rot270Pass = parsed["rot270Pass"]?.equals("true", ignoreCase = true) ?: false
        val mirror0DiagnosticRender = parsed["mirror0DiagnosticRender"] ?: "not_run"
        val mirror0DiagnosticLastError = parsed["mirror0DiagnosticLastError"] ?: ""
        val mirror0Pass = parsed["mirror0Pass"]?.equals("true", ignoreCase = true) ?: false
        val mirror90DiagnosticRender = parsed["mirror90DiagnosticRender"] ?: "not_run"
        val mirror90DiagnosticLastError = parsed["mirror90DiagnosticLastError"] ?: ""
        val mirror90Pass = parsed["mirror90Pass"]?.equals("true", ignoreCase = true) ?: false
        val mirror180DiagnosticRender = parsed["mirror180DiagnosticRender"] ?: "not_run"
        val mirror180DiagnosticLastError = parsed["mirror180DiagnosticLastError"] ?: ""
        val mirror180Pass = parsed["mirror180Pass"]?.equals("true", ignoreCase = true) ?: false
        val mirror270DiagnosticRender = parsed["mirror270DiagnosticRender"] ?: "not_run"
        val mirror270DiagnosticLastError = parsed["mirror270DiagnosticLastError"] ?: ""
        val mirror270Pass = parsed["mirror270Pass"]?.equals("true", ignoreCase = true) ?: false
        val allTransformsPass = parsed["allTransformsPass"]?.equals("true", ignoreCase = true) ?: false
        val releaseBuffer = parsed["releaseBuffer"] ?: "not_run"
        val releaseFence = parsed["releaseFence"]?.toIntOrNull() ?: -1
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val postReleaseDiagnosticRender = parsed["postReleaseDiagnosticRender"] ?: "not_run"
        val postReleaseLastError = parsed["postReleaseLastError"] ?: ""
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val postDetachRead = parsed["postDetachRead"] ?: "not_run"
        val postDetachLastError = parsed["postDetachLastError"] ?: ""
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_renderFrame_asymmetric_uv_mapping_rgba_quadrants_no_swap_no_yuv_no_fence_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "bufferUsage" to bufferUsage,
            "bufferStride" to bufferStride,
            "bufferFill" to bufferFill,
            "writeFenceFd" to writeFenceFd,
            "writeFenceWait" to writeFenceWait,
            "preInitDiagnosticRender" to preInitDiagnosticRender,
            "preInitLastError" to preInitLastError,
            "initialize" to initialize,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "surfaceKindAfterAttach" to surfaceKindAfterAttach,
            "widthAfterAttach" to widthAfterAttach,
            "heightAfterAttach" to heightAfterAttach,
            "importBuffer" to importBuffer,
            "handle" to handle,
            "descriptorWidth" to descriptorWidth,
            "descriptorHeight" to descriptorHeight,
            "descriptorLayers" to descriptorLayers,
            "descriptorFormat" to descriptorFormat,
            "descriptorUsageSampled" to descriptorUsageSampled,
            "hasAfterImport" to hasAfterImport,
            "invalidHandleDiagnosticRender" to invalidHandleDiagnosticRender,
            "invalidHandleLastError" to invalidHandleLastError,
            "identityDiagnosticRender" to identityDiagnosticRender,
            "identityDiagnosticLastError" to identityDiagnosticLastError,
            "identityColorsDistinct" to identityColorsDistinct,
            "uv00R" to uv00R,
            "uv00G" to uv00G,
            "uv00B" to uv00B,
            "uv00A" to uv00A,
            "uv00Label" to uv00Label,
            "uv10R" to uv10R,
            "uv10G" to uv10G,
            "uv10B" to uv10B,
            "uv10A" to uv10A,
            "uv10Label" to uv10Label,
            "uv01R" to uv01R,
            "uv01G" to uv01G,
            "uv01B" to uv01B,
            "uv01A" to uv01A,
            "uv01Label" to uv01Label,
            "uv11R" to uv11R,
            "uv11G" to uv11G,
            "uv11B" to uv11B,
            "uv11A" to uv11A,
            "uv11Label" to uv11Label,
            "identityPass" to identityPass,
            "rot90DiagnosticRender" to rot90DiagnosticRender,
            "rot90DiagnosticLastError" to rot90DiagnosticLastError,
            "rot90Pass" to rot90Pass,
            "rot180DiagnosticRender" to rot180DiagnosticRender,
            "rot180DiagnosticLastError" to rot180DiagnosticLastError,
            "rot180Pass" to rot180Pass,
            "rot270DiagnosticRender" to rot270DiagnosticRender,
            "rot270DiagnosticLastError" to rot270DiagnosticLastError,
            "rot270Pass" to rot270Pass,
            "mirror0DiagnosticRender" to mirror0DiagnosticRender,
            "mirror0DiagnosticLastError" to mirror0DiagnosticLastError,
            "mirror0Pass" to mirror0Pass,
            "mirror90DiagnosticRender" to mirror90DiagnosticRender,
            "mirror90DiagnosticLastError" to mirror90DiagnosticLastError,
            "mirror90Pass" to mirror90Pass,
            "mirror180DiagnosticRender" to mirror180DiagnosticRender,
            "mirror180DiagnosticLastError" to mirror180DiagnosticLastError,
            "mirror180Pass" to mirror180Pass,
            "mirror270DiagnosticRender" to mirror270DiagnosticRender,
            "mirror270DiagnosticLastError" to mirror270DiagnosticLastError,
            "mirror270Pass" to mirror270Pass,
            "allTransformsPass" to allTransformsPass,
            "releaseBuffer" to releaseBuffer,
            "releaseFence" to releaseFence,
            "hasAfterRelease" to hasAfterRelease,
            "postReleaseDiagnosticRender" to postReleaseDiagnosticRender,
            "postReleaseLastError" to postReleaseLastError,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "postDetachRead" to postDetachRead,
            "postDetachLastError" to postDetachLastError,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesRenderFrameTransformMappingFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=$reason;bufferWidth=0;bufferHeight=0;" +
            "bufferLayers=0;bufferFormat=0;bufferUsage=0;bufferStride=0;bufferFill=not_run;writeFenceFd=-1;writeFenceWait=none;" +
            "preInitDiagnosticRender=not_run;preInitLastError=;initialize=not_run;attach=not_run;hasSurfaceAfterAttach=false;" +
            "surfaceKindAfterAttach=none;widthAfterAttach=0;heightAfterAttach=0;importBuffer=not_run;handle=0;" +
            "descriptorWidth=0;descriptorHeight=0;descriptorLayers=0;descriptorFormat=0;descriptorUsageSampled=false;" +
            "hasAfterImport=false;invalidHandleDiagnosticRender=not_run;invalidHandleLastError=;identityDiagnosticRender=not_run;" +
            "identityDiagnosticLastError=;identityColorsDistinct=false;uv00R=0;uv00G=0;uv00B=0;uv00A=0;uv00Label=unknown;" +
            "uv10R=0;uv10G=0;uv10B=0;uv10A=0;uv10Label=unknown;uv01R=0;uv01G=0;uv01B=0;uv01A=0;uv01Label=unknown;" +
            "uv11R=0;uv11G=0;uv11B=0;uv11A=0;uv11Label=unknown;identityPass=false;rot90DiagnosticRender=not_run;rot90DiagnosticLastError=;" +
            "rot90Pass=false;rot180DiagnosticRender=not_run;rot180DiagnosticLastError=;rot180Pass=false;rot270DiagnosticRender=not_run;" +
            "rot270DiagnosticLastError=;rot270Pass=false;mirror0DiagnosticRender=not_run;mirror0DiagnosticLastError=;mirror0Pass=false;" +
            "mirror90DiagnosticRender=not_run;mirror90DiagnosticLastError=;mirror90Pass=false;mirror180DiagnosticRender=not_run;" +
            "mirror180DiagnosticLastError=;mirror180Pass=false;mirror270DiagnosticRender=not_run;mirror270DiagnosticLastError=;mirror270Pass=false;" +
            "allTransformsPass=false;releaseBuffer=not_run;releaseFence=-1;hasAfterRelease=false;postReleaseDiagnosticRender=not_run;" +
            "postReleaseLastError=;detach=not_run;surfaceKindAfterDetach=none;postDetachRead=not_run;postDetachLastError=;" +
            "shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_renderFrame_asymmetric_uv_mapping_rgba_quadrants_no_swap_no_yuv_no_fence_no_product;lastError=$reason"

    // ── Phase 1-Unit AE: Android GLES backend AHardwareBuffer acquire-fence wait/close foundation smoke ──
    private const val RESULT_MARKER_PHASE1AE = "ANDROID_GLES_ACQUIRE_FENCE_UNIT_AE_NATIVE_RESULT"

    fun runGlesAcquireFenceSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var buffer: HardwareBuffer? = null
        var raw = glesAcquireFenceFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesAcquireFenceFailure("api_below_26")
                return parseGlesAcquireFenceResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesAcquireFenceFailure("invalid_dimensions")
                return parseGlesAcquireFenceResult(raw)
            }

            buffer = HardwareBuffer.create(
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
            raw = nativeBridge.runAndroidDagPhase1AEGlesAcquireFenceSmoke(
                buffer,
                width,
                height,
            )
            return parseGlesAcquireFenceResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesAcquireFenceFailure("exception:$reason")
            return parseGlesAcquireFenceResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AE $raw")
            try {
                buffer?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun parseGlesAcquireFenceResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val symbolsResolved = parsed["symbolsResolved"]?.equals("true", ignoreCase = true) ?: false
        val nativeFenceExtension = parsed["nativeFenceExtension"] ?: "not_run"
        val preInitImport = parsed["preInitImport"] ?: "not_run"
        val preInitHandle = parsed["preInitHandle"]?.toLongOrNull() ?: 0L
        val preInitDescriptorZero = parsed["preInitDescriptorZero"]?.equals("true", ignoreCase = true) ?: false
        val initialize = parsed["initialize"] ?: "not_run"
        val invalidFenceImport = parsed["invalidFenceImport"] ?: "not_run"
        val invalidFenceLastError = parsed["invalidFenceLastError"] ?: ""
        val invalidFenceDescriptorZero = parsed["invalidFenceDescriptorZero"]?.equals("true", ignoreCase = true) ?: false
        val invalidFenceHandle = parsed["invalidFenceHandle"]?.toLongOrNull() ?: 0L
        val invalidFenceClosed = parsed["invalidFenceClosed"]?.equals("true", ignoreCase = true) ?: false
        val timeoutImport = parsed["timeoutImport"] ?: "not_run"
        val timeoutLastError = parsed["timeoutLastError"] ?: ""
        val timeoutDescriptorZero = parsed["timeoutDescriptorZero"]?.equals("true", ignoreCase = true) ?: false
        val timeoutHandle = parsed["timeoutHandle"]?.toLongOrNull() ?: 0L
        val timeoutFdClosed = parsed["timeoutFdClosed"]?.equals("true", ignoreCase = true) ?: false
        val signaledFenceCreate = parsed["signaledFenceCreate"] ?: "not_run"
        val signaledFenceDup = parsed["signaledFenceDup"] ?: "not_run"
        val signaledFenceFd = parsed["signaledFenceFd"]?.toIntOrNull() ?: -1
        val signaledImport = parsed["signaledImport"] ?: "not_run"
        val signaledFdClosed = parsed["signaledFdClosed"]?.equals("true", ignoreCase = true) ?: false
        val signaledHandle = parsed["signaledHandle"]?.toLongOrNull() ?: 0L
        val descriptorWidth = parsed["descriptorWidth"]?.toIntOrNull() ?: 0
        val descriptorHeight = parsed["descriptorHeight"]?.toIntOrNull() ?: 0
        val descriptorLayers = parsed["descriptorLayers"]?.toIntOrNull() ?: 0
        val descriptorFormat = parsed["descriptorFormat"]?.toIntOrNull() ?: 0
        val descriptorUsageSampled = parsed["descriptorUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport = parsed["hasAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val release = parsed["release"] ?: "not_run"
        val releaseFence = parsed["releaseFence"]?.toIntOrNull() ?: -1
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_ahb_rgba_import_acquire_fence_wait_close_no_yuv_no_release_fence_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "symbolsResolved" to symbolsResolved,
            "nativeFenceExtension" to nativeFenceExtension,
            "preInitImport" to preInitImport,
            "preInitHandle" to preInitHandle,
            "preInitDescriptorZero" to preInitDescriptorZero,
            "initialize" to initialize,
            "invalidFenceImport" to invalidFenceImport,
            "invalidFenceLastError" to invalidFenceLastError,
            "invalidFenceDescriptorZero" to invalidFenceDescriptorZero,
            "invalidFenceHandle" to invalidFenceHandle,
            "invalidFenceClosed" to invalidFenceClosed,
            "timeoutImport" to timeoutImport,
            "timeoutLastError" to timeoutLastError,
            "timeoutDescriptorZero" to timeoutDescriptorZero,
            "timeoutHandle" to timeoutHandle,
            "timeoutFdClosed" to timeoutFdClosed,
            "signaledFenceCreate" to signaledFenceCreate,
            "signaledFenceDup" to signaledFenceDup,
            "signaledFenceFd" to signaledFenceFd,
            "signaledImport" to signaledImport,
            "signaledFdClosed" to signaledFdClosed,
            "signaledHandle" to signaledHandle,
            "descriptorWidth" to descriptorWidth,
            "descriptorHeight" to descriptorHeight,
            "descriptorLayers" to descriptorLayers,
            "descriptorFormat" to descriptorFormat,
            "descriptorUsageSampled" to descriptorUsageSampled,
            "hasAfterImport" to hasAfterImport,
            "release" to release,
            "releaseFence" to releaseFence,
            "hasAfterRelease" to hasAfterRelease,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesAcquireFenceFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;symbolsResolved=false;" +
            "nativeFenceExtension=not_run;preInitImport=not_run;preInitHandle=0;preInitDescriptorZero=false;" +
            "initialize=not_run;invalidFenceImport=not_run;invalidFenceLastError=none;invalidFenceDescriptorZero=false;" +
            "invalidFenceHandle=0;invalidFenceClosed=false;timeoutImport=not_run;timeoutLastError=none;" +
            "timeoutDescriptorZero=false;timeoutHandle=0;timeoutFdClosed=false;signaledFenceCreate=not_run;" +
            "signaledFenceDup=not_run;signaledFenceFd=-1;signaledImport=not_run;signaledFdClosed=false;" +
            "signaledHandle=0;descriptorWidth=0;descriptorHeight=0;descriptorLayers=0;descriptorFormat=0;" +
            "descriptorUsageSampled=false;hasAfterImport=false;release=not_run;releaseFence=-1;" +
            "hasAfterRelease=false;shutdown=not_run;idempotentShutdown=not_run;" +
            "proofBoundary=gles_ahb_rgba_import_acquire_fence_wait_close_no_yuv_no_release_fence_no_product;lastError=$reason"

    // ── Phase 1-Unit AF: Android GLES RGBX AHardwareBuffer renderFrame content readback physical smoke ──
    private const val RESULT_MARKER_PHASE1AF = "ANDROID_GLES_RGBX_RENDERFRAME_CONTENT_UNIT_AF_NATIVE_RESULT"

    fun runGlesRgbxRenderFrameContentSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesRgbxRenderFrameContentFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesRgbxRenderFrameContentFailure("api_below_26")
                return parseGlesRgbxRenderFrameContentResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesRgbxRenderFrameContentFailure("invalid_dimensions")
                return parseGlesRgbxRenderFrameContentResult(raw)
            }

            surfaceTexture = SurfaceTexture(false).apply {
                setDefaultBufferSize(width, height)
            }
            surface = Surface(surfaceTexture)

            hardwareBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBX_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AFGlesRgbxRenderFrameContentSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesRgbxRenderFrameContentResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesRgbxRenderFrameContentFailure("exception:$reason")
            return parseGlesRgbxRenderFrameContentResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AF $raw")
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

    private fun parseGlesRgbxRenderFrameContentResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val bufferDescribe = parsed["bufferDescribe"] ?: "not_run"
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val formatIsRgbx = parsed["formatIsRgbx"]?.equals("true", ignoreCase = true) ?: false
        val bufferUsage = parsed["bufferUsage"]?.toLongOrNull() ?: 0L
        val bufferStride = parsed["bufferStride"]?.toIntOrNull() ?: 0
        val bufferFill = parsed["bufferFill"] ?: "not_run"
        val writeFenceFd = parsed["writeFenceFd"]?.toIntOrNull() ?: -1
        val writeFenceWait = parsed["writeFenceWait"] ?: "none"
        val preInitDiagnosticRender = parsed["preInitDiagnosticRender"] ?: "not_run"
        val preInitLastError = parsed["preInitLastError"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val surfaceKindAfterAttach = parsed["surfaceKindAfterAttach"] ?: "none"
        val widthAfterAttach = parsed["widthAfterAttach"]?.toIntOrNull() ?: 0
        val heightAfterAttach = parsed["heightAfterAttach"]?.toIntOrNull() ?: 0
        val importBuffer = parsed["importBuffer"] ?: "not_run"
        val handle = parsed["handle"]?.toLongOrNull() ?: 0L
        val descriptorWidth = parsed["descriptorWidth"]?.toIntOrNull() ?: 0
        val descriptorHeight = parsed["descriptorHeight"]?.toIntOrNull() ?: 0
        val descriptorLayers = parsed["descriptorLayers"]?.toIntOrNull() ?: 0
        val descriptorFormat = parsed["descriptorFormat"]?.toIntOrNull() ?: 0
        val descriptorFormatIsRgbx = parsed["descriptorFormatIsRgbx"]?.equals("true", ignoreCase = true) ?: false
        val descriptorUsageSampled = parsed["descriptorUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport = parsed["hasAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val invalidHandleDiagnosticRender = parsed["invalidHandleDiagnosticRender"] ?: "not_run"
        val invalidHandleLastError = parsed["invalidHandleLastError"] ?: ""
        val identityDiagnosticRender = parsed["identityDiagnosticRender"] ?: "not_run"
        val identityDiagnosticLastError = parsed["identityDiagnosticLastError"] ?: ""
        val identityCenterRead = parsed["identityCenterRead"] ?: "not_run"
        val identityCenterReadLastError = parsed["identityCenterReadLastError"] ?: ""
        val identityCenterR = parsed["identityCenterR"]?.toIntOrNull() ?: 0
        val identityCenterG = parsed["identityCenterG"]?.toIntOrNull() ?: 0
        val identityCenterB = parsed["identityCenterB"]?.toIntOrNull() ?: 0
        val identityCenterA = parsed["identityCenterA"]?.toIntOrNull() ?: 0
        val identityCenterPixelMatches = parsed["identityCenterPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val rot90DiagnosticRender = parsed["rot90DiagnosticRender"] ?: "not_run"
        val rot90DiagnosticLastError = parsed["rot90DiagnosticLastError"] ?: ""
        val rot90CenterRead = parsed["rot90CenterRead"] ?: "not_run"
        val rot90CenterReadLastError = parsed["rot90CenterReadLastError"] ?: ""
        val rot90CenterR = parsed["rot90CenterR"]?.toIntOrNull() ?: 0
        val rot90CenterG = parsed["rot90CenterG"]?.toIntOrNull() ?: 0
        val rot90CenterB = parsed["rot90CenterB"]?.toIntOrNull() ?: 0
        val rot90CenterA = parsed["rot90CenterA"]?.toIntOrNull() ?: 0
        val rot90CenterPixelMatches = parsed["rot90CenterPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val releaseBuffer = parsed["releaseBuffer"] ?: "not_run"
        val releaseFence = parsed["releaseFence"]?.toIntOrNull() ?: -1
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val postReleaseDiagnosticRender = parsed["postReleaseDiagnosticRender"] ?: "not_run"
        val postReleaseLastError = parsed["postReleaseLastError"] ?: ""
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val postDetachRead = parsed["postDetachRead"] ?: "not_run"
        val postDetachLastError = parsed["postDetachLastError"] ?: ""
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_renderFrame_rgbx_texture_content_readback_no_swap_no_yuv_no_fence_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "formatIsRgbx" to formatIsRgbx,
            "bufferUsage" to bufferUsage,
            "bufferStride" to bufferStride,
            "bufferFill" to bufferFill,
            "writeFenceFd" to writeFenceFd,
            "writeFenceWait" to writeFenceWait,
            "preInitDiagnosticRender" to preInitDiagnosticRender,
            "preInitLastError" to preInitLastError,
            "initialize" to initialize,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "surfaceKindAfterAttach" to surfaceKindAfterAttach,
            "widthAfterAttach" to widthAfterAttach,
            "heightAfterAttach" to heightAfterAttach,
            "importBuffer" to importBuffer,
            "handle" to handle,
            "descriptorWidth" to descriptorWidth,
            "descriptorHeight" to descriptorHeight,
            "descriptorLayers" to descriptorLayers,
            "descriptorFormat" to descriptorFormat,
            "descriptorFormatIsRgbx" to descriptorFormatIsRgbx,
            "descriptorUsageSampled" to descriptorUsageSampled,
            "hasAfterImport" to hasAfterImport,
            "invalidHandleDiagnosticRender" to invalidHandleDiagnosticRender,
            "invalidHandleLastError" to invalidHandleLastError,
            "identityDiagnosticRender" to identityDiagnosticRender,
            "identityDiagnosticLastError" to identityDiagnosticLastError,
            "identityCenterRead" to identityCenterRead,
            "identityCenterReadLastError" to identityCenterReadLastError,
            "identityCenterR" to identityCenterR,
            "identityCenterG" to identityCenterG,
            "identityCenterB" to identityCenterB,
            "identityCenterA" to identityCenterA,
            "identityCenterPixelMatches" to identityCenterPixelMatches,
            "rot90DiagnosticRender" to rot90DiagnosticRender,
            "rot90DiagnosticLastError" to rot90DiagnosticLastError,
            "rot90CenterRead" to rot90CenterRead,
            "rot90CenterReadLastError" to rot90CenterReadLastError,
            "rot90CenterR" to rot90CenterR,
            "rot90CenterG" to rot90CenterG,
            "rot90CenterB" to rot90CenterB,
            "rot90CenterA" to rot90CenterA,
            "rot90CenterPixelMatches" to rot90CenterPixelMatches,
            "releaseBuffer" to releaseBuffer,
            "releaseFence" to releaseFence,
            "hasAfterRelease" to hasAfterRelease,
            "postReleaseDiagnosticRender" to postReleaseDiagnosticRender,
            "postReleaseLastError" to postReleaseLastError,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "postDetachRead" to postDetachRead,
            "postDetachLastError" to postDetachLastError,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesRgbxRenderFrameContentFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=$reason;bufferWidth=0;bufferHeight=0;" +
            "bufferLayers=0;bufferFormat=0;formatIsRgbx=false;bufferUsage=0;bufferStride=0;bufferFill=not_run;writeFenceFd=-1;writeFenceWait=none;" +
            "preInitDiagnosticRender=not_run;preInitLastError=;initialize=not_run;attach=not_run;hasSurfaceAfterAttach=false;" +
            "surfaceKindAfterAttach=none;widthAfterAttach=0;heightAfterAttach=0;importBuffer=not_run;handle=0;" +
            "descriptorWidth=0;descriptorHeight=0;descriptorLayers=0;descriptorFormat=0;descriptorFormatIsRgbx=false;descriptorUsageSampled=false;" +
            "hasAfterImport=false;invalidHandleDiagnosticRender=not_run;invalidHandleLastError=;identityDiagnosticRender=not_run;" +
            "identityDiagnosticLastError=;identityCenterRead=not_run;identityCenterReadLastError=;identityCenterR=0;identityCenterG=0;" +
            "identityCenterB=0;identityCenterA=0;identityCenterPixelMatches=false;rot90DiagnosticRender=not_run;rot90DiagnosticLastError=;" +
            "rot90CenterRead=not_run;rot90CenterReadLastError=;rot90CenterR=0;rot90CenterG=0;rot90CenterB=0;rot90CenterA=0;" +
            "rot90CenterPixelMatches=false;releaseBuffer=not_run;releaseFence=-1;hasAfterRelease=false;postReleaseDiagnosticRender=not_run;" +
            "postReleaseLastError=;detach=not_run;surfaceKindAfterDetach=none;postDetachRead=not_run;postDetachLastError=;" +
            "shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_renderFrame_rgbx_texture_content_readback_no_swap_no_yuv_no_fence_no_product;lastError=$reason"

    // ── Phase 1-Unit AG: Android GLES AHardwareBuffer import guard fail-closed physical smoke ──
    private const val RESULT_MARKER_PHASE1AG = "ANDROID_GLES_IMPORT_GUARD_UNIT_AG_NATIVE_RESULT"

    fun runGlesImportGuardSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var validRgbaBuffer: HardwareBuffer? = null
        var missingUsageBuffer: HardwareBuffer? = null
        var unsupportedFormatBuffer: HardwareBuffer? = null
        var unsupportedFormatAllocation = "not_run"
        var raw = glesImportGuardFailure("not_run", "not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesImportGuardFailure("api_below_26", "not_run")
                return parseGlesImportGuardResult(raw, "not_run")
            }
            if (width <= 0 || height <= 0) {
                raw = glesImportGuardFailure("invalid_dimensions", "not_run")
                return parseGlesImportGuardResult(raw, "not_run")
            }

            validRgbaBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            missingUsageBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            try {
                unsupportedFormatBuffer = HardwareBuffer.create(
                    width,
                    height,
                    HardwareBuffer.RGB_565,
                    1,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                )
                unsupportedFormatAllocation = "success"
            } catch (t: Throwable) {
                val excReason = t.javaClass.simpleName.ifEmpty { "allocation_exception" }
                unsupportedFormatAllocation = "exception:$excReason"
                raw = glesImportGuardFailure("unsupported_format_allocation_failed", unsupportedFormatAllocation)
                return parseGlesImportGuardResult(raw, unsupportedFormatAllocation)
            }

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AGGlesImportGuardSmoke(
                validRgbaBuffer,
                missingUsageBuffer,
                unsupportedFormatBuffer,
                width,
                height,
            )
            return parseGlesImportGuardResult(raw, unsupportedFormatAllocation)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesImportGuardFailure("exception:$reason", unsupportedFormatAllocation)
            return parseGlesImportGuardResult(raw, unsupportedFormatAllocation)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AG $raw")
            try {
                validRgbaBuffer?.close()
            } catch (_: Throwable) {
            }
            try {
                missingUsageBuffer?.close()
            } catch (_: Throwable) {
            }
            try {
                unsupportedFormatBuffer?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun parseGlesImportGuardResult(raw: String, unsupportedFormatAllocation: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val validBufferDescribe = parsed["validBufferDescribe"] ?: "not_run"
        val validBufferFormat = parsed["validBufferFormat"]?.toIntOrNull() ?: 0
        val validBufferUsage = parsed["validBufferUsage"]?.toLongOrNull() ?: 0L
        val missingUsageBufferDescribe = parsed["missingUsageBufferDescribe"] ?: "not_run"
        val missingUsageBufferFormat = parsed["missingUsageBufferFormat"]?.toIntOrNull() ?: 0
        val missingUsageBufferUsage = parsed["missingUsageBufferUsage"]?.toLongOrNull() ?: 0L
        val missingUsageHasSampled = parsed["missingUsageHasSampled"]?.equals("true", ignoreCase = true) ?: false
        val unsupportedFormatBufferDescribe = parsed["unsupportedFormatBufferDescribe"] ?: "not_run"
        val unsupportedFormatBufferFormat = parsed["unsupportedFormatBufferFormat"]?.toIntOrNull() ?: 0
        val unsupportedFormatBufferUsage = parsed["unsupportedFormatBufferUsage"]?.toLongOrNull() ?: 0L
        val unsupportedFormatIsRgb565 = parsed["unsupportedFormatIsRgb565"]?.equals("true", ignoreCase = true) ?: false
        val initialize = parsed["initialize"] ?: "not_run"
        val validPreImport = parsed["validPreImport"] ?: "not_run"
        val validPreHandle = parsed["validPreHandle"]?.toLongOrNull() ?: 0L
        val validPreDescWidth = parsed["validPreDescWidth"]?.toIntOrNull() ?: 0
        val validPreDescHeight = parsed["validPreDescHeight"]?.toIntOrNull() ?: 0
        val validPreDescLayers = parsed["validPreDescLayers"]?.toIntOrNull() ?: 0
        val validPreDescFormat = parsed["validPreDescFormat"]?.toIntOrNull() ?: 0
        val validPreDescUsageSampled = parsed["validPreDescUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasValidPreAfterImport = parsed["hasValidPreAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val validPreRelease = parsed["validPreRelease"] ?: "not_run"
        val validPreReleaseFence = parsed["validPreReleaseFence"]?.toIntOrNull() ?: -1
        val hasValidPreAfterRelease = parsed["hasValidPreAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val missingUsageImport = parsed["missingUsageImport"] ?: "not_run"
        val missingUsageHandle = parsed["missingUsageHandle"]?.toLongOrNull() ?: 0L
        val missingUsageDescZero = parsed["missingUsageDescZero"]?.equals("true", ignoreCase = true) ?: false
        val missingUsageLastError = parsed["missingUsageLastError"] ?: ""
        val hasMissingUsageAfterImport = parsed["hasMissingUsageAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val unsupportedFormatImport = parsed["unsupportedFormatImport"] ?: "not_run"
        val unsupportedFormatHandle = parsed["unsupportedFormatHandle"]?.toLongOrNull() ?: 0L
        val unsupportedFormatDescZero = parsed["unsupportedFormatDescZero"]?.equals("true", ignoreCase = true) ?: false
        val unsupportedFormatLastError = parsed["unsupportedFormatLastError"] ?: ""
        val hasUnsupportedFormatAfterImport = parsed["hasUnsupportedFormatAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val validPostImport = parsed["validPostImport"] ?: "not_run"
        val validPostHandle = parsed["validPostHandle"]?.toLongOrNull() ?: 0L
        val validPostDescWidth = parsed["validPostDescWidth"]?.toIntOrNull() ?: 0
        val validPostDescHeight = parsed["validPostDescHeight"]?.toIntOrNull() ?: 0
        val validPostDescLayers = parsed["validPostDescLayers"]?.toIntOrNull() ?: 0
        val validPostDescFormat = parsed["validPostDescFormat"]?.toIntOrNull() ?: 0
        val validPostDescUsageSampled = parsed["validPostDescUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasValidPostAfterImport = parsed["hasValidPostAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val validPostRelease = parsed["validPostRelease"] ?: "not_run"
        val validPostReleaseFence = parsed["validPostReleaseFence"]?.toIntOrNull() ?: -1
        val hasValidPostAfterRelease = parsed["hasValidPostAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_ahb_import_guard_fail_closed_no_yuv_no_oes_no_release_fence_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "unsupportedFormatAllocation" to unsupportedFormatAllocation,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "validBufferDescribe" to validBufferDescribe,
            "validBufferFormat" to validBufferFormat,
            "validBufferUsage" to validBufferUsage,
            "missingUsageBufferDescribe" to missingUsageBufferDescribe,
            "missingUsageBufferFormat" to missingUsageBufferFormat,
            "missingUsageBufferUsage" to missingUsageBufferUsage,
            "missingUsageHasSampled" to missingUsageHasSampled,
            "unsupportedFormatBufferDescribe" to unsupportedFormatBufferDescribe,
            "unsupportedFormatBufferFormat" to unsupportedFormatBufferFormat,
            "unsupportedFormatBufferUsage" to unsupportedFormatBufferUsage,
            "unsupportedFormatIsRgb565" to unsupportedFormatIsRgb565,
            "initialize" to initialize,
            "validPreImport" to validPreImport,
            "validPreHandle" to validPreHandle,
            "validPreDescWidth" to validPreDescWidth,
            "validPreDescHeight" to validPreDescHeight,
            "validPreDescLayers" to validPreDescLayers,
            "validPreDescFormat" to validPreDescFormat,
            "validPreDescUsageSampled" to validPreDescUsageSampled,
            "hasValidPreAfterImport" to hasValidPreAfterImport,
            "validPreRelease" to validPreRelease,
            "validPreReleaseFence" to validPreReleaseFence,
            "hasValidPreAfterRelease" to hasValidPreAfterRelease,
            "missingUsageImport" to missingUsageImport,
            "missingUsageHandle" to missingUsageHandle,
            "missingUsageDescZero" to missingUsageDescZero,
            "missingUsageLastError" to missingUsageLastError,
            "hasMissingUsageAfterImport" to hasMissingUsageAfterImport,
            "unsupportedFormatImport" to unsupportedFormatImport,
            "unsupportedFormatHandle" to unsupportedFormatHandle,
            "unsupportedFormatDescZero" to unsupportedFormatDescZero,
            "unsupportedFormatLastError" to unsupportedFormatLastError,
            "hasUnsupportedFormatAfterImport" to hasUnsupportedFormatAfterImport,
            "validPostImport" to validPostImport,
            "validPostHandle" to validPostHandle,
            "validPostDescWidth" to validPostDescWidth,
            "validPostDescHeight" to validPostDescHeight,
            "validPostDescLayers" to validPostDescLayers,
            "validPostDescFormat" to validPostDescFormat,
            "validPostDescUsageSampled" to validPostDescUsageSampled,
            "hasValidPostAfterImport" to hasValidPostAfterImport,
            "validPostRelease" to validPostRelease,
            "validPostReleaseFence" to validPostReleaseFence,
            "hasValidPostAfterRelease" to hasValidPostAfterRelease,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesImportGuardFailure(reason: String, unsupportedFormatAllocation: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;validBufferDescribe=not_run;validBufferFormat=0;validBufferUsage=0;" +
            "missingUsageBufferDescribe=not_run;missingUsageBufferFormat=0;missingUsageBufferUsage=0;missingUsageHasSampled=false;" +
            "unsupportedFormatBufferDescribe=not_run;unsupportedFormatBufferFormat=0;unsupportedFormatBufferUsage=0;unsupportedFormatIsRgb565=false;" +
            "unsupportedFormatAllocation=$unsupportedFormatAllocation;" +
            "initialize=not_run;validPreImport=not_run;validPreHandle=0;validPreDescWidth=0;validPreDescHeight=0;validPreDescLayers=0;validPreDescFormat=0;" +
            "validPreDescUsageSampled=false;hasValidPreAfterImport=false;validPreRelease=not_run;validPreReleaseFence=-1;hasValidPreAfterRelease=false;" +
            "missingUsageImport=not_run;missingUsageHandle=0;missingUsageDescZero=false;missingUsageLastError=none;hasMissingUsageAfterImport=false;" +
            "unsupportedFormatImport=not_run;unsupportedFormatHandle=0;unsupportedFormatDescZero=false;unsupportedFormatLastError=none;hasUnsupportedFormatAfterImport=false;" +
            "validPostImport=not_run;validPostHandle=0;validPostDescWidth=0;validPostDescHeight=0;validPostDescLayers=0;validPostDescFormat=0;" +
            "validPostDescUsageSampled=false;hasValidPostAfterImport=false;validPostRelease=not_run;validPostReleaseFence=-1;hasValidPostAfterRelease=false;" +
            "shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_ahb_import_guard_fail_closed_no_yuv_no_oes_no_release_fence_no_product;lastError=$reason"

    // ── Phase 1-Unit AH: Android GLES YCBCR_420_888 AHardwareBuffer import guard fail-closed physical proof ──
    private const val RESULT_MARKER_PHASE1AH = "ANDROID_GLES_YCBCR_IMPORT_GUARD_UNIT_AH_NATIVE_RESULT"

    fun runGlesYcbcrImportGuardSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var validRgbaBuffer: HardwareBuffer? = null
        var ycbcrBuffer: HardwareBuffer? = null
        var ycbcrAllocation = "not_run"
        var raw = glesYcbcrImportGuardFailure("not_run", "not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesYcbcrImportGuardFailure("api_below_26", "not_run")
                return parseGlesYcbcrImportGuardResult(raw, "not_run")
            }
            if (width <= 0 || height <= 0) {
                raw = glesYcbcrImportGuardFailure("invalid_dimensions", "not_run")
                return parseGlesYcbcrImportGuardResult(raw, "not_run")
            }

            validRgbaBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )

            try {
                ycbcrBuffer = HardwareBuffer.create(
                    width,
                    height,
                    HardwareBuffer.YCBCR_420_888,
                    1,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                )
                ycbcrAllocation = "success"
            } catch (t: Throwable) {
                val excReason = t.javaClass.simpleName.ifEmpty { "allocation_exception" }
                ycbcrAllocation = "exception:$excReason"
                raw = glesYcbcrImportGuardFailure("ycbcr_allocation_failed", ycbcrAllocation)
                return parseGlesYcbcrImportGuardResult(raw, ycbcrAllocation)
            }

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AHGlesYcbcrImportGuardSmoke(
                validRgbaBuffer,
                ycbcrBuffer,
                width,
                height,
            )
            return parseGlesYcbcrImportGuardResult(raw, ycbcrAllocation)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesYcbcrImportGuardFailure("exception:$reason", ycbcrAllocation)
            return parseGlesYcbcrImportGuardResult(raw, ycbcrAllocation)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AH $raw")
            try {
                validRgbaBuffer?.close()
            } catch (_: Throwable) {
            }
            try {
                ycbcrBuffer?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun parseGlesYcbcrImportGuardResult(raw: String, ycbcrAllocation: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val validBufferDescribe = parsed["validBufferDescribe"] ?: "not_run"
        val validBufferFormat = parsed["validBufferFormat"]?.toIntOrNull() ?: 0
        val validBufferUsage = parsed["validBufferUsage"]?.toLongOrNull() ?: 0L
        val ycbcrBufferDescribe = parsed["ycbcrBufferDescribe"] ?: "not_run"
        val ycbcrBufferFormat = parsed["ycbcrBufferFormat"]?.toIntOrNull() ?: 0
        val ycbcrBufferUsage = parsed["ycbcrBufferUsage"]?.toLongOrNull() ?: 0L
        val ycbcrFormatIs420888 = parsed["ycbcrFormatIs420888"]?.equals("true", ignoreCase = true) ?: false
        val initialize = parsed["initialize"] ?: "not_run"
        val validPreImport = parsed["validPreImport"] ?: "not_run"
        val validPreHandle = parsed["validPreHandle"]?.toLongOrNull() ?: 0L
        val validPreDescWidth = parsed["validPreDescWidth"]?.toIntOrNull() ?: 0
        val validPreDescHeight = parsed["validPreDescHeight"]?.toIntOrNull() ?: 0
        val validPreDescLayers = parsed["validPreDescLayers"]?.toIntOrNull() ?: 0
        val validPreDescFormat = parsed["validPreDescFormat"]?.toIntOrNull() ?: 0
        val validPreDescUsageSampled = parsed["validPreDescUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasValidPreAfterImport = parsed["hasValidPreAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val validPreRelease = parsed["validPreRelease"] ?: "not_run"
        val validPreReleaseFence = parsed["validPreReleaseFence"]?.toIntOrNull() ?: -1
        val hasValidPreAfterRelease = parsed["hasValidPreAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val ycbcrImport = parsed["ycbcrImport"] ?: "not_run"
        val ycbcrHandle = parsed["ycbcrHandle"]?.toLongOrNull() ?: 0L
        val ycbcrDescZero = parsed["ycbcrDescZero"]?.equals("true", ignoreCase = true) ?: false
        val ycbcrLastError = parsed["ycbcrLastError"] ?: ""
        val hasYcbcrAfterImport = parsed["hasYcbcrAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val validPostImport = parsed["validPostImport"] ?: "not_run"
        val validPostHandle = parsed["validPostHandle"]?.toLongOrNull() ?: 0L
        val validPostDescWidth = parsed["validPostDescWidth"]?.toIntOrNull() ?: 0
        val validPostDescHeight = parsed["validPostDescHeight"]?.toIntOrNull() ?: 0
        val validPostDescLayers = parsed["validPostDescLayers"]?.toIntOrNull() ?: 0
        val validPostDescFormat = parsed["validPostDescFormat"]?.toIntOrNull() ?: 0
        val validPostDescUsageSampled = parsed["validPostDescUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasValidPostAfterImport = parsed["hasValidPostAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val validPostRelease = parsed["validPostRelease"] ?: "not_run"
        val validPostReleaseFence = parsed["validPostReleaseFence"]?.toIntOrNull() ?: -1
        val hasValidPostAfterRelease = parsed["hasValidPostAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_ycbcr_ahb_import_guard_fail_closed_no_oes_no_release_fence_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "ycbcrAllocation" to ycbcrAllocation,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "validBufferDescribe" to validBufferDescribe,
            "validBufferFormat" to validBufferFormat,
            "validBufferUsage" to validBufferUsage,
            "ycbcrBufferDescribe" to ycbcrBufferDescribe,
            "ycbcrBufferFormat" to ycbcrBufferFormat,
            "ycbcrBufferUsage" to ycbcrBufferUsage,
            "ycbcrFormatIs420888" to ycbcrFormatIs420888,
            "initialize" to initialize,
            "validPreImport" to validPreImport,
            "validPreHandle" to validPreHandle,
            "validPreDescWidth" to validPreDescWidth,
            "validPreDescHeight" to validPreDescHeight,
            "validPreDescLayers" to validPreDescLayers,
            "validPreDescFormat" to validPreDescFormat,
            "validPreDescUsageSampled" to validPreDescUsageSampled,
            "hasValidPreAfterImport" to hasValidPreAfterImport,
            "validPreRelease" to validPreRelease,
            "validPreReleaseFence" to validPreReleaseFence,
            "hasValidPreAfterRelease" to hasValidPreAfterRelease,
            "ycbcrImport" to ycbcrImport,
            "ycbcrHandle" to ycbcrHandle,
            "ycbcrDescZero" to ycbcrDescZero,
            "ycbcrLastError" to ycbcrLastError,
            "hasYcbcrAfterImport" to hasYcbcrAfterImport,
            "validPostImport" to validPostImport,
            "validPostHandle" to validPostHandle,
            "validPostDescWidth" to validPostDescWidth,
            "validPostDescHeight" to validPostDescHeight,
            "validPostDescLayers" to validPostDescLayers,
            "validPostDescFormat" to validPostDescFormat,
            "validPostDescUsageSampled" to validPostDescUsageSampled,
            "hasValidPostAfterImport" to hasValidPostAfterImport,
            "validPostRelease" to validPostRelease,
            "validPostReleaseFence" to validPostReleaseFence,
            "hasValidPostAfterRelease" to hasValidPostAfterRelease,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesYcbcrImportGuardFailure(reason: String, ycbcrAllocation: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;validBufferDescribe=not_run;validBufferFormat=0;validBufferUsage=0;" +
            "ycbcrBufferDescribe=not_run;ycbcrBufferFormat=0;ycbcrBufferUsage=0;ycbcrFormatIs420888=false;" +
            "ycbcrAllocation=$ycbcrAllocation;" +
            "initialize=not_run;validPreImport=not_run;validPreHandle=0;validPreDescWidth=0;validPreDescHeight=0;validPreDescLayers=0;validPreDescFormat=0;" +
            "validPreDescUsageSampled=false;hasValidPreAfterImport=false;validPreRelease=not_run;validPreReleaseFence=-1;hasValidPreAfterRelease=false;" +
            "ycbcrImport=not_run;ycbcrHandle=0;ycbcrDescZero=false;ycbcrLastError=none;hasYcbcrAfterImport=false;" +
            "validPostImport=not_run;validPostHandle=0;validPostDescWidth=0;validPostDescHeight=0;validPostDescLayers=0;validPostDescFormat=0;" +
            "validPostDescUsageSampled=false;hasValidPostAfterImport=false;validPostRelease=not_run;validPostReleaseFence=-1;hasValidPostAfterRelease=false;" +
            "shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_ycbcr_ahb_import_guard_fail_closed_no_oes_no_release_fence_no_product;lastError=$reason"

    // ── Phase 1-Unit AI: Android GLES/EGL extension and native-fence capability inventory physical proof ──
    private const val RESULT_MARKER_PHASE1AI = "ANDROID_GLES_EXTENSION_CAPABILITY_UNIT_AI_NATIVE_RESULT"

    fun runGlesExtensionCapabilitySmoke(): Map<String, Any?> {
        var raw = glesExtensionCapabilityFailure("not_run")
        try {
            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AIGlesExtensionCapabilitySmoke()
            return parseGlesExtensionCapabilityResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesExtensionCapabilityFailure("exception:$reason")
            return parseGlesExtensionCapabilityResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AI $raw")
        }
    }

    private fun parseGlesExtensionCapabilityResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val eglCurrentDisplayOk = parsed["eglCurrentDisplayOk"]?.equals("true", ignoreCase = true) ?: false
        val eglExtensionsAvailable = parsed["eglExtensionsAvailable"]?.equals("true", ignoreCase = true) ?: false
        val glExtensionsAvailable = parsed["glExtensionsAvailable"]?.equals("true", ignoreCase = true) ?: false
        val hasEglAndroidImageNativeBuffer = parsed["hasEglAndroidImageNativeBuffer"]?.equals("true", ignoreCase = true) ?: false
        val hasEglAndroidGetNativeClientBuffer = parsed["hasEglAndroidGetNativeClientBuffer"]?.equals("true", ignoreCase = true) ?: false
        val hasEglKhrImageBase = parsed["hasEglKhrImageBase"]?.equals("true", ignoreCase = true) ?: false
        val hasEglAndroidNativeFenceSync = parsed["hasEglAndroidNativeFenceSync"]?.equals("true", ignoreCase = true) ?: false
        val hasEglKhrFenceSync = parsed["hasEglKhrFenceSync"]?.equals("true", ignoreCase = true) ?: false
        val hasGlOesEglImage = parsed["hasGlOesEglImage"]?.equals("true", ignoreCase = true) ?: false
        val hasGlOesEglImageExternal = parsed["hasGlOesEglImageExternal"]?.equals("true", ignoreCase = true) ?: false
        val hasGlExtYuvTarget = parsed["hasGlExtYuvTarget"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglGetNativeClientBufferAndroid = parsed["symbolEglGetNativeClientBufferAndroid"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglCreateImageKhr = parsed["symbolEglCreateImageKhr"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglDestroyImageKhr = parsed["symbolEglDestroyImageKhr"]?.equals("true", ignoreCase = true) ?: false
        val symbolGlEglImageTargetTexture2DOes = parsed["symbolGlEglImageTargetTexture2DOes"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglCreateSyncKhr = parsed["symbolEglCreateSyncKhr"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglDestroySyncKhr = parsed["symbolEglDestroySyncKhr"]?.equals("true", ignoreCase = true) ?: false
        val symbolEglDupNativeFenceFdAndroid = parsed["symbolEglDupNativeFenceFdAndroid"]?.equals("true", ignoreCase = true) ?: false
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_egl_extension_capability_inventory_no_import_no_render_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "initialize" to initialize,
            "eglCurrentDisplayOk" to eglCurrentDisplayOk,
            "eglExtensionsAvailable" to eglExtensionsAvailable,
            "glExtensionsAvailable" to glExtensionsAvailable,
            "hasEglAndroidImageNativeBuffer" to hasEglAndroidImageNativeBuffer,
            "hasEglAndroidGetNativeClientBuffer" to hasEglAndroidGetNativeClientBuffer,
            "hasEglKhrImageBase" to hasEglKhrImageBase,
            "hasEglAndroidNativeFenceSync" to hasEglAndroidNativeFenceSync,
            "hasEglKhrFenceSync" to hasEglKhrFenceSync,
            "hasGlOesEglImage" to hasGlOesEglImage,
            "hasGlOesEglImageExternal" to hasGlOesEglImageExternal,
            "hasGlExtYuvTarget" to hasGlExtYuvTarget,
            "symbolEglGetNativeClientBufferAndroid" to symbolEglGetNativeClientBufferAndroid,
            "symbolEglCreateImageKhr" to symbolEglCreateImageKhr,
            "symbolEglDestroyImageKhr" to symbolEglDestroyImageKhr,
            "symbolGlEglImageTargetTexture2DOes" to symbolGlEglImageTargetTexture2DOes,
            "symbolEglCreateSyncKhr" to symbolEglCreateSyncKhr,
            "symbolEglDestroySyncKhr" to symbolEglDestroySyncKhr,
            "symbolEglDupNativeFenceFdAndroid" to symbolEglDupNativeFenceFdAndroid,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesExtensionCapabilityFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;initialize=not_run;" +
            "eglCurrentDisplayOk=false;eglExtensionsAvailable=false;glExtensionsAvailable=false;" +
            "hasEglAndroidImageNativeBuffer=false;hasEglAndroidGetNativeClientBuffer=false;" +
            "hasEglKhrImageBase=false;hasEglAndroidNativeFenceSync=false;hasEglKhrFenceSync=false;" +
            "hasGlOesEglImage=false;hasGlOesEglImageExternal=false;hasGlExtYuvTarget=false;" +
            "symbolEglGetNativeClientBufferAndroid=false;symbolEglCreateImageKhr=false;" +
            "symbolEglDestroyImageKhr=false;symbolGlEglImageTargetTexture2DOes=false;" +
            "symbolEglCreateSyncKhr=false;symbolEglDestroySyncKhr=false;symbolEglDupNativeFenceFdAndroid=false;" +
            "shutdown=not_run;idempotentShutdown=not_run;" +
            "proofBoundary=gles_egl_extension_capability_inventory_no_import_no_render_no_product;lastError=$reason"

    // ── Phase 1-Unit AJ: Android GLES EGL native-fence FD lifecycle physical proof ──
    private const val RESULT_MARKER_PHASE1AJ = "ANDROID_GLES_NATIVE_FENCE_FD_UNIT_AJ_NATIVE_RESULT"

    fun runGlesNativeFenceFdSmoke(): Map<String, Any?> {
        var raw = glesNativeFenceFdFailure("not_run")
        try {
            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AJGlesNativeFenceFdSmoke()
            return parseGlesNativeFenceFdResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesNativeFenceFdFailure("exception:$reason")
            return parseGlesNativeFenceFdResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AJ $raw")
        }
    }

    private fun parseGlesNativeFenceFdResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val initialize = parsed["initialize"] ?: "not_run"
        val eglCurrentDisplayOk = parsed["eglCurrentDisplayOk"]?.equals("true", ignoreCase = true) ?: false
        val symbolsResolved = parsed["symbolsResolved"]?.equals("true", ignoreCase = true) ?: false
        val nativeFenceSyncCreate = parsed["nativeFenceSyncCreate"] ?: "not_run"
        val glFlushOk = parsed["glFlushOk"]?.equals("true", ignoreCase = true) ?: false
        val dupNativeFenceFd = parsed["dupNativeFenceFd"]?.toIntOrNull() ?: -1
        val fdOpenBeforeClose = parsed["fdOpenBeforeClose"]?.equals("true", ignoreCase = true) ?: false
        val waitOutcome = parsed["waitOutcome"] ?: "not_run"
        val waitSignaled = parsed["waitSignaled"]?.equals("true", ignoreCase = true) ?: false
        val closeResult = parsed["closeResult"] ?: "not_run"
        val fdClosedAfterClose = parsed["fdClosedAfterClose"]?.equals("true", ignoreCase = true) ?: false
        val destroySync = parsed["destroySync"] ?: "not_run"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_native_fence_fd_lifecycle_no_release_fence_production_no_import_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "initialize" to initialize,
            "eglCurrentDisplayOk" to eglCurrentDisplayOk,
            "symbolsResolved" to symbolsResolved,
            "nativeFenceSyncCreate" to nativeFenceSyncCreate,
            "glFlushOk" to glFlushOk,
            "dupNativeFenceFd" to dupNativeFenceFd,
            "fdOpenBeforeClose" to fdOpenBeforeClose,
            "waitOutcome" to waitOutcome,
            "waitSignaled" to waitSignaled,
            "closeResult" to closeResult,
            "fdClosedAfterClose" to fdClosedAfterClose,
            "destroySync" to destroySync,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesNativeFenceFdFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;initialize=not_run;" +
            "eglCurrentDisplayOk=false;symbolsResolved=false;nativeFenceSyncCreate=not_run;glFlushOk=false;" +
            "dupNativeFenceFd=-1;fdOpenBeforeClose=false;waitOutcome=not_run;waitSignaled=false;" +
            "closeResult=not_run;fdClosedAfterClose=false;destroySync=not_run;shutdown=not_run;idempotentShutdown=not_run;" +
            "proofBoundary=gles_native_fence_fd_lifecycle_no_release_fence_production_no_import_no_product;lastError=$reason"

    // ── Phase 1-Unit AL: Android GLES releaseHardwareBuffer nullptr release-fence output physical proof ──
    private const val RESULT_MARKER_PHASE1AL = "ANDROID_GLES_RELEASE_NULL_FENCE_UNIT_AL_NATIVE_RESULT"

    fun runGlesReleaseNullFenceSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesReleaseNullFenceFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesReleaseNullFenceFailure("api_below_26")
                return parseGlesReleaseNullFenceResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesReleaseNullFenceFailure("invalid_dimensions")
                return parseGlesReleaseNullFenceResult(raw)
            }

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
            raw = nativeBridge.runAndroidDagPhase1ALGlesReleaseNullFenceSmoke(
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesReleaseNullFenceResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesReleaseNullFenceFailure("exception:$reason")
            return parseGlesReleaseNullFenceResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AL $raw")
            try {
                hardwareBuffer?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun parseGlesReleaseNullFenceResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val bufferDescribe = parsed["bufferDescribe"] ?: "not_run"
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val bufferUsageSampled = parsed["bufferUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val initialize = parsed["initialize"] ?: "not_run"
        val import1 = parsed["import1"] ?: "not_run"
        val handle1 = parsed["handle1"]?.toLongOrNull() ?: 0L
        val desc1Width = parsed["desc1Width"]?.toIntOrNull() ?: 0
        val desc1Height = parsed["desc1Height"]?.toIntOrNull() ?: 0
        val desc1Layers = parsed["desc1Layers"]?.toIntOrNull() ?: 0
        val desc1Format = parsed["desc1Format"]?.toIntOrNull() ?: 0
        val desc1UsageSampled = parsed["desc1UsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport1 = parsed["hasAfterImport1"]?.equals("true", ignoreCase = true) ?: false
        val nullFenceRelease1 = parsed["nullFenceRelease1"] ?: "not_run"
        val hasAfterNullFenceRelease1 = parsed["hasAfterNullFenceRelease1"]?.equals("true", ignoreCase = true) ?: false
        val nullFenceDoubleRelease1 = parsed["nullFenceDoubleRelease1"] ?: "not_run"
        val import2 = parsed["import2"] ?: "not_run"
        val handle2 = parsed["handle2"]?.toLongOrNull() ?: 0L
        val desc2Width = parsed["desc2Width"]?.toIntOrNull() ?: 0
        val desc2Height = parsed["desc2Height"]?.toIntOrNull() ?: 0
        val desc2Layers = parsed["desc2Layers"]?.toIntOrNull() ?: 0
        val desc2Format = parsed["desc2Format"]?.toIntOrNull() ?: 0
        val desc2UsageSampled = parsed["desc2UsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport2 = parsed["hasAfterImport2"]?.equals("true", ignoreCase = true) ?: false
        val release2 = parsed["release2"] ?: "not_run"
        val release2Fence = parsed["release2Fence"]?.toIntOrNull() ?: -1
        val hasAfterRelease2 = parsed["hasAfterRelease2"]?.equals("true", ignoreCase = true) ?: false
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_release_null_fence_output_contract_no_release_fence_production_no_render_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "bufferUsageSampled" to bufferUsageSampled,
            "initialize" to initialize,
            "import1" to import1,
            "handle1" to handle1,
            "desc1Width" to desc1Width,
            "desc1Height" to desc1Height,
            "desc1Layers" to desc1Layers,
            "desc1Format" to desc1Format,
            "desc1UsageSampled" to desc1UsageSampled,
            "hasAfterImport1" to hasAfterImport1,
            "nullFenceRelease1" to nullFenceRelease1,
            "hasAfterNullFenceRelease1" to hasAfterNullFenceRelease1,
            "nullFenceDoubleRelease1" to nullFenceDoubleRelease1,
            "import2" to import2,
            "handle2" to handle2,
            "desc2Width" to desc2Width,
            "desc2Height" to desc2Height,
            "desc2Layers" to desc2Layers,
            "desc2Format" to desc2Format,
            "desc2UsageSampled" to desc2UsageSampled,
            "hasAfterImport2" to hasAfterImport2,
            "release2" to release2,
            "release2Fence" to release2Fence,
            "hasAfterRelease2" to hasAfterRelease2,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesReleaseNullFenceFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=not_run;bufferWidth=0;bufferHeight=0;bufferLayers=0;bufferFormat=0;bufferUsageSampled=false;" +
            "initialize=not_run;import1=not_run;handle1=0;desc1Width=0;desc1Height=0;desc1Layers=0;desc1Format=0;desc1UsageSampled=false;hasAfterImport1=false;" +
            "nullFenceRelease1=not_run;hasAfterNullFenceRelease1=false;nullFenceDoubleRelease1=not_run;import2=not_run;handle2=0;desc2Width=0;desc2Height=0;desc2Layers=0;desc2Format=0;desc2UsageSampled=false;hasAfterImport2=false;" +
            "release2=not_run;release2Fence=-1;hasAfterRelease2=false;shutdown=not_run;idempotentShutdown=not_run;" +
            "proofBoundary=gles_release_null_fence_output_contract_no_release_fence_production_no_render_no_product;lastError=$reason"

    // ── Phase 1-Unit AM: Android GLES renderFrame -> EGL native-fence GPU chain physical proof ──
    private const val RESULT_MARKER_PHASE1AM = "ANDROID_GLES_RENDER_FENCE_CHAIN_UNIT_AM_NATIVE_RESULT"

    fun runGlesRenderFenceChainSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesRenderFenceChainFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesRenderFenceChainFailure("api_below_26")
                return parseGlesRenderFenceChainResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesRenderFenceChainFailure("invalid_dimensions")
                return parseGlesRenderFenceChainResult(raw)
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
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1AMGlesRenderFenceChainSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesRenderFenceChainResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesRenderFenceChainFailure("exception:$reason")
            return parseGlesRenderFenceChainResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AM $raw")
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

    private fun parseGlesRenderFenceChainResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val bufferDescribe = parsed["bufferDescribe"] ?: "not_run"
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val bufferUsageSampled = parsed["bufferUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val bufferUsageCpuWrite = parsed["bufferUsageCpuWrite"]?.equals("true", ignoreCase = true) ?: false
        val bufferFill = parsed["bufferFill"] ?: "not_run"
        val writeFenceFd = parsed["writeFenceFd"]?.toIntOrNull() ?: -1
        val writeFenceWait = parsed["writeFenceWait"] ?: "none"
        val initialize = parsed["initialize"] ?: "not_run"
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val import = parsed["import"] ?: "not_run"
        val handle = parsed["handle"]?.toLongOrNull() ?: 0L
        val hasAfterImport = parsed["hasAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val renderFrame = parsed["renderFrame"] ?: "not_run"
        val eglCurrentDisplayOk = parsed["eglCurrentDisplayOk"]?.equals("true", ignoreCase = true) ?: false
        val symbolsResolved = parsed["symbolsResolved"]?.equals("true", ignoreCase = true) ?: false
        val nativeFenceSyncCreate = parsed["nativeFenceSyncCreate"] ?: "not_run"
        val glFlushOk = parsed["glFlushOk"]?.equals("true", ignoreCase = true) ?: false
        val dupNativeFenceFd = parsed["dupNativeFenceFd"]?.toIntOrNull() ?: -1
        val fdOpenBeforeClose = parsed["fdOpenBeforeClose"]?.equals("true", ignoreCase = true) ?: false
        val waitOutcome = parsed["waitOutcome"] ?: "not_run"
        val waitSignaled = parsed["waitSignaled"]?.equals("true", ignoreCase = true) ?: false
        val closeResult = parsed["closeResult"] ?: "not_run"
        val fdClosedAfterClose = parsed["fdClosedAfterClose"]?.equals("true", ignoreCase = true) ?: false
        val destroySync = parsed["destroySync"] ?: "not_run"
        val releaseBuffer = parsed["releaseBuffer"] ?: "not_run"
        val releaseFence = parsed["releaseFence"]?.toIntOrNull() ?: -1
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_renderFrame_native_fence_chain_no_release_fence_production_no_yuv_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "bufferUsageSampled" to bufferUsageSampled,
            "bufferUsageCpuWrite" to bufferUsageCpuWrite,
            "bufferFill" to bufferFill,
            "writeFenceFd" to writeFenceFd,
            "writeFenceWait" to writeFenceWait,
            "initialize" to initialize,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "import" to import,
            "handle" to handle,
            "hasAfterImport" to hasAfterImport,
            "renderFrame" to renderFrame,
            "eglCurrentDisplayOk" to eglCurrentDisplayOk,
            "symbolsResolved" to symbolsResolved,
            "nativeFenceSyncCreate" to nativeFenceSyncCreate,
            "glFlushOk" to glFlushOk,
            "dupNativeFenceFd" to dupNativeFenceFd,
            "fdOpenBeforeClose" to fdOpenBeforeClose,
            "waitOutcome" to waitOutcome,
            "waitSignaled" to waitSignaled,
            "closeResult" to closeResult,
            "fdClosedAfterClose" to fdClosedAfterClose,
            "destroySync" to destroySync,
            "releaseBuffer" to releaseBuffer,
            "releaseFence" to releaseFence,
            "hasAfterRelease" to hasAfterRelease,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesRenderFenceChainFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=not_run;bufferWidth=0;bufferHeight=0;bufferLayers=0;bufferFormat=0;bufferUsageSampled=false;bufferUsageCpuWrite=false;bufferFill=not_run;writeFenceFd=-1;writeFenceWait=none;initialize=not_run;attach=not_run;hasSurfaceAfterAttach=false;import=not_run;handle=0;hasAfterImport=false;renderFrame=not_run;eglCurrentDisplayOk=false;symbolsResolved=false;nativeFenceSyncCreate=not_run;glFlushOk=false;dupNativeFenceFd=-1;fdOpenBeforeClose=false;waitOutcome=not_run;waitSignaled=false;closeResult=not_run;fdClosedAfterClose=false;destroySync=not_run;releaseBuffer=not_run;releaseFence=-1;hasAfterRelease=false;detach=not_run;surfaceKindAfterDetach=none;shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_renderFrame_native_fence_chain_no_release_fence_production_no_yuv_no_product;lastError=$reason"

    // ── Phase 1-Unit AN: Android GLES acquire-fence import -> renderFrame content physical proof ──
    private const val RESULT_MARKER_PHASE1AN = "ANDROID_GLES_ACQUIRE_FENCE_RENDER_CONTENT_UNIT_AN_NATIVE_RESULT"

    fun runGlesAcquireFenceRenderContentSmoke(width: Int = 64, height: Int = 64): Map<String, Any?> {
        var surfaceTexture: SurfaceTexture? = null
        var surface: Surface? = null
        var hardwareBuffer: HardwareBuffer? = null
        var raw = glesAcquireFenceRenderContentFailure("not_run")

        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                raw = glesAcquireFenceRenderContentFailure("api_below_26")
                return parseGlesAcquireFenceRenderContentResult(raw)
            }
            if (width <= 0 || height <= 0) {
                raw = glesAcquireFenceRenderContentFailure("invalid_dimensions")
                return parseGlesAcquireFenceRenderContentResult(raw)
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
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_CPU_WRITE_OFTEN,
            )

            val diagnostics = VanguardDiagnostics()
            val nativeBridge = VanguardNativeBridge(
                VanguardLifecycleObserver(diagnostics),
                diagnostics,
                null,
            )
            raw = nativeBridge.runAndroidDagPhase1ANGlesAcquireFenceRenderContentSmoke(
                surface,
                hardwareBuffer,
                width,
                height,
            )
            return parseGlesAcquireFenceRenderContentResult(raw)
        } catch (throwable: Throwable) {
            val reason = throwable.javaClass.simpleName.ifEmpty { "unknown_exception" }
            raw = glesAcquireFenceRenderContentFailure("exception:$reason")
            return parseGlesAcquireFenceRenderContentResult(raw)
        } finally {
            Log.i(TAG, "$RESULT_MARKER_PHASE1AN $raw")
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

    private fun parseGlesAcquireFenceRenderContentResult(raw: String): Map<String, Any?> {
        val parsed = mutableMapOf<String, String>()
        raw.split(';').forEach { token ->
            val eq = token.indexOf('=')
            if (eq > 0) {
                parsed[token.substring(0, eq).trim()] = token.substring(eq + 1).trim()
            }
        }
        val pass = raw.startsWith("status=PASS;")
        val clientVersion = parsed["clientVersion"]?.toIntOrNull() ?: 0
        val vendor = parsed["vendor"] ?: ""
        val renderer = parsed["renderer"] ?: ""
        val version = parsed["version"] ?: ""
        val bufferDescribe = parsed["bufferDescribe"] ?: "not_run"
        val bufferWidth = parsed["bufferWidth"]?.toIntOrNull() ?: 0
        val bufferHeight = parsed["bufferHeight"]?.toIntOrNull() ?: 0
        val bufferLayers = parsed["bufferLayers"]?.toIntOrNull() ?: 0
        val bufferFormat = parsed["bufferFormat"]?.toIntOrNull() ?: 0
        val bufferUsageSampled = parsed["bufferUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val bufferUsageCpuWrite = parsed["bufferUsageCpuWrite"]?.equals("true", ignoreCase = true) ?: false
        val bufferFill = parsed["bufferFill"] ?: "not_run"
        val writeFenceFd = parsed["writeFenceFd"]?.toIntOrNull() ?: -1
        val writeFenceWait = parsed["writeFenceWait"] ?: "none"
        val initialize = parsed["initialize"] ?: "not_run"
        val eglCurrentDisplayOk = parsed["eglCurrentDisplayOk"]?.equals("true", ignoreCase = true) ?: false
        val symbolsResolved = parsed["symbolsResolved"]?.equals("true", ignoreCase = true) ?: false
        val acquireFenceCreate = parsed["acquireFenceCreate"] ?: "not_run"
        val glFlushOk = parsed["glFlushOk"]?.equals("true", ignoreCase = true) ?: false
        val acquireFenceFd = parsed["acquireFenceFd"]?.toIntOrNull() ?: -1
        val acquireFenceOpenBeforeImport = parsed["acquireFenceOpenBeforeImport"]?.equals("true", ignoreCase = true) ?: false
        val acquireFenceDestroyed = parsed["acquireFenceDestroyed"]?.equals("true", ignoreCase = true) ?: false
        val attach = parsed["attach"] ?: "not_run"
        val hasSurfaceAfterAttach = parsed["hasSurfaceAfterAttach"]?.equals("true", ignoreCase = true) ?: false
        val import = parsed["import"] ?: "not_run"
        val acquireFenceClosedAfterImport = parsed["acquireFenceClosedAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val handle = parsed["handle"]?.toLongOrNull() ?: 0L
        val descriptorWidth = parsed["descriptorWidth"]?.toIntOrNull() ?: 0
        val descriptorHeight = parsed["descriptorHeight"]?.toIntOrNull() ?: 0
        val descriptorLayers = parsed["descriptorLayers"]?.toIntOrNull() ?: 0
        val descriptorFormat = parsed["descriptorFormat"]?.toIntOrNull() ?: 0
        val descriptorUsageSampled = parsed["descriptorUsageSampled"]?.equals("true", ignoreCase = true) ?: false
        val hasAfterImport = parsed["hasAfterImport"]?.equals("true", ignoreCase = true) ?: false
        val diagnosticRender = parsed["diagnosticRender"] ?: "not_run"
        val centerRead = parsed["centerRead"] ?: "not_run"
        val centerR = parsed["centerR"]?.toIntOrNull() ?: 0
        val centerG = parsed["centerG"]?.toIntOrNull() ?: 0
        val centerB = parsed["centerB"]?.toIntOrNull() ?: 0
        val centerA = parsed["centerA"]?.toIntOrNull() ?: 0
        val centerPixelMatches = parsed["centerPixelMatches"]?.equals("true", ignoreCase = true) ?: false
        val releaseBuffer = parsed["releaseBuffer"] ?: "not_run"
        val releaseFence = parsed["releaseFence"]?.toIntOrNull() ?: -1
        val hasAfterRelease = parsed["hasAfterRelease"]?.equals("true", ignoreCase = true) ?: false
        val detach = parsed["detach"] ?: "not_run"
        val surfaceKindAfterDetach = parsed["surfaceKindAfterDetach"] ?: "none"
        val shutdown = parsed["shutdown"] ?: "not_run"
        val idempotentShutdown = parsed["idempotentShutdown"] ?: "not_run"
        val proofBoundary = parsed["proofBoundary"] ?: "gles_acquire_fence_import_render_content_no_release_fence_production_no_yuv_no_product"
        val lastError = parsed["lastError"] ?: ""

        return mapOf(
            "pass" to pass,
            "raw" to raw,
            "clientVersion" to clientVersion,
            "vendor" to vendor,
            "renderer" to renderer,
            "version" to version,
            "bufferDescribe" to bufferDescribe,
            "bufferWidth" to bufferWidth,
            "bufferHeight" to bufferHeight,
            "bufferLayers" to bufferLayers,
            "bufferFormat" to bufferFormat,
            "bufferUsageSampled" to bufferUsageSampled,
            "bufferUsageCpuWrite" to bufferUsageCpuWrite,
            "bufferFill" to bufferFill,
            "writeFenceFd" to writeFenceFd,
            "writeFenceWait" to writeFenceWait,
            "initialize" to initialize,
            "eglCurrentDisplayOk" to eglCurrentDisplayOk,
            "symbolsResolved" to symbolsResolved,
            "acquireFenceCreate" to acquireFenceCreate,
            "glFlushOk" to glFlushOk,
            "acquireFenceFd" to acquireFenceFd,
            "acquireFenceOpenBeforeImport" to acquireFenceOpenBeforeImport,
            "acquireFenceDestroyed" to acquireFenceDestroyed,
            "attach" to attach,
            "hasSurfaceAfterAttach" to hasSurfaceAfterAttach,
            "import" to import,
            "acquireFenceClosedAfterImport" to acquireFenceClosedAfterImport,
            "handle" to handle,
            "descriptorWidth" to descriptorWidth,
            "descriptorHeight" to descriptorHeight,
            "descriptorLayers" to descriptorLayers,
            "descriptorFormat" to descriptorFormat,
            "descriptorUsageSampled" to descriptorUsageSampled,
            "hasAfterImport" to hasAfterImport,
            "diagnosticRender" to diagnosticRender,
            "centerRead" to centerRead,
            "centerR" to centerR,
            "centerG" to centerG,
            "centerB" to centerB,
            "centerA" to centerA,
            "centerPixelMatches" to centerPixelMatches,
            "releaseBuffer" to releaseBuffer,
            "releaseFence" to releaseFence,
            "hasAfterRelease" to hasAfterRelease,
            "detach" to detach,
            "surfaceKindAfterDetach" to surfaceKindAfterDetach,
            "shutdown" to shutdown,
            "idempotentShutdown" to idempotentShutdown,
            "proofBoundary" to proofBoundary,
            "lastError" to lastError,
        )
    }

    private fun glesAcquireFenceRenderContentFailure(reason: String): String =
        "status=FAIL;clientVersion=0;vendor=;renderer=;version=;bufferDescribe=not_run;bufferWidth=0;bufferHeight=0;bufferLayers=0;bufferFormat=0;bufferUsageSampled=false;bufferUsageCpuWrite=false;bufferFill=not_run;writeFenceFd=-1;writeFenceWait=none;initialize=not_run;eglCurrentDisplayOk=false;symbolsResolved=false;acquireFenceCreate=not_run;glFlushOk=false;acquireFenceFd=-1;acquireFenceOpenBeforeImport=false;acquireFenceDestroyed=false;attach=not_run;hasSurfaceAfterAttach=false;import=not_run;acquireFenceClosedAfterImport=false;handle=0;descriptorWidth=0;descriptorHeight=0;descriptorLayers=0;descriptorFormat=0;descriptorUsageSampled=false;hasAfterImport=false;diagnosticRender=not_run;centerRead=not_run;centerR=0;centerG=0;centerB=0;centerA=0;centerPixelMatches=false;releaseBuffer=not_run;releaseFence=-1;hasAfterRelease=false;detach=not_run;surfaceKindAfterDetach=none;shutdown=not_run;idempotentShutdown=not_run;proofBoundary=gles_acquire_fence_import_render_content_no_release_fence_production_no_yuv_no_product;lastError=$reason"
}
