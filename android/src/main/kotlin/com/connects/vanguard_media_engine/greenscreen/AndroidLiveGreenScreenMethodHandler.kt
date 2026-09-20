package com.connects.vanguard_media_engine.greenscreen

import android.content.Context
import android.os.Handler
import com.connects.vanguard_media_engine.camera.AndroidCameraSessionAdmission
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * Thin MethodChannel handler for the generic live green-screen routes:
 * `startLiveGreenScreenSession`, `updateLiveGreenScreenBackground`,
 * `updateLiveGreenScreenTransform`, `stopLiveGreenScreenSession`.
 *
 * The plugin only routes here. This class owns argument parsing and
 * validation (`INVALID_ARG`) and error-code decoding; every lifecycle
 * decision lives in [AndroidLiveGreenScreenSessionCoordinator], which replies
 * with `live_busy`, `cameraUnavailable`, `composition_failed` or
 * `session_not_found`.
 *
 * Caller-agnostic: live meeting/calling, going live, camera, and the
 * Universal Editor are all expected callers; nothing here is Duet-owned.
 * All public methods are called on the main thread.
 */
class AndroidLiveGreenScreenMethodHandler(
    mainHandler: Handler,
    textureRegistry: TextureRegistry?,
    context: Context?,
    cameraAdmission: AndroidCameraSessionAdmission,
    onLiveGreenScreenEvent: ((Map<String, Any?>) -> Unit)?,
) {

    companion object {
        const val METHOD_START = "startLiveGreenScreenSession"
        const val METHOD_UPDATE_BACKGROUND = "updateLiveGreenScreenBackground"
        const val METHOD_UPDATE_TRANSFORM = "updateLiveGreenScreenTransform"
        const val METHOD_STOP = "stopLiveGreenScreenSession"

        private val OWNED_METHODS = setOf(
            METHOD_START,
            METHOD_UPDATE_BACKGROUND,
            METHOD_UPDATE_TRANSFORM,
            METHOD_STOP,
        )

        private const val ERROR_INVALID_ARG = "INVALID_ARG"

        @JvmStatic
        fun ownsMethod(method: String): Boolean = OWNED_METHODS.contains(method)
    }

    private val coordinator = AndroidLiveGreenScreenSessionCoordinator(
        mainHandler,
        textureRegistry,
        context,
        cameraAdmission,
        onLiveGreenScreenEvent,
    )

    // ── Dispatch ──────────────────────────────────────────────────────────────

    @Suppress("UNCHECKED_CAST")
    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        val safeArgs = args as? Map<String, Any?> ?: emptyMap()
        when (method) {
            METHOD_START -> {
                val request = try {
                    parseStartRequest(safeArgs)
                } catch (t: IllegalArgumentException) {
                    invalidArg(result, method, t)
                    return
                }
                coordinator.startSession(request) { value, errStr ->
                    replyFromCoordinator(result, value, errStr)
                }
            }

            METHOD_UPDATE_BACKGROUND -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                val background = try {
                    parseBackground(safeArgs["background"])
                } catch (t: IllegalArgumentException) {
                    invalidArg(result, method, t)
                    return
                }
                coordinator.updateBackground(sid, background) { value, errStr ->
                    replyFromCoordinator(result, value, errStr)
                }
            }

            METHOD_UPDATE_TRANSFORM -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                val transform = try {
                    parseForegroundTransform(safeArgs["foregroundTransform"], required = true)
                } catch (t: IllegalArgumentException) {
                    invalidArg(result, method, t)
                    return
                }
                coordinator.updateTransform(sid, transform) { value, errStr ->
                    replyFromCoordinator(result, value, errStr)
                }
            }

            METHOD_STOP -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                coordinator.stopSession(sid) { value, errStr ->
                    replyFromCoordinator(result, value, errStr)
                }
            }

            else -> result.notImplemented()
        }
    }

    // ── Teardown ──────────────────────────────────────────────────────────────

    /** Idempotent: stops any active live session and quits the coordinator's threads. */
    fun disposeAll() {
        coordinator.disposeAll()
    }

    // ── Parsing / validation (throws IllegalArgumentException → INVALID_ARG) ──

    private fun parseStartRequest(args: Map<String, Any?>): AndroidLiveGreenScreenSessionCoordinator.StartRequest {
        val canvas = args["canvasSize"] as? Map<*, *>
            ?: throw IllegalArgumentException("'canvasSize' map required")
        val widthPx = requirePositiveInt(canvas, "canvasSize.width", "width")
        val heightPx = requirePositiveInt(canvas, "canvasSize.height", "height")
        val background = parseBackground(args["background"])
        val transform = parseForegroundTransform(args["foregroundTransform"], required = false)
        return AndroidLiveGreenScreenSessionCoordinator.StartRequest(
            widthPx = widthPx,
            heightPx = heightPx,
            background = background,
            foregroundTransform = transform,
        )
    }

    /**
     * Static backgrounds only (v1): `{type: solidColor, argbColor}` or
     * `{type: image, filePath, scaleMode?}`. The image file must exist so a
     * missing background fails closed here instead of silently drawing black.
     */
    private fun parseBackground(raw: Any?): AndroidGreenScreenBackground {
        val map = raw as? Map<*, *> ?: throw IllegalArgumentException("'background' map required")
        return when (val type = map["type"] as? String) {
            "solidColor" -> {
                val argb = (map["argbColor"] as? Number)?.toInt()
                    ?: throw IllegalArgumentException("'background.argbColor' integer required")
                AndroidGreenScreenBackground(
                    type = AndroidGreenScreenBackgroundType.SOLID_COLOR,
                    argbColor = argb,
                    filePath = null,
                    scaleMode = AndroidGreenScreenBackgroundScaleMode.ASPECT_FILL,
                )
            }
            "image" -> {
                val path = (map["filePath"] as? String)?.trim()
                if (path.isNullOrEmpty()) {
                    throw IllegalArgumentException("'background.filePath' must be a non-blank string")
                }
                if (!File(path).isFile) {
                    throw IllegalArgumentException("'background.filePath' does not exist: $path")
                }
                val scaleMode = when (val rawMode = map["scaleMode"]) {
                    null, "aspectFill" -> AndroidGreenScreenBackgroundScaleMode.ASPECT_FILL
                    "aspectFit" -> AndroidGreenScreenBackgroundScaleMode.ASPECT_FIT
                    else -> throw IllegalArgumentException(
                        "'background.scaleMode' must be aspectFill or aspectFit (got $rawMode)",
                    )
                }
                AndroidGreenScreenBackground(
                    type = AndroidGreenScreenBackgroundType.IMAGE,
                    argbColor = AndroidGreenScreenBackground.VIDEO.argbColor,
                    filePath = path,
                    scaleMode = scaleMode,
                )
            }
            else -> throw IllegalArgumentException(
                "'background.type' must be solidColor or image (got ${type ?: "null"}); " +
                    "video backgrounds are not supported by the live session",
            )
        }
    }

    /**
     * `{scale, offset: {x, y}?, anchor: {x, y}?}`. Absent → null (identity)
     * when not [required]. Scale must be finite and positive; components, when
     * present, must be finite numbers (offset defaults 0.0, anchor 0.5).
     */
    private fun parseForegroundTransform(raw: Any?, required: Boolean): AndroidGreenScreenForegroundTransform? {
        if (raw == null) {
            if (required) throw IllegalArgumentException("'foregroundTransform' map required")
            return null
        }
        val map = raw as? Map<*, *> ?: throw IllegalArgumentException("'foregroundTransform' must be a map")
        val scale = requireFiniteDouble(map, "foregroundTransform.scale", "scale")
        if (scale <= 0.0) throw IllegalArgumentException("'foregroundTransform.scale' must be > 0")
        val (offsetX, offsetY) = parsePoint(map["offset"], "foregroundTransform.offset", 0.0)
        val (anchorX, anchorY) = parsePoint(map["anchor"], "foregroundTransform.anchor", 0.5)
        return AndroidGreenScreenForegroundTransform(
            scale = scale,
            offsetX = offsetX,
            offsetY = offsetY,
            anchorX = anchorX,
            anchorY = anchorY,
        )
    }

    private fun parsePoint(raw: Any?, label: String, default: Double): Pair<Double, Double> {
        if (raw == null) return Pair(default, default)
        val map = raw as? Map<*, *> ?: throw IllegalArgumentException("'$label' must be a map")
        return Pair(
            optionalFiniteDouble(map, "$label.x", "x", default),
            optionalFiniteDouble(map, "$label.y", "y", default),
        )
    }

    private fun requireSessionId(
        args: Map<String, Any?>,
        method: String,
        result: MethodChannel.Result,
    ): String? {
        val sid = args["sessionId"] as? String
        if (sid.isNullOrEmpty()) {
            result.error(ERROR_INVALID_ARG, "$method: missing required argument 'sessionId'.", null)
            return null
        }
        return sid
    }

    private fun requirePositiveInt(map: Map<*, *>, label: String, key: String): Int {
        val value = (map[key] as? Number)?.toInt()
            ?: throw IllegalArgumentException("'$label' integer required")
        if (value <= 0) throw IllegalArgumentException("'$label' must be > 0")
        return value
    }

    private fun requireFiniteDouble(map: Map<*, *>, label: String, key: String): Double {
        val value = (map[key] as? Number)?.toDouble()
            ?: throw IllegalArgumentException("'$label' number required")
        if (!value.isFinite()) throw IllegalArgumentException("'$label' must be finite")
        return value
    }

    private fun optionalFiniteDouble(map: Map<*, *>, label: String, key: String, default: Double): Double =
        when (val value = map[key]) {
            null -> default
            is Number -> {
                val d = value.toDouble()
                if (!d.isFinite()) throw IllegalArgumentException("'$label' must be finite")
                d
            }
            else -> throw IllegalArgumentException("'$label' must be a number")
        }

    // ── Reply helpers ─────────────────────────────────────────────────────────

    private fun invalidArg(result: MethodChannel.Result, method: String, t: Throwable) {
        result.error(ERROR_INVALID_ARG, "$method: ${t.message ?: t.javaClass.simpleName}", null)
    }

    /** [errStr] is encoded as "code|message" by the coordinator when non-null. */
    private fun replyFromCoordinator(result: MethodChannel.Result, value: Any?, errStr: String?) {
        if (errStr != null) {
            val (code, message) = splitError(errStr)
            result.error(code, message, null)
        } else {
            result.success(value)
        }
    }

    private fun splitError(errStr: String): Pair<String, String> {
        val idx = errStr.indexOf('|')
        return if (idx < 0) Pair("unknown", errStr)
        else Pair(errStr.substring(0, idx), errStr.substring(idx + 1))
    }
}
