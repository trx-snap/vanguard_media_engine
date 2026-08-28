package com.connects.vanguard_media_engine.export

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.util.Log
import java.io.File

// -- AndroidStillImageDecoder (Export Unit R) --------------------------------
//
// Local-file still-image decode helpers for the exportTimeline still-image
// clip path. Uses BitmapFactory (not ImageDecoder) for bounds probing, EXIF
// orientation reading, sample-size calculation, and bitmap decode. Holds no
// EGL/MediaCodec lifecycle state, so it can be called safely from both
// AndroidTimelineExportSession (probe) and AndroidTimelineVideoEncoder
// (render) without crossing ownership boundaries.
//
// Scope (Unit R): local absolute file paths only. This object performs no
// EXIF auto-rotation -- callers must reject any orientation other than
// ORIENTATION_NORMAL before treating a decoded bitmap as usable.
object AndroidStillImageDecoder {

    data class ImageBounds(val width: Int, val height: Int)

    /**
     * Decodes only the bounds (width/height) of the image at [path] without
     * allocating pixel memory. Returns null if the file cannot be read or
     * BitmapFactory cannot determine bounds.
     */
    fun probeBounds(path: String): ImageBounds? {
        val file = File(path)
        if (!file.exists() || !file.canRead()) return null
        return try {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, options)
            val width = options.outWidth
            val height = options.outHeight
            if (width <= 0 || height <= 0) null else ImageBounds(width, height)
        } catch (t: Throwable) {
            Log.e(TAG, "probeBounds failed for $path: $t")
            null
        }
    }

    /**
     * Reads the EXIF orientation tag for the image at [path]. Defaults to
     * ExifInterface.ORIENTATION_NORMAL when the tag is missing or the file
     * cannot be parsed as EXIF (e.g. PNG). Callers must reject any value
     * other than ORIENTATION_NORMAL -- this object performs no auto-rotation.
     */
    fun readExifOrientation(path: String): Int {
        return try {
            val exif = ExifInterface(path)
            val orientation = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
            if (orientation == ExifInterface.ORIENTATION_UNDEFINED) {
                ExifInterface.ORIENTATION_NORMAL
            } else {
                orientation
            }
        } catch (t: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
    }

    /**
     * Computes a power-of-two BitmapFactory.Options.inSampleSize so the
     * decoded bitmap fits within [maxTextureSize] (the GL_MAX_TEXTURE_SIZE of
     * the current EGL context) and is reasonably close to the requested
     * [targetWidth]x[targetHeight] output canvas. This bounds decode memory
     * and prevents a GL texture upload from silently failing (which would
     * otherwise surface as a false-success black frame) on devices with a
     * small max texture size.
     *
     * Both sampled axes are independently bounded (not "both exceed"): a
     * panorama or tall image that is oversized on only one axis must still
     * be downsampled on that axis rather than decoded at full size.
     */
    fun computeInSampleSize(
        rawWidth: Int,
        rawHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        maxTextureSize: Int,
    ): Int {
        if (rawWidth <= 0 || rawHeight <= 0 || targetWidth <= 0 || targetHeight <= 0) return 1
        var inSampleSize = 1
        val boundedWidth = if (maxTextureSize > 0) minOf(targetWidth, maxTextureSize) else targetWidth
        val boundedHeight = if (maxTextureSize > 0) minOf(targetHeight, maxTextureSize) else targetHeight
        if (boundedWidth <= 0 || boundedHeight <= 0) return inSampleSize
        var sampledWidth = rawWidth
        var sampledHeight = rawHeight
        while (sampledWidth > boundedWidth || sampledHeight > boundedHeight) {
            inSampleSize *= 2
            sampledWidth = rawWidth / inSampleSize
            sampledHeight = rawHeight / inSampleSize
        }
        return inSampleSize
    }

    /**
     * Decodes the image at [path] into an ARGB_8888 bitmap using
     * [inSampleSize] to reduce memory footprint. Returns null on decode
     * failure.
     */
    fun decodeBitmap(path: String, inSampleSize: Int): Bitmap? {
        return try {
            val options = BitmapFactory.Options().apply {
                this.inSampleSize = inSampleSize.coerceAtLeast(1)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            BitmapFactory.decodeFile(path, options)
        } catch (t: Throwable) {
            Log.e(TAG, "decodeBitmap failed for $path: $t")
            null
        }
    }

    /**
     * Returns [bitmap] unchanged if it already fits within [maxTextureSize]
     * on both axes. Otherwise uniformly scales it down to fit and recycles
     * the original bitmap, returning the scaled replacement. This is a final
     * safety clamp for devices where [computeInSampleSize]'s power-of-two
     * step still leaves the decoded bitmap over the GL texture size limit.
     */
    fun clampToMaxTextureSize(bitmap: Bitmap, maxTextureSize: Int): Bitmap {
        if (maxTextureSize <= 0) return bitmap
        if (bitmap.width <= maxTextureSize && bitmap.height <= maxTextureSize) return bitmap
        val scale = minOf(
            maxTextureSize.toFloat() / bitmap.width.toFloat(),
            maxTextureSize.toFloat() / bitmap.height.toFloat(),
        )
        val newWidth = (bitmap.width * scale).toInt().coerceAtLeast(1)
        val newHeight = (bitmap.height * scale).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(bitmap, newWidth, newHeight, true)
        if (scaled !== bitmap) bitmap.recycle()
        return scaled
    }

    private const val TAG = "VGStillImageDecoder"
}
