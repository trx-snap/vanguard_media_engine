package com.connects.vanguard_media_engine.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import com.connects.vanguard_media_engine.export.AndroidStillImageDecoder
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

// ── AndroidImageCompressionResult ─────────────────────────────────────────────
//
// Terminal outcome of an AndroidImageCompressionSession run. Success carries
// the outputPath the `compressImage` MethodChannel route hands back to Dart
// (VanguardMediaPreparer._compressImageNative expects exactly
// {"outputPath": ...}); failure carries one of the INVALID_ARG/READ_FAILED/
// RESIZE_FAILED/WRITE_FAILED codes matching the iOS compressImage contract.
sealed class AndroidImageCompressionResult {
    data class Success(val outputPath: String) : AndroidImageCompressionResult()

    data class Failure(val code: String, val message: String) : AndroidImageCompressionResult()
}

// ── AndroidImageCompressionSession (Phase 5-Unit AE / Phase 10-C-3M) ────────
//
// Runs entirely on AndroidImageCompressionCoordinator's single background
// executor thread. Probes raw bounds + EXIF orientation via
// AndroidStillImageDecoder, computes a display-space target width/height
// that preserves aspect ratio down to maxWidthPx, decodes at the matching
// inSampleSize, bakes EXIF orientation into pixels (this intentionally
// strips/normalizes EXIF orientation -- the output JPEG carries no EXIF/GPS
// metadata, matching Bitmap.compress(JPEG) and the iOS CGImageDestination
// "omit EXIF/GPS keys" contract), resizes to the exact target dimensions
// when needed, alpha-composites onto an opaque black background for JPEG
// output (AndroidImageOptimizer precedent), and commits the encoded JPEG to
// [outputPath] using the same backup/rename/rollback lifecycle as
// AndroidImageOptimizer / AndroidStillImageExportSession.
class AndroidImageCompressionSession(
    private val inputPath: String,
    private val outputPath: String,
    private val maxWidthPx: Int,
    private val qualityPercent: Int,
) {
    fun run(): AndroidImageCompressionResult {
        var decoded: Bitmap? = null
        var oriented: Bitmap? = null
        var resized: Bitmap? = null
        var encodeSource: Bitmap? = null
        var tempFile: File? = null
        try {
            val rawBounds = AndroidStillImageDecoder.probeBounds(inputPath)
                ?: return AndroidImageCompressionResult.Failure(
                    "READ_FAILED", "compressImage: cannot probe bounds: $inputPath",
                )

            val orientation = AndroidStillImageDecoder.readExifOrientation(inputPath)
            val displayBounds = AndroidStillImageDecoder.getDisplayBounds(
                rawBounds.width, rawBounds.height, orientation,
            )

            val targetWidth: Int
            val targetHeight: Int
            if (displayBounds.width > maxWidthPx) {
                val scale = maxWidthPx.toDouble() / displayBounds.width.toDouble()
                targetWidth = maxWidthPx
                targetHeight = maxOf(1, (displayBounds.height * scale).toInt())
            } else {
                targetWidth = displayBounds.width
                targetHeight = displayBounds.height
            }

            val inSampleSize = AndroidStillImageDecoder.computeInSampleSize(
                rawBounds.width, rawBounds.height, targetWidth, targetHeight, 0, orientation,
            )

            decoded = AndroidStillImageDecoder.decodeBitmap(inputPath, inSampleSize)
                ?: return AndroidImageCompressionResult.Failure(
                    "READ_FAILED", "compressImage: cannot decode: $inputPath",
                )

            oriented = try {
                AndroidStillImageDecoder.applyExifOrientation(decoded, orientation)
            } catch (e: OutOfMemoryError) {
                return AndroidImageCompressionResult.Failure(
                    "RESIZE_FAILED", "compressImage: out of memory baking EXIF orientation",
                )
            }
            // applyExifOrientation already recycles `decoded` itself when it
            // returns a distinct transformed bitmap; recycling it again here
            // would double-recycle. Just release ownership either way.
            decoded = null

            resized = if (oriented.width != targetWidth || oriented.height != targetHeight) {
                try {
                    Bitmap.createScaledBitmap(oriented, targetWidth, targetHeight, true)
                } catch (e: OutOfMemoryError) {
                    return AndroidImageCompressionResult.Failure(
                        "RESIZE_FAILED", "compressImage: out of memory resizing",
                    )
                } catch (t: Throwable) {
                    return AndroidImageCompressionResult.Failure(
                        "RESIZE_FAILED", "compressImage: resize failed: ${t.message}",
                    )
                }
            } else {
                oriented
            }
            if (resized !== oriented) oriented.recycle()
            oriented = null

            encodeSource = if (resized.hasAlpha()) {
                try {
                    val opaque = Bitmap.createBitmap(resized.width, resized.height, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(opaque)
                    canvas.drawColor(Color.BLACK)
                    canvas.drawBitmap(resized, 0f, 0f, null)
                    opaque
                } catch (e: OutOfMemoryError) {
                    return AndroidImageCompressionResult.Failure(
                        "RESIZE_FAILED", "compressImage: out of memory compositing alpha",
                    )
                }
            } else {
                resized
            }
            if (encodeSource !== resized) resized.recycle()
            resized = null

            val finalBitmap = encodeSource
            val finalFile = File(outputPath)
            val parentDir = finalFile.absoluteFile.parentFile
                ?: return AndroidImageCompressionResult.Failure(
                    "WRITE_FAILED", "compressImage: output parent directory unavailable: $outputPath",
                )

            val temp = File(parentDir, "${finalFile.name}.tmp-${UUID.randomUUID()}")
            tempFile = temp
            FileOutputStream(temp).use { out ->
                val compressed = finalBitmap.compress(Bitmap.CompressFormat.JPEG, qualityPercent, out)
                out.flush()
                if (!compressed) {
                    return AndroidImageCompressionResult.Failure(
                        "WRITE_FAILED", "compressImage: bitmap compress failed",
                    )
                }
            }
            if (temp.length() <= 0L) {
                return AndroidImageCompressionResult.Failure(
                    "WRITE_FAILED", "compressImage: encoded temp file is empty",
                )
            }

            var backupFile: File? = null
            if (finalFile.exists()) {
                backupFile = File(parentDir, "${finalFile.name}.bak-${UUID.randomUUID()}")
                if (!finalFile.renameTo(backupFile)) {
                    return AndroidImageCompressionResult.Failure(
                        "WRITE_FAILED", "compressImage: could not back up existing output",
                    )
                }
            }
            val moved = temp.renameTo(finalFile)
            if (!moved) {
                if (backupFile != null && backupFile.exists()) {
                    backupFile.renameTo(finalFile)
                }
                return AndroidImageCompressionResult.Failure(
                    "WRITE_FAILED", "compressImage: could not move temp output into place",
                )
            }
            tempFile = null // ownership transferred to finalFile; do not delete in finally
            if (backupFile != null && backupFile.exists()) {
                backupFile.delete()
            }

            return AndroidImageCompressionResult.Success(outputPath)
        } catch (e: OutOfMemoryError) {
            return AndroidImageCompressionResult.Failure("WRITE_FAILED", "compressImage: out of memory")
        } catch (t: Throwable) {
            return AndroidImageCompressionResult.Failure(
                "WRITE_FAILED", t.message ?: t.javaClass.simpleName,
            )
        } finally {
            decoded?.let { if (!it.isRecycled) it.recycle() }
            oriented?.let { if (!it.isRecycled) it.recycle() }
            resized?.let { if (!it.isRecycled) it.recycle() }
            encodeSource?.let { if (!it.isRecycled) it.recycle() }
            tempFile?.let { if (it.exists()) it.delete() }
        }
    }
}
