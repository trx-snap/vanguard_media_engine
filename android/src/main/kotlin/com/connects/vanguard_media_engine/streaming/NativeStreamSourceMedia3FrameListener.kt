package com.connects.vanguard_media_engine.streaming

import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.rtc.RtcVideoFrameDeliveryResult
import com.connects.vanguard_media_engine.rtc.RtcVideoFrameDeliveryStatus

/**
 * Diagnostic, video-only [HttpAdaptiveFrameListener] implementation that forwards decoded Media3
 * video frame metadata into the existing native C++ `StreamSourceNode` metadata session
 * (see `android_phase6_media3_ingest_stream_source_seam_jni.cpp`).
 *
 * ## Seam Boundary Invariants
 * - **Metadata Only**: Converts each [HttpAdaptiveDecodedFrame] to primitive metadata (width,
 *   height, ptsUs, frameIndex) before crossing into native; the native session never receives a
 *   jobject, [android.hardware.HardwareBuffer], JNI global reference, Surface, texture,
 *   Media3/ExoPlayer SDK object, or network state.
 * - **No Buffer Retention or Closure**: Never stores or closes
 *   [HttpAdaptiveDecodedFrame.hardwareBuffer]. Adheres strictly to the scoped-borrow contract of
 *   [HttpAdaptiveDecodedFrame].
 * - **Transport Neutral**: Proves the Media3 decoded-frame ingress boundary only: carries zero
 *   real ExoPlayer/MediaCodec/ImageReader ownership, network state, audio, or rendering
 *   dependency.
 * - **Idempotent Lifecycle**: [close] is safe to call more than once.
 *
 * @param streamId Non-blank stream identifier passed through to the native `StreamSourceNode`.
 * @param width Session-configured frame width in pixels (> 0). Ingested frames whose width differs
 *   are rejected as [RtcVideoFrameDeliveryStatus.UNSUPPORTED_FORMAT].
 * @param height Session-configured frame height in pixels (> 0). Same mismatch behavior as [width].
 * @param durationUs Native `StreamSourceNode` timeline duration in microseconds (> 0).
 * @param maxQueueCapacity Bounded native metadata queue capacity (must be in `[1, 32]`).
 */
class NativeStreamSourceMedia3FrameListener(
    streamId: String,
    width: Int,
    height: Int,
    durationUs: Long = DEFAULT_DURATION_US,
    maxQueueCapacity: Int = DEFAULT_MAX_QUEUE_CAPACITY,
) : HttpAdaptiveFrameListener, AutoCloseable {

    /** Opaque native session handle; non-zero on successful construction. */
    val handle: Long = VanguardNativeBridge.createStreamSourceMedia3IngestSession(
        streamId,
        width,
        height,
        durationUs,
        maxQueueCapacity,
    )

    init {
        check(handle != 0L) {
            "NativeStreamSourceMedia3FrameListener: native session creation failed for " +
                "streamId=$streamId, width=$width, height=$height, durationUs=$durationUs, " +
                "maxQueueCapacity=$maxQueueCapacity"
        }
    }

    @Volatile
    private var closed = false

    /**
     * Result of the most recent [onFrameAvailable] delivery attempt. [HttpAdaptiveFrameListener]'s
     * single abstract method returns `Unit` (it is invoked synchronously by the ImageReader
     * callback path), so this property is how callers/harnesses observe per-frame delivery status.
     */
    @Volatile
    var lastDeliveryResult: RtcVideoFrameDeliveryResult =
        RtcVideoFrameDeliveryResult.droppedNotReady("status=DROPPED_NOT_READY;reason=not_yet_ingested")
        private set

    /** Starts (or resumes) native ingest readiness. Idempotent. */
    fun start(): Map<String, Any?> {
        val raw = VanguardNativeBridge.startStreamSourceMedia3IngestSession(handle)
        return mapOf(
            "pass" to (extractField(raw, "status") == "ok"),
            "state" to extractField(raw, "state"),
            "raw" to raw,
        )
    }

    /** Pauses native ingest readiness; subsequent ingest calls drop as not-ready. Idempotent. */
    fun pause(): Map<String, Any?> {
        val raw = VanguardNativeBridge.pauseStreamSourceMedia3IngestSession(handle)
        return mapOf(
            "pass" to (extractField(raw, "status") == "ok"),
            "state" to extractField(raw, "state"),
            "raw" to raw,
        )
    }

    /**
     * Converts [frame] to primitive metadata and forwards it to the native session.
     * Never stores or closes [HttpAdaptiveDecodedFrame.hardwareBuffer].
     */
    override fun onFrameAvailable(frame: HttpAdaptiveDecodedFrame) {
        val raw = VanguardNativeBridge.ingestStreamSourceMedia3IngestMetadata(
            handle,
            frame.width,
            frame.height,
            frame.ptsUs,
            frame.frameIndex,
        )
        lastDeliveryResult = mapDeliveryResult(raw)
    }

    /** Drains up to [maxEntries] queued metadata entries FIFO, freeing native queue capacity. */
    fun drain(maxEntries: Int): Map<String, Any?> {
        val raw = VanguardNativeBridge.drainStreamSourceMedia3IngestSession(handle, maxEntries)
        return mapOf(
            "pass" to (extractField(raw, "status") == "ok"),
            "raw" to raw,
        )
    }

    /** Returns a diagnostic snapshot of native session state and counters. */
    fun snapshot(): Map<String, Any?> {
        val raw = VanguardNativeBridge.snapshotStreamSourceMedia3IngestSession(handle)
        return mapOf(
            "pass" to (extractField(raw, "status") == "ok"),
            "state" to extractField(raw, "state"),
            "raw" to raw,
        )
    }

    /** Destroys the native session. Safe to call more than once. */
    override fun close() {
        if (closed) return
        closed = true
        VanguardNativeBridge.destroyStreamSourceMedia3IngestSession(handle)
    }

    companion object {
        const val DEFAULT_DURATION_US: Long = 5_000_000L
        const val DEFAULT_MAX_QUEUE_CAPACITY: Int = 8

        /** Diagnostic proof-boundary marker mirrored by the native session's own snapshot output. */
        const val PROOF_BOUNDARY: String =
            "diagnostic_video_only_media3_ingest_seam_real_stream_source_node_metadata_queue_" +
                "no_media3_exoplayer_sdk_no_network_state_no_audio_no_rendering_" +
                "no_product_app_editor_wiring_no_hardware_buffer_ownership"

        /** Extracts the value for [key] from a native `;`-delimited `key=value` status string. */
        internal fun extractField(raw: String, key: String): String? {
            for (part in raw.split(";")) {
                val kv = part.split("=", limit = 2)
                if (kv.size == 2 && kv[0] == key) return kv[1]
            }
            return null
        }

        /** Maps a native ingest status string to a generic [RtcVideoFrameDeliveryResult]. */
        internal fun mapDeliveryResult(raw: String): RtcVideoFrameDeliveryResult {
            return when (extractField(raw, "status")) {
                "ACCEPTED" -> RtcVideoFrameDeliveryResult.accepted(raw)
                "DROPPED_BACKPRESSURE" -> RtcVideoFrameDeliveryResult.droppedBackpressure(raw)
                "DROPPED_NOT_READY" -> RtcVideoFrameDeliveryResult.droppedNotReady(raw)
                "UNSUPPORTED_FORMAT" -> RtcVideoFrameDeliveryResult.unsupportedFormat(
                    extractField(raw, "reason") ?: raw,
                )
                else -> RtcVideoFrameDeliveryResult.failed(raw)
            }
        }
    }
}
