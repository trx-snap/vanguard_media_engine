package com.connects.vanguard_media_engine.rtc

import android.os.Handler
import io.flutter.plugin.common.MethodChannel

/**
 * Diagnostic MethodChannel coordinator for Vanguard Android True-DAG Phase 4C3D / Phase 4C3G / Phase 4C3K / Phase 4C3N / Phase 4C3Q / Phase 4C3U / Phase 4C4C RTC video contracts, adapters, metadata, backpressure, frame validator, processed video egress, and jitter buffer controller.
 *
 * ## Diagnostic & Video-Only Invariants
 * - **Diagnostic Only**: Exposes synthetic RTC video contract, adapter, metadata, backpressure, frame validator, and jitter buffer verification harnesses over MethodChannel.
 * - **Video Only**: Operates strictly on video transport contracts. Vanguard RTC video publishers
 *   have zero ownership of room signaling, network tokens, participant rosters, audio streams,
 *   or microphone resources. Room orchestration and audio capture/mixing are strictly forbidden in Vanguard.
 * - **Zero LiveKit / Raw WebRTC Dependencies**: Pure video transport contract/adapter/metadata/backpressure/validator/jitter-buffer smoke test; does not touch
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
            "runAndroidDagPhase4C3NRtcBackpressureSmoke",
            "runAndroidDagPhase4C3QRtcFrameValidatorSmoke",
            "runAndroidDagPhase4C3UProcessedVideoEgressSmoke",
            "runAndroidDagPhase4C4BRtcJitterBufferSmoke",
            "runAndroidDagPhase6WebRtcIngestStreamSourceSeamSmoke",
            "runAndroidDagPhase6EncodedVideoEgressSeamSmoke",
            "runAndroidDagPhase6MediaCodecEncoderEgressSmoke",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "runAndroidDagPhase4C3DRtcContractSmoke" -> runRtcContractSmoke(args, result)
            "runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke" -> runRealtimeVideoAdapterSmoke(args, result)
            "runAndroidDagPhase4C3KRtcMetadataSmoke" -> runRtcMetadataSmoke(args, result)
            "runAndroidDagPhase4C3NRtcBackpressureSmoke" -> runRtcBackpressureSmoke(args, result)
            "runAndroidDagPhase4C3QRtcFrameValidatorSmoke" -> runRtcFrameValidatorSmoke(args, result)
            "runAndroidDagPhase4C3UProcessedVideoEgressSmoke" -> runProcessedVideoEgressSmoke(args, result)
            "runAndroidDagPhase4C4BRtcJitterBufferSmoke" -> runRtcJitterBufferSmoke(args, result)
            "runAndroidDagPhase6WebRtcIngestStreamSourceSeamSmoke" -> runWebRtcIngestStreamSourceSeamSmoke(args, result)
            "runAndroidDagPhase6EncodedVideoEgressSeamSmoke" -> runEncodedVideoEgressSeamSmoke(args, result)
            "runAndroidDagPhase6MediaCodecEncoderEgressSmoke" -> runMediaCodecEncoderEgressSmoke(args, result)
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

    private fun runRtcBackpressureSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        Thread {
            val backpressureResult = RtcVideoBackpressureSmokeHarness.run()
            mainHandler.post {
                result.success(backpressureResult)
            }
        }.start()
    }

    private fun runRtcFrameValidatorSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64

        Thread {
            val smokeResult = RtcVideoFrameValidatorSmokeHarness.run(
                width = width,
                height = height,
            )
            mainHandler.post {
                result.success(smokeResult)
            }
        }.start()
    }

    private fun runProcessedVideoEgressSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 3

        Thread {
            val smokeResult = ProcessedVideoFrameEgressSmokeHarness.run(
                width = width,
                height = height,
                frameCount = frameCount,
            )
            mainHandler.post {
                result.success(smokeResult)
            }
        }.start()
    }

    private fun runRtcJitterBufferSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 5

        Thread {
            val smokeResult = RtcVideoJitterBufferSmokeHarness.run(
                frameCount = frameCount,
            )
            mainHandler.post {
                result.success(smokeResult)
            }
        }.start()
    }

    // P6-WEBRTC-INGEST-STREAM-SOURCE-SEAM-A: diagnostic, video-only RTC ingest seam proving
    // RealtimeVideoInputAdapter/RtcVideoFrameSink can forward frame metadata into a real native
    // vanguard::sources::StreamSourceNode-backed session. No real WebRTC/LiveKit SDK, no network
    // room/session, no audio, no rendering, no product/editor/app wiring.
    private fun runWebRtcIngestStreamSourceSeamSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val width = (args?.get("width") as? Number)?.toInt() ?: 64
        val height = (args?.get("height") as? Number)?.toInt() ?: 64
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 3

        Thread {
            val smokeResult = NativeStreamSourceRtcIngestSmokeHarness.run(
                width = width,
                height = height,
                frameCount = frameCount,
            )
            mainHandler.post {
                result.success(smokeResult)
            }
        }.start()
    }

    // P6-STREAM-EGRESS-ENCODED-SEAM-A: transport-neutral encoded video egress foundation seam
    // proving RealtimeEncodedVideoOutputAdapter, RtcEncodedVideoFrame, RtcEncodedVideoFramePublisher,
    // keyframe gating, scoped-borrow, and backpressure.
    private fun runEncodedVideoEgressSeamSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        val frameCount = (args?.get("frameCount") as? Number)?.toInt() ?: 3

        Thread {
            val smokeResult = RealtimeEncodedVideoOutputSmokeHarness.run(
                frameCount = frameCount,
            )
            mainHandler.post {
                result.success(smokeResult)
            }
        }.start()
    }

    // P6-STREAM-EGRESS-HW-ENCODER-BRIDGE-A: bounded package hardware-encoder-output seam proving
    // MediaCodecEncodedVideoOutputBridge drives a real hardware MediaCodec AVC encoder end to end
    // into RealtimeEncodedVideoOutputAdapter / RtcEncodedVideoFramePublisher. No MediaMuxer, no
    // file IO, no network sockets, no RTMP, no WebRTC/LiveKit SDK, no audio, no product/app/editor
    // wiring. Closes only the package hardware-encoder-output seam, not network publish.
    private fun runMediaCodecEncoderEgressSmoke(args: Map<*, *>?, result: MethodChannel.Result) {
        Thread {
            val smokeResult = MediaCodecEncodedVideoOutputSmokeHarness.run()
            mainHandler.post {
                result.success(smokeResult)
            }
        }.start()
    }
}
