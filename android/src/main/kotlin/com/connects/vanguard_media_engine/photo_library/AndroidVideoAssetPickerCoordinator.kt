package com.connects.vanguard_media_engine.photo_library

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

// ── AndroidVideoAssetPickerCoordinator (Phase 5-Unit AB / Phase 10F-Slice 2B /
// UMF V2 Slice 2B) ─────────────────────────────────────────────────────────
//
// Android parity for VGVideoAssetPickerHandler.swift (iOS). Owns the custom
// video-only gallery picker bridge: permission check/request, paged
// MediaStore video listing, thumbnail bytes, cache-dir export/cancel, app
// settings deep link, and the API 34+ limited-library re-picker.
//
// Asset ids are opaque full content:// URIs (never raw numeric MediaStore
// row ids) so Dart never observes a platform-specific identifier shape.
//
// Every reply is routed through [GuardedReply] so at most one result is
// ever delivered and never after the plugin has detached.
class AndroidVideoAssetPickerCoordinator(
    private val context: Context,
    private val mainHandler: Handler,
) : PluginRegistry.RequestPermissionsResultListener {

    private enum class PendingKind { STATUS, LIMITED_PICKER }

    companion object {
        private const val PREFS_NAME = "vanguard_video_asset_picker"
        private const val KEY_HAS_REQUESTED = "has_requested_photo_permission"
        private const val PERMISSION_REQUEST_CODE = 84_216

        private val OWNED_METHODS = setOf(
            "checkPhotoLibraryPermission",
            "requestPhotoLibraryPermission",
            "fetchPhotoVideos",
            "fetchPhotoVideoThumbnail",
            "exportPhotoVideo",
            "cancelExportPhotoVideo",
            "openAppSettings",
            "presentLimitedLibraryPicker",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    @Volatile private var activity: Activity? = null
    @Volatile private var detached = false

    // Single in-flight permission request shared by requestPhotoLibraryPermission
    // and presentLimitedLibraryPicker -- there is never more than one at a time.
    // Guarded by [pendingLock] so MethodChannel calls and permission-result
    // callbacks (which can arrive on different threads) never race.
    private val pendingLock = Any()
    private var pendingReply: GuardedReply? = null
    private var pendingKind: PendingKind? = null

    // Cancellation state keyed by opaque asset id string.
    private val exportCancelFlags = ConcurrentHashMap<String, AtomicBoolean>()
    private val thumbnailCancelFlags = ConcurrentHashMap<String, AtomicBoolean>()
    private val thumbnailSignals = ConcurrentHashMap<String, CancellationSignal>()

    // Bounded, owned daemon executors -- replaces raw unbounded Thread(...) starts.
    private val queryExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "VGVideoAssetPickerFetch").apply { isDaemon = true }
    }
    private val exportExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "VGVideoAssetPickerExport").apply { isDaemon = true }
    }
    private val thumbnailExecutor: ExecutorService = Executors.newFixedThreadPool(4) { r ->
        Thread(r, "VGVideoAssetPickerThumb").apply { isDaemon = true }
    }

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
            "checkPhotoLibraryPermission" -> handleCheckPermission(result)
            "requestPhotoLibraryPermission" -> handleRequestPermission(result)
            "fetchPhotoVideos" -> handleFetchVideos(args, result)
            "fetchPhotoVideoThumbnail" -> handleFetchThumbnail(args, result)
            "exportPhotoVideo" -> handleExportVideo(args, result)
            "cancelExportPhotoVideo" -> handleCancelExport(args, result)
            "openAppSettings" -> handleOpenSettings(result)
            "presentLimitedLibraryPicker" -> handlePresentLimitedLibraryPicker(result)
        }
    }

    // ── Activity lifecycle (driven by the plugin's ActivityAware callbacks) ──

    fun onActivityAttached(activity: Activity) {
        this.activity = activity
    }

    /** Config-change detach: activity reference drops, pending request survives. */
    fun onActivityDetachedForConfigChanges() {
        activity = null
    }

    fun onActivityReattached(activity: Activity) {
        this.activity = activity
    }

    /** Final detach: activity reference drops and any pending request is settled. */
    fun onActivityDetachedFinal() {
        activity = null
        settlePending()
    }

    private fun settlePending() {
        val reply: GuardedReply?
        val kind: PendingKind?
        synchronized(pendingLock) {
            reply = pendingReply
            kind = pendingKind
            pendingReply = null
            pendingKind = null
        }
        if (reply == null) return
        when (kind) {
            PendingKind.STATUS -> reply.success(computeStatus(null))
            PendingKind.LIMITED_PICKER -> reply.success(false)
            null -> {}
        }
    }

    // ── Authorization ────────────────────────────────────────────────────────

    private fun handleCheckPermission(result: MethodChannel.Result) {
        GuardedReply(result).success(computeStatus(activity))
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val act = activity
        synchronized(pendingLock) {
            if (pendingReply != null) {
                reply.success(computeStatus(activity))
                return
            }
            if (act == null) {
                reply.success(computeStatus(null))
                return
            }
            pendingKind = PendingKind.STATUS
            pendingReply = reply
        }
        prefs().edit().putBoolean(KEY_HAS_REQUESTED, true).apply()
        act!!.requestPermissions(permissionsToRequest(), PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val reply: GuardedReply?
        val kind: PendingKind?
        synchronized(pendingLock) {
            reply = pendingReply
            kind = pendingKind
            pendingReply = null
            pendingKind = null
        }
        if (reply != null) {
            when (kind) {
                PendingKind.STATUS -> reply.success(computeStatus(activity))
                PendingKind.LIMITED_PICKER -> reply.success(true)
                null -> {}
            }
        }
        return true
    }

    private fun prefs() = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun permissionsToRequest(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 ->
            arrayOf(Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        Build.VERSION.SDK_INT == 33 -> arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    private fun computeStatus(activity: Activity?): String = when {
        Build.VERSION.SDK_INT >= 34 -> computeStatusApi34Plus(activity)
        Build.VERSION.SDK_INT == 33 -> computeStatusApi33(activity)
        else -> computeStatusLegacy(activity)
    }

    private fun computeStatusApi34Plus(activity: Activity?): String {
        if (isGranted(Manifest.permission.READ_MEDIA_VIDEO)) return "authorized"
        if (isGranted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)) return "limited"
        return deniedOrNotDetermined(activity, Manifest.permission.READ_MEDIA_VIDEO)
    }

    private fun computeStatusApi33(activity: Activity?): String {
        if (isGranted(Manifest.permission.READ_MEDIA_VIDEO)) return "authorized"
        return deniedOrNotDetermined(activity, Manifest.permission.READ_MEDIA_VIDEO)
    }

    private fun computeStatusLegacy(activity: Activity?): String {
        if (isPermissionDeclared(Manifest.permission.READ_EXTERNAL_STORAGE) &&
            isGranted(Manifest.permission.READ_EXTERNAL_STORAGE)
        ) {
            return "authorized"
        }
        return deniedOrNotDetermined(activity, Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    private fun isGranted(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun isPermissionDeclared(permission: String): Boolean = try {
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        info.requestedPermissions?.contains(permission) == true
    } catch (e: Exception) {
        false
    }

    /** No attached Activity: cannot determine rationale, so an ungranted permission is "denied". */
    private fun deniedOrNotDetermined(activity: Activity?, permission: String): String {
        if (activity == null) return "denied"
        if (!prefs().getBoolean(KEY_HAS_REQUESTED, false)) return "notDetermined"
        return if (activity.shouldShowRequestPermissionRationale(permission)) "notDetermined" else "denied"
    }

    // ── Query Videos ─────────────────────────────────────────────────────────

    private fun handleFetchVideos(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val status = computeStatus(activity)
        if (status != "authorized" && status != "limited") {
            reply.success(emptyList<Map<String, Any?>>())
            return
        }
        val limit = (args?.get("limit") as? Number)?.toInt()
        val offset = (args?.get("offset") as? Number)?.toInt() ?: 0
        try {
            queryExecutor.execute {
                reply.success(queryVideos(limit, offset))
            }
        } catch (e: Exception) {
            reply.success(emptyList<Map<String, Any?>>())
        }
    }

    private fun queryVideos(limit: Int?, offset: Int): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.DATE_ADDED,
            MediaStore.Video.Media.DATE_TAKEN,
            MediaStore.Video.Media.MIME_TYPE,
            MediaStore.Video.Media.DISPLAY_NAME,
        )
        val sortOrder = "${MediaStore.Video.Media.DATE_ADDED} DESC"
        val results = mutableListOf<Map<String, Any?>>()
        try {
            context.contentResolver.query(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                projection,
                null,
                null,
                sortOrder,
            )?.use { cursor ->
                val total = cursor.count
                val start = offset.coerceIn(0, total)
                val effectiveLimit = limit ?: (total - start)
                val end = (start + effectiveLimit.coerceAtLeast(0)).coerceIn(start, total)
                if (start >= end || !cursor.moveToPosition(start)) return results

                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
                val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
                val widthCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.WIDTH)
                val heightCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.HEIGHT)
                val dateAddedCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_ADDED)
                val dateTakenCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_TAKEN)

                var position = start
                while (position < end) {
                    val id = cursor.getLong(idCol)
                    val durationMs = cursor.getLong(durationCol)
                    val width = cursor.getInt(widthCol)
                    val height = cursor.getInt(heightCol)
                    val dateAddedSec = cursor.getLong(dateAddedCol)
                    val dateTakenMs = cursor.getLong(dateTakenCol)

                    val uri = ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
                    val creationTimestampMs = if (dateTakenMs > 0L) dateTakenMs else dateAddedSec * 1000L

                    results.add(
                        mapOf(
                            "id" to uri.toString(),
                            "durationSeconds" to durationMs / 1000.0,
                            "pixelWidth" to width,
                            "pixelHeight" to height,
                            "creationTimestampMs" to creationTimestampMs,
                        )
                    )
                    position++
                    if (position < end && !cursor.moveToNext()) break
                }
            }
        } catch (e: Throwable) {
            return emptyList()
        }
        return results
    }

    // ── Thumbnails ───────────────────────────────────────────────────────────

    private fun handleFetchThumbnail(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val idStr = (args?.get("id") as? String)?.trim()
        val uri = idStr?.let { parseAssetUri(it) }
        if (idStr.isNullOrEmpty() || uri == null) {
            reply.error("INVALID_ARGUMENT", "Asset ID is required")
            return
        }

        val width = ((args?.get("width") as? Number)?.toInt() ?: 240).coerceIn(1, 1024)
        val height = ((args?.get("height") as? Number)?.toInt() ?: 240).coerceIn(1, 1024)
        val cancelFlag = AtomicBoolean(false)
        if (thumbnailCancelFlags.putIfAbsent(idStr, cancelFlag) != null) {
            // A thumbnail request for this asset is already active -- do not
            // overwrite its cancel flag/signal; resolve this duplicate now.
            reply.success(null)
            return
        }
        val signal = CancellationSignal()
        thumbnailSignals[idStr] = signal

        thumbnailExecutor.execute {
            val bitmap = loadThumbnailBitmap(uri, width, height, signal)
            thumbnailCancelFlags.remove(idStr, cancelFlag)
            thumbnailSignals.remove(idStr, signal)
            if (bitmap == null || cancelFlag.get()) {
                bitmap?.recycle()
                reply.success(null)
                return@execute
            }
            val bytes = bitmapToJpeg(bitmap)
            bitmap.recycle()
            reply.success(bytes)
        }
    }

    private fun loadThumbnailBitmap(uri: Uri, width: Int, height: Int, signal: CancellationSignal): Bitmap? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            context.contentResolver.loadThumbnail(uri, Size(width, height), signal)
        } else {
            @Suppress("DEPRECATION")
            MediaStore.Video.Thumbnails.getThumbnail(
                context.contentResolver,
                ContentUris.parseId(uri),
                MediaStore.Video.Thumbnails.MINI_KIND,
                null,
            )
        }
    } catch (e: Exception) {
        null
    }

    private fun bitmapToJpeg(bitmap: Bitmap): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 75, stream)
        return stream.toByteArray()
    }

    // ── Export Video ─────────────────────────────────────────────────────────

    private fun handleExportVideo(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val idStr = (args?.get("id") as? String)?.trim()
        val uri = idStr?.let { parseAssetUri(it) }
        if (idStr.isNullOrEmpty() || uri == null) {
            reply.error("INVALID_ARGUMENT", "Asset ID is required")
            return
        }

        val cancelFlag = AtomicBoolean(false)
        val existing = exportCancelFlags.putIfAbsent(idStr, cancelFlag)
        if (existing != null) {
            reply.error("EXPORT_IN_PROGRESS", "Export already in progress for asset $idStr")
            return
        }

        exportExecutor.execute {
            performExport(idStr, uri, cancelFlag, reply)
        }
    }

    private fun performExport(idStr: String, uri: Uri, cancelFlag: AtomicBoolean, reply: GuardedReply) {
        val row = queryRowByUri(uri)
        if (row == null) {
            exportCancelFlags.remove(idStr, cancelFlag)
            reply.error("ASSET_NOT_FOUND", "Asset with ID $idStr not found")
            return
        }

        val ext = deriveExtension(row.mimeType, row.displayName)
        val exportId = UUID.randomUUID().toString()
        val tempFile = File(context.cacheDir, "ue_video_$exportId.$ext.tmp")
        val finalFile = File(context.cacheDir, "ue_video_$exportId.$ext")

        val input: InputStream
        try {
            input = context.contentResolver.openInputStream(uri)
                ?: throw java.io.IOException("openInputStream returned null")
        } catch (e: SecurityException) {
            exportCancelFlags.remove(idStr, cancelFlag)
            reply.error("ASSET_NOT_FOUND", e.message)
            return
        } catch (e: Exception) {
            exportCancelFlags.remove(idStr, cancelFlag)
            reply.error("EXPORT_FAILED", e.message ?: e.javaClass.simpleName)
            return
        }

        try {
            val completed = input.use { ins ->
                FileOutputStream(tempFile).use { out -> copyWithCancellation(ins, out, cancelFlag) }
            }
            exportCancelFlags.remove(idStr, cancelFlag)

            if (!completed) {
                tempFile.delete()
                finalFile.delete()
                reply.error("EXPORT_CANCELLED", "Export cancelled")
                return
            }

            if (!tempFile.renameTo(finalFile)) {
                tempFile.delete()
                reply.error("EXPORT_FAILED", "Failed to finalize export file")
                return
            }

            reply.success(finalFile.absolutePath)
        } catch (e: Exception) {
            exportCancelFlags.remove(idStr, cancelFlag)
            tempFile.delete()
            finalFile.delete()
            reply.error("EXPORT_FAILED", e.message ?: e.javaClass.simpleName)
        }
    }

    private fun copyWithCancellation(
        input: InputStream,
        output: FileOutputStream,
        cancelFlag: AtomicBoolean,
    ): Boolean {
        val buffer = ByteArray(64 * 1024)
        while (true) {
            if (cancelFlag.get()) return false
            val read = input.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
        }
        return !cancelFlag.get()
    }

    private data class VideoRow(val mimeType: String?, val displayName: String?)

    private fun queryRowByUri(uri: Uri): VideoRow? = try {
        context.contentResolver.query(
            uri,
            arrayOf(MediaStore.Video.Media.MIME_TYPE, MediaStore.Video.Media.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { c ->
            if (c.moveToFirst()) {
                VideoRow(
                    c.getString(c.getColumnIndexOrThrow(MediaStore.Video.Media.MIME_TYPE)),
                    c.getString(c.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)),
                )
            } else {
                null
            }
        }
    } catch (e: Exception) {
        null
    }

    private fun deriveExtension(mimeType: String?, displayName: String?): String {
        when (mimeType) {
            "video/mp4" -> return "mp4"
            "video/quicktime" -> return "mov"
        }
        val nameExt = displayName?.substringAfterLast('.', "")?.lowercase()
        if (nameExt == "mp4" || nameExt == "mov" || nameExt == "m4v") return nameExt
        return "mp4"
    }

    /** Only non-empty content:// asset URIs are accepted -- file/http/blank/malformed are rejected. */
    private fun parseAssetUri(idStr: String): Uri? {
        if (idStr.isBlank()) return null
        return try {
            val uri = Uri.parse(idStr)
            if (uri.scheme != "content") return null
            if (uri.schemeSpecificPart.isNullOrEmpty()) return null
            uri
        } catch (e: Exception) {
            null
        }
    }

    private fun handleCancelExport(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val idStr = args?.get("id") as? String
        if (!idStr.isNullOrEmpty()) {
            exportCancelFlags[idStr]?.set(true)
            thumbnailCancelFlags[idStr]?.set(true)
            thumbnailSignals.remove(idStr)?.let { signal ->
                try {
                    signal.cancel()
                } catch (e: Exception) {
                    // best-effort cancellation
                }
            }
        }
        reply.success(true)
    }

    // ── Open App Settings ───────────────────────────────────────────────────

    private fun handleOpenSettings(result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val act = activity
        if (act == null) {
            reply.success(false)
            return
        }
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${context.packageName}"),
            )
            act.startActivity(intent)
            reply.success(true)
        } catch (e: Exception) {
            reply.success(false)
        }
    }

    // ── Limited Library Picker ───────────────────────────────────────────────

    private fun handlePresentLimitedLibraryPicker(result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        if (Build.VERSION.SDK_INT < 34) {
            reply.success(false)
            return
        }
        val act = activity
        synchronized(pendingLock) {
            if (pendingReply != null) {
                reply.success(false)
                return
            }
            if (act == null) {
                reply.success(false)
                return
            }
            pendingKind = PendingKind.LIMITED_PICKER
            pendingReply = reply
        }
        // Still an OS media permission request -- the has-requested flag must be set
        // before requestPermissions is invoked, matching handleRequestPermission.
        prefs().edit().putBoolean(KEY_HAS_REQUESTED, true).apply()
        act!!.requestPermissions(permissionsToRequest(), PERMISSION_REQUEST_CODE)
    }

    // ── Disposal ─────────────────────────────────────────────────────────────

    /** Idempotent: blocks any further replies and settles/cancels outstanding work. */
    fun disposeAll() {
        detached = true
        activity = null
        settlePending()
        exportCancelFlags.values.forEach { it.set(true) }
        thumbnailCancelFlags.values.forEach { it.set(true) }
        thumbnailSignals.values.forEach { signal ->
            try {
                signal.cancel()
            } catch (e: Exception) {
                // best-effort cancellation
            }
        }
        exportCancelFlags.clear()
        thumbnailCancelFlags.clear()
        thumbnailSignals.clear()
        queryExecutor.shutdownNow()
        exportExecutor.shutdownNow()
        thumbnailExecutor.shutdownNow()
    }
}
