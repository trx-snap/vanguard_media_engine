package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer

/**
 * Diagnostic and runtime validator for [RealtimeVideoFrame] instances passed across generic RTC video seams.
 *
 * ## Verification & Delivery Invariants
 * - **Video-Only Domain Invariant**: This validator operates strictly on video frame metadata and platform buffer attributes.
 *   Vanguard True-DAG carries zero room orchestration, signaling session, participant roster, network token,
 *   or audio stream semantics. Audio capture, routing, mixing, and WebRTC audio tracks are exclusively managed outside Vanguard.
 * - **Zero LiveKit / Raw WebRTC Dependencies**: Transport-neutral validation; does not import or couple with LiveKit, WebRTC SDKs,
 *   or platform audio routing.
 * - **Scoped-Borrow Semantics**: Validates frame envelope and [HardwareBuffer] properties before scoped-borrow delivery.
 *   Buffer ownership remains with the producing pipeline. Zero-copy is capability/implementation-specific and is not claimed as guaranteed.
 */
object RtcVideoFrameValidator {

    /** Set of supported platform pixel formats for GPU-sampled RTC video delivery. */
    val SUPPORTED_BUFFER_FORMATS: Set<Int> = setOf(
        HardwareBuffer.RGBA_8888,
        HardwareBuffer.RGBX_8888,
        HardwareBuffer.RGB_888,
        HardwareBuffer.RGB_565,
        HardwareBuffer.RGBA_FP16,
        HardwareBuffer.RGBA_1010102,
        HardwareBuffer.YCBCR_420_888,
    )

    /**
     * Checks if a [HardwareBuffer] pixel format is in the supported format taxonomy.
     *
     * @param format Android [HardwareBuffer] pixel format constant.
     * @return `true` if supported; `false` otherwise.
     */
    fun isSupportedFormat(format: Int): Boolean = format in SUPPORTED_BUFFER_FORMATS

    /**
     * Validates that the given [RealtimeVideoFrame] satisfies all structural, metadata, and [HardwareBuffer]
     * constraints required for real-time video delivery across transport seams.
     *
     * @param frame The [RealtimeVideoFrame] to validate.
     * @return [RtcVideoFrameDeliveryResult.accepted] on pass, [RtcVideoFrameDeliveryResult.unsupportedFormat] on format/dimension/usage mismatch,
     *         or [RtcVideoFrameDeliveryResult.failed] on unexpected exceptions.
     */
    fun validate(frame: RealtimeVideoFrame): RtcVideoFrameDeliveryResult {
        return try {
            val buffer = frame.hardwareBuffer

            if (buffer.isClosed) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat("buffer_closed")
            }

            if (frame.width <= 0 || frame.height <= 0) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat(
                    "invalid_frame_dimensions:width=${frame.width},height=${frame.height}"
                )
            }

            if (frame.timestampNs < 0L) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat(
                    "invalid_timestamp_ns:${frame.timestampNs}"
                )
            }

            if (frame.frameIndex < 0L) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat(
                    "invalid_frame_index:${frame.frameIndex}"
                )
            }

            if (frame.sourceId.isBlank()) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat("blank_source_id")
            }

            if (frame.width != buffer.width) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat(
                    "dimension_mismatch_width:frame=${frame.width},buffer=${buffer.width}"
                )
            }

            if (frame.height != buffer.height) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat(
                    "dimension_mismatch_height:frame=${frame.height},buffer=${buffer.height}"
                )
            }

            if (buffer.layers != 1) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat(
                    "unsupported_layer_count:${buffer.layers}"
                )
            }

            val hasGpuSampledUsage = (buffer.usage and HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE) == HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
            if (!hasGpuSampledUsage) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat(
                    "missing_gpu_sampled_usage:usage=0x${java.lang.Long.toHexString(buffer.usage)}"
                )
            }

            if (!isSupportedFormat(buffer.format)) {
                return RtcVideoFrameDeliveryResult.unsupportedFormat(
                    "unsupported_pixel_format:${buffer.format}"
                )
            }

            RtcVideoFrameDeliveryResult.accepted(
                "status=OK;width=${frame.width};height=${frame.height};format=${buffer.format};timestampNs=${frame.timestampNs};frameIndex=${frame.frameIndex}"
            )
        } catch (t: Throwable) {
            RtcVideoFrameDeliveryResult.failed("unexpected_validation_error:${t.message}", retryable = false)
        }
    }
}
