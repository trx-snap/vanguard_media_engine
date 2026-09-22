package com.connects.vanguard_media_engine.greenscreen

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

// -----------------------------------------------------------------------------
// Standalone Live Green Screen video background plate decoder (Slice 2).
// -----------------------------------------------------------------------------
//
// Self-contained, self-paced, looping local-file decoder for a standalone
// green-screen background plate. Deliberately independent of the Duet decode
// stack: AndroidDuetSourceVideoDecoder is clock-driven (an external session
// clock calls stepFrame(targetPtsMs) to scrub to an exact host-timeline
// position, and its output Surface is caller-owned/shared and never released
// by the decoder). A green-screen background plate has no host timeline to
// follow — it only needs to play continuously for as long as the session is
// active — so this decoder instead free-runs on its own HandlerThread at the
// source video's own frame rate and loops back to the start on end-of-stream.
//
// Surface ownership is also deliberately different from the Duet decoder: the
// [outputSurface]/[outputSurfaceTexture] pair passed in here is allocated by
// AndroidGreenScreenPreviewCompositor exclusively for this one decoder
// instance's private, single-use ingest (never shared or rebindable). This
// decoder therefore owns their teardown, so the compositor's render thread
// never has to block waiting for the decoder thread to drain before reusing
// GL state: on [release] the render thread only ever deletes the (separate)
// GL texture id and drops its own references immediately; this decoder
// releases the actual Surface/SurfaceTexture asynchronously, on its own
// thread, only after MediaCodec.stop() has guaranteed no further writes.
//
// Threading: [start] and [release] are both fire-and-forget from any thread
// (typically the render thread) and never block the caller — this decoder
// must never stall the render loop's ~30fps pacing, including when a
// mid-session background switch tears down the previous video plate while
// the render loop keeps pumping frames for the still-live camera layer.
class AndroidGreenScreenVideoBackgroundDecoder(
    private val filePath: String,
    private val outputSurface: Surface,
    private val outputSurfaceTexture: SurfaceTexture,
    /** Invoked (possibly more than once) on this decoder's own thread once the video's dimensions/rotation are known. */
    private val onFormatKnown: (widthPx: Int, heightPx: Int, rotationDegrees: Int) -> Unit,
    /** Invoked on this decoder's own thread at most once, only for a genuine decode failure (not a caller-initiated release). */
    private val onFatalError: (message: String) -> Unit,
) {

    companion object {
        private const val TAG = "GreenScreenBgVideoDecoder"
        private const val TIMEOUT_US = 10_000L

        /** Pacing sleep granularity, so [release] is noticed promptly instead of oversleeping one whole frame interval. */
        private const val SLEEP_CHUNK_MS = 20L
    }

    private val thread = HandlerThread("vg.greenscreen.bgvideo").apply { start() }
    private val handler = Handler(thread.looper)
    private val isReleased = AtomicBoolean(false)

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null

    /** Fire-and-forget: begins the decode loop on this decoder's own thread. Safe to call at most once. */
    fun start() {
        if (isReleased.get()) return
        handler.post {
            try {
                runDecodeLoop()
            } catch (t: Throwable) {
                if (!isReleased.get()) {
                    Log.w(TAG, "ANDROID_GREENSCREEN_BG_VIDEO_DECODE_FAILED path=$filePath error=${t.message}")
                    onFatalError(t.message ?: t.javaClass.simpleName)
                }
            } finally {
                teardown()
                thread.quitSafely()
            }
        }
    }

    /**
     * Non-blocking, idempotent. Flips the loop's exit flag (noticed within one
     * bounded dequeue/sleep chunk on the decoder thread) and separately posts
     * a guaranteed teardown + thread-quit task; never awaits either, so a
     * caller on the render thread never stalls waiting for this decoder to
     * actually stop.
     */
    fun release() {
        if (!isReleased.compareAndSet(false, true)) return
        try {
            handler.post {
                teardown()
                thread.quitSafely()
            }
        } catch (_: Throwable) {
            // Looper already gone; nothing left to post to.
        }
    }

    private fun runDecodeLoop() {
        val resolved = resolveFilePath(filePath)
        if (!File(resolved).isFile) throw IOException("Source file does not exist: $resolved")

        val ext = MediaExtractor()
        extractor = ext
        ext.setDataSource(resolved)

        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until ext.trackCount) {
            val candidate = ext.getTrackFormat(i)
            val mime = candidate.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) {
                trackIndex = i
                format = candidate
                break
            }
        }
        if (trackIndex < 0 || format == null) {
            throw IOException("Source file contains no video track: $resolved")
        }
        ext.selectTrack(trackIndex)

        var widthPx = format.getInteger(MediaFormat.KEY_WIDTH, 0).let { if (it > 0) it else 1 }
        var heightPx = format.getInteger(MediaFormat.KEY_HEIGHT, 0).let { if (it > 0) it else 1 }
        val rotationDegrees = normalizeRotation(format.getInteger(MediaFormat.KEY_ROTATION, 0))
        onFormatKnown(widthPx, heightPx, rotationDegrees)

        val mime = format.getString(MediaFormat.KEY_MIME)
            ?: throw IOException("Missing MIME type for video track.")
        val dec = MediaCodec.createDecoderByType(mime)
        codec = dec
        dec.configure(format, outputSurface, null, 0)
        dec.start()

        val bufferInfo = MediaCodec.BufferInfo()
        var inputEos = false
        var loopStartRealtimeMs = SystemClock.elapsedRealtime()
        var firstSamplePtsUs = -1L

        while (!isReleased.get()) {
            if (!inputEos) {
                val inIndex = dec.dequeueInputBuffer(TIMEOUT_US)
                if (inIndex >= 0) {
                    val inBuf = dec.getInputBuffer(inIndex)
                    if (inBuf != null) {
                        val sampleSize = ext.readSampleData(inBuf, 0)
                        if (sampleSize < 0) {
                            dec.queueInputBuffer(inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEos = true
                        } else {
                            val sampleTimeUs = ext.sampleTime
                            if (firstSamplePtsUs < 0L) firstSamplePtsUs = sampleTimeUs
                            dec.queueInputBuffer(inIndex, 0, sampleSize, sampleTimeUs, 0)
                            ext.advance()
                        }
                    }
                }
            }

            val outIndex = dec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
            when {
                outIndex >= 0 -> {
                    val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val hasFrame = bufferInfo.size > 0
                    if (hasFrame) {
                        paceToPresentationTime(bufferInfo.presentationTimeUs, firstSamplePtsUs, loopStartRealtimeMs)
                    }
                    dec.releaseOutputBuffer(outIndex, hasFrame)
                    if (isEos) {
                        if (isReleased.get()) break
                        // Loop continuously: rewind to the start and keep
                        // decoding on the same codec/extractor (no teardown/
                        // reconfigure), so playback never freezes at EOS.
                        dec.flush()
                        ext.seekTo(0L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                        inputEos = false
                        firstSamplePtsUs = -1L
                        loopStartRealtimeMs = SystemClock.elapsedRealtime()
                    }
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val newFmt = dec.outputFormat
                    widthPx = newFmt.getInteger(MediaFormat.KEY_WIDTH, widthPx)
                    heightPx = newFmt.getInteger(MediaFormat.KEY_HEIGHT, heightPx)
                    onFormatKnown(widthPx, heightPx, rotationDegrees)
                }
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    // Bounded timeout; loop and re-check isReleased.
                }
            }
        }
    }

    /**
     * Holds this (decoder) thread until [presentationTimeUs] has actually
     * elapsed since [loopStartRealtimeMs], so background playback runs at the
     * source's own frame rate instead of decoding as fast as the codec
     * allows. Sleeps in bounded [SLEEP_CHUNK_MS] chunks, re-checking
     * [isReleased] between each, so [release] is noticed promptly rather than
     * after a full wait. Runs only on this decoder's own thread — never the
     * render thread — so it never affects render loop pacing.
     */
    private fun paceToPresentationTime(presentationTimeUs: Long, firstSamplePtsUs: Long, loopStartRealtimeMs: Long) {
        val basePtsUs = firstSamplePtsUs.coerceAtLeast(0L)
        val targetElapsedMs = (presentationTimeUs - basePtsUs) / 1000L
        var remainingMs = targetElapsedMs - (SystemClock.elapsedRealtime() - loopStartRealtimeMs)
        while (remainingMs > 0 && !isReleased.get()) {
            val chunk = remainingMs.coerceAtMost(SLEEP_CHUNK_MS)
            try {
                Thread.sleep(chunk)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            }
            remainingMs -= chunk
        }
    }

    /** Idempotent, best-effort, never throws. Runs on this decoder's own thread only. */
    private fun teardown() {
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        codec = null
        try { extractor?.release() } catch (_: Throwable) {}
        extractor = null
        // codec.stop() above guarantees no further writes into outputSurface,
        // so it is safe for this decoder thread (never the render thread) to
        // release the Surface/SurfaceTexture it exclusively owned.
        try { outputSurface.release() } catch (_: Throwable) {}
        try { outputSurfaceTexture.setOnFrameAvailableListener(null) } catch (_: Throwable) {}
        try { outputSurfaceTexture.release() } catch (_: Throwable) {}
    }

    private fun normalizeRotation(degrees: Int): Int =
        when (((degrees % 360) + 360) % 360) {
            0 -> 0
            90 -> 90
            180 -> 180
            270 -> 270
            else -> 0
        }

    private fun resolveFilePath(path: String): String =
        if (path.startsWith("file://")) {
            try { java.net.URI(path).path ?: path } catch (_: Exception) { path }
        } else {
            path
        }
}
