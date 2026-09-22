package com.connects.vanguard_media_engine.diagnostics

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * ANDROID-DUET-EXPORT-TRANSFORM-PIXEL-PROOF diagnostic coordinator.
 *
 * Validates that real public MethodChannel `exportDuetComposition` carries
 * `foregroundTransform.rotationDegrees` into the produced MP4.
 *
 * Routes owned:
 *  - [METHOD_ASSERT]: decodes exported MP4s via MediaMetadataRetriever and
 *    asserts expected pixel values at sampled points (center, rightArm, lowerArm, farCorner)
 *    to differentiate 0-degree vs 90-degree foreground rotation, and (via the optional
 *    third `anchorRotation90Path`) asserts anchor-pivot placement parity for a non-center
 *    anchor combined with 90-degree rotation.
 *
 * Diagnostic only: not wired into production export, Duet, or product UI.
 */
class AndroidDuetExportTransformPixelProofSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardDuetTransformProof"
        const val METHOD_ASSERT = "assertAndroidDuetExportTransformPixelProofOutput"
        private val OWNED_METHODS = setOf(METHOD_ASSERT)

        private const val DEFAULT_WIDTH = 360
        private const val DEFAULT_HEIGHT = 640
        private const val DEFAULT_FPS = 30
        private const val DEFAULT_PIXEL_TOLERANCE = 80

        fun ownsMethod(method: String): Boolean = OWNED_METHODS.contains(method)
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-duet-transform-proof-coordinator").apply { isDaemon = true }
    }
    private val disposed = AtomicBoolean(false)

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ) {
        when (method) {
            METHOD_ASSERT -> handleAssert(args, result)
            else -> result.notImplemented()
        }
    }

    fun disposeAll() {
        if (disposed.compareAndSet(false, true)) {
            executor.shutdown()
        }
    }

    private fun handleAssert(args: Map<*, *>?, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.success(mapOf("pass" to false, "reason" to "coordinator_disposed"))
            return
        }
        val rotation0Path = args?.get("rotation0Path") as? String
        val rotation90Path = args?.get("rotation90Path") as? String
        val anchorRotation90Path = args?.get("anchorRotation90Path") as? String
        if (rotation0Path.isNullOrBlank() || rotation90Path.isNullOrBlank() ||
            anchorRotation90Path.isNullOrBlank()
        ) {
            result.success(
                mapOf(
                    "pass" to false,
                    "reason" to "invalid_arguments: rotation0Path, rotation90Path, and " +
                        "anchorRotation90Path required",
                ),
            )
            return
        }

        val width = (args["width"] as? Number)?.toInt() ?: DEFAULT_WIDTH
        val height = (args["height"] as? Number)?.toInt() ?: DEFAULT_HEIGHT
        val fps = (args["fps"] as? Number)?.toInt() ?: DEFAULT_FPS
        val tolerance = (args["tolerance"] as? Number)?.toInt() ?: DEFAULT_PIXEL_TOLERANCE

        try {
            executor.execute {
                val outcome = decodeAndAssert(
                    rotation0Path = rotation0Path,
                    rotation90Path = rotation90Path,
                    anchorRotation90Path = anchorRotation90Path,
                    width = width,
                    height = height,
                    fps = fps,
                    tolerance = tolerance,
                )
                mainHandler.post { result.success(outcome) }
            }
        } catch (t: Throwable) {
            result.success(
                mapOf(
                    "pass" to false,
                    "reason" to "assertion_execution_rejected:${t.message}",
                ),
            )
        }
    }

    private fun decodeAndAssertFailure(reason: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "reason" to reason,
        "decodeOk" to false,
        "centerOverlayOk" to false,
        "rightArmRotationDifferentiatesOk" to false,
        "lowerArmRotationDifferentiatesOk" to false,
        "farCornerBackgroundOk" to false,
        "anchorPivotShiftOk" to false,
    )

    private fun decodeAndAssert(
        rotation0Path: String,
        rotation90Path: String,
        anchorRotation90Path: String,
        width: Int,
        height: Int,
        fps: Int,
        tolerance: Int,
    ): Map<String, Any?> {
        val rot0File = File(rotation0Path)
        val rot90File = File(rotation90Path)
        val anchorRot90File = File(anchorRotation90Path)

        if (!rot0File.exists() || rot0File.length() == 0L) {
            return decodeAndAssertFailure("rotation0_file_missing_or_empty:$rotation0Path")
        }
        if (!rot90File.exists() || rot90File.length() == 0L) {
            return decodeAndAssertFailure("rotation90_file_missing_or_empty:$rotation90Path")
        }
        if (!anchorRot90File.exists() || anchorRot90File.length() == 0L) {
            return decodeAndAssertFailure(
                "anchor_rotation90_file_missing_or_empty:$anchorRotation90Path",
            )
        }

        val rot0Bitmap = decodeMidFrame(rotation0Path, fps)
        val rot90Bitmap = decodeMidFrame(rotation90Path, fps)
        val anchorRot90Bitmap = decodeMidFrame(anchorRotation90Path, fps)

        if (rot0Bitmap == null) {
            return decodeAndAssertFailure("rotation0_decode_failed_null_bitmap")
        }
        if (rot90Bitmap == null) {
            return decodeAndAssertFailure("rotation90_decode_failed_null_bitmap")
        }
        if (anchorRot90Bitmap == null) {
            return decodeAndAssertFailure("anchor_rotation90_decode_failed_null_bitmap")
        }

        val center0 = sampleAndClassify("center", 180, 320, rot0Bitmap, width, height, expectedMagenta = true, tolerance = tolerance)
        val rightArm0 = sampleAndClassify("rightArm", 290, 320, rot0Bitmap, width, height, expectedMagenta = false, tolerance = tolerance)
        val lowerArm0 = sampleAndClassify("lowerArm", 180, 430, rot0Bitmap, width, height, expectedMagenta = true, tolerance = tolerance)
        val farCorner0 = sampleAndClassify("farCorner", 20, 20, rot0Bitmap, width, height, expectedMagenta = false, tolerance = tolerance)

        val center90 = sampleAndClassify("center", 180, 320, rot90Bitmap, width, height, expectedMagenta = true, tolerance = tolerance)
        val rightArm90 = sampleAndClassify("rightArm", 290, 320, rot90Bitmap, width, height, expectedMagenta = true, tolerance = tolerance)
        val lowerArm90 = sampleAndClassify("lowerArm", 180, 430, rot90Bitmap, width, height, expectedMagenta = false, tolerance = tolerance)
        val farCorner90 = sampleAndClassify("farCorner", 20, 20, rot90Bitmap, width, height, expectedMagenta = false, tolerance = tolerance)

        // Anchor-pivot proof: scale=0.4, offset=(0,0), anchor=(0.25,0.25), rotationDegrees=90
        // on a 360x640 canvas. fgRect = left=144, top=256, width=144, height=256; pivot =
        // (180,320); shifted center = (116,356); fixed overlay left/top = (44,228). The
        // rotated bounding box is approximately x=[-12,244], y=[284,428].
        //   shiftedOnly (20,356): only magenta with the anchor-pivot fix applied.
        //   oldCenterOnly (300,356): only magenta under the old (unfixed) center placement.
        //   shiftedCenter (116,356): magenta under both, a positive control that the
        //     overlay itself still renders.
        val shiftedOnly = sampleAndClassify("shiftedOnly", 20, 356, anchorRot90Bitmap, width, height, expectedMagenta = true, tolerance = tolerance)
        val oldCenterOnly = sampleAndClassify("oldCenterOnly", 300, 356, anchorRot90Bitmap, width, height, expectedMagenta = false, tolerance = tolerance)
        val shiftedCenter = sampleAndClassify("shiftedCenter", 116, 356, anchorRot90Bitmap, width, height, expectedMagenta = true, tolerance = tolerance)

        val centerOverlayOk = (center0["pass"] == true) && (center90["pass"] == true)
        val rightArmRotationDifferentiatesOk = (rightArm0["pass"] == true) && (rightArm90["pass"] == true)
        val lowerArmRotationDifferentiatesOk = (lowerArm0["pass"] == true) && (lowerArm90["pass"] == true)
        val farCornerBackgroundOk = (farCorner0["pass"] == true) && (farCorner90["pass"] == true)
        val anchorPivotShiftOk = (shiftedOnly["pass"] == true) && (oldCenterOnly["pass"] == true) && (shiftedCenter["pass"] == true)

        val allPass = centerOverlayOk && rightArmRotationDifferentiatesOk &&
            lowerArmRotationDifferentiatesOk && farCornerBackgroundOk && anchorPivotShiftOk
        val failureReasons = mutableListOf<String>()
        if (!centerOverlayOk) failureReasons.add("center_overlay_failed:rot0=${center0["isMagenta"]},rot90=${center90["isMagenta"]}")
        if (!rightArmRotationDifferentiatesOk) failureReasons.add("right_arm_differentiation_failed:rot0=${rightArm0["isMagenta"]},rot90=${rightArm90["isMagenta"]}")
        if (!lowerArmRotationDifferentiatesOk) failureReasons.add("lower_arm_differentiation_failed:rot0=${lowerArm0["isMagenta"]},rot90=${lowerArm90["isMagenta"]}")
        if (!farCornerBackgroundOk) failureReasons.add("far_corner_background_failed:rot0=${farCorner0["isMagenta"]},rot90=${farCorner90["isMagenta"]}")
        if (!anchorPivotShiftOk) failureReasons.add("anchor_pivot_shift_failed:shiftedOnly=${shiftedOnly["isMagenta"]},oldCenterOnly=${oldCenterOnly["isMagenta"]},shiftedCenter=${shiftedCenter["isMagenta"]}")
        val reason = if (allPass) "pass" else failureReasons.joinToString(";")

        return mapOf(
            "pass" to allPass,
            "reason" to reason,
            "decodeOk" to true,
            "centerOverlayOk" to centerOverlayOk,
            "rightArmRotationDifferentiatesOk" to rightArmRotationDifferentiatesOk,
            "lowerArmRotationDifferentiatesOk" to lowerArmRotationDifferentiatesOk,
            "farCornerBackgroundOk" to farCornerBackgroundOk,
            "anchorPivotShiftOk" to anchorPivotShiftOk,
            "tolerance" to tolerance,
            "rotation0" to mapOf(
                "center" to center0,
                "rightArm" to rightArm0,
                "lowerArm" to lowerArm0,
                "farCorner" to farCorner0,
            ),
            "rotation90" to mapOf(
                "center" to center90,
                "rightArm" to rightArm90,
                "lowerArm" to lowerArm90,
                "farCorner" to farCorner90,
            ),
            "anchorRotation90" to mapOf(
                "shiftedOnly" to shiftedOnly,
                "oldCenterOnly" to oldCenterOnly,
                "shiftedCenter" to shiftedCenter,
            ),
        )
    }

    private fun decodeMidFrame(path: String, fps: Int): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val midTimeUs = if (durationMs > 0) {
                (durationMs * 1000L) / 2
            } else {
                val frameDurationUs = 1_000_000L / fps.coerceAtLeast(1)
                frameDurationUs * 3
            }
            retriever.getFrameAtTime(midTimeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                ?: retriever.frameAtTime
        } catch (t: Throwable) {
            Log.e(TAG, "decodeMidFrame failed for $path", t)
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Throwable) {}
        }
    }

    private fun sampleAndClassify(
        name: String,
        x: Int,
        y: Int,
        bitmap: Bitmap,
        targetWidth: Int,
        targetHeight: Int,
        expectedMagenta: Boolean,
        tolerance: Int,
    ): Map<String, Any?> {
        val bw = bitmap.width
        val bh = bitmap.height
        val sx = (x * bw / targetWidth).coerceIn(0, bw - 1)
        val sy = (y * bh / targetHeight).coerceIn(0, bh - 1)
        val pixel = bitmap.getPixel(sx, sy)
        val r = Color.red(pixel)
        val g = Color.green(pixel)
        val b = Color.blue(pixel)
        val rgb = intArrayOf(r, g, b)

        val isMag = isMagenta(rgb, tolerance)
        val pass = (isMag == expectedMagenta)

        return mapOf(
            "name" to name,
            "x" to x,
            "y" to y,
            "sampledX" to sx,
            "sampledY" to sy,
            "rgb" to listOf(r, g, b),
            "isMagenta" to isMag,
            "expectedMagenta" to expectedMagenta,
            "pass" to pass,
        )
    }

    private fun isMagenta(rgb: IntArray, tolerance: Int): Boolean {
        val r = rgb[0]
        val g = rgb[1]
        val b = rgb[2]
        // Magenta synthetic overlay is Color.argb(255, 255, 20, 147).
        // Red fixture background is Color.rgb(240, 20, 20).
        // Magenta requires high red, low green, and blue substantially above red-source background (~20).
        val minBlue = maxOf(60, 147 - tolerance)
        return r >= 140 && g <= 100 && b >= minBlue
    }
}
