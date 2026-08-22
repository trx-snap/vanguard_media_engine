// Copyright (c) Connects - Phase 4C1C: Decoded-frame value type for the headless ImageReader bridge.
// Kotlin-only slice. No native DAG render wiring, no public Dart APIs, no C++.

package com.connects.vanguard_media_engine.streaming

import android.hardware.HardwareBuffer

/**
 * Functional interface delivered to callers of the headless ImageReader bridge.
 *
 * The listener is always invoked **synchronously on the handler thread** supplied to
 * [HttpAdaptiveImageReaderBridge].  Implementations must be fast and non-blocking; they must
 * **not** retain or close [HttpAdaptiveDecodedFrame.hardwareBuffer] after the callback returns.
 *
 * @see HttpAdaptiveDecodedFrame for full scoped-borrow semantics.
 */
fun interface HttpAdaptiveFrameListener {
    /**
     * Called once per decoded video frame.
     *
     * [frame] is valid only for the duration of this call.  Do **not** store a reference to
     * [frame] or to [frame.hardwareBuffer] beyond this callback; the underlying [HardwareBuffer]
     * and [android.media.Image] are closed immediately after [onFrameAvailable] returns.
     */
    fun onFrameAvailable(frame: HttpAdaptiveDecodedFrame)
}

/**
 * Immutable snapshot of a single decoded video frame delivered by [HttpAdaptiveImageReaderBridge].
 *
 * ## Scoped-borrow semantics
 * [hardwareBuffer] is **only valid during the synchronous [HttpAdaptiveFrameListener.onFrameAvailable]
 * callback** in which this instance is delivered.  The bridge closes both the [HardwareBuffer] and
 * the underlying [android.media.Image] immediately after the callback returns.
 *
 * Consumers **must not**:
 * - Retain a reference to this object or to [hardwareBuffer] after the callback returns.
 * - Call [HardwareBuffer.close] on [hardwareBuffer] (the bridge owns the close).
 * - Access [hardwareBuffer] from another thread (it is already closed by the time any concurrent
 *   access could succeed).
 *
 * If the consumer needs GPU-resident data beyond the callback lifetime it must, within the
 * callback, wrap or import the [HardwareBuffer] into its own GPU resource (e.g. an
 * `EGLImage`) **before** returning.
 *
 * @property hardwareBuffer GPU-accessible buffer wrapping the decoded frame pixels.
 *                          Valid only during the enclosing [HttpAdaptiveFrameListener.onFrameAvailable] call.
 * @property ptsUs          Presentation timestamp in **microseconds**.  Derived from
 *                          [android.media.Image.getTimestamp] (nanoseconds / 1000).
 * @property width          Frame width in pixels, as reported at bridge creation / last resize.
 * @property height         Frame height in pixels, as reported at bridge creation / last resize.
 * @property frameIndex     Monotonically increasing frame counter (0-based) within this bridge
 *                          instance's lifetime.  Resets to 0 when a new bridge is created after a
 *                          resolution change.
 */
data class HttpAdaptiveDecodedFrame(
    val hardwareBuffer: HardwareBuffer,
    val ptsUs: Long,
    val width: Int,
    val height: Int,
    val frameIndex: Long,
)
