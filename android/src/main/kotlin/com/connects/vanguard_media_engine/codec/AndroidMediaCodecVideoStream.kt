package com.connects.vanguard_media_engine.codec

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Vanguard Android True-DAG P2-CONCURRENT-DEC: single hardware decode stream.
 *
 * Owns exactly one MediaExtractor + MediaCodec + ImageReader + Surface hardware
 * decode pipeline for a single video stream taking part in a Phase 2 concurrent-
 * decode coordinator run. Round-robin pumped externally by
 * [AndroidMultiStreamDecodeCoordinator] via [pumpOnce]; owns no rendering,
 * compositing, or presentation state -- this is decode-ingest validation only.
 *
 * [prepare] selects a hardware-accelerated decoder by name (never
 * [MediaCodec.createDecoderByType], which may resolve to a software codec) so a
 * missing hardware decoder fails closed instead of silently falling back to
 * software decode.
 */
class AndroidMediaCodecVideoStream(
    val sourceNodeId: String,
    private val videoPath: String,
    private val pool: AndroidConcurrentDecoderPool,
) {
    companion object {
        private const val TAG = "ConcurrentDecoderStream"
        private const val IMAGE_READER_MAX_IMAGES = 3

        // Frozen architecture: transient steady-state retry allowed at most 2
        // attempts and <=50ms total per stream pump.
        private const val RETRY_WAIT_MS = 50L
    }

    private val closed = AtomicBoolean(false)
    private val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES)

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var imageReader: ImageReader? = null
    private var surface: Surface? = null
    private var handlerThread: HandlerThread? = null

    var mime: String = ""
        private set
    var width: Int = 0
        private set
    var height: Int = 0
        private set
    var rotationDegrees: Int = 0
        private set

    var framesIngested: Int = 0
        private set
    var lastError: String? = null
        private set

    private var inputDone = false
    private var outputDone = false

    /** Runs source inspection + hardware decoder/ImageReader configure. Returns a failure reason, or null on success. */
    fun prepare(): String? {
        val inspection = AndroidDagSourceInspector().inspect(videoPath)
        if (!inspection.pass) {
            return "source_inspection_failed;reason=${inspection.failureReason}"
        }

        // Ownership transferred to this stream; close() always releases it,
        // regardless of which failure path below is taken.
        extractor = inspection.extractor!!
        mime = inspection.mime
        width = inspection.width
        height = inspection.height
        rotationDegrees = inspection.rotationDegrees

        val decoderName = selectHardwareDecoderName(mime)
            ?: return "no_hardware_decoder_available;mime=$mime"

        return try {
            val ht = HandlerThread("ConcurrentDecoderStream-$sourceNodeId").also {
                handlerThread = it
                it.start()
            }
            val h = Handler(ht.looper)

            val reader = ImageReader.newInstance(
                width,
                height,
                ImageFormat.PRIVATE,
                IMAGE_READER_MAX_IMAGES,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            ).also { imageReader = it }

            reader.setOnImageAvailableListener(
                { r ->
                    try {
                        val img = r.acquireNextImage()
                        if (img != null) {
                            if (!imageQueue.offer(img)) {
                                img.close()
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "acquireNextImage failed for $sourceNodeId: $e")
                    }
                },
                h,
            )

            surface = reader.surface

            val dec = MediaCodec.createByCodecName(decoderName).also { codec = it }
            dec.configure(inspection.format!!, reader.surface, null, 0)
            dec.start()
            null
        } catch (t: Throwable) {
            "codec_configure_failed;reason=${t.javaClass.simpleName}"
        }
    }

    /**
     * Feeds available input, drains available output, and attempts to ingest at
     * most one produced frame via [ingest]. Bounded retry for the asynchronously
     * delivered ImageReader callback: at most 2 poll attempts, <=[RETRY_WAIT_MS]ms
     * total wait, per the frozen per-stream-pump budget.
     */
    fun pumpOnce(ingest: (hardwareBuffer: HardwareBuffer, timelinePtsUs: Long, frameIndex: Int) -> String): PumpOutcome {
        if (closed.get()) return PumpOutcome.Failed("stream_closed")

        return try {
            while (!inputDone) {
                val inIdx = codec?.dequeueInputBuffer(0) ?: -1
                if (inIdx < 0) break
                val buf = codec?.getInputBuffer(inIdx) ?: break
                val sampleSize = extractor?.readSampleData(buf, 0) ?: -1
                if (sampleSize < 0) {
                    codec?.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    val pts = extractor?.sampleTime ?: 0L
                    codec?.queueInputBuffer(inIdx, 0, sampleSize, pts, 0)
                    extractor?.advance()
                }
            }

            while (!outputDone) {
                val info = MediaCodec.BufferInfo()
                val outIdx = codec?.dequeueOutputBuffer(info, 0) ?: -1
                if (outIdx < 0) break
                val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                val renderable = info.size > 0 && !isEos
                codec?.releaseOutputBuffer(outIdx, renderable)
                if (isEos) outputDone = true
            }

            // Attempt 1: non-blocking poll for an already-delivered image.
            var image = imageQueue.poll(0, TimeUnit.MILLISECONDS)
            if (image == null) {
                // Attempt 2: bounded wait for the ImageReader listener callback.
                image = imageQueue.poll(RETRY_WAIT_MS, TimeUnit.MILLISECONDS)
            }

            if (image == null) {
                return if (outputDone) PumpOutcome.Eos else PumpOutcome.NoImageAvailable
            }

            var hwBuf: HardwareBuffer? = null
            try {
                hwBuf = image.hardwareBuffer
                if (hwBuf == null) {
                    return PumpOutcome.Failed("hardware_buffer_null")
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val fence = image.fence
                    try {
                        if (fence.isValid) {
                            fence.await(java.time.Duration.ofMillis(1000))
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "SyncFence exception for $sourceNodeId: $e")
                    } finally {
                        try { fence.close() } catch (_: Throwable) {}
                    }
                }

                val statusRaw = ingest(hwBuf, image.timestamp / 1000, framesIngested)
                if (statusRaw.startsWith("status=PASS;")) {
                    framesIngested++
                    PumpOutcome.Ingested(statusRaw)
                } else {
                    lastError = statusRaw
                    PumpOutcome.Failed(statusRaw)
                }
            } finally {
                try { hwBuf?.close() } catch (_: Throwable) {}
                try { image.close() } catch (_: Throwable) {}
            }
        } catch (t: Throwable) {
            val reason = "pump_exception:${t.javaClass.simpleName}"
            lastError = reason
            PumpOutcome.Failed(reason)
        }
    }

    /**
     * Close order (frozen architecture): close queued Images/HardwareBuffers,
     * stop/release codec, release Surface, close ImageReader, release extractor,
     * release pool slot. Idempotent.
     */
    fun close() {
        if (!closed.compareAndSet(false, true)) return

        while (true) {
            val img = imageQueue.poll() ?: break
            try { img.close() } catch (_: Throwable) {}
        }

        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}

        try { surface?.release() } catch (_: Throwable) {}
        try { imageReader?.close() } catch (_: Throwable) {}
        try { extractor?.release() } catch (_: Throwable) {}

        try { handlerThread?.quitSafely() } catch (_: Throwable) {}

        pool.releaseSlot()
    }

    private fun selectHardwareDecoderName(mime: String): String? {
        return try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            list.codecInfos.firstOrNull { info ->
                !info.isEncoder &&
                    info.isHardwareAccelerated &&
                    info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }?.name
        } catch (t: Throwable) {
            Log.w(TAG, "selectHardwareDecoderName failed for mime=$mime: $t")
            null
        }
    }
}

/** Outcome of a single [AndroidMediaCodecVideoStream.pumpOnce] call. */
sealed class PumpOutcome {
    data class Ingested(val statusRaw: String) : PumpOutcome()
    object NoImageAvailable : PumpOutcome()
    object Eos : PumpOutcome()
    data class Failed(val reason: String) : PumpOutcome()
}
