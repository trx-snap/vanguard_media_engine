package com.connects.vanguard_media_engine.codec

import android.hardware.HardwareBuffer
import android.media.Image
import android.media.MediaCodec
import android.media.MediaExtractor
import android.os.Build
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.util.concurrent.LinkedBlockingQueue

/**
 * Vanguard Android True-DAG Phase 4B2B3C: Frame Render Pump Core Extraction.
 *
 * Result of a single [AndroidDagFrameRenderPump.pumpOnce] call.
 * All fields reflect post-pump state; the session assigns them back to its own fields.
 */
data class AndroidDagFrameRenderPumpResult(
    val inputDone: Boolean,
    val outputDone: Boolean,
    val renderedFrames: Int,
    val lastRenderedPtsUs: Long,
    val frameRenderError: String?,
    /** True only when this pumpOnce call actually rendered a new frame (localRenderedFrames incremented). */
    val renderedFrame: Boolean,
    /**
     * True when the next decoded frame's PTS is at or beyond [AndroidDagFrameRenderPump.pumpOnce]'s
     * `sourceEndPtsUs` boundary. The frame is left queued (unrendered, unclosed) rather than
     * dropped, since the caller is expected to terminate/dispose shortly after this fires.
     */
    val playbackEndReached: Boolean = false,
    /**
     * Raw status string returned by the native generation-aware render call for the frame
     * rendered/attempted during this pumpOnce, on both pass and fail. Null when no render
     * attempt was made (e.g. no image was due/queued).
     */
    val nativeRenderStatus: String? = null,
    /**
     * Number of stale queued images this pumpOnce call closed for wall-clock catch-up
     * (continuous playback with `allowCatchUpDrop` only). Always 0 for proof callers.
     */
    val catchUpDroppedFrames: Int = 0,
)

/**
 * Stateless helper that performs one iteration of the feed/drain/render pipeline.
 *
 * Responsibilities:
 *  - Feed MediaCodec input buffers from MediaExtractor until stalled or EOS.
 *  - Drain MediaCodec output buffers to ImageReader until queue is warm or EOS.
 *  - Poll at most one Image from [imageQueue], wait SyncFence (API 33+), and render
 *    via [VanguardNativeBridge.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration].
 *  - Close HardwareBuffer, Image, and SyncFence exactly as the session loop did, unless
 *    the caller's `deferRenderedImageClose` seam takes ownership of the rendered Image
 *    (see [pumpOnce]); the HardwareBuffer wrapper is always closed by the pump.
 *  - Return updated flags/counters/error - does NOT mutate session fields.
 *
 * Excluded: Choreographer scheduling, target-frame completion, pending callback
 * handling, state transitions, play/pause/seek/dispose, and surface lifecycle.
 */
class AndroidDagFrameRenderPump {

    companion object {
        private const val TAG = "DagFrameRenderPump"

        /**
         * Tolerance for treating a slightly-early decoded frame as "due" for render.
         * Kept tight for target-frame-count proof callers, which need each pump call
         * to advance by exactly one decoded frame.
         */
        const val DEFAULT_DUE_TOLERANCE_US = 2_000L

        /**
         * Frame-pacing tolerance for continuous (non-proof) playback. Kept below half a
         * 30fps frame period (~33ms, so half is ~16.7ms) so frames are not treated as due
         * and submitted nearly half a frame early on high-refresh displays, while still
         * wide enough to absorb normal vsync/codec jitter without tipping into the
         * pathological late/drop behavior a too-tight tolerance produces.
         */
        const val CONTINUOUS_DUE_TOLERANCE_US = 8_000L

        /** Bound on how many stale queued images a single pumpOnce call may drop for catch-up. */
        const val DEFAULT_MAX_CATCH_UP_DROPS_PER_PUMP = 2

        /**
         * Bound on how many non-EOS input buffers a single pumpOnce call may feed to the
         * codec. Feeding an unbounded backlog of input buffers in one Choreographer tick
         * can stall the render-thread pump long enough to itself cause uneven render
         * intervals; a small per-tick cap spreads that feed work across ticks instead.
         */
        const val MAX_INPUT_BUFFERS_PER_PUMP = 2

        /**
         * Small bounded poll timeout for MediaCodec input/output dequeue calls. Zero-timeout
         * (pure poll) dequeues were returning immediately with nothing available far more often
         * than the codec actually needed to produce a buffer, starving decode throughput well
         * below real-time. A short bounded wait lets the codec catch up within the same pump
         * call without ever blocking the VSYNC thread for a meaningful fraction of a frame.
         */
        const val CODEC_DEQUEUE_TIMEOUT_US = 2_000L

        /** Status-string key under which the native PASS status reports the release sync fd. */
        private const val RELEASE_FENCE_FD_KEY = ";releaseFenceFd="

        /**
         * Extracts `releaseFenceFd=<fd>` from a native render status string; -1 when the
         * field is absent or unparsable (older native builds, or no fence exported).
         */
        fun parseReleaseFenceFd(nativeRenderStatus: String): Int {
            val idx = nativeRenderStatus.indexOf(RELEASE_FENCE_FD_KEY)
            if (idx < 0) return -1
            return nativeRenderStatus
                .substring(idx + RELEASE_FENCE_FD_KEY.length)
                .substringBefore(';')
                .toIntOrNull() ?: -1
        }
    }

    fun pumpOnce(
        extractor: MediaExtractor?,
        codec: MediaCodec?,
        imageQueue: LinkedBlockingQueue<Image>,
        bridge: VanguardNativeBridge?,
        sessionId: String?,
        videoWidth: Int,
        videoHeight: Int,
        displayWidth: Int,
        displayHeight: Int,
        rotationDegrees: Int,
        currentGenerationId: Long,
        inputDone: Boolean,
        outputDone: Boolean,
        renderedFrames: Int,
        lastRenderedPtsUs: Long,
        /** Media-clock PTS (us) up to which a decoded frame is considered due; null = no pacing gate. */
        dueMediaPtsUs: Long? = null,
        dueToleranceUs: Long = DEFAULT_DUE_TOLERANCE_US,
        /** Trim-end boundary (source PTS, us); frames at/after this are never rendered. Null = untrimmed. */
        sourceEndPtsUs: Long? = null,
        /**
         * Continuous-playback-only option: when true and decoded frames have fallen behind
         * [dueMediaPtsUs] by more than [dueToleranceUs], drop a bounded number of stale queued
         * images before rendering so preview can catch back up to wall-clock. Defaults to false
         * (existing behavior) so target-frame-count proof callers are unaffected.
         */
        allowCatchUpDrop: Boolean = false,
        maxCatchUpDropsPerPump: Int = DEFAULT_MAX_CATCH_UP_DROPS_PER_PUMP,
        /**
         * ImageReader.maxImages() the shared [imageQueue] is bounded by. Used to derive
         * [queueWarmTarget] instead of hardcoding the decoder-drain stop point.
         */
        imageReaderMaxImages: Int = 3,
        /**
         * Capacity of the caller's [imageQueue] instance. May be smaller than
         * [imageReaderMaxImages] so a fully-queued backlog of unrendered Images alone
         * cannot saturate the ImageReader pool; [queueWarmTarget] is clamped to this so
         * the decoder-drain loop never targets filling the queue past what it can hold.
         */
        imageQueueCapacity: Int = imageReaderMaxImages,
        /**
         * Count of rendered Images currently retained off-queue by an async release-fence
         * waiter (see [deferRenderedImageClose]). Each one still holds an ImageReader
         * acquisition slot until its GPU fence signals, so it must reduce how many *more*
         * images the decoder is allowed to queue up — otherwise the queued backlog plus the
         * retained rendered Images can together saturate `maxImages` and acquireNextImage()
         * starts throwing. Always 0 for target-frame-count proof callers, which never defer.
         */
        deferredRenderedImageCloseInFlight: Int = 0,
        /**
         * Continuous-playback-only seam for GPU-to-decoder release synchronization.
         *
         * Invoked synchronously on the pump thread immediately after a successful native
         * render, with the rendered [Image] and the native-reported release sync fd (>= 0).
         * Native retains ownership of that fd and closes it on the next render call for the
         * same session, so the fd number is only valid for the duration of the callback: a
         * callback that wants to wait on it must dup it before returning (for example via
         * `ParcelFileDescriptor.fromFd`). The callback must never close the reported fd.
         *
         * Return true to take ownership of the [Image]: the pump will NOT close it and the
         * callback is responsible for closing it once the fence signals (or on timeout).
         * Return false, or throw, to leave the Image with the pump, which then closes it
         * immediately. Not invoked when the render fails or when no fence was exported
         * (fd < 0); in both cases the pump closes the Image immediately.
         *
         * Defaults to null, preserving the immediate-close behavior proof callers rely on.
         */
        deferRenderedImageClose: ((Image, Int) -> Boolean)? = null,
    ): AndroidDagFrameRenderPumpResult {
        var localInputDone = inputDone
        var localOutputDone = outputDone
        var localRenderedFrames = renderedFrames
        var localLastRenderedPtsUs = lastRenderedPtsUs
        var localFrameRenderError: String? = null
        var localRenderedFrame = false
        var localNativeRenderStatus: String? = null

        // Stop feeding the ImageReader once the queue is warm, leaving at least one reader
        // slot free for in-flight acquisition rather than saturating maxImages. Rendered
        // Images retained off-queue by the release-fence waiter also occupy a slot, so they
        // are subtracted from the pool before deriving how many more may be queued.
        val retainedRenderedImages = deferredRenderedImageCloseInFlight.coerceAtLeast(0)
        val availableForQueue = imageReaderMaxImages - retainedRenderedImages
        val queueWarmTarget = (if (availableForQueue <= 1) {
            0
        } else {
            (availableForQueue - 1).coerceAtMost(imageReaderMaxImages - 1)
        }).coerceAtMost(imageQueueCapacity)
        if (queueWarmTarget == 0 && retainedRenderedImages > 0) {
            Log.w(TAG, "queue warm target clamped to 0: retainedRenderedImages=$retainedRenderedImages imageReaderMaxImages=$imageReaderMaxImages")
        }

        // Feed MediaCodec input buffers, capped at MAX_INPUT_BUFFERS_PER_PUMP non-EOS
        // buffers per pump call so a large decode backlog can't stall this Choreographer
        // tick; EOF is still always honored (queues EOS/sets localInputDone) even on the
        // iteration that reaches the cap, since the cap only gates starting another
        // iteration, not finishing the one already in progress.
        var queuedInputBuffers = 0
        while (!localInputDone && queuedInputBuffers < MAX_INPUT_BUFFERS_PER_PUMP) {
            val inIdx = codec?.dequeueInputBuffer(CODEC_DEQUEUE_TIMEOUT_US) ?: -1
            if (inIdx < 0) break
            val buf = codec?.getInputBuffer(inIdx)
            if (buf == null) break
            val sampleSize = extractor?.readSampleData(buf, 0) ?: -1
            if (sampleSize < 0) {
                codec?.queueInputBuffer(
                    inIdx,
                    0,
                    0,
                    0,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
                localInputDone = true
            } else {
                val pts = extractor?.sampleTime ?: 0L
                codec?.queueInputBuffer(inIdx, 0, sampleSize, pts, 0)
                extractor?.advance()
                queuedInputBuffers++
            }
        }

        // Drain MediaCodec output buffers to ImageReader. At most one renderable buffer is
        // released to the reader per pump call: the ImageReader.OnImageAvailableListener
        // callback that updates imageQueue.size runs asynchronously on its own thread, so a
        // loop gated only on imageQueue.size can race ahead and release several renderable
        // buffers before that size reflects any of them - overfilling ImageReader past
        // maxImages despite queueWarmTarget. Non-renderable buffers (EOS/zero-size) don't
        // consume a reader slot, so they keep draining without that cap.
        while (!localOutputDone && imageQueue.size < queueWarmTarget) {
            val info = MediaCodec.BufferInfo()
            val outIdx = codec?.dequeueOutputBuffer(info, CODEC_DEQUEUE_TIMEOUT_US) ?: -1
            if (outIdx < 0) break

            val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
            val renderable = info.size > 0 && !isEos
            codec?.releaseOutputBuffer(outIdx, renderable)

            if (isEos) {
                localOutputDone = true
            }
            if (renderable) break
        }

        // Catch-up (continuous playback only, opt-in): drop a small bounded number of stale
        // queued images so a decode backlog doesn't keep preview permanently behind wall-clock.
        // Never touches a boundary-or-later frame (left for the playbackEnd drain below) and
        // always leaves at least one queued image behind for the normal render selection.
        var catchUpDrops = 0
        if (allowCatchUpDrop && dueMediaPtsUs != null) {
            val staleThresholdUs = dueMediaPtsUs - dueToleranceUs
            while (catchUpDrops < maxCatchUpDropsPerPump && imageQueue.size > 1) {
                val front = imageQueue.peek() ?: break
                val frontPtsUs = front.timestamp / 1000L
                if (sourceEndPtsUs != null && frontPtsUs >= sourceEndPtsUs) break
                if (frontPtsUs >= staleThresholdUs) break
                val dropped = imageQueue.poll() ?: break
                try { dropped.close() } catch (_: Throwable) {}
                catchUpDrops++
            }
            if (catchUpDrops > 0) {
                Log.d(TAG, "catch-up: dropped $catchUpDrops stale frame(s) behind dueMediaPtsUs=$dueMediaPtsUs")
            }
        }

        // Render at most ONE frame per call, and only once its PTS is due per the playback clock.
        // Peek first so an early frame is left queued (not dropped) until its due time arrives.
        val peeked = imageQueue.peek()
        val peekedPtsUs = peeked?.timestamp?.div(1000L)
        val hitPlaybackEnd = peekedPtsUs != null && sourceEndPtsUs != null && peekedPtsUs >= sourceEndPtsUs
        val image: Image? = if (peeked != null && !hitPlaybackEnd &&
            (dueMediaPtsUs == null || peekedPtsUs!! <= dueMediaPtsUs + dueToleranceUs)
        ) {
            imageQueue.poll()
        } else {
            null
        }
        if (hitPlaybackEnd) {
            // Trim-end boundary reached: this pump owns every queued image at/after the
            // boundary (decode order is PTS-monotonic, so nothing behind the peeked frame
            // is before it) and must close/drain them here rather than leaving them queued
            // as normal playback state — the caller completes on playbackEndReached and
            // must never observe or render a boundary-or-later frame from this queue.
            while (true) {
                val queuedImage = imageQueue.poll() ?: break
                try { queuedImage.close() } catch (_: Throwable) {}
            }
        }
        if (image != null) {
            var hwBuf: HardwareBuffer? = null
            // Set only when deferRenderedImageClose accepted the rendered Image; the pump then
            // must not close it (the callback closes it after the release fence signals).
            var imageOwnedByCallback = false
            try {
                hwBuf = image.hardwareBuffer
                if (hwBuf != null) {
                    // SyncFence API >= 33 wait <= 1s
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val fence = image.fence
                        try {
                            if (fence.isValid) {
                                fence.await(java.time.Duration.ofMillis(1000))
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "SyncFence exception: $e")
                        } finally {
                            try { fence.close() } catch (_: Throwable) {}
                        }
                    }

                    val sid = sessionId
                    val nb = bridge
                    if (sid != null && nb != null) {
                        val ptsUs = image.timestamp / 1000L
                        localLastRenderedPtsUs = ptsUs
                        // Phase 4B2C: pass displayWidth/displayHeight and rotationDegrees.
                        val renderStr = nb.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
                            sid,
                            hwBuf,
                            displayWidth,
                            displayHeight,
                            ptsUs,
                            localRenderedFrames,
                            currentGenerationId,
                            rotationDegrees,
                            false,
                        )

                        localNativeRenderStatus = renderStr
                        if (renderStr.startsWith("status=PASS;")) {
                            localRenderedFrames++
                            localRenderedFrame = true
                            // Hand the Image to the caller's release-fence waiter when one is
                            // installed and native exported a fence. Any rejection or throw
                            // falls through to the immediate close in finally.
                            val deferClose = deferRenderedImageClose
                            if (deferClose != null) {
                                val releaseFenceFd = parseReleaseFenceFd(renderStr)
                                if (releaseFenceFd >= 0) {
                                    imageOwnedByCallback = try {
                                        deferClose(image, releaseFenceFd)
                                    } catch (t: Throwable) {
                                        Log.w(TAG, "deferRenderedImageClose threw; closing image immediately: $t")
                                        false
                                    }
                                }
                            }
                        } else {
                            Log.w(TAG, "renderFrame FAIL at index $localRenderedFrames: $renderStr")
                            localFrameRenderError = renderStr
                        }
                    }
                }
            } finally {
                // The HardwareBuffer wrapper is always closed here: native holds its own
                // reference to the underlying AHardwareBuffer until the frame retires, and
                // the Image (which keeps the decoder buffer out of MediaCodec's hands) is
                // closed here only when nobody deferred it.
                try { hwBuf?.close() } catch (_: Throwable) {}
                if (!imageOwnedByCallback) {
                    try { image.close() } catch (_: Throwable) {}
                }
            }
        }

        return AndroidDagFrameRenderPumpResult(
            inputDone = localInputDone,
            outputDone = localOutputDone,
            renderedFrames = localRenderedFrames,
            lastRenderedPtsUs = localLastRenderedPtsUs,
            frameRenderError = localFrameRenderError,
            renderedFrame = localRenderedFrame,
            playbackEndReached = hitPlaybackEnd,
            nativeRenderStatus = localNativeRenderStatus,
            catchUpDroppedFrames = catchUpDrops,
        )
    }
}
