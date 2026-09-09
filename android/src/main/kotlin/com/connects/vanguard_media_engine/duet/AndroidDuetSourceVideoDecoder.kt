package com.connects.vanguard_media_engine.duet

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-SLICE-3: Android source video decoder & frame provider seam
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Frame provider seam for Duet source video playback and composition.
 */
interface AndroidDuetFrameProvider {
    val lastPresentationTimeMs: Long
    val videoWidth: Int
    val videoHeight: Int
    fun stepFrame(targetPtsMs: Long): Boolean
    fun seekTo(ptsMs: Long): Boolean
    fun release()
}

/**
 * Encapsulates MediaExtractor + MediaCodec decoding for Duet source video.
 *
 * Uses a pluggable [Surface] sink; defaults to an internal [ImageReader] / [HardwareBuffer]
 * for headless Slice 3 verification without requiring EGL or GLES.
 *
 * Enforces strict release ordering, bounded waits, and cancellation polling.
 * No camera, Camera2, GLES, Vulkan, or compositor wiring.
 */
class AndroidDuetSourceVideoDecoder(
    private val filePath: String,
    private val customSurface: Surface? = null,
) : AndroidDuetFrameProvider {

    private val isReleased = AtomicBoolean(false)

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var imageReader: ImageReader? = null
    private var sinkSurface: Surface? = null

    override var videoWidth: Int = 0
        private set
    override var videoHeight: Int = 0
        private set
    override var lastPresentationTimeMs: Long = 0L
        private set

    private var videoTrackIndex: Int = -1
    private var isEos: Boolean = false

    /**
     * Initializes extractor and codec, primes the first frame at [trimStartMs].
     * Must be called on a background HandlerThread.
     */
    fun prepare(trimStartMs: Long) {
        if (isReleased.get()) throw IllegalStateException("Decoder already released.")

        val resolvedPath = resolveFilePath(filePath)
        val file = File(resolvedPath)
        if (!file.exists()) {
            throw IOException("Source file does not exist: '$resolvedPath'")
        }

        val ext = MediaExtractor()
        extractor = ext
        ext.setDataSource(resolvedPath)

        var selectedTrack = -1
        var selectedFormat: MediaFormat? = null
        for (i in 0 until ext.trackCount) {
            val format = ext.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) {
                selectedTrack = i
                selectedFormat = format
                break
            }
        }

        if (selectedTrack < 0 || selectedFormat == null) {
            throw IOException("Source file contains no video track: '$resolvedPath'")
        }

        videoTrackIndex = selectedTrack
        ext.selectTrack(selectedTrack)

        videoWidth  = selectedFormat.getInteger(MediaFormat.KEY_WIDTH, 0)
        videoHeight = selectedFormat.getInteger(MediaFormat.KEY_HEIGHT, 0)
        if (videoWidth <= 0) videoWidth = 64
        if (videoHeight <= 0) videoHeight = 64

        val mime = selectedFormat.getString(MediaFormat.KEY_MIME)
            ?: throw IOException("Missing MIME type for video track.")

        // Pluggable sink: external surface or internal headless ImageReader
        val surface: Surface
        if (customSurface != null) {
            surface = customSurface
            sinkSurface = customSurface
        } else {
            val reader = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ImageReader.newInstance(
                    videoWidth,
                    videoHeight,
                    ImageFormat.PRIVATE,
                    2,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
                )
            } else {
                ImageReader.newInstance(
                    videoWidth,
                    videoHeight,
                    ImageFormat.PRIVATE,
                    2,
                )
            }
            reader.setOnImageAvailableListener({ r ->
                try {
                    val img = r.acquireLatestImage()
                    img?.close()
                } catch (_: Exception) {}
            }, null)
            imageReader = reader
            surface = reader.surface
            sinkSurface = surface
        }

        val dec = MediaCodec.createDecoderByType(mime)
        codec = dec
        dec.configure(selectedFormat, surface, null, 0)
        dec.start()

        // Seek extractor to trimStart and prime first frame
        ext.seekTo(trimStartMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        lastPresentationTimeMs = trimStartMs

        // Prime the first frame
        decodeToTarget(trimStartMs * 1000L)
    }

    /**
     * Steps frame decoding on demand until [targetPtsMs].
     */
    override fun stepFrame(targetPtsMs: Long): Boolean {
        if (isReleased.get()) return false
        if (targetPtsMs < lastPresentationTimeMs) {
            return seekTo(targetPtsMs)
        }
        if (lastPresentationTimeMs >= targetPtsMs) {
            return true
        }
        val reached = decodeToTarget(targetPtsMs * 1000L)
        if (!reached && !isEos) {
            return seekTo(targetPtsMs)
        }
        return reached
    }

    /**
     * Flushes codec and seeks extractor to [ptsMs].
     */
    override fun seekTo(ptsMs: Long): Boolean {
        if (isReleased.get()) return false
        val ext = extractor ?: return false
        val dec = codec ?: return false

        try {
            dec.flush()
            ext.seekTo(ptsMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            isEos = false
            return decodeToTarget(ptsMs * 1000L)
        } catch (_: Exception) {
            return false
        }
    }

    /**
     * Decodes frames until presentation time >= [targetPtsUs], with bounded loops and cancellation polling.
     */
    private fun decodeToTarget(targetPtsUs: Long): Boolean {
        val dec = codec ?: return false
        val ext = extractor ?: return false

        val bufferInfo = MediaCodec.BufferInfo()
        val timeoutUs = 10_000L // 10ms bounded wait
        var iterations = 0
        val maxIterations = 200 // bounded loop: at most 2 seconds total budget
        var reached = false

        while (!isReleased.get() && !reached && iterations < maxIterations && !isEos) {
            iterations++

            // Feed input buffer
            val inIndex = dec.dequeueInputBuffer(timeoutUs)
            if (inIndex >= 0) {
                val inBuf = dec.getInputBuffer(inIndex)
                if (inBuf != null) {
                    val sampleSize = ext.readSampleData(inBuf, 0)
                    if (sampleSize < 0) {
                        dec.queueInputBuffer(inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        isEos = true
                    } else {
                        val sampleTimeUs = ext.sampleTime
                        dec.queueInputBuffer(inIndex, 0, sampleSize, sampleTimeUs, 0)
                        ext.advance()
                    }
                }
            }

            // Dequeue output buffer
            val outIndex = dec.dequeueOutputBuffer(bufferInfo, timeoutUs)
            when {
                outIndex >= 0 -> {
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        isEos = true
                    }
                    val framePtsMs = bufferInfo.presentationTimeUs / 1000L
                    lastPresentationTimeMs = framePtsMs
                    dec.releaseOutputBuffer(outIndex, true)
                    if (bufferInfo.presentationTimeUs >= targetPtsUs || isEos) {
                        reached = true
                    }
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val newFmt = dec.outputFormat
                    videoWidth  = newFmt.getInteger(MediaFormat.KEY_WIDTH, videoWidth)
                    videoHeight = newFmt.getInteger(MediaFormat.KEY_HEIGHT, videoHeight)
                }
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    // bounded timeout, continue
                }
            }
        }
        return reached
    }

    /**
     * Strict release ordering:
     * 1. Cancellation flag
     * 2. MediaCodec stop and release
     * 3. ImageReader close (if owned)
     * 4. MediaExtractor release
     */
    override fun release() {
        if (!isReleased.compareAndSet(false, true)) return

        try {
            codec?.stop()
        } catch (_: Exception) {}
        try {
            codec?.release()
        } catch (_: Exception) {}
        codec = null

        try {
            imageReader?.close()
        } catch (_: Exception) {}
        imageReader = null
        sinkSurface = null

        try {
            extractor?.release()
        } catch (_: Exception) {}
        extractor = null
    }

    private fun resolveFilePath(path: String): String {
        return if (path.startsWith("file://")) {
            try {
                java.net.URI(path).path ?: path
            } catch (_: Exception) {
                path
            }
        } else {
            path
        }
    }
}
