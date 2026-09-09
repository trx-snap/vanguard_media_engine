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
// VG-DUET-SLICE-4B-A: frame identity + output surface egress seam
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Result of a single [AndroidDuetFrameProvider.stepFrame] call.
 *
 * - [advancedToNewFrame]: at least one decoded output buffer was actually
 *   rendered to the current output sink during this step (including any
 *   internal seek the step performed). `false` means the sink still shows
 *   whatever frame it showed before the call.
 * - [presentationTimeMs]: presentation time of the most recently rendered frame
 *   (or the primed/seeked target when nothing has been rendered yet).
 * - [isEndOfStream]: the decoder has dequeued its output end-of-stream buffer
 *   (not merely run out of input); further steps forward will not render new
 *   frames until a seek or rebind clears the EOS state.
 */
data class AndroidDuetFrameStepResult(
    val advancedToNewFrame: Boolean,
    val presentationTimeMs: Long,
    val isEndOfStream: Boolean,
)

/**
 * Frame provider seam for Duet source video playback and composition.
 */
interface AndroidDuetFrameProvider {
    val lastPresentationTimeMs: Long
    val videoWidth: Int
    val videoHeight: Int
    val isEndOfStream: Boolean
    fun stepFrame(targetPtsMs: Long): AndroidDuetFrameStepResult
    fun seekTo(ptsMs: Long): Boolean
    fun release()
}

/**
 * Encapsulates MediaExtractor + MediaCodec decoding for Duet source video.
 *
 * Uses a pluggable [Surface] sink; defaults to an internal [ImageReader] / [HardwareBuffer]
 * for headless Slice 3 verification without requiring EGL or GLES.
 *
 * Surface ownership:
 * - A caller-supplied output [Surface] (via [prepare] or [rebindOutputSurface], or the
 *   legacy [customSurface] constructor fallback) is NEVER released by this decoder.
 *   The caller owns its lifetime and must keep it valid while it is bound.
 * - The headless [ImageReader] sink (used when no caller surface is supplied) is
 *   decoder-owned and closed on rebind/release.
 *
 * Enforces strict release ordering, bounded waits, and cancellation polling.
 * No camera, Camera2, GLES, Vulkan, SurfaceTexture, or compositor wiring.
 *
 * Threading: [prepare], [rebindOutputSurface], [stepFrame], [seekTo] and [release]
 * must all be called on the same background decoder HandlerThread.
 */
class AndroidDuetSourceVideoDecoder(
    private val filePath: String,
    private val customSurface: Surface? = null,
) : AndroidDuetFrameProvider {

    private val isReleased = AtomicBoolean(false)

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null

    /** Decoder-owned headless sink; closed on rebind/release. Null when a caller surface is bound. */
    private var imageReader: ImageReader? = null
    /** Whatever surface the codec is currently configured against (caller-owned or reader.surface). */
    private var sinkSurface: Surface? = null

    /** Selected video track format/MIME, retained so a rebind can reconfigure. */
    private var trackFormat: MediaFormat? = null
    private var trackMime: String? = null

    override var videoWidth: Int = 0
        private set
    override var videoHeight: Int = 0
        private set
    override var lastPresentationTimeMs: Long = 0L
        private set

    private var videoTrackIndex: Int = -1

    /**
     * Input-side EOS: the extractor ran dry and an EOS input buffer was queued to the codec.
     * After this no further input may be submitted until a flush/reconfigure, but the codec
     * may still hold undelivered output frames.
     */
    private var inputEosQueued: Boolean = false

    /** Output-side EOS: the codec's output EOS buffer has been dequeued. This is decoder EOS. */
    private var outputEosReached: Boolean = false

    override val isEndOfStream: Boolean
        get() = outputEosReached

    /** Set by [decodeToTarget] when it rendered at least one output buffer. */
    private var renderedOutputInLastDecode: Boolean = false

    /**
     * Initializes extractor and codec, primes the first frame at [trimStartMs].
     * Must be called on a background HandlerThread.
     *
     * @param outputSurface caller-owned sink. When non-null the decoder renders into it and
     *   never releases it. When null, falls back to the legacy [customSurface] constructor
     *   value, and if that is also null a decoder-owned headless [ImageReader] is used.
     */
    fun prepare(trimStartMs: Long, outputSurface: Surface? = null) {
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
        trackFormat = selectedFormat
        trackMime = mime

        // Pluggable sink: caller surface (explicit, then legacy constructor) or headless ImageReader.
        val surface = bindSink(outputSurface ?: customSurface)
        startCodec(mime, selectedFormat, surface)

        // Seek extractor to trimStart and prime first frame
        ext.seekTo(trimStartMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        lastPresentationTimeMs = trimStartMs

        // Prime the first frame
        decodeToTarget(trimStartMs * 1000L)
    }

    /**
     * Rebinds the decoder output to [surface] (caller-owned, never released here) or, when
     * null, to a fresh decoder-owned headless [ImageReader].
     *
     * Ordering:
     * 1. stop + release the current MediaCodec
     * 2. close the decoder-owned ImageReader (caller surfaces are only dereferenced);
     *    clear both EOS flags, since they described the codec that was just torn down
     * 3. create + configure + start a new MediaCodec against the new sink
     * 4. seek the extractor to [resumePtsMs] and prime (best effort)
     *
     * Returns `true` when the new codec is configured and started on the new sink.
     * Returns `false` (leaving no codec bound) when not prepared, already released,
     * [surface] is invalid, or codec creation fails. Priming not reaching [resumePtsMs]
     * within its bounded budget does not fail the rebind, matching [prepare].
     *
     * Must be called on the decoder HandlerThread. No GL / SurfaceTexture involvement.
     */
    fun rebindOutputSurface(surface: Surface?, resumePtsMs: Long): Boolean {
        // Nothing rendered yet for this call; cleared before any early return so a
        // subsequent stepFrame/seekTo cannot report a stale advancedToNewFrame.
        renderedOutputInLastDecode = false
        if (isReleased.get()) return false
        val ext = extractor ?: return false
        val format = trackFormat ?: return false
        val mime = trackMime ?: return false
        if (surface != null && !surface.isValid) return false

        // 1 + 2: tear down the current codec and any decoder-owned sink.
        stopAndReleaseCodec()
        closeOwnedSink()
        // Both EOS flags described the codec that was just torn down.
        inputEosQueued = false
        outputEosReached = false

        // 3: bind the new sink and bring up a fresh codec.
        try {
            val sink = bindSink(surface)
            startCodec(mime, format, sink)
        } catch (_: Exception) {
            stopAndReleaseCodec()
            closeOwnedSink()
            return false
        }

        // 4: seek, prime.
        try {
            ext.seekTo(resumePtsMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        } catch (_: Exception) {
            return false
        }
        lastPresentationTimeMs = resumePtsMs
        decodeToTarget(resumePtsMs * 1000L)
        return true
    }

    /**
     * Steps frame decoding on demand until [targetPtsMs].
     */
    override fun stepFrame(targetPtsMs: Long): AndroidDuetFrameStepResult {
        if (isReleased.get()) return stepResult(advanced = false)
        if (targetPtsMs < lastPresentationTimeMs) {
            seekTo(targetPtsMs)
            return stepResult(advanced = renderedOutputInLastDecode)
        }
        if (lastPresentationTimeMs >= targetPtsMs) {
            return stepResult(advanced = false)
        }
        val reached = decodeToTarget(targetPtsMs * 1000L)
        var advanced = renderedOutputInLastDecode
        if (!reached && !outputEosReached) {
            seekTo(targetPtsMs)
            advanced = advanced || renderedOutputInLastDecode
        }
        return stepResult(advanced = advanced)
    }

    /**
     * Flushes codec and seeks extractor to [ptsMs].
     */
    override fun seekTo(ptsMs: Long): Boolean {
        // Nothing rendered yet for this seek; cleared before any early return so
        // stepFrame's seek path cannot report a stale advancedToNewFrame.
        renderedOutputInLastDecode = false
        if (isReleased.get()) return false
        val ext = extractor ?: return false
        val dec = codec ?: return false

        try {
            dec.flush()
            // Flush discards queued input (including a queued EOS) and pending output.
            inputEosQueued = false
            outputEosReached = false
            ext.seekTo(ptsMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            return decodeToTarget(ptsMs * 1000L)
        } catch (_: Exception) {
            return false
        }
    }

    /**
     * Decodes frames until presentation time >= [targetPtsUs], with bounded loops and cancellation polling.
     * Sets [renderedOutputInLastDecode] when at least one non-empty output buffer was rendered.
     *
     * Once input EOS has been queued the loop stops feeding input but keeps draining output
     * until the target is reached, the output EOS buffer is dequeued, the iteration budget is
     * exhausted, or the decoder is released.
     */
    private fun decodeToTarget(targetPtsUs: Long): Boolean {
        renderedOutputInLastDecode = false
        val dec = codec ?: return false
        val ext = extractor ?: return false

        val bufferInfo = MediaCodec.BufferInfo()
        val timeoutUs = 10_000L // 10ms bounded wait
        var iterations = 0
        val maxIterations = 200 // bounded loop: at most 2 seconds total budget
        var reached = false

        while (!isReleased.get() && !reached && iterations < maxIterations && !outputEosReached) {
            iterations++

            // Feed input buffer. After EOS has been queued no further input may be submitted
            // until a flush/reconfigure; only output draining remains.
            if (!inputEosQueued) {
                val inIndex = dec.dequeueInputBuffer(timeoutUs)
                if (inIndex >= 0) {
                    val inBuf = dec.getInputBuffer(inIndex)
                    if (inBuf != null) {
                        val sampleSize = ext.readSampleData(inBuf, 0)
                        if (sampleSize < 0) {
                            dec.queueInputBuffer(inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEosQueued = true
                        } else {
                            val sampleTimeUs = ext.sampleTime
                            dec.queueInputBuffer(inIndex, 0, sampleSize, sampleTimeUs, 0)
                            ext.advance()
                        }
                    }
                }
            }

            // Dequeue output buffer
            val outIndex = dec.dequeueOutputBuffer(bufferInfo, timeoutUs)
            when {
                outIndex >= 0 -> {
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        outputEosReached = true
                    }
                    // Only a non-empty buffer carries a frame; an empty EOS marker renders nothing.
                    val hasFrame = bufferInfo.size > 0
                    if (hasFrame) {
                        lastPresentationTimeMs = bufferInfo.presentationTimeUs / 1000L
                    }
                    dec.releaseOutputBuffer(outIndex, hasFrame)
                    if (hasFrame) {
                        renderedOutputInLastDecode = true
                    }
                    if ((hasFrame && bufferInfo.presentationTimeUs >= targetPtsUs) || outputEosReached) {
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
     * 3. ImageReader close (if owned); caller surfaces are only dereferenced
     * 4. MediaExtractor release
     */
    override fun release() {
        if (!isReleased.compareAndSet(false, true)) return

        stopAndReleaseCodec()
        closeOwnedSink()

        try {
            extractor?.release()
        } catch (_: Exception) {}
        extractor = null
        trackFormat = null
        trackMime = null
    }

    // ── Sink / codec helpers ──────────────────────────────────────────────────

    /**
     * Binds the output sink: [external] when supplied (caller-owned), otherwise a new
     * decoder-owned headless [ImageReader]. Returns the surface to configure the codec with.
     */
    private fun bindSink(external: Surface?): Surface {
        if (external != null) {
            // Caller-owned: referenced only, never released by this decoder.
            imageReader = null
            sinkSurface = external
            return external
        }
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
        val surface = reader.surface
        sinkSurface = surface
        return surface
    }

    private fun startCodec(mime: String, format: MediaFormat, surface: Surface) {
        val dec = MediaCodec.createDecoderByType(mime)
        codec = dec
        dec.configure(format, surface, null, 0)
        dec.start()
    }

    private fun stopAndReleaseCodec() {
        try {
            codec?.stop()
        } catch (_: Exception) {}
        try {
            codec?.release()
        } catch (_: Exception) {}
        codec = null
    }

    /** Closes the decoder-owned ImageReader (if any) and drops all sink references. */
    private fun closeOwnedSink() {
        try {
            imageReader?.close()
        } catch (_: Exception) {}
        imageReader = null
        // A caller-owned sinkSurface is dereferenced only, never released.
        sinkSurface = null
    }

    private fun stepResult(advanced: Boolean): AndroidDuetFrameStepResult =
        AndroidDuetFrameStepResult(
            advancedToNewFrame = advanced,
            presentationTimeMs = lastPresentationTimeMs,
            // Output EOS only; a queued input EOS with undrained output is not decoder EOS.
            isEndOfStream = outputEosReached,
        )

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
