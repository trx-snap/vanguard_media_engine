package com.connects.vanguard_media_engine.codec

import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.os.Build
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Result of a seek/preroll decode-render operation.
 *
 * @property pass              True when a frame at or after [seekTargetUs] was successfully rendered.
 * @property generationId      The native generation id used for the render call.
 * @property renderedFrames    Updated cumulative rendered-frame count (input value + 1 on success).
 * @property lastRenderedPtsUs Updated last-rendered PTS (us); equals [seekRenderedPtsUs] on success.
 * @property seekRenderedPtsUs PTS (us) of the frame that was rendered; -1 if none was rendered.
 * @property failureReason     Non-null failure token when [pass] is false; null on success.
 */
data class AndroidDagSeekPrerollResult(
    val pass: Boolean,
    val generationId: Long,
    val renderedFrames: Int,
    val lastRenderedPtsUs: Long,
    val seekRenderedPtsUs: Long,
    val failureReason: String?,
)

/**
 * Vanguard Android True-DAG Phase 4B2B2A: Seek/preroll decode-render engine.
 *
 * Owns the dense preroll loop that was previously inlined inside
 * [AndroidDagTexturePlaybackControlSession.seek]. Callers supply all Android media
 * resources; this class has no mutable state of its own and is therefore
 * safe to call from any thread that already holds the session's HandlerThread context.
 */
class AndroidDagSeekPrerollEngine {

    companion object {
        private const val TAG = "DagSeekPrerollEngine"
        private const val SEEK_DEADLINE_MS = 8000L
        private const val IMAGE_POLL_DEADLINE_MS = 2000L
        private const val IMAGE_POLL_SLEEP_MS = 10L
        private const val IMAGE_POLL_TIMEOUT_MS = 20L
    }

    /**
     * Executes the seek preroll: decodes frames from [extractor]/[codec] starting at the
     * sync keyframe at or before [seekTargetUs], discards preroll frames without rendering,
     * then renders the first frame whose PTS ≥ [seekTargetUs] via [bridge].
     *
     * The caller is responsible for:
     * - Flushing [codec] before calling this method.
     * - Seeking [extractor] to [MediaExtractor.SEEK_TO_PREVIOUS_SYNC] before calling this method.
     * - Bumping the native generation before calling this method and passing the resulting
     *   [currentGenerationId].
     *
     * @param extractor           Prepared, track-selected, and already-seeked [MediaExtractor].
     * @param codec               Flushed and running [MediaCodec] decoder.
     * @param imageReader         [ImageReader] whose surface is the codec's output surface.
     * @param imageQueue          Shared queue populated by the [ImageReader.OnImageAvailableListener].
     * @param bridge              [VanguardNativeBridge] used to invoke the render JNI call.
     * @param sessionId           Native session identifier.
     * @param videoWidth          Frame width in pixels.
     * @param videoHeight         Frame height in pixels.
     * @param seekTargetUs        Target presentation timestamp in microseconds.
     * @param currentGenerationId Current native generation id (after caller's bump).
     * @param renderedFramesBefore Cumulative rendered-frame count before this seek.
     * @param deadlineMs          Wall-clock deadline (System.currentTimeMillis()) for the loop.
     *                            Pass [System.currentTimeMillis] + [SEEK_DEADLINE_MS] or custom.
     * @param shouldCancel        Optional lambda checked at the top of each loop iteration.
     *                            When it returns `true` the loop exits immediately and
     *                            [AndroidDagSeekPrerollResult.failureReason] is set to
     *                            `"surface_lost"`. Defaults to `{ false }`.
     * @return [AndroidDagSeekPrerollResult] describing outcome.
     */
    fun run(
        extractor: MediaExtractor,
        codec: MediaCodec,
        imageReader: ImageReader,
        imageQueue: LinkedBlockingQueue<Image>,
        bridge: VanguardNativeBridge,
        sessionId: String,
        videoWidth: Int,
        videoHeight: Int,
        displayWidth: Int,
        displayHeight: Int,
        rotationDegrees: Int,
        seekTargetUs: Long,
        currentGenerationId: Long,
        renderedFramesBefore: Int,
        deadlineMs: Long,
        shouldCancel: () -> Boolean = { false },
    ): AndroidDagSeekPrerollResult {
        var inputDone = false
        var outputDone = false
        var seekRenderedPtsUs = -1L
        var seekSuccess = false
        var seekError: String? = null
        var renderedFrames = renderedFramesBefore
        var lastRenderedPtsUs = -1L

        while (System.currentTimeMillis() < deadlineMs && !seekSuccess && seekError == null) {
            // ── Cancellation check (e.g. surface lost during preroll) ─────────
            if (shouldCancel()) {
                seekError = "surface_lost"
                break
            }

            // ── Feed input ────────────────────────────────────────────────────
            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val buf = codec.getInputBuffer(inIdx)
                    if (buf != null) {
                        val sampleSize = extractor.readSampleData(buf, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(
                                inIdx,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            val pts = extractor.sampleTime
                            codec.queueInputBuffer(inIdx, 0, sampleSize, pts, 0)
                            extractor.advance()
                        }
                    }
                }
            }

            // ── Drain output ──────────────────────────────────────────────────
            val info = MediaCodec.BufferInfo()
            val outIdx = codec.dequeueOutputBuffer(info, 10_000)
            if (outIdx >= 0) {
                val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                val ptsUs = info.presentationTimeUs

                if (isEos) {
                    outputDone = true
                    codec.releaseOutputBuffer(outIdx, false)
                    if (!seekSuccess) {
                        seekError = "eos_reached_before_seek_target"
                    }
                    break
                }

                if (seekTargetUs > 0 && ptsUs < seekTargetUs) {
                    // Preroll frame: release without rendering to surface
                    codec.releaseOutputBuffer(outIdx, false)
                } else {
                    // Target frame reached: release with render=true to push to ImageReader
                    codec.releaseOutputBuffer(outIdx, true)

                    // ── Wait for ImageReader to produce the frame ─────────────
                    var image: Image? = null
                    val pollDeadline = System.currentTimeMillis() + IMAGE_POLL_DEADLINE_MS
                    while (System.currentTimeMillis() < pollDeadline && image == null) {
                        image = try {
                            imageReader.acquireLatestImage()
                                ?: imageReader.acquireNextImage()
                                ?: imageQueue.poll(IMAGE_POLL_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                        } catch (_: Throwable) {
                            imageQueue.poll(IMAGE_POLL_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                        }
                        if (image == null) {
                            try { Thread.sleep(IMAGE_POLL_SLEEP_MS) } catch (_: Throwable) {}
                        }
                    }

                    if (image == null) {
                        seekError = "image_reader_timeout_on_seek_frame"
                        break
                    }

                    var hwBuf: HardwareBuffer? = null
                    try {
                        hwBuf = image.hardwareBuffer
                        if (hwBuf == null) {
                            seekError = "hardware_buffer_null_on_seek"
                            break
                        }

                        // SyncFence wait (API >= 33)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            val fence = image.fence
                            try {
                                if (fence.isValid) {
                                    fence.await(java.time.Duration.ofMillis(1000))
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "SyncFence await exception on seek: $e")
                            } finally {
                                try { fence.close() } catch (_: Throwable) {}
                            }
                        }

                        val imgPtsUs = image.timestamp / 1000L
                        val framePts = if (imgPtsUs > 0) imgPtsUs else ptsUs

                        // Phase 4B2C: use display dimensions and rotationDegrees for render.
                        val renderStr = bridge.renderAndroidDagPhase4B1TexturePlaybackFrameForGeneration(
                            sessionId,
                            hwBuf,
                            displayWidth,
                            displayHeight,
                            framePts,
                            renderedFrames,
                            currentGenerationId,
                            rotationDegrees,
                            false,
                        )

                        if (renderStr.startsWith("status=PASS;")) {
                            renderedFrames++
                            lastRenderedPtsUs = framePts
                            seekRenderedPtsUs = framePts
                            seekSuccess = true
                        } else {
                            seekError = "render_failed_on_seek;$renderStr"
                        }
                    } finally {
                        try { hwBuf?.close() } catch (_: Throwable) {}
                        try { image.close() } catch (_: Throwable) {}
                    }
                    break
                }
            }
        }

        return if (seekSuccess) {
            AndroidDagSeekPrerollResult(
                pass = true,
                generationId = currentGenerationId,
                renderedFrames = renderedFrames,
                lastRenderedPtsUs = lastRenderedPtsUs,
                seekRenderedPtsUs = seekRenderedPtsUs,
                failureReason = null,
            )
        } else {
            AndroidDagSeekPrerollResult(
                pass = false,
                generationId = currentGenerationId,
                renderedFrames = renderedFrames,
                lastRenderedPtsUs = lastRenderedPtsUs,
                seekRenderedPtsUs = seekRenderedPtsUs,
                failureReason = seekError ?: "seek_timeout",
            )
        }
    }
}
