package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer
import android.os.Build

/**
 * Diagnostic smoke harness validating RTC video delivery contracts, scoped-borrow lifecycle,
 * and delivery status transitions (accepted, backpressure drops, not-ready drops).
 *
 * ## Verification Invariants
 * - **Zero Room / Audio Dependencies**: Pure video transport contract smoke test; does not touch
 *   LiveKit, WebRTC native rooms, audio tracks, or microphone resources.
 * - **Scoped-Borrow Buffer Verification**: Uses a single synthetic [HardwareBuffer] passed across
 *   consecutive frames under scoped-borrow semantics. The harness retains buffer ownership and closes
 *   it in `finally` after all publisher invocations have completed.
 * - **Mechanical & Platform Safety**: Returns a structured result map with `pass=false` rather than
 *   throwing uncaught exceptions on invalid arguments or unsupported OS levels.
 */
object RtcVideoContractSmokeHarness {

    /**
     * Executes the RTC video publisher contract smoke test.
     *
     * @param width Width of the synthetic frame buffer (> 0).
     * @param height Height of the synthetic frame buffer (> 0).
     * @param frameCount Number of sequential frames to publish in the primary test loop (> 0).
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and snapshot telemetry.
     */
    fun run(width: Int = 64, height: Int = 64, frameCount: Int = 3): Map<String, Any?> {
        if (width <= 0 || height <= 0 || frameCount <= 0) {
            return mapOf(
                "pass" to false,
                "raw" to "status=INVALID_ARGUMENT;reason=width, height, and frameCount must be positive;width=$width;height=$height;frameCount=$frameCount",
            )
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf(
                "pass" to false,
                "raw" to "status=UNSUPPORTED_API;reason=HardwareBuffer requires Android O (API 26) or higher;sdkInt=${Build.VERSION.SDK_INT}",
            )
        }

        val hardwareBuffer = try {
            HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
        } catch (t: Throwable) {
            return mapOf(
                "pass" to false,
                "raw" to "status=HARDWARE_BUFFER_CREATION_FAILED;reason=${t.message}",
            )
        }

        try {
            // 1. Primary Publisher Test: Normal delivery of sequential frames
            val primaryPublisher = NoOpRtcVideoFramePublisher()
            var primaryAcceptedCount = 0
            var primaryDeliverySuccess = true

            for (i in 0 until frameCount) {
                val frame = RealtimeVideoFrame(
                    hardwareBuffer = hardwareBuffer,
                    width = width,
                    height = height,
                    timestampNs = i * 33333333L,
                    rotationDegrees = 0,
                    frameIndex = i.toLong(),
                    sourceId = "rtc_contract_smoke",
                )
                val result = primaryPublisher.publishFrame(frame)
                if (result.accepted && result.status == RtcVideoFrameDeliveryStatus.ACCEPTED) {
                    primaryAcceptedCount++
                } else {
                    primaryDeliverySuccess = false
                }
            }

            val primarySnapshot = primaryPublisher.snapshot()
            val primaryAcceptedFrames = (primarySnapshot["acceptedFrames"] as? Number)?.toLong() ?: -1L
            val primaryDroppedBackpressure = (primarySnapshot["droppedBackpressureFrames"] as? Number)?.toLong() ?: -1L
            val primaryDroppedNotReady = (primarySnapshot["droppedNotReadyFrames"] as? Number)?.toLong() ?: -1L
            val primaryFailed = (primarySnapshot["failedFrames"] as? Number)?.toLong() ?: -1L

            val primaryPass = primaryDeliverySuccess &&
                primaryAcceptedCount == frameCount &&
                primaryAcceptedFrames == frameCount.toLong() &&
                primaryDroppedBackpressure == 0L &&
                primaryDroppedNotReady == 0L &&
                primaryFailed == 0L

            // 2. Secondary Publisher Test: Verify backpressure drop (maxAccepted=1) and not-ready drop
            val secondaryPublisher = NoOpRtcVideoFramePublisher(
                maxAcceptedFrames = 1,
                initiallyReady = true,
            )

            // Frame 0: Should be ACCEPTED
            val frame0 = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = 0L,
                rotationDegrees = 0,
                frameIndex = 0L,
                sourceId = "rtc_contract_smoke",
            )
            val res0 = secondaryPublisher.publishFrame(frame0)
            val res0Accepted = res0.accepted && res0.status == RtcVideoFrameDeliveryStatus.ACCEPTED

            // Frame 1: Should be DROPPED_BACKPRESSURE (exceeded maxAcceptedFrames=1)
            val frame1 = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = 33333333L,
                rotationDegrees = 0,
                frameIndex = 1L,
                sourceId = "rtc_contract_smoke",
            )
            val res1 = secondaryPublisher.publishFrame(frame1)
            val res1Backpressure = !res1.accepted && res1.status == RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE

            // Set publisher not ready
            secondaryPublisher.setReady(false)

            // Frame 2: Should be DROPPED_NOT_READY
            val frame2 = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = width,
                height = height,
                timestampNs = 66666666L,
                rotationDegrees = 0,
                frameIndex = 2L,
                sourceId = "rtc_contract_smoke",
            )
            val res2 = secondaryPublisher.publishFrame(frame2)
            val res2NotReady = !res2.accepted && res2.status == RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY

            val secondarySnapshot = secondaryPublisher.snapshot()
            val secondaryAcceptedFrames = (secondarySnapshot["acceptedFrames"] as? Number)?.toLong() ?: -1L
            val secondaryDroppedBackpressure = (secondarySnapshot["droppedBackpressureFrames"] as? Number)?.toLong() ?: -1L
            val secondaryDroppedNotReady = (secondarySnapshot["droppedNotReadyFrames"] as? Number)?.toLong() ?: -1L
            val secondaryFailed = (secondarySnapshot["failedFrames"] as? Number)?.toLong() ?: -1L
            val secondaryReady = secondarySnapshot["ready"] as? Boolean ?: true

            val secondaryPass = res0Accepted &&
                res1Backpressure &&
                res2NotReady &&
                secondaryAcceptedFrames == 1L &&
                secondaryDroppedBackpressure == 1L &&
                secondaryDroppedNotReady == 1L &&
                secondaryFailed == 0L &&
                !secondaryReady

            val overallPass = primaryPass && secondaryPass
            val rawStatus = if (overallPass) {
                "status=OK;primaryAccepted=$primaryAcceptedCount;secondaryAccepted=$secondaryAcceptedFrames;secondaryBackpressure=$secondaryDroppedBackpressure;secondaryNotReady=$secondaryDroppedNotReady"
            } else {
                "status=CONTRACT_VERIFICATION_FAILED;primaryPass=$primaryPass;secondaryPass=$secondaryPass;primaryAccepted=$primaryAcceptedCount;secondaryAccepted=$secondaryAcceptedFrames;secondaryBackpressure=$secondaryDroppedBackpressure;secondaryNotReady=$secondaryDroppedNotReady"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "primarySnapshot" to primarySnapshot,
                "secondarySnapshot" to secondarySnapshot,
                "frameCount" to frameCount,
                "primaryAcceptedCount" to primaryAcceptedCount,
            )
        } finally {
            hardwareBuffer.close()
        }
    }
}
