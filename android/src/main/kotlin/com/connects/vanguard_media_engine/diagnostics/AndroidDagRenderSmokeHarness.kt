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
        val proofBoundary = parsed["proofBoundary"] ?: "gles_renderFrame_rgba_texture_quad_no_transform_no_yuv_no_fence_sync"
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
            "releaseA=not_run;releaseAFence=-1;hasAAfterRelease=false;hasBAfterReleaseA=false;releasedHandleRender=not_run;releasedHandleLastError=;" +
            "detach=not_run;surfaceKindAfterDetach=none;postDetachRenderB=not_run;postDetachLastError=;shutdown=not_run;" +
            "hasBAfterShutdown=false;idempotentShutdown=not_run;proofBoundary=gles_renderFrame_rgba_texture_quad_no_transform_no_yuv_no_fence_sync;lastError=$reason"
}
