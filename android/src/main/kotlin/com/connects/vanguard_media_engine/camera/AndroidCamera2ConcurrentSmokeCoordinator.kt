package com.connects.vanguard_media_engine.camera

import android.content.Context
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * P3-CAM-CONCURRENT: Camera2 dual-camera concurrent PRIVATE AHardwareBuffer
 * ingest verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route. Runs
 * [AndroidCamera2ConcurrentIngestSmokeHarness] on a background thread and
 * posts the result map back to [mainHandler]. Expected gate outcomes
 * (unsupported API, missing permission, unsupported concurrent
 * configuration, timeouts, native ingest/destroy failure) are returned as
 * result maps, never as MethodChannel errors.
 */
class AndroidCamera2ConcurrentSmokeCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP3CamConcurrent"
        private const val METHOD_NAME = "runAndroidDagPhase3CameraConcurrentIngestSmoke"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        runSmoke(args, result)
        return true
    }

    private fun runSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        Thread {
            val map = try {
                AndroidCamera2ConcurrentIngestSmokeHarness(context).run(args)
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME failed", t)
                mapOf(
                    "pass" to false,
                    "decision" to "harnessException",
                    "reasons" to listOf("exception:${t.javaClass.simpleName}:${t.message}"),
                )
            }
            mainHandler.post {
                result.success(map)
            }
        }.start()
    }
}
