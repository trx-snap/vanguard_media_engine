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
)

/**
 * Stateless helper that performs one iteration of the feed/drain/render pipeline.
 *
 * Responsibilities:
 *  - Feed MediaCodec input buffers from MediaExtractor until stalled or EOS.
 *  - Drain MediaCodec output buffers to ImageReader until queue is warm or EOS.
 *  - Poll at most one Image from [imageQueue], wait SyncFence (API 33+), and render
 *    via [VanguardNativeBridge.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration].
 *  - Close HardwareBuffer, Image, and SyncFence exactly as the session loop did.
 *  - Return updated flags/counters/error - does NOT mutate session fields.
 *
 * Excluded: Choreographer scheduling, target-frame completion, pending callback
 * handling, state transitions, play/pause/seek/dispose, and surface lifecycle.
 */
class AndroidDagFrameRenderPump {

    companion object {
        private const val TAG = "DagFrameRenderPump"

        /** Tolerance for treating a slightly-early decoded frame as "due" for render. */
        const val DEFAULT_DUE_TOLERANCE_US = 2_000L

        /** Bound on how many stale queued images a single pumpOnce call may drop for catch-up. */
        const val DEFAULT_MAX_CATCH_UP_DROPS_PER_PUMP = 2
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
    ): AndroidDagFrameRenderPumpResult {
        var localInputDone = inputDone
        var localOutputDone = outputDone
        var localRenderedFrames = renderedFrames
        var localLastRenderedPtsUs = lastRenderedPtsUs
        var localFrameRenderError: String? = null
        var localRenderedFrame = false

        // Feed MediaCodec input buffers
        while (!localInputDone) {
            val inIdx = codec?.dequeueInputBuffer(0) ?: -1
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
            }
        }

        // Drain MediaCodec output buffers to ImageReader
        while (!localOutputDone && imageQueue.size < 2) {
            val info = MediaCodec.BufferInfo()
            val outIdx = codec?.dequeueOutputBuffer(info, 0) ?: -1
            if (outIdx < 0) break

            val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
            val renderable = info.size > 0 && !isEos
            codec?.releaseOutputBuffer(outIdx, renderable)

            if (isEos) {
                localOutputDone = true
            }
        }

        // Catch-up (continuous playback only, opt-in): drop a small bounded number of stale
        // queued images so a decode backlog doesn't keep preview permanently behind wall-clock.
        // Never touches a boundary-or-later frame (left for the playbackEnd drain below) and
        // always leaves at least one queued image behind for the normal render selection.
        if (allowCatchUpDrop && dueMediaPtsUs != null) {
            var catchUpDrops = 0
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

                        if (renderStr.startsWith("status=PASS;")) {
                            localRenderedFrames++
                            localRenderedFrame = true
                        } else {
                            Log.w(TAG, "renderFrame FAIL at index $localRenderedFrames: $renderStr")
                            localFrameRenderError = renderStr
                        }
                    }
                }
            } finally {
                try { hwBuf?.close() } catch (_: Throwable) {}
                try { image.close() } catch (_: Throwable) {}
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
        )
    }
}
