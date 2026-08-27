package com.connects.vanguard_media_engine.image

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.math.roundToInt

// ── AndroidImageOptimizer (Phase 5 Unit E) ────────────────────────────────────
//
// Thin owner of the `optimizeImage` MethodChannel route. All decode/resize/
// encode policy lives here; VanguardMediaEnginePlugin only forwards the call.
//
// Baseline native route: BitmapFactory decode + EXIF-aware rotation + a
// single-pass bounding-box resize + Bitmap.compress encode. No adaptive
// quality search, no ROI compositing, no metadata preservation -- those are
// Unit E's documented deferrals (advisory fields are accepted and logged,
// never enforced).
internal object AndroidImageOptimizer {
    private const val TAG = "VanguardImageOptimizer"

    private const val DEFAULT_QUALITY = 0.80

    fun optimize(
        context: Context,
        args: Map<*, *>?,
        result: MethodChannel.Result,
        mainHandler: Handler,
    ) {
        fun replySuccess(map: Map<String, Any?>) {
            mainHandler.post { result.success(map) }
        }

        fun replyError(code: String, message: String?) {
            mainHandler.post { result.error(code, message, null) }
        }

        val sourcePath = args?.get("sourcePath") as? String
        if (sourcePath.isNullOrBlank()) {
            replyError("MISSING_SOURCE_PATH", "optimizeImage: sourcePath required")
            return
        }

        val sourceFile = File(sourcePath)
        if (!sourceFile.exists() || !sourceFile.canRead() || !sourceFile.isFile) {
            replyError("FILE_UNREADABLE", "optimizeImage: cannot read sourcePath: $sourcePath")
            return
        }

        val requestedFormat = (args.get("format") as? String)?.lowercase()?.trim()
        val resolved = resolveFormat(requestedFormat)
        if (resolved == null) {
            replyError(
                "UNSUPPORTED_FORMAT",
                "optimizeImage: unsupported format: ${requestedFormat ?: "<null>"}",
            )
            return
        }
        Log.i(
            TAG,
            "optimizeImage: format requested=${requestedFormat ?: "<default:jpeg>"} " +
                "resolved=${resolved.wireName} reason=${resolved.reason}",
        )

        val outputPathArg = (args.get("outputPath") as? String)?.takeIf { it.isNotBlank() }
        val maxWidth = (args.get("maxWidth") as? Number)?.toInt()
        val maxHeight = (args.get("maxHeight") as? Number)?.toInt()
        val maxLongEdge = (args.get("maxLongEdge") as? Number)?.toInt()
        val qualityArg = (args.get("quality") as? Number)?.toDouble()
        val roiConfig = args.get("roiConfig") as? Map<*, *>
        val enhancementConfig = args.get("enhancementConfig") as? Map<*, *>

        if (enhancementConfig != null) {
            Log.i(TAG, "optimizeImage: enhancementConfig present — accepted/ignored in Unit E")
        }
        // Advisory-only fields, parsed for parity but never enforced in Unit E.
        args.get("fileSizeTargetBytes")
        args.get("colorPolicy")
        args.get("destinationIntent")

        Thread {
            runOptimization(
                context = context,
                sourceFile = sourceFile,
                outputPathArg = outputPathArg,
                resolved = resolved,
                maxWidth = maxWidth,
                maxHeight = maxHeight,
                maxLongEdge = maxLongEdge,
                qualityArg = qualityArg,
                roiConfig = roiConfig,
                onSuccess = ::replySuccess,
                onError = ::replyError,
            )
        }.start()
    }

    // ── Format resolution ────────────────────────────────────────────────────

    private class ResolvedFormat(
        val wireName: String,
        val compressFormat: Bitmap.CompressFormat,
        val defaultExtension: String,
        val reason: String,
    )

    private fun resolveFormat(requested: String?): ResolvedFormat? {
        val token = requested ?: "jpeg"
        return when (token) {
            "jpeg", "jpg" -> ResolvedFormat("jpeg", Bitmap.CompressFormat.JPEG, "jpg", "direct")
            "png" -> ResolvedFormat("png", Bitmap.CompressFormat.PNG, "png", "direct")
            "heic" -> ResolvedFormat(
                "jpeg",
                Bitmap.CompressFormat.JPEG,
                "jpg",
                "heic_unsupported_unit_e_fallback_jpeg",
            )
            else -> null
        }
    }

    // ── Background decode/resize/encode ──────────────────────────────────────

    private fun runOptimization(
        context: Context,
        sourceFile: File,
        outputPathArg: String?,
        resolved: ResolvedFormat,
        maxWidth: Int?,
        maxHeight: Int?,
        maxLongEdge: Int?,
        qualityArg: Double?,
        roiConfig: Map<*, *>?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String?) -> Unit,
    ) {
        val sourcePath = sourceFile.absolutePath
        var decoded: Bitmap? = null
        var oriented: Bitmap? = null
        var resized: Bitmap? = null
        var encodeSource: Bitmap? = null
        var tempFile: File? = null

        try {
            // ── Bounds pass ───────────────────────────────────────────────────
            val boundsOptions = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(sourcePath, boundsOptions)
            val rawWidth = boundsOptions.outWidth
            val rawHeight = boundsOptions.outHeight
            if (rawWidth <= 0 || rawHeight <= 0) {
                onError("DECODE_FAILED", "optimizeImage: cannot decode bounds: $sourcePath")
                return
            }

            // ── EXIF orientation ─────────────────────────────────────────────
            val orientation = readExifOrientation(sourcePath)

            // ── Compute inSampleSize against the post-rotation resize targets ─
            val swapDims = orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
                orientation == ExifInterface.ORIENTATION_ROTATE_270 ||
                orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
                orientation == ExifInterface.ORIENTATION_TRANSVERSE
            // displayWidth/displayHeight are the dimensions as they will appear
            // after EXIF rotation is baked in -- maxWidth/maxHeight/maxLongEdge
            // bound this space, not the raw (pre-rotation) decode space.
            val displayWidth = if (swapDims) rawHeight else rawWidth
            val displayHeight = if (swapDims) rawWidth else rawHeight
            val (displayTargetWidth, displayTargetHeight) = computeTargetDimensions(
                displayWidth, displayHeight, maxWidth, maxHeight, maxLongEdge,
            )
            // Map the display-space target back to raw (pre-rotation) axes so
            // inSampleSize prescales the correct dimension of the raw decode.
            val rawTargetWidth = if (swapDims) displayTargetHeight else displayTargetWidth
            val rawTargetHeight = if (swapDims) displayTargetWidth else displayTargetHeight

            val sampleOptions = BitmapFactory.Options().apply {
                inSampleSize = computeInSampleSize(rawWidth, rawHeight, rawTargetWidth, rawTargetHeight)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            decoded = BitmapFactory.decodeFile(sourcePath, sampleOptions)
            if (decoded == null) {
                onError("DECODE_FAILED", "optimizeImage: decode failed: $sourcePath")
                return
            }

            // ── Apply EXIF rotation/flip ──────────────────────────────────────
            oriented = applyExifOrientation(decoded, orientation)
            if (oriented !== decoded) {
                decoded.recycle()
            }
            decoded = null

            // ── Exact scale to target size ────────────────────────────────────
            val finalTarget = computeTargetDimensions(
                oriented.width, oriented.height, maxWidth, maxHeight, maxLongEdge,
            )
            resized = if (finalTarget.first != oriented.width || finalTarget.second != oriented.height) {
                Bitmap.createScaledBitmap(oriented, finalTarget.first, finalTarget.second, true)
            } else {
                oriented
            }
            if (resized !== oriented) {
                oriented.recycle()
            }
            oriented = null

            // ── Alpha composite for JPEG ───────────────────────────────────────
            encodeSource = if (resolved.wireName == "jpeg" && resized.hasAlpha()) {
                val opaque = Bitmap.createBitmap(resized.width, resized.height, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(opaque)
                canvas.drawColor(Color.BLACK)
                canvas.drawBitmap(resized, 0f, 0f, null)
                opaque
            } else {
                resized
            }
            if (encodeSource !== resized) {
                resized.recycle()
            }
            resized = null

            // ── Resolve output path ────────────────────────────────────────────
            val finalOutputPath = outputPathArg ?: File(
                context.cacheDir,
                "vg_img_opt_${UUID.randomUUID()}.${resolved.defaultExtension}",
            ).absolutePath
            if (outputPathArg != null) {
                val callerExt = outputPathArg.substringAfterLast('.', "").lowercase()
                if (callerExt != resolved.defaultExtension) {
                    Log.w(
                        TAG,
                        "optimizeImage: outputPath extension '$callerExt' does not match " +
                            "resolved format '${resolved.wireName}' — honoring caller path verbatim",
                    )
                }
            }

            val quality = (qualityArg ?: DEFAULT_QUALITY).coerceIn(0.0, 1.0)
            val qualityInt = (quality * 100).roundToInt().coerceIn(0, 100)

            // ── Encode to a unique sibling temp file ───────────────────────────
            val finalFile = File(finalOutputPath)
            val parentDir = finalFile.absoluteFile.parentFile
            parentDir?.mkdirs()
            tempFile = File(parentDir, "${finalFile.name}.tmp-${UUID.randomUUID()}")

            FileOutputStream(tempFile).use { out ->
                val compressed = encodeSource.compress(resolved.compressFormat, qualityInt, out)
                out.flush()
                if (!compressed) {
                    onError("IMAGE_OPTIMIZER_FAILED", "optimizeImage: bitmap compress failed")
                    return
                }
            }
            if (tempFile!!.length() == 0L) {
                onError("IMAGE_OPTIMIZER_FAILED", "optimizeImage: encoded temp file is empty")
                return
            }

            // ── Commit temp → final with backup/rollback ───────────────────────
            var backupFile: File? = null
            if (finalFile.exists()) {
                backupFile = File(parentDir, "${finalFile.name}.bak-${UUID.randomUUID()}")
                if (!finalFile.renameTo(backupFile)) {
                    onError("IMAGE_OPTIMIZER_FAILED", "optimizeImage: could not back up existing output")
                    return
                }
            }
            val moved = tempFile!!.renameTo(finalFile)
            if (!moved) {
                // Roll back: restore backup if we had one; temp cleanup happens in finally.
                if (backupFile != null && backupFile.exists()) {
                    backupFile.renameTo(finalFile)
                }
                onError("IMAGE_OPTIMIZER_FAILED", "optimizeImage: could not move temp to final output")
                return
            }
            tempFile = null // ownership transferred to finalFile; do not delete in finally
            if (backupFile != null && backupFile.exists()) {
                backupFile.delete()
            }

            val fileSizeBytes = finalFile.length()

            val resultMap = mutableMapOf<String, Any?>(
                "success" to true,
                "outputPath" to finalOutputPath,
                "width" to encodeSource.width,
                "height" to encodeSource.height,
                "fileSizeBytes" to fileSizeBytes,
                "format" to resolved.wireName,
                "passCount" to 1,
                "chosenQuality" to quality,
            )

            if (roiConfig != null && roiConfig.get("enabled") == true) {
                resultMap["roiApplied"] = false
                resultMap["roiFallbackReason"] = "unsupported_platform"
                val detector = roiConfig.get("detector") as? String
                if (detector != null) resultMap["roiDetector"] = detector
                resultMap["roiFaceCount"] = 0
                resultMap["roiSuppressionPass"] = 1
            }

            onSuccess(resultMap)
        } catch (e: OutOfMemoryError) {
            Log.e(TAG, "optimizeImage: OOM: ${e.message}")
            onError("IMAGE_OPTIMIZER_FAILED", "optimizeImage: out of memory")
        } catch (e: Exception) {
            Log.e(TAG, "optimizeImage: ${e.message}", e)
            onError("IMAGE_OPTIMIZER_FAILED", "optimizeImage: ${e.message}")
        } finally {
            decoded?.recycle()
            if (oriented != null && oriented !== decoded) oriented.recycle()
            if (resized != null && resized !== oriented) resized.recycle()
            if (encodeSource != null && encodeSource !== resized) encodeSource.recycle()
            tempFile?.let { if (it.exists()) it.delete() }
        }
    }

    // ── EXIF helpers ─────────────────────────────────────────────────────────

    private fun readExifOrientation(sourcePath: String): Int {
        return try {
            val exif = ExifInterface(sourcePath)
            exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (e: Exception) {
            Log.w(TAG, "optimizeImage: EXIF parse failed, continuing with no rotation: ${e.message}")
            ExifInterface.ORIENTATION_NORMAL
        }
    }

    private fun applyExifOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
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
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    // ── Resize math ──────────────────────────────────────────────────────────

    private fun computeTargetDimensions(
        width: Int,
        height: Int,
        maxWidth: Int?,
        maxHeight: Int?,
        maxLongEdge: Int?,
    ): Pair<Int, Int> {
        var scale = 1.0
        if (maxWidth != null && maxWidth > 0 && width > maxWidth) {
            scale = minOf(scale, maxWidth.toDouble() / width.toDouble())
        }
        if (maxHeight != null && maxHeight > 0 && height > maxHeight) {
            scale = minOf(scale, maxHeight.toDouble() / height.toDouble())
        }
        if (maxLongEdge != null && maxLongEdge > 0) {
            val longEdge = maxOf(width, height)
            if (longEdge > maxLongEdge) {
                scale = minOf(scale, maxLongEdge.toDouble() / longEdge.toDouble())
            }
        }
        val targetWidth = (width * scale).toInt().coerceAtLeast(1)
        val targetHeight = (height * scale).toInt().coerceAtLeast(1)
        return Pair(targetWidth, targetHeight)
    }

    private fun computeInSampleSize(rawWidth: Int, rawHeight: Int, targetWidth: Int, targetHeight: Int): Int {
        var inSampleSize = 1
        val halfWidth = rawWidth / 2
        val halfHeight = rawHeight / 2
        while (halfWidth / inSampleSize >= targetWidth && halfHeight / inSampleSize >= targetHeight) {
            inSampleSize *= 2
        }
        return inSampleSize
    }
}
