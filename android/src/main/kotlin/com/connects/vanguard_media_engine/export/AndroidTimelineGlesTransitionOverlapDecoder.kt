package com.connects.vanguard_media_engine.export

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.view.Surface

// ── AndroidTimelineGlesTransitionDecodeSlot (P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A) ──
//
// Persistent per-side GLES decode target shared across every segment of one
// AndroidTimelineGlesTransitionVideoEncoder.encode() call -- created once
// (see [setup]), fed by every clip/segment decoded onto this side (a solo
// segment uses exactly one slot; an overlap segment uses two, one per side),
// and released once at the very end of the encode call. Mirrors
// AndroidTimelineVideoEncoder's single persistent OES decode texture /
// SurfaceTexture / frame-available wait mechanism, just duplicated per side
// so two decodes can be in flight at once during an overlap segment.
internal class AndroidTimelineGlesTransitionDecodeSlot {
    var oesTextureId = 0
        private set
    var inputSurface: Surface? = null
        private set
    private var surfaceTexture: SurfaceTexture? = null

    private val syncLock = Object()
    private var frameAvailable = false

    /** Refreshed by [awaitNewImage]; valid only after it returns true. */
    val transformMatrix = FloatArray(16)

    fun setup() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        oesTextureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val texture = SurfaceTexture(oesTextureId)
        texture.setOnFrameAvailableListener {
            synchronized(syncLock) {
                frameAvailable = true
                syncLock.notifyAll()
            }
        }
        surfaceTexture = texture
        inputSurface = Surface(texture)
    }

    /** Must be called before feeding a new decoder into [inputSurface]. */
    fun resetFrameAvailable() {
        synchronized(syncLock) { frameAvailable = false }
    }

    /**
     * Blocks until the decoder feeding [inputSurface] reports a new frame,
     * then updateTexImage()s and refreshes [transformMatrix]. Returns false
     * on timeout (a real failure, never faked).
     */
    fun awaitNewImage(timeoutMs: Long): Boolean {
        synchronized(syncLock) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (!frameAvailable) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0L) return false
                syncLock.wait(remaining)
            }
            frameAvailable = false
        }
        val texture = surfaceTexture ?: return false
        texture.updateTexImage()
        texture.getTransformMatrix(transformMatrix)
        return true
    }

    fun release() {
        try { inputSurface?.release() } catch (_: Throwable) {}
        try { surfaceTexture?.release() } catch (_: Throwable) {}
        if (oesTextureId != 0) {
            try { GLES20.glDeleteTextures(1, intArrayOf(oesTextureId), 0) } catch (_: Throwable) {}
        }
        oesTextureId = 0
        surfaceTexture = null
        inputSurface = null
    }
}

// ── AndroidTimelineGlesTransitionOverlapDecoder (P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A) ──
//
// GLES analogue of AndroidTimelineTransitionOverlapDecoder (the Vulkan
// production route's dual-decoder helper): owns one or two independent
// MediaExtractor+MediaCodec decode pipelines, each targeting its own
// caller-owned [AndroidTimelineGlesTransitionDecodeSlot] (a SurfaceTexture-
// backed GL_TEXTURE_EXTERNAL_OES target) instead of an ImageReader/
// HardwareBuffer -- there is no AHardwareBuffer import on this route; frames
// are transferred to GL purely via SurfaceTexture.updateTexImage(),
// mirroring AndroidGlesDualOesTransitionSmokeHarness's proven dual-OES
// pattern.
//
// [toSource] is nullable: passing null degenerates this into a single-side
// decoder (used for AndroidTimelineExportSegment.Solo segments), so both
// solo and overlap segments share exactly one stepping/lifecycle
// implementation -- [nextStep] simply always reports the "to" side as
// exhausted from the start when there is no [toSource].
//
// Steps both pipelines in lockstep, one decode pull per side per [nextStep]
// call (never free-running threads); a side whose window is exhausted yields
// a null [Step.Frames] slot going forward, matching the Vulkan sibling's
// unpaired-edge-frame tolerance -- see AndroidTimelineTransitionOverlapDecoder's
// own class doc for why this is correct (decoder timing jitter, not a real
// mismatch): if one window ends a frame earlier than the other, the
// remaining unpaired frames on the longer side are still reported (as a
// [Step.Frames] with only one non-null slot) so no source frame is silently
// dropped -- the caller renders those solo through its own plain OES draw
// path.
//
// This class owns each pipeline's MediaExtractor/MediaCodec only; it does
// NOT create, own, or destroy either [AndroidTimelineGlesTransitionDecodeSlot]
// (its OES texture, SurfaceTexture, or input Surface) -- those are created
// once by the caller (AndroidTimelineGlesTransitionVideoEncoder) and reused
// across every segment for the whole encode() call.
internal class AndroidTimelineGlesTransitionOverlapDecoder(
    private val fromSource: Source,
    private val toSource: Source?,
    private val isCancelled: () -> Boolean,
) {
    data class Source(
        val label: String,
        val clip: AndroidTimelineVideoEncoder.ClipInput,
        val windowStartSeconds: Double,
        val windowEndSeconds: Double,
        val slot: AndroidTimelineGlesTransitionDecodeSlot,
    )

    /** Signals a fresh frame is now available in the owning [Source.slot]'s texture. */
    class Frame internal constructor(val presentationTimeUs: Long)

    sealed class Step {
        /** At least one of [from]/[to] is non-null; both null never occurs (see [Exhausted]). */
        class Frames(val from: Frame?, val to: Frame?) : Step()
        object Exhausted : Step()
        object Cancelled : Step()
        class Failed(val reason: String) : Step()
    }

    private var fromPipeline: Pipeline? = null
    private var toPipeline: Pipeline? = null
    private var fromExhausted = false
    private var toExhausted = false

    /** Opens the underlying decoder(s). Returns null on success, or a precise failure reason. */
    fun open(): String? {
        val from = Pipeline(fromSource)
        val fromError = from.open()
        if (fromError != null) return fromError
        fromPipeline = from

        val source = toSource
        if (source == null) {
            toExhausted = true
            return null
        }
        val to = Pipeline(source)
        val toError = to.open()
        if (toError != null) {
            from.close()
            fromPipeline = null
            return toError
        }
        toPipeline = to
        return null
    }

    /** Pulls one step from each still-active side. See the class doc for the pairing contract. */
    fun nextStep(): Step {
        if (isCancelled()) return Step.Cancelled
        if (fromExhausted && toExhausted) return Step.Exhausted

        val fromOutcome = if (!fromExhausted) fromPipeline!!.nextFrame() else Outcome.Ended
        if (fromOutcome is Outcome.Cancelled) return Step.Cancelled
        if (fromOutcome is Outcome.Failed) return Step.Failed(fromOutcome.reason)
        if (fromOutcome is Outcome.Ended) fromExhausted = true

        val toOutcome = if (!toExhausted) toPipeline!!.nextFrame() else Outcome.Ended
        if (toOutcome is Outcome.Cancelled) return Step.Cancelled
        if (toOutcome is Outcome.Failed) return Step.Failed(toOutcome.reason)
        if (toOutcome is Outcome.Ended) toExhausted = true

        val fromFrame = (fromOutcome as? Outcome.Produced)?.let { Frame(it.presentationTimeUs) }
        val toFrame = (toOutcome as? Outcome.Produced)?.let { Frame(it.presentationTimeUs) }

        if (fromFrame == null && toFrame == null) return Step.Exhausted
        return Step.Frames(fromFrame, toFrame)
    }

    fun close() {
        try { fromPipeline?.close() } catch (_: Throwable) {}
        try { toPipeline?.close() } catch (_: Throwable) {}
    }

    private sealed class Outcome {
        class Produced(val presentationTimeUs: Long) : Outcome()
        object Ended : Outcome()
        object Cancelled : Outcome()
        class Failed(val reason: String) : Outcome()
    }

    private inner class Pipeline(private val source: Source) {
        private val extractor = MediaExtractor()
        private var decoder: MediaCodec? = null
        private var inputDone = false
        private var stallAttempts = 0
        private val windowStartUs = (source.windowStartSeconds * 1_000_000L).toLong()
        private val windowEndUs = (source.windowEndSeconds * 1_000_000L).toLong()

        fun open(): String? {
            return try {
                extractor.setDataSource(source.clip.sourcePath)
                var trackIndex = -1
                var trackFormat: MediaFormat? = null
                for (i in 0 until extractor.trackCount) {
                    val f = extractor.getTrackFormat(i)
                    if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                        trackIndex = i
                        trackFormat = f
                        break
                    }
                }
                if (trackIndex < 0 || trackFormat == null) return "${source.label}:no_video_track"
                extractor.selectTrack(trackIndex)
                if (windowStartUs > 0L) {
                    extractor.seekTo(windowStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                }
                val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
                val dec = MediaCodec.createDecoderByType(mime)
                dec.configure(trackFormat, source.slot.inputSurface, null, 0)
                dec.start()
                decoder = dec
                null
            } catch (t: Throwable) {
                "${source.label}:open_exception:${t.javaClass.simpleName}"
            }
        }

        /** Pulls until an in-window frame is rendered+available, EOS/exhaustion, or failure. */
        fun nextFrame(): Outcome {
            val dec = decoder ?: return Outcome.Failed("${source.label}:decoder_not_open")
            val info = MediaCodec.BufferInfo()
            source.slot.resetFrameAvailable()
            try {
                while (true) {
                    if (isCancelled()) return Outcome.Cancelled
                    if (!inputDone) {
                        val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                        if (inIdx >= 0) {
                            val buf = dec.getInputBuffer(inIdx)!!
                            val size = extractor.readSampleData(buf, 0)
                            if (size < 0 || extractor.sampleTime > windowEndUs) {
                                dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                dec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val outIdx = dec.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                    if (outIdx >= 0) {
                        stallAttempts = 0
                        val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        if (info.size > 0) {
                            val inWindow = info.presentationTimeUs >= windowStartUs &&
                                info.presentationTimeUs < windowEndUs
                            if (inWindow) {
                                dec.releaseOutputBuffer(outIdx, true)
                                if (!source.slot.awaitNewImage(FRAME_WAIT_TIMEOUT_MS)) {
                                    return Outcome.Failed("${source.label}:frame_transfer_timeout")
                                }
                                return Outcome.Produced(info.presentationTimeUs)
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                        } else {
                            dec.releaseOutputBuffer(outIdx, false)
                        }
                        if (isEos) return Outcome.Ended
                    } else if (outIdx == MediaCodec.INFO_TRY_AGAIN_LATER && inputDone) {
                        stallAttempts++
                        if (stallAttempts > MAX_STALL_ATTEMPTS) {
                            return Outcome.Failed("${source.label}:decoder_stalled")
                        }
                    }
                }
            } catch (t: Throwable) {
                return Outcome.Failed("${source.label}:decode_exception:${t.javaClass.simpleName}")
            }
        }

        fun close() {
            try { decoder?.stop() } catch (_: Throwable) {}
            try { decoder?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val FRAME_WAIT_TIMEOUT_MS = 2_000L

        /**
         * Bounded retry so a genuinely stalled decoder fails closed instead of
         * spinning forever -- 500 attempts at [DEQUEUE_TIMEOUT_US] each is a
         * ~5s ceiling, matching this route's other decode/drain deadlines.
         */
        private const val MAX_STALL_ATTEMPTS = 500
    }
}
