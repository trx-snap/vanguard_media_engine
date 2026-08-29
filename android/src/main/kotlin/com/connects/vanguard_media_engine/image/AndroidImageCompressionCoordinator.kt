package com.connects.vanguard_media_engine.image

import android.content.Context
import android.os.Handler
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

// ── AndroidImageCompressionCoordinator (Phase 5-Unit AE / Phase 10-C-3M) ────
//
// Android parity for the `compressImage` MethodChannel route (see
// VanguardMediaEnginePlugin.swift's "compressImage" case and
// VanguardMediaPreparer._compressImageNative in
// lib/vanguard_media_preparer.dart). Cheap argument/type validation runs
// synchronously on the calling (platform) thread; decode, EXIF bake,
// resize, JPEG encode, and the safe output commit run on a single
// background executor via [AndroidImageCompressionSession]. Every reply is
// routed through [GuardedReply] so at most one result is ever delivered and
// never after detach.
class AndroidImageCompressionCoordinator(
    @Suppress("UNUSED_PARAMETER") context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private val OWNED_METHODS = setOf("compressImage")

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "VGImageCompression").apply { isDaemon = true }
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
            "compressImage" -> handleCompressImage(args, result)
        }
    }

    // ── compressImage ────────────────────────────────────────────────────────

    private fun handleCompressImage(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val inputPath = (args?.get("inputPath") as? String)?.takeIf { it.isNotEmpty() }
        if (inputPath == null) {
            reply.error("INVALID_ARG", "compressImage: inputPath is required and must be non-empty")
            return
        }
        val outputPath = (args.get("outputPath") as? String)?.takeIf { it.isNotEmpty() }
        if (outputPath == null) {
            reply.error("INVALID_ARG", "compressImage: outputPath is required and must be non-empty")
            return
        }
        val maxWidthNumber = args.get("maxWidthPx") as? Number
        if (maxWidthNumber == null) {
            reply.error("INVALID_ARG", "compressImage: maxWidthPx is required and must be a number")
            return
        }
        val maxWidthPx = maxWidthNumber.toInt()
        if (maxWidthPx <= 0) {
            reply.error("INVALID_ARG", "compressImage: maxWidthPx must be > 0")
            return
        }
        val qualityNumber = args.get("jpegQuality") as? Number
        if (qualityNumber == null) {
            reply.error("INVALID_ARG", "compressImage: jpegQuality is required and must be a number")
            return
        }
        val qualityRaw = qualityNumber.toDouble()
        if (!qualityRaw.isFinite()) {
            reply.error("INVALID_ARG", "compressImage: jpegQuality must be finite")
            return
        }
        val qualityPercent = (qualityRaw.coerceIn(0.0, 1.0) * 100).roundToInt().coerceIn(1, 100)

        val inputFile = File(inputPath)
        if (!inputFile.exists() || !inputFile.isFile || !inputFile.canRead()) {
            reply.error(
                "INVALID_ARG",
                "compressImage: input file does not exist or is not readable: $inputPath",
            )
            return
        }

        val outputFile = File(outputPath)
        val parentDir = outputFile.absoluteFile.parentFile
        if (parentDir == null || !parentDir.exists() || !parentDir.isDirectory) {
            reply.error(
                "INVALID_ARG",
                "compressImage: output parent directory does not exist: ${parentDir?.path ?: outputPath}",
            )
            return
        }

        if (detached) return

        try {
            executor.execute {
                val session = AndroidImageCompressionSession(
                    inputPath = inputPath,
                    outputPath = outputPath,
                    maxWidthPx = maxWidthPx,
                    qualityPercent = qualityPercent,
                )
                when (val sessionResult = session.run()) {
                    is AndroidImageCompressionResult.Success -> reply.success(
                        mapOf("outputPath" to sessionResult.outputPath),
                    )
                    is AndroidImageCompressionResult.Failure -> reply.error(
                        sessionResult.code,
                        sessionResult.message,
                    )
                }
            }
        } catch (t: Throwable) {
            reply.error("WRITE_FAILED", t.message ?: t.javaClass.simpleName)
        }
    }

    // ── Disposal ─────────────────────────────────────────────────────────────

    /** Idempotent: blocks any further replies and shuts down the executor. */
    fun disposeAll() {
        detached = true
        executor.shutdown()
    }
}
