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

// ── AndroidImageOptimizer (Phase 5 Unit E/F) ──────────────────────────────────
//
// Thin owner of the `optimizeImage` MethodChannel route. All decode/resize/
// encode policy lives here; VanguardMediaEnginePlugin only forwards the call.
//
// Baseline native route: BitmapFactory decode + EXIF-aware rotation + a
// single-pass bounding-box resize + Bitmap.compress encode. Unit F adds a
// bounded adaptive JPEG quality/size search on top of that baseline. ROI
// compositing and metadata preservation remain deferred (advisory fields are
// accepted and logged, never enforced).
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
        val formatToken = normalizeFormatToken(requestedFormat)
        if (formatToken == null) {
            replyError(
                "UNSUPPORTED_FORMAT",
                "optimizeImage: unsupported format: ${requestedFormat ?: "<null>"}",
            )
            return
        }

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
        // fileSizeTargetBytes drives Unit F's adaptive JPEG quality search below.
        // Null, missing, zero, or negative means no adaptive target.
        val fileSizeTargetBytes = (args.get("fileSizeTargetBytes") as? Number)?.toLong()?.takeIf { it > 0L }
        // Advisory-only fields, parsed for parity but never enforced.
        args.get("colorPolicy")
        args.get("destinationIntent")

        Thread {
            // resolveFormat probes HEIC/HEVC codec capability for "heic" --
            // deferred to this background thread so codec enumeration never
            // blocks the platform thread the MethodChannel call arrived on.
            val resolved = resolveFormat(formatToken)
            Log.i(
                TAG,
                "optimizeImage: format requested=${requestedFormat ?: "<default:jpeg>"} " +
                    "resolved=${resolved.wireName} reason=${resolved.reason}",
            )
            runOptimization(
                context = context,
                sourceFile = sourceFile,
                outputPathArg = outputPathArg,
                resolved = resolved,
                maxWidth = maxWidth,
                maxHeight = maxHeight,
                maxLongEdge = maxLongEdge,
                qualityArg = qualityArg,
                fileSizeTargetBytes = fileSizeTargetBytes,
                roiConfig = roiConfig,
                onSuccess = ::replySuccess,
                onError = ::replyError,
            )
        }.start()
    }

    // ── Format resolution ────────────────────────────────────────────────────

    // Which Bitmap/encoder path an EncodeCandidate should use. HEIC has no
    // Bitmap.CompressFormat member, so encoder choice is its own enum rather
    // than a nullable CompressFormat.
    private enum class EncoderKind { JPEG, PNG, HEIC }

    private class ResolvedFormat(
        val wireName: String,
        val encoderKind: EncoderKind,
        val defaultExtension: String,
        val reason: String,
    )

    // Cheap, device-independent token normalization. Runs on the calling
    // (platform) thread before any background work starts, so it must never
    // probe hardware/codec capability -- that happens in resolveFormat below,
    // off the platform thread.
    private fun normalizeFormatToken(requested: String?): String? {
        val token = requested ?: "jpeg"
        return when (token) {
            "jpeg", "jpg" -> "jpeg"
            "png" -> "png"
            "heic" -> "heic"
            else -> null
        }
    }

    // Resolves a normalized token to its concrete encoder. For "heic" this
    // probes device HEIC/HEVC still-encode capability via
    // AndroidHeicImageEncoder.isSupported(), so callers must invoke this off
    // the platform thread (see the Thread block in optimize() below).
    private fun resolveFormat(token: String): ResolvedFormat {
        return when (token) {
            "jpeg" -> ResolvedFormat("jpeg", EncoderKind.JPEG, "jpg", "direct")
            "png" -> ResolvedFormat("png", EncoderKind.PNG, "png", "direct")
            "heic" -> if (AndroidHeicImageEncoder.isSupported()) {
                ResolvedFormat("heic", EncoderKind.HEIC, "heic", "direct")
            } else {
                ResolvedFormat(
                    "jpeg",
                    EncoderKind.JPEG,
                    "jpg",
                    "heic_unsupported_device_fallback_jpeg",
                )
            }
            else -> throw IllegalStateException("resolveFormat: unreachable token=$token")
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
        fileSizeTargetBytes: Long?,
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
        val candidateFiles = mutableListOf<File>()

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

            val startQuality = (qualityArg ?: DEFAULT_QUALITY).coerceIn(0.0, 1.0)

            // ── Encode candidate(s) to unique sibling temp files ───────────────
            val finalFile = File(finalOutputPath)
            val parentDir = finalFile.absoluteFile.parentFile
            parentDir?.mkdirs()

            val adaptiveEligible = resolved.wireName == "jpeg" && fileSizeTargetBytes != null
            val candidates = mutableListOf<EncodeCandidate>()

            if (!adaptiveEligible) {
                candidates.add(
                    encodeCandidate(
                        encodeSource, resolved.encoderKind, startQuality, parentDir, finalFile.name, candidateFiles,
                    ),
                )
            } else {
                val targetBytes = fileSizeTargetBytes!!
                val qualitySchedule = buildAdaptiveQualitySchedule(startQuality, ADAPTIVE_QUALITY_FLOOR)
                for ((index, quality) in qualitySchedule.withIndex()) {
                    val candidate = encodeCandidate(
                        encodeSource, resolved.encoderKind, quality, parentDir, finalFile.name, candidateFiles,
                    )
                    candidates.add(candidate)
                    if (index == 0 && candidate.sizeBytes <= targetBytes) {
                        break // pass 1 already meets target -- no adaptive search needed
                    }
                }
            }

            val meetingTarget = if (fileSizeTargetBytes != null) {
                candidates.filter { it.sizeBytes <= fileSizeTargetBytes }
            } else {
                emptyList()
            }
            val selected = if (meetingTarget.isNotEmpty()) {
                meetingTarget.maxByOrNull { it.quality }!!
            } else if (fileSizeTargetBytes != null) {
                candidates.minByOrNull { it.sizeBytes }!!
            } else {
                candidates.first()
            }

            if (adaptiveEligible) {
                Log.i(
                    TAG,
                    "optimizeImage: adaptive search targetBytes=$fileSizeTargetBytes " +
                        "passCount=${candidates.size} selectedQuality=${selected.quality} " +
                        "selectedSize=${selected.sizeBytes} targetMet=${meetingTarget.isNotEmpty()}",
                )
            }

            // Non-selected candidates are no longer needed; drop them now so only
            // the winner's temp file participates in the commit below.
            for (candidate in candidates) {
                if (candidate !== selected && candidate.file.exists()) {
                    candidate.file.delete()
                }
            }

            tempFile = selected.file

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
                "passCount" to candidates.size,
                "chosenQuality" to selected.quality,
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
            candidateFiles.forEach { if (it.exists()) it.delete() }
        }
    }

    // ── Adaptive JPEG quality/size search (Phase 5 Unit F) ───────────────────

    private const val ADAPTIVE_MAX_ATTEMPTS = 4
    private const val ADAPTIVE_QUALITY_FLOOR = 0.35

    // Deterministic, distinct quality attempts: pass 1 is the requested quality;
    // passes 2..ADAPTIVE_MAX_ATTEMPTS linearly descend to the floor so the last
    // pass lands exactly on it. If the request is already at/below the floor,
    // there is nothing to descend toward -- run a single pass at that quality.
    private fun buildAdaptiveQualitySchedule(startQuality: Double, floor: Double): List<Double> {
        if (startQuality <= floor) {
            return listOf(startQuality)
        }
        val schedule = mutableListOf(startQuality)
        for (attempt in 2..ADAPTIVE_MAX_ATTEMPTS) {
            val quality = startQuality - (startQuality - floor) * (attempt - 1) / (ADAPTIVE_MAX_ATTEMPTS - 1)
            schedule.add(quality.coerceIn(floor, startQuality))
        }
        return schedule.distinct()
    }

    private class EncodeCandidate(val quality: Double, val file: File, val sizeBytes: Long)

    private class EncodeAttemptFailure(message: String) : Exception(message)

    private fun encodeCandidate(
        encodeSource: Bitmap,
        encoderKind: EncoderKind,
        quality: Double,
        parentDir: File?,
        finalFileName: String,
        candidateFiles: MutableList<File>,
    ): EncodeCandidate {
        val qualityInt = (quality * 100).roundToInt().coerceIn(0, 100)
        val candidateFile = File(parentDir, "$finalFileName.tmp-${UUID.randomUUID()}")
        candidateFiles.add(candidateFile)
        when (encoderKind) {
            EncoderKind.JPEG, EncoderKind.PNG -> {
                val compressFormat = if (encoderKind == EncoderKind.JPEG) {
                    Bitmap.CompressFormat.JPEG
                } else {
                    Bitmap.CompressFormat.PNG
                }
                FileOutputStream(candidateFile).use { out ->
                    val compressed = encodeSource.compress(compressFormat, qualityInt, out)
                    out.flush()
                    if (!compressed) {
                        throw EncodeAttemptFailure("bitmap compress failed")
                    }
                }
            }
            EncoderKind.HEIC -> {
                try {
                    AndroidHeicImageEncoder.encode(encodeSource, candidateFile, qualityInt)
                } catch (e: AndroidHeicImageEncoder.HeicEncodeException) {
                    throw EncodeAttemptFailure("heic encode failed: ${e.message}")
                }
            }
        }
        val size = candidateFile.length()
        if (size == 0L) {
            throw EncodeAttemptFailure("encoded temp file is empty")
        }
        return EncodeCandidate(quality, candidateFile, size)
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
