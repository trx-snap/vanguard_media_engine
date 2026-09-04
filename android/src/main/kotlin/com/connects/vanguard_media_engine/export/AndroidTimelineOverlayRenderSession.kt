package com.connects.vanguard_media_engine.export

import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG V4.3 Phase 5 P5-OVERLAYS-TRANS (Route-A N8 helper).
 *
 * Standalone session helper that prepares validated sticker, text, and emoji
 * overlays for the native Vulkan overlay render seam
 * ([VanguardNativeBridge.renderAndroidTimelineVulkanExportFrameCroppedWithOverlays]).
 * Sticker overlays are decoded via [AndroidTimelineOverlayAssetDecoder]; text
 * and emoji overlays are rasterized via [AndroidTimelineOverlayTextRasterizer]
 * (P5-OVERLAYS-TEXT-PRODUCTION-EXPORT, P5-OVERLAYS-EMOJI-PRODUCTION-EXPORT).
 *
 * Helper-only: this class does not wire encoder/export admission, does not
 * mutate native/JNI, and does not unblock overlay export.
 */
internal class AndroidTimelineOverlayRenderSession internal constructor(
    val sessionId: String,
    private val nativeBridge: VanguardNativeBridge,
    uploadedOverlays: List<UploadedOverlay>,
    val hasNativeUploads: Boolean,
) : AutoCloseable {

    internal data class UploadedOverlay(
        val descriptor: AndroidTimelineOverlayDescriptor,
        val textureHandle: Long,
        val inputIndex: Int,
    )

    sealed class PrepareResult {
        data class Success(val session: AndroidTimelineOverlayRenderSession) : PrepareResult()
        data class Failure(val code: String, val message: String) : PrepareResult()
    }

    sealed class FramePayloadResult {
        data class Success(val payload: FramePayload) : FramePayloadResult()
        data class Failure(val code: String, val message: String) : FramePayloadResult()
    }

    data class FramePayload(
        val overlayTextureHandles: LongArray?,
        val overlayGeometry: DoubleArray?,
        val overlayCount: Int,
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is FramePayload) return false
            if (overlayCount != other.overlayCount) return false
            val handlesMatch = when {
                overlayTextureHandles == null -> other.overlayTextureHandles == null
                other.overlayTextureHandles == null -> false
                else -> overlayTextureHandles.contentEquals(other.overlayTextureHandles)
            }
            if (!handlesMatch) return false
            val geomMatch = when {
                overlayGeometry == null -> other.overlayGeometry == null
                other.overlayGeometry == null -> false
                else -> overlayGeometry.contentEquals(other.overlayGeometry)
            }
            return geomMatch
        }

        override fun hashCode(): Int {
            var result = overlayCount
            result = 31 * result + (overlayTextureHandles?.contentHashCode() ?: 0)
            result = 31 * result + (overlayGeometry?.contentHashCode() ?: 0)
            return result
        }
    }

    private val closed = AtomicBoolean(false)
    private val localUploadedOverlays: MutableList<UploadedOverlay> = uploadedOverlays.toMutableList()

    val isClosed: Boolean
        get() = closed.get()

    val uploadedOverlayCount: Int
        get() = synchronized(localUploadedOverlays) { localUploadedOverlays.size }

    /**
     * Builds the frame overlay payload for playhead position [timelinePtsUs].
     *
     * Selects active overlays at [timelinePtsUs], sorts them back-to-front by
     * [AndroidTimelineOverlayDescriptor.DRAW_ORDER_COMPARATOR] with original input
     * index tie-breaking, and packs texture handles and geometry tuples.
     *
     * Returns [FramePayloadResult.Failure] if the session is closed or if
     * [timelinePtsUs] is negative. Returns an empty payload ([FramePayload] with
     * null arrays and count 0) when no overlays are active at [timelinePtsUs].
     */
    fun buildFramePayload(timelinePtsUs: Long): FramePayloadResult {
        if (closed.get()) {
            return FramePayloadResult.Failure(
                code = OVERLAY_SESSION_CLOSED,
                message = "AndroidTimelineOverlayRenderSession is closed: sessionId='$sessionId'",
            )
        }
        if (timelinePtsUs < 0L) {
            return FramePayloadResult.Failure(
                code = INVALID_ARG,
                message = "timelinePtsUs must be non-negative: $timelinePtsUs",
            )
        }

        val candidates = synchronized(localUploadedOverlays) {
            if (closed.get()) {
                return FramePayloadResult.Failure(
                    code = OVERLAY_SESSION_CLOSED,
                    message = "AndroidTimelineOverlayRenderSession is closed: sessionId='$sessionId'",
                )
            }
            localUploadedOverlays.toList()
        }

        val ptsSeconds = timelinePtsUs / 1_000_000.0
        val activeOverlays = ArrayList<UploadedOverlay>()
        for (item in candidates) {
            if (item.descriptor.isActiveAtTime(ptsSeconds)) {
                activeOverlays.add(item)
            }
        }

        if (activeOverlays.isEmpty()) {
            return FramePayloadResult.Success(FramePayload(null, null, 0))
        }

        activeOverlays.sortWith { a, b ->
            val cmp = AndroidTimelineOverlayDescriptor.DRAW_ORDER_COMPARATOR.compare(a.descriptor, b.descriptor)
            if (cmp != 0) cmp else a.inputIndex.compareTo(b.inputIndex)
        }

        val activeCount = activeOverlays.size
        val textureHandles = LongArray(activeCount)
        val geometry = DoubleArray(activeCount * 7)

        for (i in 0 until activeCount) {
            val active = activeOverlays[i]
            textureHandles[i] = active.textureHandle
            val desc = active.descriptor
            val base = i * 7
            if (desc.keyframes.isNotEmpty()) {
                val eval = AndroidTimelineOverlayTransformEvaluator.evaluate(desc, ptsSeconds)
                geometry[base] = eval.translationX
                geometry[base + 1] = eval.translationY
                geometry[base + 2] = eval.width
                geometry[base + 3] = eval.height
                geometry[base + 4] = eval.rotation
                geometry[base + 5] = eval.scale
                geometry[base + 6] = eval.opacity
            } else {
                geometry[base] = desc.translationX
                geometry[base + 1] = desc.translationY
                geometry[base + 2] = desc.width
                geometry[base + 3] = desc.height
                geometry[base + 4] = desc.rotation
                geometry[base + 5] = desc.scale
                geometry[base + 6] = desc.opacity
            }
        }

        return FramePayloadResult.Success(
            FramePayload(
                overlayTextureHandles = textureHandles,
                overlayGeometry = geometry,
                overlayCount = activeCount,
            ),
        )
    }

    /**
     * Idempotent teardown. Never throws.
     *
     * If not already closed, marks the session closed, clears native texture store
     * state if any texture was successfully uploaded, and clears local uploaded overlays.
     */
    override fun close() {
        if (closed.compareAndSet(false, true)) {
            if (hasNativeUploads) {
                quietlyClearNativeTextures(nativeBridge, sessionId)
            }
            synchronized(localUploadedOverlays) {
                localUploadedOverlays.clear()
            }
        }
    }

    companion object {
        const val CODE_INVALID_ARG: String = AndroidTimelineOverlayAssetDecoder.CODE_INVALID_ARG
        const val CODE_OVERLAY_UPLOAD_FAILED: String = "OVERLAY_UPLOAD_FAILED"
        const val CODE_OVERLAY_SESSION_CLOSED: String = "OVERLAY_SESSION_CLOSED"

        const val INVALID_ARG: String = CODE_INVALID_ARG
        const val OVERLAY_UPLOAD_FAILED: String = CODE_OVERLAY_UPLOAD_FAILED
        const val OVERLAY_SESSION_CLOSED: String = CODE_OVERLAY_SESSION_CLOSED

        /**
         * Prepares and uploads all sticker and text overlay textures for [sessionId].
         *
         * Sticker overlays are decoded via [AndroidTimelineOverlayAssetDecoder.decodeStaticSticker];
         * text overlays are rasterized via [AndroidTimelineOverlayTextRasterizer.rasterizeText].
         * Each resulting RGBA buffer is uploaded to the backend-owned Vulkan overlay
         * texture store via [VanguardNativeBridge.uploadAndroidTimelineVulkanExportOverlayTexture].
         *
         * On any decode, rasterize, upload, or parsing failure, rolls back by clearing
         * native texture state if any prior upload succeeded, and returns
         * [PrepareResult.Failure]. Never keeps direct ByteBuffer references after upload.
         */
        fun prepare(
            sessionId: String,
            overlays: List<AndroidTimelineOverlayDescriptor>,
            nativeBridge: VanguardNativeBridge,
        ): PrepareResult {
            if (sessionId.isBlank()) {
                return PrepareResult.Failure(
                    code = INVALID_ARG,
                    message = "sessionId must be non-blank",
                )
            }

            if (overlays.isEmpty()) {
                return PrepareResult.Success(
                    AndroidTimelineOverlayRenderSession(
                        sessionId = sessionId,
                        nativeBridge = nativeBridge,
                        uploadedOverlays = emptyList(),
                        hasNativeUploads = false,
                    ),
                )
            }

            val uploadedList = ArrayList<UploadedOverlay>(overlays.size)
            var anyUploadSucceeded = false

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
                                    if (anyUploadSucceeded) {
                                        quietlyClearNativeTextures(nativeBridge, sessionId)
                                    }
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
                                    if (anyUploadSucceeded) {
                                        quietlyClearNativeTextures(nativeBridge, sessionId)
                                    }
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

                    val uploadStatus = nativeBridge.uploadAndroidTimelineVulkanExportOverlayTexture(
                        sessionId = sessionId,
                        rgbaBuffer = rgbaBuffer,
                        width = pixelWidth,
                        height = pixelHeight,
                        rowStrideBytes = rowStrideBytes,
                    )
                    val textureHandle = parseTextureHandle(uploadStatus)
                    if (textureHandle == null || textureHandle <= 0L) {
                        if (anyUploadSucceeded) {
                            quietlyClearNativeTextures(nativeBridge, sessionId)
                        }
                        val boundedStatus = if (uploadStatus.length > 200) {
                            uploadStatus.take(200) + "..."
                        } else {
                            uploadStatus
                        }
                        return PrepareResult.Failure(
                            code = OVERLAY_UPLOAD_FAILED,
                            message = "Failed to upload overlay texture '${overlay.overlayId}': status='$boundedStatus'",
                        )
                    }
                    uploadedList.add(
                        UploadedOverlay(
                            descriptor = overlay,
                            textureHandle = textureHandle,
                            inputIndex = index,
                        ),
                    )
                    anyUploadSucceeded = true
                }
            } catch (t: Throwable) {
                if (anyUploadSucceeded) {
                    quietlyClearNativeTextures(nativeBridge, sessionId)
                }
                return PrepareResult.Failure(
                    code = OVERLAY_UPLOAD_FAILED,
                    message = "Unexpected error preparing overlay textures: ${t.javaClass.simpleName}: ${t.message}",
                )
            }

            return PrepareResult.Success(
                AndroidTimelineOverlayRenderSession(
                    sessionId = sessionId,
                    nativeBridge = nativeBridge,
                    uploadedOverlays = uploadedList,
                    hasNativeUploads = true,
                ),
            )
        }

        private fun parseTextureHandle(raw: String): Long? {
            if (raw.isBlank()) return null
            var isOk = false
            var handle: Long? = null
            val tokens = raw.split(';')
            for (token in tokens) {
                val eq = token.indexOf('=')
                if (eq > 0) {
                    val key = token.substring(0, eq).trim()
                    val value = token.substring(eq + 1).trim()
                    if (key.equals("status", ignoreCase = true) && value.equals("OK", ignoreCase = true)) {
                        isOk = true
                    } else if (key.equals("textureHandle", ignoreCase = true)) {
                        handle = value.toLongOrNull()
                    }
                }
            }
            return if (isOk && handle != null && handle > 0L) handle else null
        }

        private fun quietlyClearNativeTextures(
            nativeBridge: VanguardNativeBridge,
            sessionId: String,
        ) {
            try {
                nativeBridge.clearAndroidTimelineVulkanExportOverlayTextures(sessionId)
            } catch (_: Throwable) {
                // Quietly clear native textures; never throw.
            }
        }
    }
}
