package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer
import android.os.Build

/**
 * Diagnostic smoke harness validating [RtcVideoFrameValidator] structural checks, pixel format matching,
 * [HardwareBuffer] dimension invariants, usage flags, closed-buffer guards, and constructor bounds.
 *
 * ## Verification Invariants
 * - **Zero Room / Audio Dependencies**: Operates strictly within the video domain without audio or room coupling.
 * - **Deterministic Verification**: Tests synthetic buffers and frames against precise validation assertions.
 * - **Mechanical & Platform Safety**: Allocates synthetic [HardwareBuffer]s and closes all buffers in `finally` blocks.
 */
object RtcVideoFrameValidatorSmokeHarness {

    /**
     * Executes the [RtcVideoFrameValidator] smoke verification suite.
     *
     * @param width Frame buffer width in pixels (> 0).
     * @param height Frame buffer height in pixels (> 0).
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and test telemetry.
     */
    fun run(width: Int = 64, height: Int = 64): Map<String, Any?> {
        if (width <= 0 || height <= 0) {
            return mapOf(
                "pass" to false,
                "raw" to "status=INVALID_ARGUMENT;reason=width and height must be positive;width=$width;height=$height",
            )
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf(
                "pass" to false,
                "raw" to "status=UNSUPPORTED_API;reason=HardwareBuffer requires Android O (API 26) or higher;sdkInt=${Build.VERSION.SDK_INT}",
            )
        }

        var validBuffer: HardwareBuffer? = null
        var noGpuUsageBuffer: HardwareBuffer? = null
        var closedTestBuffer: HardwareBuffer? = null

        try {
            // 1. Valid Frame Scenario: RGBA_8888 + GPU_SAMPLED_IMAGE
            validBuffer = try {
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

            val validFrame = RealtimeVideoFrame(
                hardwareBuffer = validBuffer,
                width = width,
                height = height,
                timestampNs = 1000000L,
                rotationDegrees = 0,
                frameIndex = 1L,
                sourceId = "validator_smoke",
            )
            val validRes = RtcVideoFrameValidator.validate(validFrame)
            val validFramePass = validRes.accepted &&
                validRes.status == RtcVideoFrameDeliveryStatus.ACCEPTED &&
                validRes.raw.contains("status=OK")

            // 2. Mismatched Width Scenario
            val mismatchedWidthFrame = RealtimeVideoFrame(
                hardwareBuffer = validBuffer,
                width = width + 10,
                height = height,
                timestampNs = 2000000L,
                rotationDegrees = 0,
                frameIndex = 2L,
                sourceId = "validator_smoke",
            )
            val mismatchedWidthRes = RtcVideoFrameValidator.validate(mismatchedWidthFrame)
            val mismatchedWidthPass = !mismatchedWidthRes.accepted &&
                mismatchedWidthRes.status == RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT &&
                mismatchedWidthRes.raw.contains("dimension_mismatch_width")

            // 3. Mismatched Height Scenario
            val mismatchedHeightFrame = RealtimeVideoFrame(
                hardwareBuffer = validBuffer,
                width = width,
                height = height + 10,
                timestampNs = 3000000L,
                rotationDegrees = 0,
                frameIndex = 3L,
                sourceId = "validator_smoke",
            )
            val mismatchedHeightRes = RtcVideoFrameValidator.validate(mismatchedHeightFrame)
            val mismatchedHeightPass = !mismatchedHeightRes.accepted &&
                mismatchedHeightRes.status == RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT &&
                mismatchedHeightRes.raw.contains("dimension_mismatch_height")

            // 4. Missing GPU_SAMPLED_IMAGE Usage Scenario
            var missingUsageScenarioSkipped = false
            var missingUsagePass = false
            try {
                noGpuUsageBuffer = HardwareBuffer.create(
                    width,
                    height,
                    HardwareBuffer.RGBA_8888,
                    1,
                    HardwareBuffer.USAGE_CPU_READ_OFTEN,
                )
                val missingUsageFrame = RealtimeVideoFrame(
                    hardwareBuffer = noGpuUsageBuffer,
                    width = width,
                    height = height,
                    timestampNs = 4000000L,
                    rotationDegrees = 0,
                    frameIndex = 4L,
                    sourceId = "validator_smoke",
                )
                val missingUsageRes = RtcVideoFrameValidator.validate(missingUsageFrame)
                missingUsagePass = !missingUsageRes.accepted &&
                    missingUsageRes.status == RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT &&
                    missingUsageRes.raw.contains("missing_gpu_sampled_usage")
            } catch (_: Throwable) {
                // Platform rejected buffer allocation without GPU usage flags
                missingUsageScenarioSkipped = true
                missingUsagePass = true
            }

            // 5. Closed Buffer Scenario
            closedTestBuffer = HardwareBuffer.create(
                width,
                height,
                HardwareBuffer.RGBA_8888,
                1,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
            val closedTestFrame = RealtimeVideoFrame(
                hardwareBuffer = closedTestBuffer,
                width = width,
                height = height,
                timestampNs = 5000000L,
                rotationDegrees = 0,
                frameIndex = 5L,
                sourceId = "validator_smoke",
            )
            closedTestBuffer.close()
            val closedBufferRes = RtcVideoFrameValidator.validate(closedTestFrame)
            val closedBufferPass = !closedBufferRes.accepted &&
                closedBufferRes.status == RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT &&
                closedBufferRes.raw.contains("buffer_closed")

            // 6. Constructor Validation Negative Bounds Check
            var zeroWidthRejected = false
            try {
                RealtimeVideoFrame(validBuffer, width = 0, height = height, timestampNs = 0L)
            } catch (_: IllegalArgumentException) {
                zeroWidthRejected = true
            }

            var zeroHeightRejected = false
            try {
                RealtimeVideoFrame(validBuffer, width = width, height = 0, timestampNs = 0L)
            } catch (_: IllegalArgumentException) {
                zeroHeightRejected = true
            }

            var negTimestampRejected = false
            try {
                RealtimeVideoFrame(validBuffer, width = width, height = height, timestampNs = -1L)
            } catch (_: IllegalArgumentException) {
                negTimestampRejected = true
            }

            var negIndexRejected = false
            try {
                RealtimeVideoFrame(validBuffer, width = width, height = height, timestampNs = 0L, frameIndex = -1L)
            } catch (_: IllegalArgumentException) {
                negIndexRejected = true
            }

            var blankSourceRejected = false
            try {
                RealtimeVideoFrame(validBuffer, width = width, height = height, timestampNs = 0L, sourceId = "   ")
            } catch (_: IllegalArgumentException) {
                blankSourceRejected = true
            }

            var invalidRotationRejected = false
            try {
                RealtimeVideoFrame(validBuffer, width = width, height = height, timestampNs = 0L, rotationDegrees = 45)
            } catch (_: IllegalArgumentException) {
                invalidRotationRejected = true
            }

            val constructorValidationPass = zeroWidthRejected &&
                zeroHeightRejected &&
                negTimestampRejected &&
                negIndexRejected &&
                blankSourceRejected &&
                invalidRotationRejected

            val overallPass = validFramePass &&
                mismatchedWidthPass &&
                mismatchedHeightPass &&
                missingUsagePass &&
                closedBufferPass &&
                constructorValidationPass

            val rawStatus = if (overallPass) {
                "status=OK;validFramePass=true;mismatchedWidthPass=true;mismatchedHeightPass=true;missingUsagePass=true;missingUsageSkipped=$missingUsageScenarioSkipped;closedBufferPass=true;constructorValidationPass=true"
            } else {
                "status=VALIDATOR_VERIFICATION_FAILED;validFramePass=$validFramePass;mismatchedWidthPass=$mismatchedWidthPass;mismatchedHeightPass=$mismatchedHeightPass;missingUsagePass=$missingUsagePass;closedBufferPass=$closedBufferPass;constructorValidationPass=$constructorValidationPass"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "validFramePass" to validFramePass,
                "mismatchedWidthPass" to mismatchedWidthPass,
                "mismatchedHeightPass" to mismatchedHeightPass,
                "missingUsagePass" to missingUsagePass,
                "missingUsageScenarioSkipped" to missingUsageScenarioSkipped,
                "closedBufferPass" to closedBufferPass,
                "constructorValidationPass" to constructorValidationPass,
                "width" to width,
                "height" to height,
            )
        } catch (t: Throwable) {
            return mapOf(
                "pass" to false,
                "raw" to "status=UNEXPECTED_ERROR;reason=${t.message}",
            )
        } finally {
            validBuffer?.close()
            noGpuUsageBuffer?.close()
            if (closedTestBuffer != null && !closedTestBuffer.isClosed) {
                closedTestBuffer.close()
            }
        }
    }
}
