package com.connects.vanguard_media_engine.rtc

import android.os.Handler
import io.flutter.plugin.common.MethodChannel

/**
 * Diagnostic MethodChannel coordinator for Vanguard Android True-DAG Phase 4C3D / Phase 4C3G / Phase 4C3K RTC video contracts, adapters, and metadata.
 *
 * ## Diagnostic & Video-Only Invariants
 * - **Diagnostic Only**: Exposes synthetic RTC video contract, adapter, and metadata verification harnesses over MethodChannel.
 * - **Video Only**: Operates strictly on video transport contracts. Vanguard RTC video publishers
 *   have zero ownership of room signaling, network tokens, participant rosters, audio streams,
 *   or microphone resources. Room orchestration and audio capture/mixing are strictly forbidden in Vanguard.
 * - **Zero LiveKit / Raw WebRTC Dependencies**: Pure video transport contract/adapter/metadata smoke test; does not touch
 *   LiveKit, WebRTC native rooms, audio tracks, or platform audio routing.
 */
class AndroidRtcVideoCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private val OWNED_METHODS = setOf(
            "runAndroidDagPhase4C3DRtcContractSmoke",
            "runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke",
            "runAndroidDagPhase4C3KRtcMetadataSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "runAndroidDagPhase4C3DRtcContractSmoke" -> runRtcContractSmoke(args, result)
            "runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke" -> runRealtimeVideoAdapterSmoke(args, result)
            "runAndroidDagPhase4C3KRtcMetadataSmoke" -> runRtcMetadataSmoke(args, result)
            else -> return false
        }
        return true
    }

    private fun runRtcContractSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 3

        Thread {
            val smokeResult = RtcVideoContractSmokeHarness.run(
                width = width,
                height = height,
                frameCount = frameCount,
            )
            mainHandler.post {
                result.success(smokeResult)
            }
        }.start()
    }

    private fun runRealtimeVideoAdapterSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 3

        Thread {
            val outputResult = RealtimeVideoOutputAdapterSmokeHarness.run(
                width = width,
                height = height,
                frameCount = frameCount,
            )
            val inputResult = RealtimeVideoInputAdapterSmokeHarness.run(
                width = width,
                height = height,
                frameCount = frameCount,
            )

            val outputPass = outputResult["pass"] == true
            val inputPass = inputResult["pass"] == true
            val overallPass = outputPass && inputPass

            val rawStatus = if (overallPass) {
                "status=OK;outputPass=true;inputPass=true"
            } else {
                "status=FAIL;outputPass=$outputPass;inputPass=$inputPass"
            }

            val combinedMap = mapOf(
                "pass" to overallPass,
                "output" to outputResult,
                "input" to inputResult,
                "width" to width,
                "height" to height,
                "frameCount" to frameCount,
                "raw" to rawStatus,
            )

            mainHandler.post {
                result.success(combinedMap)
            }
        }.start()
    }

    private fun runRtcMetadataSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        Thread {
            val timestampResult = RtcVideoTimestampMapperSmokeHarness.run()
            val orientationResult = RtcVideoOrientationPolicySmokeHarness.run()

            val timestampPass = timestampResult["pass"] == true
            val orientationPass = orientationResult["pass"] == true
            val overallPass = timestampPass && orientationPass

            val rawStatus = if (overallPass) {
                "status=OK;timestampPass=true;orientationPass=true"
            } else {
                "status=FAIL;timestampPass=$timestampPass;orientationPass=$orientationPass"
            }

            val combinedMap = mapOf(
                "pass" to overallPass,
                "timestamp" to timestampResult,
                "orientation" to orientationResult,
                "raw" to rawStatus,
            )

            mainHandler.post {
                result.success(combinedMap)
            }
        }.start()
    }
}
