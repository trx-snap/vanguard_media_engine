package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import com.connects.vanguard_media_engine.export.AndroidAudioFoundationSmokeHarness
import io.flutter.plugin.common.MethodChannel

/**
 * Diagnostic MethodChannel coordinator for the Android True-DAG smoke routes.
 *
 * Owns the diagnostic-only smoke methods previously routed inline by
 * VanguardMediaEnginePlugin (Phase 2O2B3/2O2B4/2Q/3C/4A/5) plus the
 * Export/Audio Unit B audio foundation smoke. Every route runs on a background
 * Thread and posts exactly one result.success/result.error to [mainHandler].
 *
 * Diagnostic only: no production export, playback, or UI wiring lives here.
 */
class AndroidDagDiagnosticsCoordinator(
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
}
