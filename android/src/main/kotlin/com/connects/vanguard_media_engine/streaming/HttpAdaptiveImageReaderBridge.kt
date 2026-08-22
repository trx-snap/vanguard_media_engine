// Copyright (c) Connects - Phase 4C1C: Headless ImageReader -> HardwareBuffer frame bridge.
// Kotlin-only slice. No native DAG render wiring, no Flutter SurfaceProducer, no C++.
// Native DAG render wiring is deferred to Phase 4C1D.

package com.connects.vanguard_media_engine.streaming

import android.hardware.HardwareBuffer
import android.graphics.ImageFormat
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.view.Surface
import androidx.annotation.RequiresApi
import java.time.Duration
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Headless Media3 decode surface bridge that routes decoded frames through an [ImageReader] and
 * delivers each frame's [HardwareBuffer] to a [HttpAdaptiveFrameListener] for GPU processing.
 *
 * ## API level gate
 * Construction requires **API 29 (Android 10 / Q)** or higher.  The caller must check
 * [android.os.Build.VERSION.SDK_INT] before construction, or use the factory helper:
 * ```kotlin
 * val bridge = HttpAdaptiveImageReaderBridge(width, height, handler, listener) // throws on < Q
 * ```
 *
 * ## Ownership
 * - This class owns the [ImageReader] and its internal [Surface].
 * - [surface] must be passed to `ExoPlayer.setVideoSurface(bridge.surface)`.
 * - The caller must **not** close [surface] directly; [release] does so via [ImageReader.close].
 *
 * ## Threading
 * - All [ImageReader.OnImageAvailableListener] callbacks execute on the [Handler] supplied at
 *   construction (typically the adapter's HandlerThread).
 * - [HttpAdaptiveFrameListener.onFrameAvailable] is therefore also called on that thread.
 * - [release] is safe to call from any thread and is idempotent.
 *
 * ## Frame lifecycle
 * Each [HardwareBuffer] is valid **only during the synchronous [HttpAdaptiveFrameListener.onFrameAvailable]
 * callback**.  After [onFrameAvailable] returns the bridge closes the [HardwareBuffer] and then
 * the [android.media.Image] in a `finally` block.  Consumers must not retain or close the buffer.
 *
 * @param width         Frame width in pixels. Must be positive.
 * @param height        Frame height in pixels. Must be positive.
 * @param handler       [Handler] on which [ImageReader] callbacks and [HttpAdaptiveFrameListener]
 *                      invocations are dispatched.
 * @param frameListener Called synchronously on [handler] for every acquired frame.
 *
 * @throws IllegalArgumentException if [width] or [height] is not positive.
 * @throws UnsupportedOperationException if the device is running below API 29.
 */
@RequiresApi(Build.VERSION_CODES.Q)
class HttpAdaptiveImageReaderBridge(
    val width: Int,
    val height: Int,
    handler: Handler,
    private val frameListener: HttpAdaptiveFrameListener,
) {

    init {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException(
                "HttpAdaptiveImageReaderBridge requires API ${Build.VERSION_CODES.Q} (Q/10); " +
                    "device is running API ${Build.VERSION.SDK_INT}."
            )
        }
        require(width > 0) { "width must be positive, got $width" }
        require(height > 0) { "height must be positive, got $height" }
    }

    // --- ImageReader ---------------------------------------------------------------------------

    /**
     * Internal [ImageReader] allocated with [ImageFormat.PRIVATE] so that the decoder can write
     * directly to GPU-backed buffers without an extra copy.  `maxImages = 3` provides a small
     * pipeline to absorb one-frame jitter.
     *
     * [HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE] allows the HardwareBuffer to be sampled by a GPU
     * shader (e.g. an EGLImage or a Vulkan texture) without any additional CPU mapping step.
     */
    private val reader: ImageReader = ImageReader.newInstance(
        width,
        height,
        ImageFormat.PRIVATE,
        /* maxImages = */ 3,
        /* usage = */ HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
    )

    /**
     * The [Surface] backed by this [ImageReader].  Pass this to
     * `ExoPlayer.setVideoSurface(bridge.surface)`.  Do **not** close this surface directly;
     * [release] handles cleanup via [ImageReader.close].
     */
    val surface: Surface get() = reader.surface

    // --- Frame counter ------------------------------------------------------------------------

    /** Monotonically increasing frame counter. 0-based within this bridge instance's lifetime. */
    private val frameCounter: AtomicLong = AtomicLong(0L)

    // --- Released guard -----------------------------------------------------------------------

    private val released: AtomicBoolean = AtomicBoolean(false)

    // --- ImageReader listener -----------------------------------------------------------------

    private val imageAvailableListener = ImageReader.OnImageAvailableListener { imageReader ->
        if (released.get()) return@OnImageAvailableListener

        // acquireLatestImage is preferred for real-time pipelines: it automatically drops stale
        // frames and prevents the image queue from exhausting due to a slow consumer.
        val image = imageReader.acquireLatestImage() ?: return@OnImageAvailableListener

        try {
            val hwBuf: HardwareBuffer = image.hardwareBuffer
                ?: run {
                    // No HardwareBuffer available; skip this frame.
                    // Do NOT close image here -- the outer finally block closes it exactly once.
                    return@OnImageAvailableListener
                }

            try {
                // On API 33+ await the sync fence so GPU writes are complete before handing the
                // buffer to the listener.  Invalid fences (isValid == false) are treated as
                // already signaled; await() returns true immediately for them.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val fence = image.fence
                    try {
                        fence.await(Duration.ofMillis(1000L))
                    } finally {
                        fence.close()
                    }
                }

                val index = frameCounter.getAndIncrement()
                val ptsUs = image.timestamp / 1_000L  // nanoseconds -> microseconds

                val frame = HttpAdaptiveDecodedFrame(
                    hardwareBuffer = hwBuf,
                    ptsUs = ptsUs,
                    width = width,
                    height = height,
                    frameIndex = index,
                )

                frameListener.onFrameAvailable(frame)
            } finally {
                // Always close the HardwareBuffer before closing the Image (bridge owns the close).
                hwBuf.close()
            }
        } finally {
            // Image.close() MUST be called to return the slot back to the ImageReader queue.
            image.close()
        }
    }

    init {
        // Register the listener on the caller-supplied handler (the adapter's HandlerThread).
        reader.setOnImageAvailableListener(imageAvailableListener, handler)
    }

    // --- Lifecycle ----------------------------------------------------------------------------

    /**
     * Releases the [ImageReader] (which also closes the internal [Surface]).  Idempotent.
     *
     * After [release] the [surface] reference is no longer valid.  The caller must call
     * `ExoPlayer.setVideoSurface(null)` **before** calling [release] to avoid writing frames
     * to a closed surface.
     *
     * Do **not** close [surface] separately; [ImageReader.close] owns the surface.
     */
    fun release() {
        if (!released.compareAndSet(false, true)) return
        // Unregister the listener so no further callbacks fire after close.
        reader.setOnImageAvailableListener(null, null)
        reader.close()
    }
}
