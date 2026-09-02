package com.connects.vanguard_media_engine.export

import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

// ── AndroidTimelineTransitionOverlapDecoder (P5-COMPOSITOR-TRANS production) ─
//
// Paired decode source for one compositor-owned clip overlap window of the
// production Vulkan export route (AndroidTimelineVulkanVideoEncoder). Owns
// exactly two independent decode pipelines -- the outgoing "from" clip's
// tail window and the incoming "to" clip's head window -- each a
// MediaExtractor + MediaCodec + ImageReader.PRIVATE
// (HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE) + HandlerThread, stepped in
// lockstep from the caller's thread: every [nextStep] yields at most one
// decoded frame per pipeline, in presentation order, restricted to that
// pipeline's [Source] window `[windowStartSeconds, windowEndSeconds)` (the
// same end-exclusive, pts-based membership rule the solo decode path uses
// for a clip's trim window, so a source frame belongs to exactly one export
// segment).
//
// Lifecycle / failure contract:
//   - [open] configures both pipelines; a failure in either closes whatever
//     was opened and reports a machine-readable reason. Never throws.
//   - [nextStep] blocks only on bounded waits (decoder dequeue timeouts, a
//     bounded no-output attempt budget, a bounded Image acquire timeout, a
//     bounded SyncFence wait on API 33+) and polls [isCancelled] on every
//     decode iteration, returning [Step.Cancelled] promptly. Never throws.
//   - Every [Frame] handed out owns its Image + HardwareBuffer and is
//     released exactly once: by the caller's [Frame.close], or by [close]
//     for any frame still outstanding. [close] is idempotent and releases,
//     per pipeline, in this order: queued Images, outstanding Frames, codec
//     stop/release, Surface release, ImageReader close, HandlerThread quit,
//     MediaExtractor release.
//   - Decoder KEY_ROTATION metadata is zeroed before configure (like the
//     solo path): the caller applies clip rotation through the native
//     render transform, so the ImageReader buffer is the unrotated decode.
//
// This class knows nothing about the encoder, muxer, native session or
// transition geometry; it only produces frame pairs.
class AndroidTimelineTransitionOverlapDecoder(
    private val fromSource: Source,
    private val toSource: Source,
    private val isCancelled: () -> Boolean,
) {
    /** One pipeline's clip + pts window + expected decoded extent. */
    data class Source(
        val label: String,
        val sourcePath: String,
        val windowStartSeconds: Double,
        val windowEndSeconds: Double,
        val decodedWidth: Int,
        val decodedHeight: Int,
    )

    /**
     * One decoded frame. [cropRect] / [bufferWidth] / [bufferHeight] are read
     * at acquisition so the caller can validate geometry before rendering.
     * [close] releases the HardwareBuffer, then the Image, exactly once.
     */
    class Frame internal constructor(
        val image: Image,
        val hardwareBuffer: HardwareBuffer,
        val presentationTimeUs: Long,
        private val onClosed: (Frame) -> Unit,
    ) {
        val cropRect: Rect = Rect(image.cropRect)
        val bufferWidth: Int = hardwareBuffer.width
        val bufferHeight: Int = hardwareBuffer.height
        private val closed = AtomicBoolean(false)

        fun close() {
            if (!closed.compareAndSet(false, true)) return
            try { hardwareBuffer.close() } catch (_: Throwable) {}
            try { image.close() } catch (_: Throwable) {}
            onClosed(this)
        }
    }

    sealed class Step {
        /** At least one of [from] / [to] is non-null; the caller must close both. */
        class Frames(val from: Frame?, val to: Frame?) : Step()

        /** Both windows are exhausted; no frames were produced by this call. */
        object Exhausted : Step()

        /** [isCancelled] observed true; no frames were produced by this call. */
        object Cancelled : Step()

        /** Decode failure (machine-readable [reason]); no frames outstanding from this call. */
        class Failed(val reason: String) : Step()
    }

    private val fromPipeline = Pipeline(fromSource)
    private val toPipeline = Pipeline(toSource)
    private val opened = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    /** Frames produced by each pipeline so far (diagnostics only). */
    val fromFramesProduced: Int get() = fromPipeline.framesProduced
    val toFramesProduced: Int get() = toPipeline.framesProduced

    /** Configures both pipelines. Returns null on success, else a reason; never throws. */
    fun open(): String? {
        if (closed.get()) return "decoder_closed"
        if (!opened.compareAndSet(false, true)) return "decoder_already_opened"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "api_below_29"
        val fromFailure = fromPipeline.open()
        if (fromFailure != null) {
            close()
            return "${fromSource.label}:$fromFailure"
        }
        val toFailure = toPipeline.open()
        if (toFailure != null) {
            close()
            return "${toSource.label}:$toFailure"
        }
        return null
    }

    /**
     * Steps both pipelines once. A pipeline whose window is exhausted yields
     * null for its side; when both are exhausted returns [Step.Exhausted].
     * Any frame acquired before a failure/cancel in the same call is closed
     * here, so a non-[Step.Frames] result never leaks a frame.
     */
    fun nextStep(): Step {
        if (closed.get()) return Step.Failed("decoder_closed")
        if (!opened.get()) return Step.Failed("decoder_not_opened")
        if (isCancelled()) return Step.Cancelled

        val fromFrame: Frame? = when (val outcome = fromPipeline.nextFrame()) {
            is Outcome.Produced -> outcome.frame
            is Outcome.Ended -> null
            is Outcome.Cancelled -> return Step.Cancelled
            is Outcome.Failed -> return Step.Failed("${fromSource.label}:${outcome.reason}")
        }
        val toFrame: Frame? = when (val outcome = toPipeline.nextFrame()) {
            is Outcome.Produced -> outcome.frame
            is Outcome.Ended -> null
            is Outcome.Cancelled -> {
                fromFrame?.close()
                return Step.Cancelled
            }
            is Outcome.Failed -> {
                fromFrame?.close()
                return Step.Failed("${toSource.label}:${outcome.reason}")
            }
        }
        if (fromFrame == null && toFrame == null) return Step.Exhausted
        return Step.Frames(fromFrame, toFrame)
    }

    /** Releases everything (both pipelines, any outstanding frames). Idempotent; never throws. */
    fun close() {
        if (!closed.compareAndSet(false, true)) return
        fromPipeline.close()
        toPipeline.close()
    }

    // ─────────────────────────────────────────────────────────────────────────

    private sealed class Outcome {
        class Produced(val frame: Frame) : Outcome()
        object Ended : Outcome()
        object Cancelled : Outcome()
        class Failed(val reason: String) : Outcome()
    }

    private inner class Pipeline(private val source: Source) {
        var framesProduced: Int = 0
            private set

        private val windowStartUs = (source.windowStartSeconds * 1_000_000L).toLong()
        private val windowEndUs = (source.windowEndSeconds * 1_000_000L).toLong()

        private var extractor: MediaExtractor? = null
        private var codec: MediaCodec? = null
        private var imageReader: ImageReader? = null
        private var surface: Surface? = null
        private var thread: HandlerThread? = null
        private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES + 2)
        private val outstanding = LinkedHashSet<Frame>()
        private var inputDone = false
        private var ended = false
        private val pipelineClosed = AtomicBoolean(false)

        fun open(): String? {
            if (source.sourcePath.isEmpty()) return "source_path_empty"
            if (source.decodedWidth <= 0 || source.decodedHeight <= 0) {
                return "decoded_dims_invalid:decodedW=${source.decodedWidth}:decodedH=${source.decodedHeight}"
            }
            if (!(windowEndUs > windowStartUs)) {
                return "window_empty:startUs=$windowStartUs:endUs=$windowEndUs"
            }
            try {
                val ex = MediaExtractor().also { extractor = it }
                ex.setDataSource(source.sourcePath)
                var trackIndex = -1
                var trackFormat: MediaFormat? = null
                for (i in 0 until ex.trackCount) {
                    val f = ex.getTrackFormat(i)
                    if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                        trackIndex = i
                        trackFormat = f
                        break
                    }
                }
                if (trackIndex < 0 || trackFormat == null) return "no_video_track"
                ex.selectTrack(trackIndex)
                if (windowStartUs > 0L) {
                    // Pre-roll from the sync sample at or before the window start.
                    // CLOSEST_SYNC may land on a sync sample at/after windowEndUs
                    // (typical for an outgoing tail window near the clip end), in
                    // which case feedInput() queues EOS immediately and the lane
                    // decodes zero frames. nextFrame() already drops every output
                    // with presentationTimeUs < windowStartUs, so pre-rolling from
                    // the previous sync only costs decode work, never wrong frames.
                    ex.seekTo(windowStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                }

                val ht = HandlerThread("VGVulkanTransition-${source.label}").also {
                    thread = it
                    it.start()
                }
                val reader = ImageReader.newInstance(
                    source.decodedWidth,
                    source.decodedHeight,
                    ImageFormat.PRIVATE,
                    IMAGE_READER_MAX_IMAGES,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                ).also { imageReader = it }
                reader.setOnImageAvailableListener(
                    { r ->
                        try {
                            val img = r.acquireNextImage()
                            if (img != null && !imageQueue.offer(img)) {
                                img.close()
                            }
                        } catch (_: Exception) {
                            // Listener callback -- nothing actionable beyond dropping the frame.
                        }
                    },
                    Handler(ht.looper),
                )
                surface = reader.surface

                val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
                val decodeFormat = MediaFormat(trackFormat)
                decodeFormat.setInteger(MediaFormat.KEY_ROTATION, 0)
                val dec = MediaCodec.createDecoderByType(mime).also { codec = it }
                dec.configure(decodeFormat, reader.surface, null, 0)
                dec.start()
                return null
            } catch (t: Throwable) {
                Log.e(TAG, "overlap pipeline open failed for ${source.label} (${source.sourcePath}): $t", t)
                return "open_exception:${t.javaClass.simpleName}"
            }
        }

        /**
         * Feeds input and drains output until one in-window frame's Image is
         * acquired, the window/stream ends, cancellation is observed, or a
         * bounded no-output budget is exhausted.
         */
        fun nextFrame(): Outcome {
            if (pipelineClosed.get()) return Outcome.Failed("pipeline_closed")
            if (ended) return Outcome.Ended
            val dec = codec ?: return Outcome.Failed("codec_missing")
            val info = MediaCodec.BufferInfo()
            var noOutputAttempts = 0
            while (true) {
                if (isCancelled()) return Outcome.Cancelled
                feedInput(dec)
                val outIdx = dec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                if (outIdx >= 0) {
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val hasData = info.size > 0
                    if (hasData && info.presentationTimeUs >= windowEndUs) {
                        // Output is in presentation order: the first frame at or
                        // beyond the window end closes this window for good.
                        dec.releaseOutputBuffer(outIdx, false)
                        ended = true
                        return Outcome.Ended
                    }
                    val renderable = hasData && info.presentationTimeUs >= windowStartUs
                    dec.releaseOutputBuffer(outIdx, renderable)
                    if (renderable) {
                        val image = imageQueue.poll(IMAGE_ACQUIRE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                            ?: return Outcome.Failed("image_acquire_timeout")
                        awaitFence(image)
                        val hwBuf = image.hardwareBuffer
                        if (hwBuf == null) {
                            try { image.close() } catch (_: Throwable) {}
                            return Outcome.Failed("hardware_buffer_null")
                        }
                        val frame = Frame(image, hwBuf, info.presentationTimeUs) { f ->
                            synchronized(outstanding) { outstanding.remove(f) }
                        }
                        synchronized(outstanding) { outstanding.add(frame) }
                        framesProduced++
                        if (isEos) ended = true
                        return Outcome.Produced(frame)
                    }
                    if (isEos) {
                        ended = true
                        return Outcome.Ended
                    }
                    noOutputAttempts = 0
                    continue
                }
                noOutputAttempts++
                if (noOutputAttempts >= MAX_NO_OUTPUT_ATTEMPTS) {
                    return Outcome.Failed("decoder_stalled:attempts=$noOutputAttempts")
                }
            }
        }

        private fun feedInput(dec: MediaCodec) {
            val ex = extractor ?: return
            while (!inputDone) {
                val inIdx = dec.dequeueInputBuffer(0)
                if (inIdx < 0) return
                val buf = dec.getInputBuffer(inIdx)
                if (buf == null) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                    return
                }
                val size = ex.readSampleData(buf, 0)
                if (size < 0 || ex.sampleTime > windowEndUs) {
                    dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    dec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0)
                    ex.advance()
                }
            }
        }

        private fun awaitFence(image: Image) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
            try {
                val fence = image.fence
                try {
                    if (fence.isValid) {
                        fence.await(java.time.Duration.ofMillis(FENCE_WAIT_TIMEOUT_MS))
                    }
                } catch (_: Exception) {
                    // Bounded best-effort wait -- rendering proceeds either way.
                } finally {
                    try { fence.close() } catch (_: Throwable) {}
                }
            } catch (_: Throwable) {
                // image.fence itself may throw on some devices; treat as no fence.
            }
        }

        fun close() {
            if (!pipelineClosed.compareAndSet(false, true)) return
            ended = true
            while (true) {
                val img = imageQueue.poll() ?: break
                try { img.close() } catch (_: Throwable) {}
            }
            val leaked: List<Frame> = synchronized(outstanding) { outstanding.toList() }
            for (frame in leaked) {
                // Frame.close is exactly-once and removes itself from [outstanding].
                frame.close()
            }
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            codec = null
            try { surface?.release() } catch (_: Throwable) {}
            surface = null
            try { imageReader?.close() } catch (_: Throwable) {}
            imageReader = null
            try { thread?.quitSafely() } catch (_: Throwable) {}
            thread = null
            try { extractor?.release() } catch (_: Throwable) {}
            extractor = null
        }
    }

    companion object {
        private const val TAG = "VGTimelineTransitionDec"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val IMAGE_ACQUIRE_TIMEOUT_MS = 2_000L
        private const val FENCE_WAIT_TIMEOUT_MS = 1_000L
        private const val IMAGE_READER_MAX_IMAGES = 3

        /** Bounded no-output budget per [nextFrame] call (~4 s at [DEQUEUE_TIMEOUT_US]). */
        private const val MAX_NO_OUTPUT_ATTEMPTS = 400
    }
}
