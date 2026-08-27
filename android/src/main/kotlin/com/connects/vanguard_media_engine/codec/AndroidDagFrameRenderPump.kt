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
    ): AndroidDagFrameRenderPumpResult {
        var localInputDone = inputDone
        var localOutputDone = outputDone
        var localRenderedFrames = renderedFrames
        var localLastRenderedPtsUs = lastRenderedPtsUs
        var localFrameRenderError: String? = null

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

        // Render at most ONE frame per call
        val image: Image? = imageQueue.poll()
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
        )
    }
}
