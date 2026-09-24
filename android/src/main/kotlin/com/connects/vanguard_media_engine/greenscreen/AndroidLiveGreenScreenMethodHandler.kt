package com.connects.vanguard_media_engine.greenscreen

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import com.connects.vanguard_media_engine.camera.AndroidCameraSessionAdmission
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * Thin MethodChannel handler for the generic live green-screen routes:
 * `startLiveGreenScreenSession`, `updateLiveGreenScreenBackground`,
 * `updateLiveGreenScreenTransform`, `stopLiveGreenScreenSession`, and the
 * recording routes `startLiveGreenScreenRecording`,
 * `stopLiveGreenScreenRecording`, `cancelLiveGreenScreenRecording`.
 *
 * The plugin only routes here. This class owns argument parsing and
 * validation (`INVALID_ARG`) and error-code decoding; every lifecycle
 * decision lives in [AndroidLiveGreenScreenSessionCoordinator], which replies
 * with `live_busy`, `cameraUnavailable`, `composition_failed`,
 * `session_not_found`, `recording_active`, `recording_not_active`,
 * `recording_failed` or `disk_full`.
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
        const val METHOD_START_RECORDING = "startLiveGreenScreenRecording"
        const val METHOD_STOP_RECORDING = "stopLiveGreenScreenRecording"
        const val METHOD_CANCEL_RECORDING = "cancelLiveGreenScreenRecording"

        private val OWNED_METHODS = setOf(
            METHOD_START,
            METHOD_UPDATE_BACKGROUND,
            METHOD_UPDATE_TRANSFORM,
            METHOD_STOP,
            METHOD_START_RECORDING,
            METHOD_STOP_RECORDING,
            METHOD_CANCEL_RECORDING,
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

            METHOD_START_RECORDING -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                // Optional absolute output path; absent/blank lets the
                // coordinator pick a cache path. A present non-string is a
                // malformed argument.
                val rawOutputPath = safeArgs["outputPath"]
                val outputPath: String? = when (rawOutputPath) {
                    null -> null
                    is String -> rawOutputPath.trim().takeIf { it.isNotEmpty() }
                    else -> {
                        result.error(ERROR_INVALID_ARG, "$method: 'outputPath' must be a string.", null)
                        return
                    }
                }
                coordinator.startRecording(sid, outputPath) { value, errStr ->
                    replyFromCoordinator(result, value, errStr)
                }
            }

            METHOD_STOP_RECORDING -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                coordinator.stopRecording(sid) { value, errStr ->
                    replyFromCoordinator(result, value, errStr)
                }
            }

            METHOD_CANCEL_RECORDING -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                coordinator.cancelRecording(sid) { value, errStr ->
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
     * `{type: solidColor, argbColor}`, `{type: image, filePath, scaleMode?}`,
     * or `{type: video|videoFile, filePath, scaleMode?}`. The image/video file
     * must exist, and a video file must contain a decodable video track, so a
     * missing or unusable background fails closed here instead of silently
     * drawing black or freezing the render loop mid-session.
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
                val path = requireExistingFilePath(map)
                val scaleMode = requireScaleMode(map)
                AndroidGreenScreenBackground(
                    type = AndroidGreenScreenBackgroundType.IMAGE,
                    argbColor = AndroidGreenScreenBackground.VIDEO.argbColor,
                    filePath = path,
                    scaleMode = scaleMode,
                )
            }
            "video", "videoFile" -> {
                val path = requireExistingFilePath(map)
                if (!hasDecodableVideoTrack(path)) {
                    throw IllegalArgumentException(
                        "'background.filePath' has no decodable video track: $path",
                    )
                }
                val scaleMode = requireScaleMode(map)
                AndroidGreenScreenBackground(
                    type = AndroidGreenScreenBackgroundType.VIDEO,
                    argbColor = AndroidGreenScreenBackground.VIDEO.argbColor,
                    filePath = path,
                    scaleMode = scaleMode,
                )
            }
            else -> throw IllegalArgumentException(
                "'background.type' must be solidColor, image, video, or videoFile (got ${type ?: "null"})",
            )
        }
    }

    private fun requireExistingFilePath(map: Map<*, *>): String {
        val path = (map["filePath"] as? String)?.trim()
        if (path.isNullOrEmpty()) {
            throw IllegalArgumentException("'background.filePath' must be a non-blank string")
        }
        if (!File(path).isFile) {
            throw IllegalArgumentException("'background.filePath' does not exist: $path")
        }
        return path
    }

    private fun requireScaleMode(map: Map<*, *>): AndroidGreenScreenBackgroundScaleMode =
        when (val rawMode = map["scaleMode"]) {
            null, "aspectFill" -> AndroidGreenScreenBackgroundScaleMode.ASPECT_FILL
            "aspectFit" -> AndroidGreenScreenBackgroundScaleMode.ASPECT_FIT
            else -> throw IllegalArgumentException(
                "'background.scaleMode' must be aspectFill or aspectFit (got $rawMode)",
            )
        }

    /**
     * Lightweight, synchronous container-header probe (no frame decode): opens
     * [path] with a throwaway [MediaExtractor] and checks for at least one
     * track whose MIME type starts with "video/". Mirrors the cost class of
     * the image path's existing
     * synchronous [File.isFile] / [android.graphics.BitmapFactory] checks, so
     * running it here on the calling (platform) thread does not newly violate
     * the "must not block render loop pacing" requirement, which concerns
     * steady-state per-frame decode, not one-time argument validation. Always
     * releases the extractor.
     */
    private fun hasDecodableVideoTrack(path: String): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            (0 until extractor.trackCount).any { i ->
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                mime?.startsWith("video/") == true
            }
        } catch (_: Throwable) {
            false
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    /**
     * `{scale, offset: {x, y}?, anchor: {x, y}?, rotationDegrees?}`. Absent →
     * null (identity) when not [required]. Scale must be finite and positive;
     * offset/anchor components, when present, must be finite numbers (offset
     * defaults 0.0, anchor 0.5). `rotationDegrees` is best-effort: missing,
     * wrong-type, or non-finite values default to 0.0 rather than throwing.
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
        val rotationDegrees = parseRotationDegrees(map, "rotationDegrees")
        return AndroidGreenScreenForegroundTransform(
            scale = scale,
            offsetX = offsetX,
            offsetY = offsetY,
            anchorX = anchorX,
            anchorY = anchorY,
            rotationDegrees = rotationDegrees,
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

    /**
     * Unlike [optionalFiniteDouble], missing, wrong-type, and non-finite
     * `rotationDegrees` all silently default to `0.0` rather than throwing;
     * rotation is contract data only and must never fail-closed the whole
     * `foregroundTransform` parse.
     */
    private fun parseRotationDegrees(map: Map<*, *>, key: String): Double {
        val value = map[key] as? Number ?: return 0.0
        val d = value.toDouble()
        return if (d.isFinite()) d else 0.0
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
