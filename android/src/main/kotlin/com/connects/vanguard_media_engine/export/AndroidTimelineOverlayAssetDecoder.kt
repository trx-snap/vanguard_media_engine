package com.connects.vanguard_media_engine.export

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

// -- AndroidTimelineOverlayAssetDecoder (P5-OVERLAYS-PRODUCTION-EXPORT-ROUTE-A sub-slice N6) --
//
// Decodes a validated Route-A sticker overlay's local asset file into a direct
// RGBA8888 ByteBuffer compatible with the N5 native upload bridge
// (VanguardNativeBridge.uploadAndroidTimelineVulkanExportOverlayTexture).
// Helper-only: this slice does not call the native upload, does not apply
// overlay transforms/active-interval filtering/z-order/EXIF, and does not
// change export admission (AndroidTimelineExportSession still fails closed on
// any non-empty overlays list).
//
// Uses BitmapFactory + Bitmap.getPixels (non-premultiplied ARGB Color ints),
// then explicitly repacks to RGBA byte order -- NOT Bitmap.copyPixelsToBuffer,
// which copies native config-packed bytes as-is and preserves premultiplication.
internal object AndroidTimelineOverlayAssetDecoder {

    const val CODE_INVALID_ARG = "INVALID_ARG"
    const val CODE_INVALID_IMAGE = "INVALID_IMAGE"
    const val CODE_DIMENSIONS_EXCEEDED = "DIMENSIONS_EXCEEDED"
    const val CODE_OUT_OF_MEMORY = "OUT_OF_MEMORY"

    sealed class DecodeResult {
        data class Success(
            val overlayId: String,
            val assetPath: String,
            val rgbaBuffer: ByteBuffer,
            val width: Int,
            val height: Int,
            val rowStrideBytes: Int,
        ) : DecodeResult()

        data class Failure(val code: String, val message: String) : DecodeResult()
    }

    /** Decodes the sticker asset referenced by [overlay]. Never throws. */
    fun decodeStaticSticker(overlay: AndroidTimelineOverlayDescriptor): DecodeResult {
        return decodeStickerAsset(overlay.overlayId, overlay.assetPath ?: "")
    }

    /** Decodes the sticker asset at [assetPath] for [overlayId]. Never throws. */
    fun decodeStickerAsset(overlayId: String, assetPath: String): DecodeResult {
        if (overlayId.isBlank()) {
            return DecodeResult.Failure(CODE_INVALID_ARG, "overlayId must be non-blank")
        }
        if (assetPath.isBlank()) {
            return DecodeResult.Failure(CODE_INVALID_ARG, "assetPath must be non-blank")
        }

        val assetFile = File(assetPath)
        if (!assetFile.exists() || !assetFile.canRead()) {
            return DecodeResult.Failure(
                AndroidTimelineOverlayDescriptor.CODE_FILE_UNREADABLE,
                "cannot read overlay sticker asset file: $assetPath",
            )
        }

        var bitmap: Bitmap? = null
        try {
            val options = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inPremultiplied = false
                inScaled = false
            }
            bitmap = try {
                BitmapFactory.decodeFile(assetPath, options)
            } catch (oom: OutOfMemoryError) {
                return DecodeResult.Failure(CODE_OUT_OF_MEMORY, "out of memory decoding $assetPath")
            }

            val decoded = bitmap
                ?: return DecodeResult.Failure(CODE_INVALID_IMAGE, "failed to decode overlay sticker asset: $assetPath")

            if (decoded.config == Bitmap.Config.HARDWARE) {
                return DecodeResult.Failure(CODE_INVALID_IMAGE, "hardware bitmap not supported for overlay sticker asset: $assetPath")
            }

            val width = decoded.width
            val height = decoded.height
            if (width <= 0 || height <= 0) {
                return DecodeResult.Failure(CODE_INVALID_IMAGE, "invalid overlay sticker asset dimensions ${width}x$height: $assetPath")
            }

            val pixelCount = width.toLong() * height.toLong()
            if (pixelCount > Int.MAX_VALUE) {
                return DecodeResult.Failure(CODE_DIMENSIONS_EXCEEDED, "overlay sticker asset pixel count exceeds limit: $assetPath")
            }
            val byteCount = pixelCount * 4L
            if (byteCount > Int.MAX_VALUE) {
                return DecodeResult.Failure(CODE_DIMENSIONS_EXCEEDED, "overlay sticker asset byte size exceeds limit: $assetPath")
            }

            val pixels: IntArray
            try {
                pixels = IntArray(pixelCount.toInt())
                decoded.getPixels(pixels, 0, width, 0, 0, width, height)
            } catch (oom: OutOfMemoryError) {
                return DecodeResult.Failure(CODE_OUT_OF_MEMORY, "out of memory reading pixels for $assetPath")
            } catch (t: Throwable) {
                return DecodeResult.Failure(CODE_INVALID_IMAGE, "getPixels failed for overlay sticker asset: $assetPath")
            }

            val rgbaBuffer: ByteBuffer
            try {
                rgbaBuffer = ByteBuffer.allocateDirect(byteCount.toInt()).order(ByteOrder.nativeOrder())
            } catch (oom: OutOfMemoryError) {
                return DecodeResult.Failure(CODE_OUT_OF_MEMORY, "out of memory allocating RGBA buffer for $assetPath")
            }

            for (argb in pixels) {
                val a = (argb ushr 24) and 0xFF
                val r = (argb ushr 16) and 0xFF
                val g = (argb ushr 8) and 0xFF
                val b = argb and 0xFF
                rgbaBuffer.put(r.toByte())
                rgbaBuffer.put(g.toByte())
                rgbaBuffer.put(b.toByte())
                rgbaBuffer.put(a.toByte())
            }
            rgbaBuffer.rewind()

            return DecodeResult.Success(
                overlayId = overlayId,
                assetPath = assetPath,
                rgbaBuffer = rgbaBuffer,
                width = width,
                height = height,
                rowStrideBytes = width * 4,
            )
        } catch (t: Throwable) {
            return DecodeResult.Failure(CODE_INVALID_IMAGE, "unexpected error decoding overlay sticker asset $assetPath: $t")
        } finally {
            bitmap?.recycle()
        }
    }
}
