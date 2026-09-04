package com.connects.vanguard_media_engine.export

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// -- AndroidTimelineOverlayTextRasterizer (P5-OVERLAYS-TEXT-RASTERIZER-HELPER
// sub-slice of P5-OVERLAYS-TRANS) --
//
// Rasterizes text overlay content into a direct tightly packed RGBA8888
// ByteBuffer, in preparation for a later text-overlay export slice.
// Helper-only: this slice does not wire text overlays into the export
// pipeline and does not change export admission. AndroidTimelineOverlayDescriptor
// still fails closed with UNSUPPORTED_EXPORT_FEATURE for any non-sticker
// overlay type, including text.
//
// Uses Bitmap.getPixels (non-premultiplied ARGB Color ints) and explicitly
// repacks to RGBA byte order, matching AndroidTimelineOverlayAssetDecoder --
// NOT Bitmap.copyPixelsToBuffer, which copies native config-packed bytes as-is
// and preserves premultiplication.
//
// Intrinsic text/background alpha is preserved in the rasterized texture
// (not pre-multiplied by overlay opacity): the Vulkan overlay compositor
// scales sampled alpha by overlay opacity separately at draw time
// (vulkan_overlay_frame_renderer.cpp), so baking opacity in here would
// double-apply it.
internal object AndroidTimelineOverlayTextRasterizer {

    const val CODE_INVALID_ARG = "INVALID_ARG"
    const val CODE_DIMENSIONS_EXCEEDED = "DIMENSIONS_EXCEEDED"
    const val CODE_OUT_OF_MEMORY = "OUT_OF_MEMORY"
    const val CODE_RASTERIZE_FAILED = "RASTERIZE_FAILED"

    const val MAX_DIMENSION = 4096

    sealed class RasterizeResult {
        data class Success(
            val overlayId: String,
            val rgbaBuffer: ByteBuffer,
            val width: Int,
            val height: Int,
            val rowStrideBytes: Int,
        ) : RasterizeResult()

        data class Failure(val code: String, val message: String) : RasterizeResult()
    }

    /**
     * Rasterizes [textContent] for overlay [overlayId] into an RGBA8888 direct
     * ByteBuffer sized [width]x[height] (rounded to whole pixels). Optionally
     * draws a semi-transparent rounded background box behind the text. Never
     * throws.
     */
    fun rasterizeText(
        overlayId: String,
        textContent: String,
        width: Double,
        height: Double,
        drawBackground: Boolean = true,
    ): RasterizeResult {
        if (overlayId.isBlank()) {
            return RasterizeResult.Failure(CODE_INVALID_ARG, "overlayId must be non-blank")
        }
        if (textContent.isBlank()) {
            return RasterizeResult.Failure(CODE_INVALID_ARG, "textContent must be non-blank")
        }
        if (!width.isFinite() || width <= 0.0) {
            return RasterizeResult.Failure(CODE_INVALID_ARG, "width must be a finite number > 0.0")
        }
        if (!height.isFinite() || height <= 0.0) {
            return RasterizeResult.Failure(CODE_INVALID_ARG, "height must be a finite number > 0.0")
        }

        val roundedWidth = width.roundToInt()
        val roundedHeight = height.roundToInt()
        val pixelWidth = max(1, roundedWidth)
        val pixelHeight = max(1, roundedHeight)
        if (pixelWidth <= 0 || pixelHeight <= 0) {
            return RasterizeResult.Failure(CODE_DIMENSIONS_EXCEEDED, "overlay text raster dimensions overflowed: ${width}x$height")
        }
        if (pixelWidth > MAX_DIMENSION || pixelHeight > MAX_DIMENSION) {
            return RasterizeResult.Failure(
                CODE_DIMENSIONS_EXCEEDED,
                "overlay text raster dimensions ${pixelWidth}x$pixelHeight exceed limit $MAX_DIMENSION",
            )
        }

        val pixelCount = pixelWidth.toLong() * pixelHeight.toLong()
        if (pixelCount > Int.MAX_VALUE) {
            return RasterizeResult.Failure(CODE_DIMENSIONS_EXCEEDED, "overlay text raster pixel count exceeds limit: ${pixelWidth}x$pixelHeight")
        }
        val byteCount = pixelCount * 4L
        if (byteCount > Int.MAX_VALUE) {
            return RasterizeResult.Failure(CODE_DIMENSIONS_EXCEEDED, "overlay text raster byte size exceeds limit: ${pixelWidth}x$pixelHeight")
        }

        var bitmap: Bitmap? = null
        try {
            bitmap = try {
                Bitmap.createBitmap(pixelWidth, pixelHeight, Bitmap.Config.ARGB_8888)
            } catch (oom: OutOfMemoryError) {
                return RasterizeResult.Failure(CODE_OUT_OF_MEMORY, "out of memory allocating text raster bitmap for overlay $overlayId")
            }

            val canvas = Canvas(bitmap)

            if (drawBackground) {
                val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.BLACK
                    alpha = 140
                }
                val radius = min(width, height).toFloat() * 0.1f
                val clampedRadius = radius.coerceIn(4f, 16f)
                val backgroundRect = RectF(0f, 0f, pixelWidth.toFloat(), pixelHeight.toFloat())
                canvas.drawRoundRect(backgroundRect, clampedRadius, clampedRadius, backgroundPaint)
            }

            val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                typeface = Typeface.DEFAULT_BOLD
                textSize = (height.toFloat() * 0.6f).coerceIn(12f, 96f)
            }

            val layout = StaticLayout.Builder
                .obtain(textContent, 0, textContent.length, textPaint, pixelWidth)
                .setAlignment(Layout.Alignment.ALIGN_CENTER)
                .setIncludePad(false)
                .setMaxLines(Int.MAX_VALUE)
                .build()

            val offsetY = max(0f, (pixelHeight - layout.height) / 2f)
            canvas.save()
            canvas.clipRect(0, 0, pixelWidth, pixelHeight)
            canvas.translate(0f, offsetY)
            layout.draw(canvas)
            canvas.restore()

            val pixels: IntArray
            try {
                pixels = IntArray(pixelCount.toInt())
                bitmap.getPixels(pixels, 0, pixelWidth, 0, 0, pixelWidth, pixelHeight)
            } catch (oom: OutOfMemoryError) {
                return RasterizeResult.Failure(CODE_OUT_OF_MEMORY, "out of memory reading pixels for overlay text raster $overlayId")
            }

            val rgbaBuffer: ByteBuffer
            try {
                rgbaBuffer = ByteBuffer.allocateDirect(byteCount.toInt()).order(ByteOrder.nativeOrder())
            } catch (oom: OutOfMemoryError) {
                return RasterizeResult.Failure(CODE_OUT_OF_MEMORY, "out of memory allocating RGBA buffer for overlay text raster $overlayId")
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

            return RasterizeResult.Success(
                overlayId = overlayId,
                rgbaBuffer = rgbaBuffer,
                width = pixelWidth,
                height = pixelHeight,
                rowStrideBytes = pixelWidth * 4,
            )
        } catch (oom: OutOfMemoryError) {
            return RasterizeResult.Failure(CODE_OUT_OF_MEMORY, "out of memory rasterizing overlay text $overlayId")
        } catch (t: Throwable) {
            return RasterizeResult.Failure(CODE_RASTERIZE_FAILED, "unexpected error rasterizing overlay text $overlayId: $t")
        } finally {
            bitmap?.recycle()
        }
    }
}
