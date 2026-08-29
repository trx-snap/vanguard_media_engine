package com.connects.vanguard_media_engine.photo_library

import android.Manifest
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.provider.MediaStore
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

// ── AndroidPhotoLibrarySaveCoordinator (Phase 5-Unit Z / UMF V2 Slice 2A) ─────
//
// Android parity for VGPhotoLibrarySaveHandler.swift (iOS). Owns the
// `saveVideoToPhotoLibrary` MethodChannel route: cheap arg validation runs
// synchronously; all file copy and MediaStore/fallback I/O runs on a single
// daemon background executor. Every reply is routed through [GuardedReply]
// so at most one result is ever delivered and never after detach.
//
// Stable error codes (mirrors iOS):
//   invalid_args, file_not_found, invalid_format, permission_denied, save_failed
class AndroidPhotoLibrarySaveCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) {
    companion object {
        private val OWNED_METHODS = setOf("saveVideoToPhotoLibrary")
        private val ALLOWED_EXTENSIONS = setOf("mp4", "mov", "m4v")

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "VGPhotoLibrarySave").apply { isDaemon = true }
    }

    @Volatile private var detached = false

    /** AtomicBoolean-guarded, detach-aware [MethodChannel.Result] wrapper. */
    private inner class GuardedReply(private val result: MethodChannel.Result) {
        private val fired = AtomicBoolean(false)

        fun success(value: Any?) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.success(value)
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
            "saveVideoToPhotoLibrary" -> handleSaveVideo(args, result)
        }
    }

    // ── saveVideoToPhotoLibrary ─────────────────────────────────────────────

    private fun handleSaveVideo(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val filePath = (args?.get("filePath") as? String)?.trim()
        if (filePath.isNullOrEmpty()) {
            reply.error("invalid_args", "filePath is required and must not be empty.")
            return
        }

        val sourceFile = File(filePath)
        val ext = sourceFile.name.substringAfterLast('.', "").lowercase()
        if (ext !in ALLOWED_EXTENSIONS) {
            reply.error(
                "invalid_format",
                "Only mp4, mov, and m4v video files are supported. Received: .$ext")
            return
        }

        if (!sourceFile.exists() || !sourceFile.isFile || !sourceFile.canRead() ||
            sourceFile.length() <= 0L) {
            reply.error("file_not_found", "Video file not found at path: $filePath")
            return
        }

        if (detached) return

        try {
            executor.execute { performSave(sourceFile, ext, reply) }
        } catch (t: Throwable) {
            reply.error("save_failed", t.message ?: t.javaClass.simpleName)
        }
    }

    private fun performSave(sourceFile: File, ext: String, reply: GuardedReply) {
        if (detached) return
        val mimeType = when (ext) {
            "mov" -> "video/quicktime"
            else -> "video/mp4" // mp4, m4v
        }
        val displayName = sanitizedDisplayName(sourceFile.name, ext)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveViaMediaStore(sourceFile, mimeType, displayName, reply)
            } else {
                saveViaLegacyFallback(sourceFile, displayName, reply)
            }
        } catch (e: SecurityException) {
            reply.error("permission_denied", e.message ?: "Permission denied while saving video.")
        } catch (t: Throwable) {
            reply.error("save_failed", t.message ?: t.javaClass.simpleName)
        }
    }

    // ── API 29+: MediaStore ──────────────────────────────────────────────────

    private fun saveViaMediaStore(
        sourceFile: File,
        mimeType: String,
        displayName: String,
        reply: GuardedReply,
    ) {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Video.Media.MIME_TYPE, mimeType)
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/ConnectsApp")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }

        var uri: Uri? = null
        try {
            uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            val pendingUri = uri
            if (pendingUri == null) {
                reply.error("save_failed", "MediaStore insert returned null Uri.")
                return
            }

            val outputStream = resolver.openOutputStream(pendingUri, "w")
            if (outputStream == null) {
                safeDelete(resolver, pendingUri)
                reply.error("save_failed", "Unable to open output stream for MediaStore Uri.")
                return
            }

            outputStream.use { out ->
                FileInputStream(sourceFile).use { input -> copyStream(input, out) }
            }

            val publishValues = ContentValues().apply {
                put(MediaStore.Video.Media.IS_PENDING, 0)
            }
            val updated = resolver.update(pendingUri, publishValues, null, null)
            if (updated <= 0) {
                safeDelete(resolver, pendingUri)
                reply.error(
                    "save_failed", "Failed to publish MediaStore asset (IS_PENDING update failed).")
                return
            }

            reply.success(true)
        } catch (e: SecurityException) {
            uri?.let { safeDelete(resolver, it) }
            throw e
        } catch (t: Throwable) {
            uri?.let { safeDelete(resolver, it) }
            reply.error("save_failed", t.message ?: t.javaClass.simpleName)
        }
    }

    private fun safeDelete(resolver: ContentResolver, uri: Uri) {
        try {
            resolver.delete(uri, null, null)
        } catch (_: Throwable) {}
    }

    // ── API 24-28: legacy fallback ──────────────────────────────────────────

    private fun saveViaLegacyFallback(sourceFile: File, displayName: String, reply: GuardedReply) {
        if (context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED) {
            reply.error("permission_denied", "WRITE_EXTERNAL_STORAGE permission not granted.")
            return
        }

        val moviesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
        val destDir = File(moviesDir, "ConnectsApp")
        if (!destDir.exists() && !destDir.mkdirs()) {
            reply.error("save_failed", "Unable to create destination directory: ${destDir.path}")
            return
        }

        val destFile = File(destDir, displayName)
        try {
            FileInputStream(sourceFile).use { input ->
                FileOutputStream(destFile).use { out -> copyStream(input, out) }
            }
        } catch (e: SecurityException) {
            destFile.delete()
            throw e
        } catch (t: Throwable) {
            destFile.delete()
            reply.error("save_failed", t.message ?: t.javaClass.simpleName)
            return
        }

        try {
            MediaScannerConnection.scanFile(context, arrayOf(destFile.absolutePath), null, null)
        } catch (t: Throwable) {
            reply.error("save_failed", t.message ?: t.javaClass.simpleName)
            return
        }

        reply.success(true)
    }

    // ── Shared helpers ───────────────────────────────────────────────────────

    private fun copyStream(input: InputStream, output: OutputStream) {
        val buffer = ByteArray(64 * 1024)
        while (true) {
            if (detached) throw IOException("saveVideoToPhotoLibrary aborted: plugin detached.")
            val read = input.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
        }
    }

    private fun sanitizedDisplayName(originalName: String, ext: String): String {
        val base = originalName.substringBeforeLast('.', originalName)
        val sanitizedBase = base.replace(Regex("[^A-Za-z0-9._-]"), "_").trim('.', '_', ' ')
        val safeBase = if (sanitizedBase.isBlank()) "vanguard_video" else sanitizedBase
        return "${safeBase}_${System.currentTimeMillis()}.$ext"
    }

    // ── Disposal ─────────────────────────────────────────────────────────────

    /** Idempotent: blocks any further replies and shuts down the executor. */
    fun disposeAll() {
        detached = true
        executor.shutdown()
    }
}
