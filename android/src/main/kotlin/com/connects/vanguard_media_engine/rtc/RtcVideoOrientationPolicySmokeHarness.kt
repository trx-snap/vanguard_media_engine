package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer
import android.os.Build

/**
 * Diagnostic smoke harness validating [RtcVideoOrientationPolicy] rotation normalization,
 * cardinal checks, display dimension calculations, and [RealtimeVideoFrame] orientation/mirror invariants.
 *
 * ## Verification Invariants
 * - **Zero Room / Audio Dependencies**: Pure video orientation/spatial metadata verification;
 *   operates strictly in the video domain without audio or room coupling.
 * - **Scoped Buffer Lifecycle**: Allocates a single small [HardwareBuffer] for [RealtimeVideoFrame]
 *   constructor validation and guarantees explicit release in `finally`.
 * - **Mechanical Safety**: Catches exceptions and returns a structured result map with `pass=false`
 *   on any test failure or unsupported OS level.
 */
object RtcVideoOrientationPolicySmokeHarness {

    /**
     * Executes the [RtcVideoOrientationPolicy] and [RealtimeVideoFrame] orientation smoke suite.
     *
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and test telemetry.
     */
    fun run(): Map<String, Any?> {
        // 1. Test normalization: 0, 90, 180, 270, 450 -> 90, -90 -> 270, 720 -> 0
        val norm0 = RtcVideoOrientationPolicy.normalizeRotationDegrees(0)
        val norm90 = RtcVideoOrientationPolicy.normalizeRotationDegrees(90)
        val norm180 = RtcVideoOrientationPolicy.normalizeRotationDegrees(180)
        val norm270 = RtcVideoOrientationPolicy.normalizeRotationDegrees(270)
        val norm450 = RtcVideoOrientationPolicy.normalizeRotationDegrees(450)
        val normNeg90 = RtcVideoOrientationPolicy.normalizeRotationDegrees(-90)
        val norm720 = RtcVideoOrientationPolicy.normalizeRotationDegrees(720)

        val normalizePass = (norm0 == 0) &&
            (norm90 == 90) &&
            (norm180 == 180) &&
            (norm270 == 270) &&
            (norm450 == 90) &&
            (normNeg90 == 270) &&
            (norm720 == 0)

        // 2. Test cardinal check
        val cardinal0 = RtcVideoOrientationPolicy.isCardinalRotation(0)
        val cardinal90 = RtcVideoOrientationPolicy.isCardinalRotation(90)
        val cardinal180 = RtcVideoOrientationPolicy.isCardinalRotation(180)
        val cardinal270 = RtcVideoOrientationPolicy.isCardinalRotation(270)
        val nonCardinal45 = RtcVideoOrientationPolicy.isCardinalRotation(45)
        val nonCardinalNeg90 = RtcVideoOrientationPolicy.isCardinalRotation(-90)
        val nonCardinal450 = RtcVideoOrientationPolicy.isCardinalRotation(450)
        val nonCardinal360 = RtcVideoOrientationPolicy.isCardinalRotation(360)

        val cardinalPass = cardinal0 && cardinal90 && cardinal180 && cardinal270 &&
            !nonCardinal45 && !nonCardinalNeg90 && !nonCardinal450 && !nonCardinal360

        // 3. Test display dimensions swap for 90/270 only
        val srcW = 1920
        val srcH = 1080
        val dw0 = RtcVideoOrientationPolicy.displayWidth(srcW, srcH, 0)
        val dh0 = RtcVideoOrientationPolicy.displayHeight(srcW, srcH, 0)
        val dw90 = RtcVideoOrientationPolicy.displayWidth(srcW, srcH, 90)
        val dh90 = RtcVideoOrientationPolicy.displayHeight(srcW, srcH, 90)
        val dw180 = RtcVideoOrientationPolicy.displayWidth(srcW, srcH, 180)
        val dh180 = RtcVideoOrientationPolicy.displayHeight(srcW, srcH, 180)
        val dw270 = RtcVideoOrientationPolicy.displayWidth(srcW, srcH, 270)
        val dh270 = RtcVideoOrientationPolicy.displayHeight(srcW, srcH, 270)
        val dw450 = RtcVideoOrientationPolicy.displayWidth(srcW, srcH, 450)
        val dh450 = RtcVideoOrientationPolicy.displayHeight(srcW, srcH, 450)
        val dwNeg90 = RtcVideoOrientationPolicy.displayWidth(srcW, srcH, -90)
        val dhNeg90 = RtcVideoOrientationPolicy.displayHeight(srcW, srcH, -90)

        val dimensionsPass = (dw0 == 1920 && dh0 == 1080) &&
            (dw90 == 1080 && dh90 == 1920) &&
            (dw180 == 1920 && dh180 == 1080) &&
            (dw270 == 1080 && dh270 == 1920) &&
            (dw450 == 1080 && dh450 == 1920) &&
            (dwNeg90 == 1080 && dhNeg90 == 1920)

        // 4. Test invalid dimensions rejected
        var invalidWidthRejected = false
        try {
            RtcVideoOrientationPolicy.displayWidth(0, 1080, 0)
        } catch (_: IllegalArgumentException) {
            invalidWidthRejected = true
        }

        var invalidHeightRejected = false
        try {
            RtcVideoOrientationPolicy.displayHeight(1920, 0, 0)
        } catch (_: IllegalArgumentException) {
            invalidHeightRejected = true
        }

        var negativeWidthRejected = false
        try {
            RtcVideoOrientationPolicy.displayWidth(-1920, 1080, 0)
        } catch (_: IllegalArgumentException) {
            negativeWidthRejected = true
        }

        var negativeHeightRejected = false
        try {
            RtcVideoOrientationPolicy.displayHeight(1920, -1080, 0)
        } catch (_: IllegalArgumentException) {
            negativeHeightRejected = true
        }

        val invalidDimPass = invalidWidthRejected && invalidHeightRejected &&
            negativeWidthRejected && negativeHeightRejected

        // 5. Test describe helper
        val desc90Mirror = RtcVideoOrientationPolicy.describe(90, true)
        val desc90Pass = (desc90Mirror["rotationDegrees"] == 90) &&
            (desc90Mirror["normalizedRotationDegrees"] == 90) &&
            (desc90Mirror["isCardinal"] == true) &&
            (desc90Mirror["mirrored"] == true) &&
            (desc90Mirror["swapsDimensions"] == true)

        val descNeg90NoMirror = RtcVideoOrientationPolicy.describe(-90, false)
        val descNeg90Pass = (descNeg90NoMirror["rotationDegrees"] == -90) &&
            (descNeg90NoMirror["normalizedRotationDegrees"] == 270) &&
            (descNeg90NoMirror["isCardinal"] == false) &&
            (descNeg90NoMirror["mirrored"] == false) &&
            (descNeg90NoMirror["swapsDimensions"] == true)

        val describePass = desc90Pass && descNeg90Pass

        // 6. Test RealtimeVideoFrame mirror & non-cardinal rejection
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf(
                "pass" to false,
                "raw" to "status=UNSUPPORTED_API;reason=HardwareBuffer requires Android O (API 26) or higher;sdkInt=${Build.VERSION.SDK_INT}",
            )
        }

        val hardwareBuffer = try {
            HardwareBuffer.create(
                16,
                16,
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

        var frameMirrorPass = false
        var frameNonCardinalRejected = false

        try {
            // Frame with mirrored=true and cardinal rotation
            val frameMirrored = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = 16,
                height = 16,
                timestampNs = 0L,
                rotationDegrees = 90,
                mirrored = true,
            )
            val frameUnmirrored = RealtimeVideoFrame(
                hardwareBuffer = hardwareBuffer,
                width = 16,
                height = 16,
                timestampNs = 1L,
                rotationDegrees = 0,
                mirrored = false,
            )
            frameMirrorPass = frameMirrored.mirrored &&
                !frameUnmirrored.mirrored &&
                frameMirrored.rotationDegrees == 90 &&
                frameUnmirrored.rotationDegrees == 0

            // Non-cardinal rotation rejection in constructor
            var reject45 = false
            try {
                RealtimeVideoFrame(
                    hardwareBuffer = hardwareBuffer,
                    width = 16,
                    height = 16,
                    timestampNs = 2L,
                    rotationDegrees = 45,
                )
            } catch (_: IllegalArgumentException) {
                reject45 = true
            }

            var rejectNeg90 = false
            try {
                RealtimeVideoFrame(
                    hardwareBuffer = hardwareBuffer,
                    width = 16,
                    height = 16,
                    timestampNs = 3L,
                    rotationDegrees = -90,
                )
            } catch (_: IllegalArgumentException) {
                rejectNeg90 = true
            }

            var reject450 = false
            try {
                RealtimeVideoFrame(
                    hardwareBuffer = hardwareBuffer,
                    width = 16,
                    height = 16,
                    timestampNs = 4L,
                    rotationDegrees = 450,
                )
            } catch (_: IllegalArgumentException) {
                reject450 = true
            }

            frameNonCardinalRejected = reject45 && rejectNeg90 && reject450
        } finally {
            hardwareBuffer.close()
        }

        val framePass = frameMirrorPass && frameNonCardinalRejected

        val overallPass = normalizePass &&
            cardinalPass &&
            dimensionsPass &&
            invalidDimPass &&
            describePass &&
            framePass

        val rawStatus = if (overallPass) {
            "status=OK;normalizePass=true;cardinalPass=true;dimensionsPass=true;invalidDimPass=true;describePass=true;framePass=true"
        } else {
            "status=ORIENTATION_POLICY_VERIFICATION_FAILED;normalizePass=$normalizePass;cardinalPass=$cardinalPass;dimensionsPass=$dimensionsPass;invalidDimPass=$invalidDimPass;describePass=$describePass;framePass=$framePass"
        }

        return mapOf(
            "pass" to overallPass,
            "raw" to rawStatus,
            "normalizePass" to normalizePass,
            "cardinalPass" to cardinalPass,
            "dimensionsPass" to dimensionsPass,
            "invalidDimPass" to invalidDimPass,
            "describePass" to describePass,
            "framePass" to framePass,
        )
    }
}
