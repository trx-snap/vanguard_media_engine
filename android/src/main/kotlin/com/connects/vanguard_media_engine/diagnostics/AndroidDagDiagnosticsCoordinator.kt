package com.connects.vanguard_media_engine.diagnostics

import android.content.Context
import android.os.Handler
import com.connects.vanguard_media_engine.camera.AndroidCamera2CapabilityProbe
import com.connects.vanguard_media_engine.camera.AndroidCamera2ConcurrentSessionValidator
import com.connects.vanguard_media_engine.camera.AndroidCamera2HardwareBufferFrameSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2ImageReaderFrameSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2NativeRenderFrameSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2NativeRenderLoopSmokeHarness
import com.connects.vanguard_media_engine.camera.AndroidCamera2OpenCloseSmokeHarness
import com.connects.vanguard_media_engine.export.AndroidAudioFoundationSmokeHarness
import io.flutter.plugin.common.MethodChannel

/**
 * Diagnostic MethodChannel coordinator for the Android True-DAG smoke routes.
 *
 * Owns the diagnostic-only smoke methods previously routed inline by
 * VanguardMediaEnginePlugin (Phase 2O2B3/2O2B4/2Q/3C/4A/5) plus the
 * Export/Audio Unit B audio foundation smoke and the Phase 3-Unit A Camera2
 * capability probe. Every route runs on a background Thread and posts exactly
 * one result.success/result.error to [mainHandler].
 *
 * Diagnostic only: no production export, playback, or UI wiring lives here.
 */
class AndroidDagDiagnosticsCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private val OWNED_METHODS = setOf(
            "runAndroidDagPhase2O2B3PhysicalSmoke",
            "runAndroidDagPhase2O2B4MultiFrameSmoke",
            "runAndroidDagPhase2QCapabilityProbe",
            "runAndroidDagPhase3CEvalRenderSmoke",
            "runAndroidDagPhase4ADecoderSmoke",
            "runAndroidDagPhase5EncoderSurfaceSmoke",
            "runAndroidDagAudioFoundationSmoke",
            "runAndroidDagPhase3UnitACameraCapabilityProbe",
            "runAndroidDagPhase3UnitFConcurrentSessionValidation",
            "runAndroidDagPhase3UnitHCameraOpenCloseSmoke",
            "runAndroidDagPhase3UnitIImageReaderFrameSmoke",
            "runAndroidDagPhase3UnitJHardwareBufferFrameSmoke",
            "runAndroidDagPhase3UnitKCameraNativeRenderSmoke",
            "runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke",
            "runAndroidDagPhase1UGlesBackendSmoke",
            "runAndroidDagPhase1VGlesSurfaceSmoke",
            "runAndroidDagPhase1WGlesWindowPresentSmoke",
            "runAndroidDagPhase1XGlesShaderQuadSmoke",
            "runAndroidDagPhase1YGlesImportSmoke",
            "runAndroidDagPhase1ZGlesRenderFrameSmoke",
            "runAndroidDagPhase1ABGlesReadPixelsSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "runAndroidDagPhase2O2B3PhysicalSmoke" -> runPhase2O2B3PhysicalSmoke(args, result)
            "runAndroidDagPhase2O2B4MultiFrameSmoke" -> runPhase2O2B4MultiFrameSmoke(args, result)
            "runAndroidDagPhase2QCapabilityProbe" -> runPhase2QCapabilityProbe(result)
            "runAndroidDagPhase3CEvalRenderSmoke" -> runPhase3CEvalRenderSmoke(args, result)
            "runAndroidDagPhase4ADecoderSmoke" -> runPhase4ADecoderSmoke(args, result)
            "runAndroidDagPhase5EncoderSurfaceSmoke" -> runPhase5EncoderSurfaceSmoke(args, result)
            "runAndroidDagAudioFoundationSmoke" -> runAudioFoundationSmoke(args, result)
            "runAndroidDagPhase3UnitACameraCapabilityProbe" -> runPhase3UnitACameraCapabilityProbe(result)
            "runAndroidDagPhase3UnitFConcurrentSessionValidation" ->
                runPhase3UnitFConcurrentSessionValidation(args, result)
            "runAndroidDagPhase3UnitHCameraOpenCloseSmoke" ->
                runPhase3UnitHCameraOpenCloseSmoke(args, result)
            "runAndroidDagPhase3UnitIImageReaderFrameSmoke" ->
                runPhase3UnitIImageReaderFrameSmoke(args, result)
            "runAndroidDagPhase3UnitJHardwareBufferFrameSmoke" ->
                runPhase3UnitJHardwareBufferFrameSmoke(args, result)
            "runAndroidDagPhase3UnitKCameraNativeRenderSmoke" ->
                runPhase3UnitKCameraNativeRenderSmoke(args, result)
            "runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke" ->
                runPhase3UnitLCameraNativeRenderLoopSmoke(args, result)
            "runAndroidDagPhase1UGlesBackendSmoke" -> runPhase1UGlesBackendSmoke(result)
            "runAndroidDagPhase1VGlesSurfaceSmoke" -> runPhase1VGlesSurfaceSmoke(args, result)
            "runAndroidDagPhase1WGlesWindowPresentSmoke" -> runPhase1WGlesWindowPresentSmoke(args, result)
            "runAndroidDagPhase1XGlesShaderQuadSmoke" -> runPhase1XGlesShaderQuadSmoke(args, result)
            "runAndroidDagPhase1YGlesImportSmoke" -> runPhase1YGlesImportSmoke(args, result)
            "runAndroidDagPhase1ZGlesRenderFrameSmoke" -> runPhase1ZGlesRenderFrameSmoke(args, result)
            "runAndroidDagPhase1ABGlesReadPixelsSmoke" -> runPhase1ABGlesReadPixelsSmoke(args, result)
            else -> return false
        }
        return true
    }

    private fun runPhase2O2B3PhysicalSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.run(width, height)
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runPhase2O2B4MultiFrameSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 30
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.runMultiFrame(width, height, frameCount)
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runPhase2QCapabilityProbe(result: MethodChannel.Result) {
        Thread {
            val probeResult = AndroidDagRenderSmokeHarness.runCapabilityProbe()
            mainHandler.post { result.success(probeResult) }
        }.start()
    }

    private fun runPhase3CEvalRenderSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width           = (args?.get("width")           as? Number)?.toInt()  ?: 64
        val height          = (args?.get("height")          as? Number)?.toInt()  ?: 64
        val frameCount      = (args?.get("frameCount")      as? Number)?.toInt()  ?: 30
        val frameDurationUs = (args?.get("frameDurationUs") as? Number)?.toLong() ?: 33333L
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.runDagEvaluationSmoke(
                width, height, frameCount, frameDurationUs,
            )
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runPhase4ADecoderSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val path       = args?.get("path")       as? String
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 10
        if (path == null) {
            result.error("INVALID_ARG", "runAndroidDagPhase4ADecoderSmoke: path required", null)
            return
        }
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.runDecoderSmoke(
                videoPath  = path,
                frameCount = frameCount,
            )
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    private fun runPhase5EncoderSurfaceSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val outputPath = args?.get("outputPath") as? String
        if (outputPath.isNullOrBlank()) {
            result.error("INVALID_ARG", "runAndroidDagPhase5EncoderSurfaceSmoke: outputPath required", null)
            return
        }
        val width           = (args["width"]           as? Number)?.toInt()  ?: 64
        val height          = (args["height"]          as? Number)?.toInt()  ?: 64
        val frameCount      = (args["frameCount"]      as? Number)?.toInt()  ?: 10
        val frameDurationUs = (args["frameDurationUs"] as? Number)?.toLong() ?: 33333L
        val bitrate         = (args["bitrate"]         as? Number)?.toInt()  ?: 1_000_000
        Thread {
            val smokeResult = AndroidDagRenderSmokeHarness.runEncoderSurfaceSmoke(
                width           = width,
                height          = height,
                frameCount      = frameCount,
                frameDurationUs = frameDurationUs,
                bitrate         = bitrate,
                outputPath      = outputPath,
            )
            mainHandler.post { result.success(smokeResult) }
        }.start()
    }

    // ── Export/Audio Unit B: two-pass audio foundation smoke ─────────────────
    private fun runAudioFoundationSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val videoPath = args?.get("videoPath") as? String
        val audioPath = args?.get("audioPath") as? String
        val outputDir = args?.get("outputDir") as? String
        if (videoPath.isNullOrBlank() || audioPath.isNullOrBlank() || outputDir.isNullOrBlank()) {
            result.error(
                "INVALID_ARG",
                "runAndroidDagAudioFoundationSmoke: videoPath, audioPath, and outputDir required",
                null,
            )
            return
        }
        Thread {
            // The harness catches its own failures and returns a fail map; this
            // guard guarantees exactly one MethodChannel result regardless.
            try {
                val smokeResult = AndroidAudioFoundationSmokeHarness.run(
                    videoPath = videoPath,
                    audioPath = audioPath,
                    outputDir = outputDir,
                )
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "AUDIO_FOUNDATION_SMOKE_FAILED",
                        "runAndroidDagAudioFoundationSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit A: Android Camera2 capability probe ─────────────────────
    private fun runPhase3UnitACameraCapabilityProbe(result: MethodChannel.Result) {
        Thread {
            try {
                val probeResult = AndroidCamera2CapabilityProbe(context).probe()
                mainHandler.post { result.success(probeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_CAPABILITY_PROBE_FAILED",
                        "runAndroidDagPhase3UnitACameraCapabilityProbe: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit F: Android Camera2 guarded concurrent SessionConfiguration validation ──
    private fun runPhase3UnitFConcurrentSessionValidation(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val validationResult = AndroidCamera2ConcurrentSessionValidator(context).validate(args)
                mainHandler.post { result.success(validationResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CONCURRENT_SESSION_VALIDATION_FAILED",
                        "runAndroidDagPhase3UnitFConcurrentSessionValidation: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit H: Android Camera2 single-camera open/close lifecycle smoke ──
    private fun runPhase3UnitHCameraOpenCloseSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2OpenCloseSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_OPEN_CLOSE_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitHCameraOpenCloseSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit I: Android Camera2 single-camera ImageReader frame smoke ──
    private fun runPhase3UnitIImageReaderFrameSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2ImageReaderFrameSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_IMAGE_READER_FRAME_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitIImageReaderFrameSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit J: Android Camera2 single-camera PRIVATE ImageReader HardwareBuffer frame smoke ──
    private fun runPhase3UnitJHardwareBufferFrameSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2HardwareBufferFrameSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_HARDWARE_BUFFER_FRAME_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitJHardwareBufferFrameSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit K: Android Camera2 PRIVATE ImageReader HardwareBuffer native-render frame smoke ──
    private fun runPhase3UnitKCameraNativeRenderSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2NativeRenderFrameSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_NATIVE_RENDER_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitKCameraNativeRenderSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 3-Unit L: Android Camera2 PRIVATE ImageReader HardwareBuffer native-render multi-frame render loop smoke ──
    private fun runPhase3UnitLCameraNativeRenderLoopSmoke(
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val smokeResult = AndroidCamera2NativeRenderLoopSmokeHarness(context).run(args)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "CAMERA_NATIVE_RENDER_LOOP_SMOKE_FAILED",
                        "runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke: " +
                            "${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit U: Android GLES backend offscreen EGL lifecycle smoke ──
    private fun runPhase1UGlesBackendSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesBackendSmoke()
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_BACKEND_SMOKE_FAILED",
                        "runAndroidDagPhase1UGlesBackendSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit V: Android GLES backend window-surface attach/detach smoke ──
    private fun runPhase1VGlesSurfaceSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesSurfaceSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_SURFACE_SMOKE_FAILED",
                        "runAndroidDagPhase1VGlesSurfaceSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit W: Android GLES backend window-surface clear/swap presentation diagnostic ──
    private fun runPhase1WGlesWindowPresentSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesWindowPresentSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_WINDOW_PRESENT_SMOKE_FAILED",
                        "runAndroidDagPhase1WGlesWindowPresentSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit X: Android GLES backend window-surface shader-quad draw/swap presentation diagnostic ──
    private fun runPhase1XGlesShaderQuadSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesShaderQuadSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_SHADER_QUAD_SMOKE_FAILED",
                        "runAndroidDagPhase1XGlesShaderQuadSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit Y: Android GLES backend AHardwareBuffer RGBA import foundation smoke ──
    private fun runPhase1YGlesImportSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesImportSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_IMPORT_SMOKE_FAILED",
                        "runAndroidDagPhase1YGlesImportSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit Z: Android GLES backend identity renderFrame textured-quad presentation smoke ──
    private fun runPhase1ZGlesRenderFrameSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesRenderFrameSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_RENDER_FRAME_SMOKE_FAILED",
                        "runAndroidDagPhase1ZGlesRenderFrameSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }

    // ── Phase 1-Unit AB: Android GLES backend diagnostic read-pixels physical smoke ──
    private fun runPhase1ABGlesReadPixelsSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        Thread {
            try {
                val smokeResult = AndroidDagRenderSmokeHarness.runGlesReadPixelsSmoke(width, height)
                mainHandler.post { result.success(smokeResult) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error(
                        "GLES_READ_PIXELS_SMOKE_FAILED",
                        "runAndroidDagPhase1ABGlesReadPixelsSmoke: ${t.javaClass.simpleName}: ${t.message}",
                        null,
                    )
                }
            }
        }.start()
    }
}
