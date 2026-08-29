package com.connects.vanguard_media_engine.export

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

// ── AndroidStillImageExportResult ─────────────────────────────────────────────
//
// Terminal outcome of an AndroidStillImageExportSession run. Mirrors the
// success/error shape VanguardMediaEnginePlugin.swift's "exportImage" case
// hands back to Dart: success carries the fields needed to build the
// `success`/`path`/`width`/`height`/`fileSizeBytes` response map (the plugin
// adds the caller's original `format` string itself); failure carries one of
// the EXPORT_IMAGE_* error codes.
sealed class AndroidStillImageExportResult {
    data class Success(
        val path: String,
        val width: Int,
        val height: Int,
        val fileSizeBytes: Long,
    ) : AndroidStillImageExportResult()

    data class Failure(val code: String, val message: String) : AndroidStillImageExportResult()
}

// ── AndroidStillImageExportSession (Phase 5-Unit AD / Phase 10-C-3L) ─────────
//
// Runs entirely on AndroidStillImageExportCoordinator's single background
// executor thread. Parses the `filters` list into an ordered colorMatrix
// chain (Android parity scope: colorMatrix only -- enabled `transform`/
// `overlay` filters are known-but-unimplemented and fail the export rather
// than silently no-op), decodes the source bitmap via
// AndroidStillImageDecoder, bakes EXIF orientation into pixels when the
// caller requested "preserve", applies the colorMatrix chain in order,
// encodes to a unique sibling temp file, and commits it to [outputPath]
// using the same backup/rename/rollback lifecycle as AndroidImageOptimizer.
class AndroidStillImageExportSession(
    private val sourcePath: String,
    private val outputPath: String,
    private val compressFormat: Bitmap.CompressFormat,
    private val qualityPercent: Int,
    private val bakeExifOrientation: Boolean,
    private val filterDicts: List<Map<*, *>>,
) {
    fun run(): AndroidStillImageExportResult {
        var bitmap: Bitmap? = null
        var tempFile: File? = null
        try {
            // ── Parse + validate filter chain (no output mutation yet) ────────
            val colorMatrices = mutableListOf<FloatArray>()
            for (filterDict in filterDicts) {
                val type = filterDict["type"] as? String ?: continue
                val enabled = (filterDict["enabled"] as? Boolean) ?: true
                when (type) {
                    "colorMatrix" -> {
                        if (!enabled) continue
                        val parameters = filterDict["parameters"] as? Map<*, *> ?: emptyMap<Any?, Any?>()
                        val rawMatrix = parameters["matrix"] as? List<*> ?: continue
                        if (rawMatrix.size != 20) continue
                        val matrix = FloatArray(20)
                        var valid = true
                        for (i in 0 until 20) {
                            val n = rawMatrix[i] as? Number
                            if (n == null) {
                                valid = false
                                break
                            }
                            matrix[i] = n.toFloat()
                        }
                        if (!valid) continue
                        colorMatrices.add(matrix)
                    }
                    "transform", "overlay" -> {
                        if (!enabled) continue
                        return AndroidStillImageExportResult.Failure(
                            "EXPORT_IMAGE_UNSUPPORTED_FILTER",
                            "Filter type '$type' is not yet implemented for still-image export.",
                        )
                    }
                    else -> continue
                }
            }

            AndroidStillImageDecoder.probeBounds(sourcePath)
                ?: return AndroidStillImageExportResult.Failure(
                    "EXPORT_IMAGE_FAILED",
                    "Unable to probe source image bounds: $sourcePath",
                )

            val orientation = AndroidStillImageDecoder.readExifOrientation(sourcePath)

            val decoded = AndroidStillImageDecoder.decodeBitmap(sourcePath, 1)
                ?: return AndroidStillImageExportResult.Failure(
                    "EXPORT_IMAGE_FAILED",
                    "Unable to decode source image: $sourcePath",
                )
            bitmap = decoded

            if (bakeExifOrientation) {
                bitmap = AndroidStillImageDecoder.applyExifOrientation(bitmap!!, orientation)
            }

            for (matrix in colorMatrices) {
                val current = bitmap!!
                val next = Bitmap.createBitmap(current.width, current.height, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(next)
                val paint = Paint()
                paint.colorFilter = ColorMatrixColorFilter(ColorMatrix(matrix))
                canvas.drawBitmap(current, 0f, 0f, paint)
                if (next !== current) current.recycle()
                bitmap = next
            }

            val finalBitmap = bitmap
                ?: return AndroidStillImageExportResult.Failure(
                    "EXPORT_IMAGE_FAILED",
                    "No bitmap produced for: $sourcePath",
                )

            val finalFile = File(outputPath)
            val parentDir = finalFile.absoluteFile.parentFile
                ?: return AndroidStillImageExportResult.Failure(
                    "EXPORT_IMAGE_FAILED",
                    "Output parent directory unavailable: $outputPath",
                )

            // ── Encode to unique sibling temp file ────────────────────────────
            val temp = File(parentDir, "${finalFile.name}.tmp-${UUID.randomUUID()}")
            tempFile = temp
            FileOutputStream(temp).use { out ->
                val compressed = finalBitmap.compress(compressFormat, qualityPercent, out)
                out.flush()
                if (!compressed) {
                    return AndroidStillImageExportResult.Failure(
                        "EXPORT_IMAGE_FAILED",
                        "Bitmap compress failed for: $outputPath",
                    )
                }
            }
            if (temp.length() <= 0L) {
                return AndroidStillImageExportResult.Failure(
                    "EXPORT_IMAGE_FAILED",
                    "Encoded temp file is empty: ${temp.path}",
                )
            }

            // ── Commit temp → final with backup/rollback ──────────────────────
            var backupFile: File? = null
            if (finalFile.exists()) {
                backupFile = File(parentDir, "${finalFile.name}.bak-${UUID.randomUUID()}")
                if (!finalFile.renameTo(backupFile)) {
                    return AndroidStillImageExportResult.Failure(
                        "EXPORT_IMAGE_FAILED",
                        "Could not back up existing output: $outputPath",
                    )
                }
            }
            val moved = temp.renameTo(finalFile)
            if (!moved) {
                if (backupFile != null && backupFile.exists()) {
                    backupFile.renameTo(finalFile)
                }
                return AndroidStillImageExportResult.Failure(
                    "EXPORT_IMAGE_FAILED",
                    "Could not move temp output into place: $outputPath",
                )
            }
            tempFile = null // ownership transferred to finalFile; do not delete in finally
            if (backupFile != null && backupFile.exists()) {
                backupFile.delete()
            }

            val fileSizeBytes = finalFile.length()
            if (fileSizeBytes <= 0L) {
                return AndroidStillImageExportResult.Failure(
                    "EXPORT_IMAGE_FAILED",
                    "Final output file is empty: $outputPath",
                )
            }

            return AndroidStillImageExportResult.Success(
                path = outputPath,
                width = finalBitmap.width,
                height = finalBitmap.height,
                fileSizeBytes = fileSizeBytes,
            )
        } catch (e: OutOfMemoryError) {
            return AndroidStillImageExportResult.Failure("EXPORT_IMAGE_FAILED", "Out of memory during export")
        } catch (t: Throwable) {
            return AndroidStillImageExportResult.Failure(
                "EXPORT_IMAGE_FAILED",
                t.message ?: t.javaClass.simpleName,
            )
        } finally {
            bitmap?.let { if (!it.isRecycled) it.recycle() }
            tempFile?.let { if (it.exists()) it.delete() }
        }
    }
}
