package com.connects.vanguard_media_engine.greenscreen

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Thin MethodChannel handler for the generic green-screen export route
 * `exportGreenScreenComposition`. The plugin only routes here; this class owns
 * argument parsing and validation (`INVALID_ARG`), one-export-at-a-time
 * admission (`export_busy`), background execution on a single daemon thread,
 * result delivery on the main thread, and engine terminal mapping
 * (`composition_failed` with the engine result map as error details).
 *
 * Mask descriptors become direct CPU R8 mask frames here, never in the engine:
 *  - `constantAlpha`: a fresh direct buffer per output frame filled with alpha.
 *  - `r8FrameFiles`: output frame `i` reads exactly `rowStrideBytes * height`
 *    (or `width * height` when the stride is 0) bytes of file `i` into a direct
 *    buffer; missing or short files fail closed at validation and again at read.
 *    Future ML segmentation outputs can reuse this descriptor unchanged.
 *
 * Caller-agnostic: Duet, live meeting/calling, going live, camera, and the
 * Universal Editor are all expected callers; nothing here is Duet-owned.
 */
class AndroidGreenScreenExportMethodHandler(private val mainHandler: Handler) {

    companion object {
        private const val TAG = "VanguardGreenScreenExportHandler"
        const val METHOD_EXPORT = "exportGreenScreenComposition"
        private val OWNED_METHODS = setOf(METHOD_EXPORT)

        private const val ERROR_INVALID_ARG = "INVALID_ARG"
        private const val ERROR_BUSY = "export_busy"
        private const val ERROR_COMPOSITION_FAILED = "composition_failed"

        private const val MASK_TYPE_CONSTANT_ALPHA = "constantAlpha"
        private const val MASK_TYPE_R8_FRAME_FILES = "r8FrameFiles"
        private const val DEFAULT_CONSTANT_MASK_DIMENSION = 64
        private val CARDINAL_ROTATIONS = setOf(0, 90, 180, 270)

        @JvmStatic
        fun ownsMethod(method: String): Boolean = OWNED_METHODS.contains(method)
    }

    private val busy = AtomicBoolean(false)
    @Volatile private var disposed = false
    @Volatile private var activeCancelFlag: AtomicBoolean? = null
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "greenscreen-export-bg").also { it.isDaemon = true }
    }

    /** Called on the main thread by the plugin for routes [ownsMethod] returns true for. */
    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        when (method) {
            METHOD_EXPORT -> handleExport(args, result)
            else -> result.notImplemented()
        }
    }

    /**
     * Idempotent. Rejects new exports, asks any in-flight export to cancel
     * (the engine then deletes its tmp and generated background), and stops
     * the executor. The in-flight run clears `busy` itself when it ends.
     */
    fun disposeAll() {
        disposed = true
        activeCancelFlag?.set(true)
        executor.shutdown()
    }

    // ── Export route ──────────────────────────────────────────────────────────

    private fun handleExport(args: Map<*, *>?, result: MethodChannel.Result) {
        if (disposed) {
            result.error(ERROR_BUSY, "$METHOD_EXPORT: handler has been disposed.", null)
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.error(ERROR_BUSY, "$METHOD_EXPORT: another green-screen export is already active.", null)
            return
        }
        val request = try {
            parseRequest(args)
        } catch (t: Throwable) {
            busy.set(false)
            result.error(ERROR_INVALID_ARG, "$METHOD_EXPORT: ${t.message ?: t.javaClass.simpleName}", null)
            return
        }
        activeCancelFlag = request.cancelFlag
        try {
            executor.execute { runExport(request, result) }
        } catch (_: RejectedExecutionException) {
            activeCancelFlag = null
            busy.set(false)
            result.error(ERROR_BUSY, "$METHOD_EXPORT: handler has been disposed.", null)
        }
    }

    private sealed class Reply {
        class Success(val value: Map<String, Any?>) : Reply()
        class Error(val code: String, val message: String, val details: Any?) : Reply()
    }

    /** Background thread. Always clears `busy` and posts exactly one reply. */
    private fun runExport(request: AndroidGreenScreenExportEngine.Request, result: MethodChannel.Result) {
        val reply: Reply = try {
            val engineResult = AndroidGreenScreenExportEngine.export(request)
            val map = engineResult.toMap()
            if (engineResult.pass) {
                Reply.Success(map)
            } else {
                Reply.Error(
                    ERROR_COMPOSITION_FAILED,
                    "$METHOD_EXPORT: ${engineResult.terminalState.name.lowercase()}:${engineResult.reason}",
                    map,
                )
            }
        } catch (t: Throwable) {
            Log.e(TAG, "$METHOD_EXPORT uncaught exception", t)
            Reply.Error(
                ERROR_COMPOSITION_FAILED,
                "$METHOD_EXPORT: exception:${t.javaClass.simpleName}:${t.message}",
                null,
            )
        } finally {
            activeCancelFlag = null
            busy.set(false)
        }
        mainHandler.post {
            if (disposed) return@post
            when (reply) {
                is Reply.Success -> result.success(reply.value)
                is Reply.Error -> result.error(reply.code, reply.message, reply.details)
            }
        }
    }

    // ── Parsing / validation (throws IllegalArgumentException → INVALID_ARG) ──

    @Suppress("UNCHECKED_CAST")
    private fun parseRequest(rawArgs: Map<*, *>?): AndroidGreenScreenExportEngine.Request {
        val args = rawArgs as? Map<String, Any?> ?: throw IllegalArgumentException("arguments map required")
        val foregroundVideoPath = requireString(args, "foregroundVideoPath")
        val outputPath = requireString(args, "outputPath")
        val targetSize = args["targetSize"] as? Map<String, Any?>
            ?: throw IllegalArgumentException("'targetSize' map required")
        val width = requirePositiveInt(targetSize, "targetSize.width", "width")
        val height = requirePositiveInt(targetSize, "targetSize.height", "height")
        val fps = requirePositiveInt(args, "fps")
        val videoBitRate = requirePositiveInt(args, "videoBitRate")
        val outputFrameCount = requirePositiveInt(args, "outputFrameCount")
        val background = parseBackground(args["background"])
        val maskProvider = parseMask(args["mask"], outputFrameCount)
        val backgroundRect = parseRect(args["backgroundRect"], "backgroundRect")
        val foregroundRect = parseRect(args["foregroundRect"], "foregroundRect")
        val backgroundRotation = optionalInt(args, "backgroundRotationDegrees", 0)
        val foregroundRotation = optionalInt(args, "foregroundRotationDegrees", 0)
        if (backgroundRotation !in CARDINAL_ROTATIONS) {
            throw IllegalArgumentException("'backgroundRotationDegrees' must be 0, 90, 180, or 270")
        }
        if (foregroundRotation !in CARDINAL_ROTATIONS) {
            throw IllegalArgumentException("'foregroundRotationDegrees' must be 0, 90, 180, or 270")
        }
        val request = AndroidGreenScreenExportEngine.Request(
            background = background,
            foregroundVideoPath = foregroundVideoPath,
            outputPath = outputPath,
            width = width,
            height = height,
            fps = fps,
            bitrate = videoBitRate,
            outputFrameCount = outputFrameCount,
            maskProvider = maskProvider,
            cancelFlag = AtomicBoolean(false),
            backgroundRect = backgroundRect,
            foregroundRect = foregroundRect,
            backgroundRotationDegrees = backgroundRotation,
            foregroundRotationDegrees = foregroundRotation,
            backgroundMirrorHorizontal = optionalBoolean(args, "backgroundMirrorHorizontal", false),
            foregroundMirrorHorizontal = optionalBoolean(args, "foregroundMirrorHorizontal", false),
        )
        AndroidGreenScreenExportEngine.validate(request)?.let { reason ->
            throw IllegalArgumentException("invalid request: $reason")
        }
        return request
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseBackground(raw: Any?): AndroidGreenScreenExportEngine.BackgroundSource {
        val map = raw as? Map<String, Any?> ?: throw IllegalArgumentException("'background' map required")
        return when (val type = map["type"] as? String) {
            AndroidGreenScreenExportEngine.BackgroundSource.TYPE_VIDEO_FILE ->
                AndroidGreenScreenExportEngine.BackgroundSource.VideoFile(requireString(map, "background.path", "path"))
            AndroidGreenScreenExportEngine.BackgroundSource.TYPE_SOLID_COLOR -> {
                val argb = (map["argbColor"] as? Number)?.toInt()
                    ?: throw IllegalArgumentException("'background.argbColor' integer required")
                AndroidGreenScreenExportEngine.BackgroundSource.SolidColor(argb)
            }
            AndroidGreenScreenExportEngine.BackgroundSource.TYPE_IMAGE_FILE -> {
                val scaleMode = AndroidGreenScreenExportEngine.ImageScaleMode.fromWireName(map["scaleMode"] as? String)
                    ?: throw IllegalArgumentException("'background.scaleMode' must be aspectFill or aspectFit")
                AndroidGreenScreenExportEngine.BackgroundSource.ImageFile(
                    requireString(map, "background.path", "path"),
                    scaleMode,
                )
            }
            else -> throw IllegalArgumentException(
                "'background.type' must be videoFile, solidColor, or imageFile (got ${type ?: "null"})",
            )
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseMask(raw: Any?, outputFrameCount: Int): AndroidGreenScreenExportEngine.MaskProvider {
        val map = raw as? Map<String, Any?> ?: throw IllegalArgumentException("'mask' map required")
        return when (val type = map["type"] as? String) {
            MASK_TYPE_CONSTANT_ALPHA -> {
                val alpha = (map["alpha"] as? Number)?.toInt()
                    ?: throw IllegalArgumentException("'mask.alpha' integer required")
                if (alpha !in 0..255) throw IllegalArgumentException("'mask.alpha' must be within 0..255")
                val width = optionalInt(map, "width", DEFAULT_CONSTANT_MASK_DIMENSION)
                val height = optionalInt(map, "height", DEFAULT_CONSTANT_MASK_DIMENSION)
                if (width <= 0 || height <= 0) throw IllegalArgumentException("'mask.width'/'mask.height' must be > 0")
                ConstantAlphaMaskProvider(alpha, width, height)
            }
            MASK_TYPE_R8_FRAME_FILES -> {
                val rawPaths = map["framePaths"] as? List<*>
                    ?: throw IllegalArgumentException("'mask.framePaths' list required")
                val paths = rawPaths.map { it as? String ?: throw IllegalArgumentException("'mask.framePaths' must contain strings") }
                val width = requirePositiveInt(map, "mask.width", "width")
                val height = requirePositiveInt(map, "mask.height", "height")
                val rowStrideBytes = optionalInt(map, "rowStrideBytes", 0)
                if (rowStrideBytes < 0 || (rowStrideBytes in 1 until width)) {
                    throw IllegalArgumentException("'mask.rowStrideBytes' must be 0 or >= width")
                }
                if (paths.size < outputFrameCount) {
                    throw IllegalArgumentException(
                        "'mask.framePaths' has ${paths.size} entries but outputFrameCount is $outputFrameCount",
                    )
                }
                val expectedBytes = (if (rowStrideBytes > 0) rowStrideBytes else width) * height
                for (i in 0 until outputFrameCount) {
                    val path = paths[i]
                    val file = File(path)
                    if (path.isBlank() || !file.isFile) {
                        throw IllegalArgumentException("'mask.framePaths[$i]' missing: $path")
                    }
                    if (file.length() < expectedBytes) {
                        throw IllegalArgumentException(
                            "'mask.framePaths[$i]' short: ${file.length()} < $expectedBytes bytes",
                        )
                    }
                }
                R8FrameFilesMaskProvider(paths, width, height, rowStrideBytes, expectedBytes)
            }
            else -> throw IllegalArgumentException(
                "'mask.type' must be $MASK_TYPE_CONSTANT_ALPHA or $MASK_TYPE_R8_FRAME_FILES (got ${type ?: "null"})",
            )
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseRect(raw: Any?, label: String): AndroidGreenScreenExportEngine.CanvasRect? {
        if (raw == null) return null
        val map = raw as? Map<String, Any?> ?: throw IllegalArgumentException("'$label' must be a map or null")
        return AndroidGreenScreenExportEngine.CanvasRect(
            x = requireInt(map, "$label.x", "x"),
            y = requireInt(map, "$label.y", "y"),
            width = requirePositiveInt(map, "$label.width", "width"),
            height = requirePositiveInt(map, "$label.height", "height"),
        )
    }

    private fun requireString(map: Map<String, Any?>, label: String, key: String = label): String {
        val value = map[key] as? String
        if (value.isNullOrBlank()) throw IllegalArgumentException("'$label' must be a non-blank string")
        return value
    }

    private fun requireInt(map: Map<String, Any?>, label: String, key: String = label): Int =
        (map[key] as? Number)?.toInt() ?: throw IllegalArgumentException("'$label' integer required")

    private fun requirePositiveInt(map: Map<String, Any?>, label: String, key: String = label): Int {
        val value = requireInt(map, label, key)
        if (value <= 0) throw IllegalArgumentException("'$label' must be > 0")
        return value
    }

    private fun optionalInt(map: Map<String, Any?>, key: String, default: Int): Int =
        when (val value = map[key]) {
            null -> default
            is Number -> value.toInt()
            else -> throw IllegalArgumentException("'$key' must be an integer")
        }

    private fun optionalBoolean(map: Map<String, Any?>, key: String, default: Boolean): Boolean =
        when (val value = map[key]) {
            null -> default
            is Boolean -> value
            else -> throw IllegalArgumentException("'$key' must be a boolean")
        }

    // ── Mask providers: method-channel descriptors → direct CPU R8 frames ─────

    /** Allocates and fills a fresh direct `width*height` buffer for every output frame. */
    private class ConstantAlphaMaskProvider(
        alpha: Int,
        private val width: Int,
        private val height: Int,
    ) : AndroidGreenScreenExportEngine.MaskProvider {
        private val template = ByteArray(width * height) { (alpha and 0xFF).toByte() }

        override fun maskForOutputFrame(frameIndex: Int, outputPtsUs: Long): AndroidGreenScreenExportEngine.MaskFrame {
            val buffer = ByteBuffer.allocateDirect(template.size)
            buffer.put(template)
            buffer.position(0)
            return AndroidGreenScreenExportEngine.MaskFrame.CpuR8(buffer, width, height, 0)
        }
    }

    /**
     * Output frame `i` reads exactly [expectedBytes] from `framePaths[i]` into a
     * direct buffer. Missing files, short files, or an index past the list
     * throw, which the engine reports as `mask_provider_exception` (fail closed).
     */
    private class R8FrameFilesMaskProvider(
        private val framePaths: List<String>,
        private val width: Int,
        private val height: Int,
        private val rowStrideBytes: Int,
        private val expectedBytes: Int,
    ) : AndroidGreenScreenExportEngine.MaskProvider {
        override fun maskForOutputFrame(frameIndex: Int, outputPtsUs: Long): AndroidGreenScreenExportEngine.MaskFrame {
            if (frameIndex !in framePaths.indices) {
                throw IllegalStateException("mask_frame_index_out_of_range:index=$frameIndex:count=${framePaths.size}")
            }
            val file = File(framePaths[frameIndex])
            if (!file.isFile) throw IllegalStateException("mask_frame_file_missing:index=$frameIndex")
            val buffer = ByteBuffer.allocateDirect(expectedBytes)
            FileInputStream(file).use { stream ->
                val channel = stream.channel
                while (buffer.hasRemaining()) {
                    val read = channel.read(buffer)
                    if (read < 0) {
                        throw IllegalStateException(
                            "mask_frame_file_short:index=$frameIndex:read=${buffer.position()}:expected=$expectedBytes",
                        )
                    }
                }
            }
            buffer.position(0)
            return AndroidGreenScreenExportEngine.MaskFrame.CpuR8(buffer, width, height, rowStrideBytes)
        }
    }
}
