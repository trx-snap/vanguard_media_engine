package com.connects.vanguard_media_engine.util

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File

/**
 * Vanguard Android reference-import Slice 2: centralized URI data-source helper.
 *
 * Every Android inspect/probe path historically treated its `path` argument as a
 * POSIX filesystem path: `java.io.File(path)` for existence/size and
 * `setDataSource(path)` on MediaExtractor / MediaMetadataRetriever. A SAF or
 * MediaStore `content://` value cannot be opened that way — it needs a
 * [Context]-backed ContentResolver and the `(Context, Uri)` setDataSource overloads.
 *
 * This object is the single place that knows how to tell the two apart and how
 * to open each one. Rules:
 *
 *   - `content://` values are never treated as filesystem paths.
 *   - Any `content://` operation requires a non-null [Context]; a null context
 *     fails fast with [IllegalArgumentException] rather than hanging or silently
 *     returning a bogus File-based answer.
 *   - Every Cursor / ParcelFileDescriptor the helper opens is closed before the
 *     call returns. The helper caches nothing, so a retry always opens a fresh
 *     resolver/data source and there is no detach/shutdown state to release.
 *   - Plain POSIX paths keep their pre-existing File and `setDataSource(String)`
 *     behaviour byte-for-byte.
 *
 * Playback/export encoder call sites are intentionally NOT wired in this slice;
 * [setMediaPlayerDataSource] exists only so later slices have one shared entry.
 */
object AndroidUriDataSourceHelper {

    private const val CONTENT_SCHEME_PREFIX = "content://"

    /** True when [path] is a `content://` URI that must go through a ContentResolver. */
    fun isContentUri(path: String): Boolean =
        path.startsWith(CONTENT_SCHEME_PREFIX, ignoreCase = true)

    /**
     * Sets [extractor]'s data source from either a POSIX/file path or a
     * `content://` URI. Throws [IllegalArgumentException] for `content://`
     * without a [context]; propagates whatever [MediaExtractor.setDataSource]
     * throws otherwise (the caller already owns extractor release).
     */
    @Throws(java.io.IOException::class)
    fun setExtractorDataSource(extractor: MediaExtractor, path: String, context: Context?) {
        if (isContentUri(path)) {
            val ctx = requireContextForContentUri(path, context)
            extractor.setDataSource(ctx, Uri.parse(path), null)
        } else {
            extractor.setDataSource(path)
        }
    }

    /**
     * Sets [retriever]'s data source from either a POSIX/file path or a
     * `content://` URI. Same contract as [setExtractorDataSource].
     */
    fun setRetrieverDataSource(retriever: MediaMetadataRetriever, path: String, context: Context?) {
        if (isContentUri(path)) {
            val ctx = requireContextForContentUri(path, context)
            retriever.setDataSource(ctx, Uri.parse(path))
        } else {
            retriever.setDataSource(path)
        }
    }

    /**
     * Sets [player]'s data source from either a POSIX/file path or a `content://`
     * URI. Provided for later playback slices; NOT wired to any call site in
     * Slice 2.
     */
    @Throws(java.io.IOException::class)
    fun setMediaPlayerDataSource(player: MediaPlayer, path: String, context: Context?) {
        if (isContentUri(path)) {
            val ctx = requireContextForContentUri(path, context)
            player.setDataSource(ctx, Uri.parse(path))
        } else {
            player.setDataSource(path)
        }
    }

    /**
     * Byte length of the source.
     *
     * POSIX/file: `java.io.File(path).length()` (0 for missing files — unchanged
     * from the pre-slice behaviour).
     *
     * `content://`: `ContentResolver.query(OpenableColumns.SIZE)` first; if the
     * provider omits the column or returns null/negative, falls back to
     * `openFileDescriptor(uri, "r").statSize`. Returns 0 when neither yields a
     * usable value. Cursor and PFD are always closed. Throws
     * [IllegalArgumentException] for `content://` without a [context].
     */
    fun fileSizeBytes(path: String, context: Context?): Long {
        if (!isContentUri(path)) {
            return File(path).length()
        }
        val ctx = requireContextForContentUri(path, context)
        val uri = Uri.parse(path)
        val resolver = ctx.contentResolver

        // 1. OpenableColumns.SIZE via query.
        try {
            val cursor = resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
            if (cursor != null) {
                try {
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (idx >= 0 && !cursor.isNull(idx)) {
                            val size = cursor.getLong(idx)
                            if (size >= 0L) return size
                        }
                    }
                } finally {
                    try { cursor.close() } catch (_: Throwable) {}
                }
            }
        } catch (_: Throwable) {
            // Provider may not support query(); fall through to PFD statSize.
        }

        // 2. ParcelFileDescriptor.statSize fallback.
        try {
            val pfd = resolver.openFileDescriptor(uri, "r") ?: return 0L
            try {
                val size = pfd.statSize
                return if (size >= 0L) size else 0L
            } finally {
                try { pfd.close() } catch (_: Throwable) {}
            }
        } catch (_: Throwable) {
            return 0L
        }
    }

    /**
     * Readability preflight. Must be cheap and must not hang.
     *
     * POSIX/file: `File.exists() && File.canRead()` (unchanged pre-slice check).
     *
     * `content://`: requires a non-null [context] and a successful
     * `openFileDescriptor(uri, "r")`; the descriptor is closed immediately.
     * Returns false (does not throw) when the context is null or the provider
     * refuses/throws, so inspect paths can map it to a clean failure reason.
     */
    fun isReadable(path: String, context: Context?): Boolean {
        if (!isContentUri(path)) {
            val file = File(path)
            return file.exists() && file.canRead()
        }
        if (context == null) return false
        return try {
            val pfd = context.contentResolver.openFileDescriptor(Uri.parse(path), "r")
                ?: return false
            try { pfd.close() } catch (_: Throwable) {}
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun requireContextForContentUri(path: String, context: Context?): Context =
        context ?: throw IllegalArgumentException(
            "AndroidUriDataSourceHelper: content:// data source requires a non-null Context " +
                "(path=$path)"
        )
}
