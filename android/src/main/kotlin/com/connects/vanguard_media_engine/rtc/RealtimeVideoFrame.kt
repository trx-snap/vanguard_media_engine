package com.connects.vanguard_media_engine.rtc

import android.hardware.HardwareBuffer

/**
 * Immutable envelope for a single real-time video frame passed across RTC transport boundaries.
 *
 * ## Scoped-Borrow Semantics
 * The [hardwareBuffer] instance is provided under strict scoped-borrow semantics:
 * - The receiver / consumer must **not** retain a reference to [hardwareBuffer] after the synchronous callback returns.
 * - The receiver must **not** close [hardwareBuffer] directly; buffer lifecycle is owned by the producing pipeline.
 * - If the receiver requires GPU-resident or CPU-resident data beyond the synchronous delivery callback,
 *   it must synchronously import or copy the buffer into its own owned resource (e.g. GPU texture or native copy)
 *   **before** returning from the callback.
 *
 * ## Video-Only Domain Invariant
 * This contract operates strictly in the video domain. Vanguard True-DAG RTC contracts carry zero
 * room orchestration, signaling session, participant roster, network token, or audio stream semantics.
 * Audio capture, routing, mixing, and WebRTC audio tracks are exclusively managed outside Vanguard.
 *
 * @property hardwareBuffer GPU-accessible [HardwareBuffer] containing the frame pixels.
 * @property width Frame width in pixels (> 0).
 * @property height Frame height in pixels (> 0).
 * @property timestampNs Monotonic frame presentation timestamp in nanoseconds (>= 0).
 * @property rotationDegrees Display orientation adjustment in degrees (must be 0, 90, 180, or 270).
 * @property frameIndex Monotonically increasing frame sequence index (>= 0).
 * @property sourceId Identifier of the generating source/node (must not be blank).
 */
data class RealtimeVideoFrame(
    val hardwareBuffer: HardwareBuffer,
    val width: Int,
    val height: Int,
    val timestampNs: Long,
    val rotationDegrees: Int = 0,
    val frameIndex: Long = 0L,
    val sourceId: String = "vanguard",
) {
    init {
        require(width > 0) { "RealtimeVideoFrame: width must be positive, got $width" }
        require(height > 0) { "RealtimeVideoFrame: height must be positive, got $height" }
        require(timestampNs >= 0L) { "RealtimeVideoFrame: timestampNs must be non-negative, got $timestampNs" }
        require(rotationDegrees in VALID_ROTATION_DEGREES) {
            "RealtimeVideoFrame: rotationDegrees must be one of (0, 90, 180, 270), got $rotationDegrees"
        }
        require(frameIndex >= 0L) { "RealtimeVideoFrame: frameIndex must be non-negative, got $frameIndex" }
        require(sourceId.isNotBlank()) { "RealtimeVideoFrame: sourceId must not be blank" }
    }

    companion object {
        private val VALID_ROTATION_DEGREES = setOf(0, 90, 180, 270)
    }
}
