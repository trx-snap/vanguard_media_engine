package com.connects.vanguard_media_engine.export

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.util.Log
import java.io.File

// -- AndroidStillImageDecoder (Export Unit R/S) ------------------------------
//
// Local-file still-image decode helpers for the exportTimeline still-image
// clip path. Uses BitmapFactory (not ImageDecoder) for bounds probing, EXIF
// orientation reading, sample-size calculation, and bitmap decode. Holds no
// EGL/MediaCodec lifecycle state, so it can be called safely from both
// AndroidTimelineExportSession (probe) and AndroidTimelineVideoEncoder
// (render) without crossing ownership boundaries.
//
// Scope (Unit R): local absolute file paths only.
// Scope (Unit S): valid EXIF orientations 1..8 are normalized via
// [getDisplayBounds] (geometry) and [applyExifOrientation] (pixels) -- see
// AndroidImageOptimizer for the reference EXIF transform mapping this
// mirrors.
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
     * ExifInterface.ORIENTATION_NORMAL when the tag is missing, unparseable,
     * or undefined (e.g. PNG). Valid non-normal EXIF orientations (1..8) are
     * returned as-is for downstream normalization by getDisplayBounds and
     * applyExifOrientation -- this method itself does not rotate pixels.
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
     * Returns the display-space (post-EXIF-rotation) width/height for a raw
     * decode of [rawWidth]x[rawHeight] with EXIF tag [orientation]. Swaps the
     * axes for the four orientations that rotate content 90 degrees
     * (TRANSPOSE, ROTATE_90, TRANSVERSE, ROTATE_270); all other values,
     * including undefined/unknown, keep the raw axes unchanged.
     */
    fun getDisplayBounds(rawWidth: Int, rawHeight: Int, orientation: Int): ImageBounds {
        val swapDims = orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
            orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
            orientation == ExifInterface.ORIENTATION_TRANSVERSE ||
            orientation == ExifInterface.ORIENTATION_ROTATE_270
        return if (swapDims) ImageBounds(rawHeight, rawWidth) else ImageBounds(rawWidth, rawHeight)
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
     * be downsampled on that axis rather than decoded at full size. The
     * bounded loop runs against the [orientation]-adjusted display bounds
     * (see [getDisplayBounds]) so a 90-degree-rotated raw decode is compared
     * against [targetWidth]x[targetHeight] on the correct (post-rotation)
     * axes; undefined/unknown orientation behaves as normal (no swap).
     */
    fun computeInSampleSize(
        rawWidth: Int,
        rawHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        maxTextureSize: Int,
        orientation: Int = ExifInterface.ORIENTATION_NORMAL,
    ): Int {
        if (rawWidth <= 0 || rawHeight <= 0 || targetWidth <= 0 || targetHeight <= 0) return 1
        var inSampleSize = 1
        val boundedWidth = if (maxTextureSize > 0) minOf(targetWidth, maxTextureSize) else targetWidth
        val boundedHeight = if (maxTextureSize > 0) minOf(targetHeight, maxTextureSize) else targetHeight
        if (boundedWidth <= 0 || boundedHeight <= 0) return inSampleSize
        val displayBounds = getDisplayBounds(rawWidth, rawHeight, orientation)
        var sampledWidth = displayBounds.width
        var sampledHeight = displayBounds.height
        while (sampledWidth > boundedWidth || sampledHeight > boundedHeight) {
            inSampleSize *= 2
            sampledWidth = displayBounds.width / inSampleSize
            sampledHeight = displayBounds.height / inSampleSize
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
     * Applies the EXIF rotate/flip transform for [orientation] to [bitmap]
     * using a [Matrix], mirroring AndroidImageOptimizer's EXIF transform
     * mapping. Returns [bitmap] unchanged for
     * ORIENTATION_NORMAL/ORIENTATION_UNDEFINED/unknown values. Recycles the
     * original [bitmap] only when a distinct transformed bitmap is returned.
     */
    fun applyExifOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_NORMAL, ExifInterface.ORIENTATION_UNDEFINED -> return bitmap
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.postRotate(180f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            else -> return bitmap
        }
        val transformed = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (transformed !== bitmap) bitmap.recycle()
        return transformed
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
