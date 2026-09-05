package com.connects.vanguard_media_engine.export

import android.opengl.GLES20
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG V4.3 Phase 5 P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A.
 *
 * GLES sibling of [AndroidTimelineOverlayRenderSession] (which uploads to
 * backend-owned Vulkan overlay texture handles): prepares validated sticker,
 * text, and emoji overlays as caller-owned `GL_TEXTURE_2D` textures on the
 * caller's already-current GLES export EGL context, then composites the
 * overlays active at a given timeline instant via
 * [VanguardNativeBridge.drawAndroidTimelineGlesExportOverlays] (the
 * production seam over the same private `GlesOverlayCompositor` helper the
 * Vulkan route's diagnostic and this route's production seam both draw
 * through).
 *
 * Every GL call in this class requires the caller's GLES export EGL
 * context/surface to already be current on the calling thread -- this class
 * never creates or destroys an EGL context/surface, and never calls
 * `eglMakeCurrent`/`eglSwapBuffers`. Sticker overlays are decoded via
 * [AndroidTimelineOverlayAssetDecoder]; text and emoji overlays are
 * rasterized via [AndroidTimelineOverlayTextRasterizer]. Each resulting
 * top-down RGBA buffer is repacked into tightly-packed rows and row-flipped
 * (see [repackTightlyPackedAndFlipVertically]) before upload via
 * `GLES20.glTexImage2D` (never `GLUtils.texImage2D`, never relying on
 * `GL_UNPACK_ROW_LENGTH`) so that GL's bottom-up texture-row convention --
 * the same convention `GlesOverlayCompositor` documents -- renders the
 * overlay upright regardless of the decoder/rasterizer's source row stride.
 */
internal class AndroidTimelineGlesOverlayRenderSession internal constructor(
    uploadedOverlays: List<UploadedOverlay>,
) : AutoCloseable {

    internal data class UploadedOverlay(
        val descriptor: AndroidTimelineOverlayDescriptor,
        val textureId: Int,
        val inputIndex: Int,
    )

    sealed class PrepareResult {
        data class Success(val session: AndroidTimelineGlesOverlayRenderSession) : PrepareResult()
        data class Failure(val code: String, val message: String) : PrepareResult()
    }

    sealed class DrawResult {
        data class Success(val activeOverlayCount: Int) : DrawResult()
        data class Failure(val reason: String) : DrawResult()
    }

    private val closed = AtomicBoolean(false)
    private val localUploadedOverlays: MutableList<UploadedOverlay> = uploadedOverlays.toMutableList()

    /**
     * Composites every overlay active at [timelinePtsUs] (timeline
     * microseconds) onto the caller's currently-current
     * [surfaceWidth]x[surfaceHeight] GLES export EGL surface via
     * [nativeBridge]. Must be called after the base video frame has already
     * been drawn into that same surface, and before presentation/swap --
     * this never clears the framebuffer, matching `GlesOverlayCompositor`'s
     * draw model. Returns [DrawResult.Success] with the number of overlays
     * actually composited (0 when none are active at this instant, a legal
     * no-op) or [DrawResult.Failure] with a machine-readable reason on any
     * validation or native draw failure -- callers must fail the whole
     * encode rather than silently continuing without the overlay.
     */
    fun drawActiveOverlays(
        nativeBridge: VanguardNativeBridge,
        timelinePtsUs: Long,
        surfaceWidth: Int,
        surfaceHeight: Int,
    ): DrawResult {
        if (closed.get()) return DrawResult.Failure("overlay_session_closed")
        if (timelinePtsUs < 0L) return DrawResult.Failure("invalid_timeline_pts")

        val ptsSeconds = timelinePtsUs / 1_000_000.0
        val activeOverlays = ArrayList<UploadedOverlay>()
        for (item in localUploadedOverlays) {
            if (item.descriptor.isActiveAtTime(ptsSeconds)) {
                activeOverlays.add(item)
            }
        }
        if (activeOverlays.isEmpty()) return DrawResult.Success(0)

        activeOverlays.sortWith { a, b ->
            val cmp = AndroidTimelineOverlayDescriptor.DRAW_ORDER_COMPARATOR.compare(a.descriptor, b.descriptor)
            if (cmp != 0) cmp else a.inputIndex.compareTo(b.inputIndex)
        }

        val count = activeOverlays.size
        val textureIds = IntArray(count)
        val textureTargets = IntArray(count) { GLES20.GL_TEXTURE_2D }
        val zIndices = IntArray(count)
        val geometry = DoubleArray(count * 7)

        for (i in 0 until count) {
            val active = activeOverlays[i]
            textureIds[i] = active.textureId
            zIndices[i] = active.descriptor.zIndex
            val desc = active.descriptor
            val base = i * 7
            val eval = if (desc.keyframes.isNotEmpty()) {
                AndroidTimelineOverlayTransformEvaluator.evaluate(desc, ptsSeconds)
            } else {
                null
            }
            geometry[base] = eval?.translationX ?: desc.translationX
            geometry[base + 1] = eval?.translationY ?: desc.translationY
            geometry[base + 2] = eval?.width ?: desc.width
            geometry[base + 3] = eval?.height ?: desc.height
            geometry[base + 4] = eval?.rotation ?: desc.rotation
            geometry[base + 5] = eval?.scale ?: desc.scale
            geometry[base + 6] = eval?.opacity ?: desc.opacity
        }

        val status = nativeBridge.drawAndroidTimelineGlesExportOverlays(
            textureIds, textureTargets, geometry, zIndices, count, surfaceWidth, surfaceHeight,
        )
        return if (isStatusOk(status)) {
            DrawResult.Success(count)
        } else {
            DrawResult.Failure(parseFailureReason(status))
        }
    }

    /**
     * Idempotent teardown. Deletes every uploaded `GL_TEXTURE_2D` texture --
     * the caller's GLES export EGL context/surface must still be current
     * when this is called; callers must invoke [close] before tearing that
     * context/surface down. Never throws.
     */
    override fun close() {
        if (closed.compareAndSet(false, true)) {
            for (overlay in localUploadedOverlays) {
                if (overlay.textureId != 0) {
                    try {
                        GLES20.glDeleteTextures(1, intArrayOf(overlay.textureId), 0)
                    } catch (_: Throwable) {
                        // Best-effort idempotent cleanup; never throw out of close().
                    }
                }
            }
            localUploadedOverlays.clear()
        }
    }

    companion object {
        const val CODE_OVERLAY_UPLOAD_FAILED: String = "OVERLAY_UPLOAD_FAILED"

        /**
         * Hard ceiling on the sum of (pixelWidth * pixelHeight) across every
         * uploaded overlay texture in one export session -- fails closed
         * with `overlay_texture_budget_exceeded` before uploading further
         * textures, bounding worst-case overlay GPU memory to roughly
         * 256 MiB at RGBA8 (4 bytes/texel).
         */
        private const val MAX_TOTAL_OVERLAY_TEXELS = 64L * 1024L * 1024L

        /**
         * Decodes/rasterizes and uploads every overlay in [overlays] to a
         * fresh `GL_TEXTURE_2D` texture on the caller's already-current GLES
         * export EGL context. [isCancelled] is polled between overlays so a
         * long overlay list can be abandoned promptly.
         *
         * Sticker overlays are decoded via
         * [AndroidTimelineOverlayAssetDecoder.decodeStaticSticker]; text and
         * emoji overlays are rasterized via
         * [AndroidTimelineOverlayTextRasterizer.rasterizeText]. Each
         * resulting pixel size is checked against the live
         * `GL_MAX_TEXTURE_SIZE` (failing closed with
         * `overlay_texture_too_large:<id>:<w>x<h>`) and against a running
         * total-texel budget (failing closed with
         * `overlay_texture_budget_exceeded`) before upload.
         *
         * On any decode, rasterize, size, budget, or upload failure, every
         * texture already uploaded in this call is deleted before returning
         * [PrepareResult.Failure] -- this never leaks a partially-uploaded
         * overlay set. Never throws.
         */
        fun prepare(
            overlays: List<AndroidTimelineOverlayDescriptor>,
            isCancelled: () -> Boolean,
        ): PrepareResult {
            if (overlays.isEmpty()) {
                return PrepareResult.Success(AndroidTimelineGlesOverlayRenderSession(emptyList()))
            }

            val maxTextureSizeOut = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, maxTextureSizeOut, 0)
            val maxTextureSize = maxTextureSizeOut[0]

            val uploadedList = ArrayList<UploadedOverlay>(overlays.size)
            var totalTexels = 0L

            fun rollback() {
                for (uploaded in uploadedList) {
                    if (uploaded.textureId != 0) {
                        try {
                            GLES20.glDeleteTextures(1, intArrayOf(uploaded.textureId), 0)
                        } catch (_: Throwable) {
                            // Best-effort rollback; never throw out of prepare().
                        }
                    }
                }
            }

            try {
                for ((index, overlay) in overlays.withIndex()) {
                    val rgbaBuffer: ByteBuffer
                    val pixelWidth: Int
                    val pixelHeight: Int
                    val rowStrideBytes: Int

                    when (overlay.type) {
                        AndroidTimelineOverlayDescriptor.Type.STICKER -> {
                            when (val decodeResult = AndroidTimelineOverlayAssetDecoder.decodeStaticSticker(overlay)) {
                                is AndroidTimelineOverlayAssetDecoder.DecodeResult.Failure -> {
                                    rollback()
                                    return PrepareResult.Failure(
                                        code = decodeResult.code,
                                        message = "Failed to decode overlay '${overlay.overlayId}': ${decodeResult.message}",
                                    )
                                }
                                is AndroidTimelineOverlayAssetDecoder.DecodeResult.Success -> {
                                    rgbaBuffer = decodeResult.rgbaBuffer
                                    pixelWidth = decodeResult.width
                                    pixelHeight = decodeResult.height
                                    rowStrideBytes = decodeResult.rowStrideBytes
                                }
                            }
                        }
                        AndroidTimelineOverlayDescriptor.Type.TEXT,
                        AndroidTimelineOverlayDescriptor.Type.EMOJI -> {
                            val kindName = if (overlay.type == AndroidTimelineOverlayDescriptor.Type.EMOJI) "emoji" else "text"
                            when (
                                val rasterizeResult = AndroidTimelineOverlayTextRasterizer.rasterizeText(
                                    overlay.overlayId,
                                    overlay.textContent ?: "",
                                    overlay.width,
                                    overlay.height,
                                    drawBackground = true,
                                )
                            ) {
                                is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Failure -> {
                                    rollback()
                                    return PrepareResult.Failure(
                                        code = rasterizeResult.code,
                                        message = "Failed to rasterize $kindName overlay '${overlay.overlayId}': ${rasterizeResult.message}",
                                    )
                                }
                                is AndroidTimelineOverlayTextRasterizer.RasterizeResult.Success -> {
                                    rgbaBuffer = rasterizeResult.rgbaBuffer
                                    pixelWidth = rasterizeResult.width
                                    pixelHeight = rasterizeResult.height
                                    rowStrideBytes = rasterizeResult.rowStrideBytes
                                }
                            }
                        }
                    }

                    if (maxTextureSize > 0 && (pixelWidth > maxTextureSize || pixelHeight > maxTextureSize)) {
                        rollback()
                        return PrepareResult.Failure(
                            code = CODE_OVERLAY_UPLOAD_FAILED,
                            message = "overlay_texture_too_large:${overlay.overlayId}:${pixelWidth}x$pixelHeight",
                        )
                    }

                    totalTexels += pixelWidth.toLong() * pixelHeight.toLong()
                    if (totalTexels > MAX_TOTAL_OVERLAY_TEXELS) {
                        rollback()
                        return PrepareResult.Failure(
                            code = CODE_OVERLAY_UPLOAD_FAILED,
                            message = "overlay_texture_budget_exceeded",
                        )
                    }

                    val flippedBuffer = repackTightlyPackedAndFlipVertically(
                        rgbaBuffer, pixelWidth, pixelHeight, rowStrideBytes,
                    )

                    val textures = IntArray(1)
                    GLES20.glGenTextures(1, textures, 0)
                    val textureId = textures[0]
                    if (textureId == 0) {
                        rollback()
                        return PrepareResult.Failure(
                            code = CODE_OVERLAY_UPLOAD_FAILED,
                            message = "overlay_texture_generation_failed:${overlay.overlayId}",
                        )
                    }
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                    GLES20.glTexImage2D(
                        GLES20.GL_TEXTURE_2D,
                        0,
                        GLES20.GL_RGBA,
                        pixelWidth,
                        pixelHeight,
                        0,
                        GLES20.GL_RGBA,
                        GLES20.GL_UNSIGNED_BYTE,
                        flippedBuffer,
                    )
                    val uploadError = GLES20.glGetError()
                    if (uploadError != GLES20.GL_NO_ERROR) {
                        try { GLES20.glDeleteTextures(1, intArrayOf(textureId), 0) } catch (_: Throwable) {}
                        rollback()
                        return PrepareResult.Failure(
                            code = CODE_OVERLAY_UPLOAD_FAILED,
                            message = "overlay_texture_upload_failed:$uploadError:${overlay.overlayId}",
                        )
                    }

                    uploadedList.add(UploadedOverlay(descriptor = overlay, textureId = textureId, inputIndex = index))

                    if (isCancelled()) {
                        rollback()
                        return PrepareResult.Failure(code = CODE_OVERLAY_UPLOAD_FAILED, message = "cancelled")
                    }
                }
            } catch (t: Throwable) {
                rollback()
                return PrepareResult.Failure(
                    code = CODE_OVERLAY_UPLOAD_FAILED,
                    message = "Unexpected error preparing overlay textures: ${t.javaClass.simpleName}: ${t.message}",
                )
            }

            return PrepareResult.Success(AndroidTimelineGlesOverlayRenderSession(uploadedList))
        }

        /**
         * Returns a new direct buffer holding [height] tightly-packed RGBA
         * rows of exactly `width * 4` bytes each (no `GL_UNPACK_ROW_LENGTH`
         * reliance, no `GLUtils`), reversed top-to-bottom relative to
         * [source]. [source] provides [height] rows of [rowStrideBytes] each
         * -- only the leading `width * 4` pixel bytes of every source row
         * are copied, discarding any decoder/rasterizer row padding beyond
         * that. Sticker/text/emoji RGBA buffers are produced top-down (row 0
         * = visual top, via `Bitmap.getPixels`); GL's texture-row convention
         * -- and `GlesOverlayCompositor`'s documented mapping of texture row
         * 0 to the visually bottom edge -- requires a bottom-up buffer for
         * the overlay to appear upright after compositing.
         */
        private fun repackTightlyPackedAndFlipVertically(
            source: ByteBuffer,
            width: Int,
            height: Int,
            rowStrideBytes: Int,
        ): ByteBuffer {
            val tightRowBytes = width * 4
            val flipped = ByteBuffer.allocateDirect(tightRowBytes * height).order(ByteOrder.nativeOrder())
            val rowBytes = ByteArray(tightRowBytes)
            val src = source.duplicate().order(ByteOrder.nativeOrder())
            for (row in 0 until height) {
                src.position(row * rowStrideBytes)
                src.get(rowBytes)
                flipped.position((height - 1 - row) * tightRowBytes)
                flipped.put(rowBytes)
            }
            flipped.position(0)
            return flipped
        }

        private fun isStatusOk(status: String): Boolean = status.startsWith("status=OK")

        private fun parseFailureReason(status: String): String {
            val marker = "reason="
            val idx = status.indexOf(marker)
            return if (idx >= 0) status.substring(idx + marker.length) else status
        }
    }
}
