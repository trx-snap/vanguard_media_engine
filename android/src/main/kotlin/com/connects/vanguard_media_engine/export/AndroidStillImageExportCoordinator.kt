package com.connects.vanguard_media_engine.export

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

// ── AndroidStillImageExportCoordinator (Phase 5-Unit AD / Phase 10-C-3L) ─────
//
// Android parity for the `exportImage` MethodChannel route (see
// VanguardMediaEnginePlugin.swift's "exportImage" case). Cheap argument/type
// validation and format/orientation-policy resolution run synchronously;
// decode, filter application, encode, and the safe output commit run on a
// single background executor via [AndroidStillImageExportSession]. Every
// reply is routed through [GuardedReply] so at most one result is ever
// delivered and never after detach.
//
// Scope (this slice): supports "colorMatrix" filters and the "preserve"
// orientation policy (baked EXIF pixels, not metadata -- reported dimensions
// reflect the baked transform). "applyAndRotate" is a deferred shared-sink
// policy on iOS too, so this reports EXPORT_IMAGE_FAILED rather than
// claiming unsupported success. Supported encode formats: JPEG/JPG, PNG, and
// HEIC/HEIF (device-capability-gated via AndroidHeicImageEncoder inside the
// session's background executor; fails closed with
// EXPORT_IMAGE_UNSUPPORTED_FORMAT when unsupported and never falls back to
// JPEG) -- WEBP and unrecognized strings remain EXPORT_IMAGE_UNSUPPORTED_FORMAT.
// Enabled `transform`/`overlay` filters are known-but-unimplemented and
// return EXPORT_IMAGE_UNSUPPORTED_FILTER.
class AndroidStillImageExportCoordinator(
    @Suppress("UNUSED_PARAMETER") context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private val OWNED_METHODS = setOf("exportImage")

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "VGStillImageExport").apply { isDaemon = true }
    }

    @Volatile private var detached = false

    /** AtomicBoolean-guarded, detach-aware [MethodChannel.Result] wrapper. */
    private inner class GuardedReply(private val result: MethodChannel.Result) {
        private val fired = AtomicBoolean(false)

        fun success(map: Map<String, Any?>) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.success(map)
                }
            }
        }

        fun error(code: String, message: String?) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.error(code, message, null)
                }
            }
        }
    }

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        when (method) {
            "exportImage" -> handleExportImage(args, result)
        }
    }

    // ── exportImage ──────────────────────────────────────────────────────────

    private fun handleExportImage(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val sourcePath = (args?.get("sourcePath") as? String)?.takeIf { it.isNotEmpty() }
        if (sourcePath == null) {
            reply.error("EXPORT_IMAGE_INVALID_ARGUMENTS", "sourcePath is required and must be non-empty")
            return
        }
        val outputPath = (args.get("outputPath") as? String)?.takeIf { it.isNotEmpty() }
        if (outputPath == null) {
            reply.error("EXPORT_IMAGE_INVALID_ARGUMENTS", "outputPath is required and must be non-empty")
            return
        }
        val originalFormat = (args.get("format") as? String)?.takeIf { it.isNotEmpty() }
        if (originalFormat == null) {
            reply.error("EXPORT_IMAGE_INVALID_ARGUMENTS", "format is required and must be non-empty")
            return
        }
        val qualityNumber = args.get("quality") as? Number
        if (qualityNumber == null) {
            reply.error("EXPORT_IMAGE_INVALID_ARGUMENTS", "quality is required and must be a number")
            return
        }
        val filtersArg = args.get("filters")
        val filterDicts: List<Map<*, *>> = when (filtersArg) {
            null -> emptyList()
            is List<*> -> filtersArg.filterIsInstance<Map<*, *>>()
            else -> {
                reply.error("EXPORT_IMAGE_INVALID_ARGUMENTS", "filters must be a List when provided")
                return
            }
        }
        val orientationPolicyArg = (args.get("orientationPolicy") as? String)?.takeIf { it.isNotEmpty() }
        if (orientationPolicyArg == null) {
            reply.error("EXPORT_IMAGE_INVALID_ARGUMENTS", "orientationPolicy is required and must be non-empty")
            return
        }

        val sourceFile = File(sourcePath)
        if (!sourceFile.exists() || !sourceFile.canRead() || !sourceFile.isFile) {
            reply.error("EXPORT_IMAGE_INVALID_ARGUMENTS", "Source image file does not exist at: $sourcePath")
            return
        }

        val outputFile = File(outputPath)
        val parentDir = outputFile.absoluteFile.parentFile
        if (parentDir == null || !parentDir.exists() || !parentDir.isDirectory) {
            reply.error(
                "EXPORT_IMAGE_INVALID_ARGUMENTS",
                "Output parent directory does not exist: ${parentDir?.path ?: outputPath}",
            )
            return
        }

        val encodeFormat = when (originalFormat.lowercase()) {
            "jpeg", "jpg" -> StillImageEncodeFormat.JPEG
            "png" -> StillImageEncodeFormat.PNG
            "heic", "heif" -> StillImageEncodeFormat.HEIC
            else -> {
                reply.error("EXPORT_IMAGE_UNSUPPORTED_FORMAT", "Unsupported image format: $originalFormat")
                return
            }
        }

        val bakeExifOrientation: Boolean
        when (orientationPolicyArg.lowercase()) {
            "preserve" -> bakeExifOrientation = true
            "applyandrotate" -> {
                reply.error(
                    "EXPORT_IMAGE_FAILED",
                    "orientationPolicy 'applyAndRotate' is deferred on the shared image export " +
                        "sink and is not yet supported.",
                )
                return
            }
            else -> {
                reply.error("EXPORT_IMAGE_INVALID_ARGUMENTS", "Invalid orientation policy: $orientationPolicyArg")
                return
            }
        }

        val qualityPercent = (qualityNumber.toDouble().coerceIn(0.0, 1.0) * 100).roundToInt().coerceIn(0, 100)

        if (detached) return

        try {
            executor.execute {
                val session = AndroidStillImageExportSession(
                    sourcePath = sourcePath,
                    outputPath = outputPath,
                    encodeFormat = encodeFormat,
                    qualityPercent = qualityPercent,
                    bakeExifOrientation = bakeExifOrientation,
                    filterDicts = filterDicts,
                )
                when (val sessionResult = session.run()) {
                    is AndroidStillImageExportResult.Success -> reply.success(
                        mapOf(
                            "success" to true,
                            "path" to sessionResult.path,
                            "width" to sessionResult.width,
                            "height" to sessionResult.height,
                            "format" to originalFormat,
                            "fileSizeBytes" to sessionResult.fileSizeBytes,
                        ),
                    )
                    is AndroidStillImageExportResult.Failure -> reply.error(
                        sessionResult.code,
                        sessionResult.message,
                    )
                }
            }
        } catch (t: Throwable) {
            reply.error("EXPORT_IMAGE_FAILED", t.message ?: t.javaClass.simpleName)
        }
    }

    // ── Disposal ─────────────────────────────────────────────────────────────

    /** Idempotent: blocks any further replies and shuts down the executor. */
    fun disposeAll() {
        detached = true
        executor.shutdown()
    }
}
