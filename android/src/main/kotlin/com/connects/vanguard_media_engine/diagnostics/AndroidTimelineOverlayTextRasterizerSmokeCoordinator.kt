package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.export.AndroidTimelineOverlayTextRasterizer
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P5-OVERLAYS-TEXT-RASTERIZER-DIAGNOSTIC: verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for the Kotlin
 * [AndroidTimelineOverlayTextRasterizer] helper diagnostic proof.
 *
 * Diagnostic only: no export session wiring, no native C++, no JNI, no product.
 */
class AndroidTimelineOverlayTextRasterizerSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP5OverlayTextRasterizer"
        const val METHOD_NAME = "runAndroidDagPhase5TimelineOverlayTextRasterizerSmoke"
        const val PASS_MARKER =
            "ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_OVERLAY_TEXT_RASTERIZER_PHYSICAL_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "android_kotlin_text_overlay_rasterizer_rgba_buffer_diagnostic_only_no_export_no_native_no_jni_no_product"

        val GATE_KEYS = listOf(
            "validationPass",
            "backgroundPass",
            "transparentPass",
            "packingPass",
            "canonicalPass",
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vanguard-p5-overlay-text-smoke").apply { isDaemon = true }
    }
    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        runSmoke(result)
        return true
    }

    /**
     * Releases the background executor. Safe to call more than once.
     */
    fun disposeAll() {
        if (disposed.compareAndSet(false, true)) {
            executor.shutdown()
        }
    }

    private fun runSmoke(result: MethodChannel.Result) {
        if (disposed.get()) {
            result.success(makeFailedMap("coordinator_disposed"))
            return
        }
        if (!active.compareAndSet(false, true)) {
            result.success(makeFailedMap("smoke_already_active"))
            return
        }
        try {
            executor.execute {
                try {
                    val payload = executeLanes()
                    mainHandler.post { result.success(payload) }
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_NAME failed", t)
                    mainHandler.post {
                        result.success(
                            makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}")
                        )
                    }
                } finally {
                    active.set(false)
                }
            }
        } catch (t: Throwable) {
            active.set(false)
            Log.e(TAG, "$METHOD_NAME could not be scheduled", t)
            result.success(makeFailedMap("executor_rejected:${t.javaClass.simpleName}"))
        }
    }

    private fun executeLanes(): Map<String, Any?> {
        // Lane 1: validationPass
        val lane1Errors = mutableListOf<String>()

        // 1. blank overlay id
        val r1 = AndroidTimelineOverlayTextRasterizer.rasterizeText("", "Sample", 320.0, 96.0)
        if (r1 !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure ||
            r1.code != AndroidTimelineOverlayTextRasterizer.CODE_INVALID_ARG
        ) {
            lane1Errors.add("blank_overlay_id_not_rejected")
        }

        // 2. blank text
        val r2 = AndroidTimelineOverlayTextRasterizer.rasterizeText("txt_1", "   ", 320.0, 96.0)
        if (r2 !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure ||
            r2.code != AndroidTimelineOverlayTextRasterizer.CODE_INVALID_ARG
        ) {
            lane1Errors.add("blank_text_not_rejected")
        }

        // 3. zero width
        val r3 = AndroidTimelineOverlayTextRasterizer.rasterizeText("txt_1", "Sample", 0.0, 96.0)
        if (r3 !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure ||
            r3.code != AndroidTimelineOverlayTextRasterizer.CODE_INVALID_ARG
        ) {
            lane1Errors.add("zero_width_not_rejected")
        }

        // 4. negative height
        val r4 = AndroidTimelineOverlayTextRasterizer.rasterizeText("txt_1", "Sample", 320.0, -10.0)
        if (r4 !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure ||
            r4.code != AndroidTimelineOverlayTextRasterizer.CODE_INVALID_ARG
        ) {
            lane1Errors.add("negative_height_not_rejected")
        }

        // 5. NaN width
        val r5 = AndroidTimelineOverlayTextRasterizer.rasterizeText("txt_1", "Sample", Double.NaN, 96.0)
        if (r5 !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure ||
            r5.code != AndroidTimelineOverlayTextRasterizer.CODE_INVALID_ARG
        ) {
            lane1Errors.add("nan_width_not_rejected")
        }

        // 6. oversized width
        val r6 = AndroidTimelineOverlayTextRasterizer.rasterizeText(
            "txt_1",
            "Sample",
            (AndroidTimelineOverlayTextRasterizer.MAX_DIMENSION + 10).toDouble(),
            96.0,
        )
        if (r6 !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure ||
            r6.code != AndroidTimelineOverlayTextRasterizer.CODE_DIMENSIONS_EXCEEDED
        ) {
            lane1Errors.add("oversized_width_not_rejected")
        }

        // 7. oversized height
        val r7 = AndroidTimelineOverlayTextRasterizer.rasterizeText(
            "txt_1",
            "Sample",
            320.0,
            (AndroidTimelineOverlayTextRasterizer.MAX_DIMENSION + 10).toDouble(),
        )
        if (r7 !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure ||
            r7.code != AndroidTimelineOverlayTextRasterizer.CODE_DIMENSIONS_EXCEEDED
        ) {
            lane1Errors.add("oversized_height_not_rejected")
        }

        val lane1Pass = lane1Errors.isEmpty()

        // Lane 2: backgroundPass
        val lane2Errors = mutableListOf<String>()
        val rBg = AndroidTimelineOverlayTextRasterizer.rasterizeText(
            overlayId = "text_smoke_bg",
            textContent = "Vanguard Smoke",
            width = 320.0,
            height = 96.0,
            drawBackground = true,
        )

        var bgNonZeroAlphaPixels = 0
        var bgWhiteLikePixels = 0
        var bgBlackBackgroundPixels = 0

        if (rBg !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success) {
            lane2Errors.add("rasterize_background_failed:${(rBg as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure)?.code}")
        } else {
            if (rBg.width != 320) lane2Errors.add("bg_width_mismatch:${rBg.width}")
            if (rBg.height != 96) lane2Errors.add("bg_height_mismatch:${rBg.height}")
            if (rBg.rowStrideBytes != 1280) lane2Errors.add("bg_stride_mismatch:${rBg.rowStrideBytes}")
            if (!rBg.rgbaBuffer.isDirect) lane2Errors.add("bg_buffer_not_direct")
            if (rBg.rgbaBuffer.capacity() != 122880) lane2Errors.add("bg_capacity_mismatch:${rBg.rgbaBuffer.capacity()}")
            if (rBg.rgbaBuffer.position() != 0) lane2Errors.add("bg_position_not_zero:${rBg.rgbaBuffer.position()}")

            val totalPixels = rBg.width * rBg.height
            for (i in 0 until totalPixels) {
                val offset = i * 4
                val r = rBg.rgbaBuffer.get(offset).toInt() and 0xFF
                val g = rBg.rgbaBuffer.get(offset + 1).toInt() and 0xFF
                val b = rBg.rgbaBuffer.get(offset + 2).toInt() and 0xFF
                val a = rBg.rgbaBuffer.get(offset + 3).toInt() and 0xFF

                if (a > 0) {
                    bgNonZeroAlphaPixels++
                }
                if (r >= 180 && g >= 180 && b >= 180 && a >= 180) {
                    bgWhiteLikePixels++
                }
                if (r == 0 && g == 0 && b == 0 && a > 0) {
                    bgBlackBackgroundPixels++
                }
            }

            if (bgNonZeroAlphaPixels <= 0) lane2Errors.add("bg_no_nonzero_alpha_pixels")
            if (bgWhiteLikePixels <= 0) lane2Errors.add("bg_no_whitelike_pixels")
            if (rBg.rgbaBuffer.position() != 0) lane2Errors.add("bg_buffer_position_drifted")
        }

        val lane2Pass = lane2Errors.isEmpty()

        // Lane 3: transparentPass
        val lane3Errors = mutableListOf<String>()
        val rTrans = AndroidTimelineOverlayTextRasterizer.rasterizeText(
            overlayId = "text_smoke_trans",
            textContent = "Vanguard Smoke",
            width = 320.0,
            height = 96.0,
            drawBackground = false,
        )

        var transCornerAlpha = -1
        var transTransparentPixels = 0
        var transWhiteLikePixels = 0

        if (rTrans !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success) {
            lane3Errors.add("rasterize_transparent_failed:${(rTrans as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure)?.code}")
        } else {
            if (rTrans.width != 320) lane3Errors.add("trans_width_mismatch:${rTrans.width}")
            if (rTrans.height != 96) lane3Errors.add("trans_height_mismatch:${rTrans.height}")
            if (rTrans.rowStrideBytes != 1280) lane3Errors.add("trans_stride_mismatch:${rTrans.rowStrideBytes}")
            if (!rTrans.rgbaBuffer.isDirect) lane3Errors.add("trans_buffer_not_direct")
            if (rTrans.rgbaBuffer.capacity() != 122880) lane3Errors.add("trans_capacity_mismatch:${rTrans.rgbaBuffer.capacity()}")
            if (rTrans.rgbaBuffer.position() != 0) lane3Errors.add("trans_position_not_zero:${rTrans.rgbaBuffer.position()}")

            transCornerAlpha = rTrans.rgbaBuffer.get(3).toInt() and 0xFF
            val totalPixels = rTrans.width * rTrans.height
            for (i in 0 until totalPixels) {
                val offset = i * 4
                val r = rTrans.rgbaBuffer.get(offset).toInt() and 0xFF
                val g = rTrans.rgbaBuffer.get(offset + 1).toInt() and 0xFF
                val b = rTrans.rgbaBuffer.get(offset + 2).toInt() and 0xFF
                val a = rTrans.rgbaBuffer.get(offset + 3).toInt() and 0xFF

                if (a == 0) {
                    transTransparentPixels++
                }
                if (r >= 180 && g >= 180 && b >= 180 && a >= 180) {
                    transWhiteLikePixels++
                }
            }

            if (transCornerAlpha != 0 && transTransparentPixels <= 0) {
                lane3Errors.add("trans_neither_corner_zero_nor_transparent_pixels")
            }
            if (transWhiteLikePixels <= 0) {
                lane3Errors.add("trans_no_whitelike_pixels")
            }
            if (rTrans.rgbaBuffer.position() != 0) {
                lane3Errors.add("trans_buffer_position_drifted")
            }
        }

        val lane3Pass = lane3Errors.isEmpty()

        // Lane 4: packingPass
        val lane4Errors = mutableListOf<String>()
        if (rBg !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success ||
            rTrans !is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success
        ) {
            lane4Errors.add("packing_prerequisite_rasterize_failed")
        } else {
            if (!rBg.rgbaBuffer.isDirect || !rTrans.rgbaBuffer.isDirect) {
                lane4Errors.add("buffer_not_direct")
            }
            if (rBg.rgbaBuffer.order() != ByteOrder.nativeOrder() ||
                rTrans.rgbaBuffer.order() != ByteOrder.nativeOrder()
            ) {
                lane4Errors.add("buffer_not_native_order")
            }
            if (bgWhiteLikePixels <= 0 && transWhiteLikePixels <= 0) {
                lane4Errors.add("no_whitelike_pixel_for_rgba_order_sanity")
            }
            if (bgBlackBackgroundPixels <= 0) {
                lane4Errors.add("no_black_background_pixel_for_rgba_order_sanity")
            }
            if (rBg.rgbaBuffer.position() != 0 || rTrans.rgbaBuffer.position() != 0) {
                lane4Errors.add("buffer_position_drift")
            }
        }

        val lane4Pass = lane4Errors.isEmpty()

        // Lane 5: canonicalPass
        val allNativeLanesPass = lane1Pass && lane2Pass && lane3Pass && lane4Pass
        val lane5Pass = allNativeLanesPass

        val failureReasons = mutableListOf<String>()
        if (!lane1Pass) failureReasons.add("lane1_validation:${lane1Errors.joinToString(",")}")
        if (!lane2Pass) failureReasons.add("lane2_background:${lane2Errors.joinToString(",")}")
        if (!lane3Pass) failureReasons.add("lane3_transparent:${lane3Errors.joinToString(",")}")
        if (!lane4Pass) failureReasons.add("lane4_packing:${lane4Errors.joinToString(",")}")
        val failureReason = failureReasons.joinToString("; ")

        val details = LinkedHashMap<String, Any?>()
        details["validationErrorsChecked"] = 7
        details["validationErrorsFound"] = lane1Errors.size
        details["bgWidth"] = (rBg as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.width
        details["bgHeight"] = (rBg as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.height
        details["bgRowStrideBytes"] = (rBg as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.rowStrideBytes
        details["bgCapacity"] = (rBg as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.rgbaBuffer?.capacity()
        details["bgNonZeroAlphaPixels"] = bgNonZeroAlphaPixels
        details["bgWhiteLikePixels"] = bgWhiteLikePixels
        details["bgBlackBackgroundPixels"] = bgBlackBackgroundPixels
        details["transCornerAlpha"] = transCornerAlpha
        details["transTransparentAlphaPixels"] = transTransparentPixels
        details["transWhiteLikePixels"] = transWhiteLikePixels
        details["bgBufferDirect"] = (rBg as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.rgbaBuffer?.isDirect
        details["transBufferDirect"] = (rTrans as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.rgbaBuffer?.isDirect
        details["bgBufferOrder"] = (rBg as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.rgbaBuffer?.order()?.toString()
        details["bgBufferPosition"] = (rBg as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.rgbaBuffer?.position()
        details["transBufferPosition"] = (rTrans as? AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success)?.rgbaBuffer?.position()

        return buildPayload(
            pass = allNativeLanesPass,
            failureReason = failureReason,
            lane1Pass = lane1Pass,
            lane2Pass = lane2Pass,
            lane3Pass = lane3Pass,
            lane4Pass = lane4Pass,
            lane5Pass = lane5Pass,
            details = details,
        )
    }

    private fun buildPayload(
        pass: Boolean,
        failureReason: String,
        lane1Pass: Boolean,
        lane2Pass: Boolean,
        lane3Pass: Boolean,
        lane4Pass: Boolean,
        lane5Pass: Boolean,
        details: Map<String, Any?>,
    ): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        val allNativeLanesPass = pass && lane1Pass && lane2Pass && lane3Pass && lane4Pass && lane5Pass
        map["pass"] = allNativeLanesPass
        map["status"] = if (allNativeLanesPass) "PASS" else "FAIL"
        map["marker"] = if (allNativeLanesPass) PASS_MARKER else FAIL_MARKER
        map["proofBoundary"] = PROOF_BOUNDARY
        map["failureReason"] = if (allNativeLanesPass) "" else failureReason
        map["validationPass"] = lane1Pass
        map["backgroundPass"] = lane2Pass
        map["transparentPass"] = lane3Pass
        map["packingPass"] = lane4Pass
        map["canonicalPass"] = lane5Pass
        map["allNativeLanesPass"] = allNativeLanesPass
        map["nativeAllLanesPass"] = allNativeLanesPass
        map["details"] = details
        map["raw"] = mapToJsonString(map)
        return map
    }

    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        map["pass"] = false
        map["status"] = "FAIL"
        map["marker"] = FAIL_MARKER
        map["proofBoundary"] = PROOF_BOUNDARY
        map["failureReason"] = reason
        for (key in GATE_KEYS) {
            map[key] = false
        }
        map["allNativeLanesPass"] = false
        map["nativeAllLanesPass"] = false
        map["details"] = mapOf("reason" to reason)
        map["raw"] = "{\"pass\":false,\"status\":\"FAIL\",\"failureReason\":\"$reason\"}"
        return map
    }

    private fun mapToJsonString(map: Map<*, *>): String {
        return try {
            mapToJsonObject(map).toString()
        } catch (t: Throwable) {
            "{\"pass\":false,\"status\":\"FAIL\",\"failureReason\":\"json_serialization_failed\"}"
        }
    }

    private fun mapToJsonObject(map: Map<*, *>): JSONObject {
        val obj = JSONObject()
        for ((key, value) in map) {
            if (key != null) {
                obj.put(key.toString(), wrapJson(value))
            }
        }
        return obj
    }

    private fun wrapJson(value: Any?): Any? = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> mapToJsonObject(value)
        is Collection<*> -> {
            val arr = JSONArray()
            for (item in value) {
                arr.put(wrapJson(item))
            }
            arr
        }
        is Boolean, is Number, is String -> value
        else -> value.toString()
    }
}
