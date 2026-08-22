package com.connects.vanguard_media_engine.rtc

/**
 * Delivery status taxonomy for generic RTC video frame publishing and sink ingestion.
 */
enum class RtcVideoFrameDeliveryStatus {
    /** Frame was accepted for transport publishing or DAG pipeline ingestion. */
    ACCEPTED,

    /** Frame was dropped to avoid queue congestion and maintain real-time low latency. */
    DROPPED_BACKPRESSURE,

    /** Frame was dropped because the transport publisher or DAG sink is not yet ready / initialized. */
    DROPPED_NOT_READY,

    /** Frame was rejected due to an unsupported pixel format, dimension, or buffer attribute. */
    UNSUPPORTED_FORMAT,

    /** Frame delivery encountered an unrecoverable or transport error. */
    FAILED,
}

/**
 * Result descriptor for RTC video frame delivery operations.
 *
 * @property status The categorical status of the delivery attempt.
 * @property raw Diagnostic explanation or machine-readable status string.
 * @property retryable Whether the failure condition is transient and suitable for caller retry.
 */
data class RtcVideoFrameDeliveryResult(
    val status: RtcVideoFrameDeliveryStatus,
    val raw: String,
    val retryable: Boolean = false,
) {
    /** Convenience getter indicating whether the frame was accepted successfully. */
    val accepted: Boolean
        get() = status == RtcVideoFrameDeliveryStatus.ACCEPTED

    companion object {
        /** Creates an accepted delivery result. */
        fun accepted(raw: String = "status=ACCEPTED"): RtcVideoFrameDeliveryResult =
            RtcVideoFrameDeliveryResult(
                status = RtcVideoFrameDeliveryStatus.ACCEPTED,
                raw = raw,
                retryable = false,
            )

        /** Creates a dropped result caused by downstream queue backpressure. */
        fun droppedBackpressure(raw: String = "status=DROPPED_BACKPRESSURE"): RtcVideoFrameDeliveryResult =
            RtcVideoFrameDeliveryResult(
                status = RtcVideoFrameDeliveryStatus.DROPPED_BACKPRESSURE,
                raw = raw,
                retryable = false,
            )

        /** Creates a dropped result caused by uninitialized or not-ready transport/sink state. */
        fun droppedNotReady(raw: String = "status=DROPPED_NOT_READY"): RtcVideoFrameDeliveryResult =
            RtcVideoFrameDeliveryResult(
                status = RtcVideoFrameDeliveryStatus.DROPPED_NOT_READY,
                raw = raw,
                retryable = false,
            )

        /** Creates an unsupported format delivery failure result. */
        fun unsupportedFormat(reason: String): RtcVideoFrameDeliveryResult =
            RtcVideoFrameDeliveryResult(
                status = RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT,
                raw = "status=UNSUPPORTED_FORMAT;reason=$reason",
                retryable = false,
            )

        /** Creates a generic failed delivery result with optional retryability. */
        fun failed(reason: String, retryable: Boolean = false): RtcVideoFrameDeliveryResult =
            RtcVideoFrameDeliveryResult(
                status = RtcVideoFrameDeliveryStatus.FAILED,
                raw = "status=FAILED;reason=$reason;retryable=$retryable",
                retryable = retryable,
            )
    }
}
