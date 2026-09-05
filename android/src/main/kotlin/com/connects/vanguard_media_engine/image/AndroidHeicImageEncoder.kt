package com.connects.vanguard_media_engine.image

import android.graphics.Bitmap
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import androidx.heifwriter.HeifWriter
import java.io.File

// ── AndroidHeicImageEncoder (Phase 5 Unit G) ──────────────────────────────────
//
// Owns HEIC still-image encode capability probing and the AndroidX HeifWriter
// lifecycle. AndroidImageOptimizer decides whether to route a request here
// (based on isSupported()) and otherwise falls back to its existing JPEG path;
// this object never falls back on its own -- a failed encode() throws so the
// caller can clean up its temp candidate and report failure.
internal object AndroidHeicImageEncoder {
    private const val TAG = "VanguardHeicEncoder"

    // HeifWriter.stop() timeout for a single INPUT_MODE_BITMAP still image.
    private const val STOP_TIMEOUT_MS = 3_000L

    // MediaFormat.MIMETYPE_IMAGE_ANDROID_HEIC was added in API 30. It is a
    // compile-time String constant (inlined by the compiler), so referencing
    // it directly is safe even though minSdk is below 30 -- no class/method
    // lookup happens at runtime.
    private val HEIC_STILL_MIME: String? = MediaFormat.MIMETYPE_IMAGE_ANDROID_HEIC

    // Thrown when the capability probe reported support but the HeifWriter
    // build/start/addBitmap/stop/close lifecycle failed or produced no usable
    // output. Callers must treat this exactly like any other encode failure:
    // clean up the temp candidate and surface IMAGE_OPTIMIZER_FAILED.
    class HeicEncodeException(message: String, cause: Throwable? = null) : Exception(message, cause)

    // Conservative device capability probe. Never throws -- any probe failure
    // (missing constants, codec query exceptions, pre-API-28 devices) is
    // treated as "unsupported" so the caller can fall back to JPEG.
    fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < 28) {
            return false
        }
        return try {
            val codecInfos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            codecInfos.any { info ->
                info.isEncoder && encoderAdvertisesHeicOrHevc(info.supportedTypes)
            }
        } catch (e: Exception) {
            Log.w(TAG, "isSupported: codec probe failed, treating HEIC as unsupported: ${e.message}")
            false
        }
    }

    private fun encoderAdvertisesHeicOrHevc(supportedTypes: Array<String>): Boolean {
        return try {
            supportedTypes.any { type ->
                (HEIC_STILL_MIME != null && type.equals(HEIC_STILL_MIME, ignoreCase = true)) ||
                    type.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true)
            }
        } catch (e: Exception) {
            false
        }
    }

    // Encodes a single Bitmap to outputFile as HEIC via AndroidX HeifWriter in
    // INPUT_MODE_BITMAP. outputFile must be a fresh/unique temp path owned by
    // the caller -- this function does not delete it on failure; the caller's
    // existing candidate-cleanup path is responsible for that.
    //
    // qualityPercent is clamped to HeifWriter's documented 0..100 range.
    fun encode(bitmap: Bitmap, outputFile: File, qualityPercent: Int) {
        val quality = qualityPercent.coerceIn(0, 100)
        var writer: HeifWriter? = null
        try {
            writer = HeifWriter.Builder(
                outputFile.absolutePath,
                bitmap.width,
                bitmap.height,
                HeifWriter.INPUT_MODE_BITMAP,
            )
                .setQuality(quality)
                .setMaxImages(1)
                .build()
            writer.start()
            writer.addBitmap(bitmap)
            writer.stop(STOP_TIMEOUT_MS)
        } catch (e: Exception) {
            throw HeicEncodeException("HEIC encode failed: ${e.message}", e)
        } finally {
            try {
                writer?.close()
            } catch (e: Exception) {
                Log.w(TAG, "encode: HeifWriter close failed: ${e.message}")
            }
        }
        if (!outputFile.exists() || outputFile.length() == 0L) {
            throw HeicEncodeException("HEIC encode produced empty or missing output: ${outputFile.absolutePath}")
        }
    }
}
