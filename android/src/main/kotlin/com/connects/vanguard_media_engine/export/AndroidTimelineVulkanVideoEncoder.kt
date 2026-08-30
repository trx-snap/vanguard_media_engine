package com.connects.vanguard_media_engine.export

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.ceil
import kotlin.math.min

// ── AndroidTimelineVulkanVideoEncoder (Vulkan-first export, pass-1) ──────────
//
// Preferred/default [AndroidTimelineVideoPassEncoder] implementation, used by
// AndroidTimelineExportSession only when AndroidExportRenderBackendSelector
// resolves the Vulkan backend for its production safe scope: video-only
// clips, cardinal 0/90/180/270 rotation, positive requested output and
// decoded clip dimensions. Decoded clip dimensions need not match the
// requested output geometry: this class computes a per-clip
// aspect-preserving-fit destination rect (see [computeAspectFitRect]) that
// centers the clip's rotated display geometry within the fixed output
// surface, letterboxed/pillarboxed over black where the aspect ratios
// differ. AndroidTimelineExportSession falls back to
// AndroidTimelineVideoEncoder (GLES) whenever this class fails before
// pass-2/finalization and cancellation has not been requested -- this class
// itself never falls back; it only reports a distinct machine-readable
// failure reason and lets the caller decide.
//
// Frame path: MediaExtractor + MediaCodec decode -> ImageReader.PRIVATE
// (HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE, API 29+) -> native Vulkan session
// (VanguardNativeBridge.createAndroidTimelineVulkanExportSession /
// renderAndroidTimelineVulkanExportFrame / destroyAndroidTimelineVulkanExportSession),
// which renders the decoded HardwareBuffer directly into the MediaCodec
// encoder's own input Surface. No native/JNI code is added or altered here.
//
// PTS mechanism (must stay compatible with AndroidTimelineVideoEncoder's
// frozen fixed frame clock, since a mid-export fallback re-runs the same
// clips through the GLES encoder from sample 0): both the native-render
// timelinePtsUs and the muxed sample presentationTimeUs are
// `sampleIndex * frameDurationUs`, driven off this encoder's own
// [renderedFrames] / [writtenVideoSamples] counters respectively.
//
// Guardrails enforced upstream by AndroidExportRenderBackendSelector /
// AndroidTimelineExportSession (not here): video-only clips, cardinal
// 0/90/180/270 rotation, positive requested output and decoded clip
// dimensions. This class computes a per-clip aspect-preserving-fit
// destination rect (see [computeAspectFitRect]) and additionally verifies
// the *real* decoder HardwareBuffer/Image geometry before rendering every
// frame (Opus P1 guard) because real decoder buffers can be padded/cropped
// even when track metadata reports matching dimensions.
// When the crop is a valid, same-size, even-aligned slice of a padded
// buffer (e.g. bufW=1920:bufH=1088 with crop 0,0-1920,1080), the frame is
// still rendered via the native crop-aware render seam rather than
// rejected outright; only a genuinely invalid/unsupported crop or buffer
// geometry fails the frame.
class AndroidTimelineVulkanVideoEncoder(
    private val outputPath: String,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrateBps: Int,
    private val nativeBridge: VanguardNativeBridge,
) : AndroidTimelineVideoPassEncoder {

    @Volatile private var cancelRequested = false

    /** Signals the encode loop to stop feeding new frames. Thread-safe. */
    override fun cancel() {
        cancelRequested = true
    }

    private val frameDurationUs = 1_000_000L / fps.coerceAtLeast(1)

    // ─── MediaCodec / MediaMuxer / native session state ──────────────────────
    private var codec: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var videoTrackIndex = -1
    private var writtenVideoSamples = 0
    private var renderedFrames = 0
    private var nativeSessionId: String? = null

    // ─── Pass-1 sample-ratio progress ─────────────────────────────────────────
    private var totalExpectedSamples = 0
    private var onProgress: ((Double) -> Unit)? = null

    /// Encodes [clips] sequentially (hard-cut concatenation) into [outputPath]
    /// as a video-only MP4, using the native Vulkan export session for every
    /// frame. Returns a structured result; never throws.
    override fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        onProgress: ((Double) -> Unit)?,
    ): AndroidTimelineVideoEncoder.EncodeResult {
        this.onProgress = onProgress
        totalExpectedSamples = clips.sumOf { clip ->
            ceil((clip.trimEndSeconds - clip.trimStartSeconds) * fps).toInt().coerceAtLeast(1)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return failResult("api_below_29")
        }

        var succeeded = false
        var muxerStoppedCleanly = false
        var reason = "not_run"
        try {
            setupEncoderMuxerAndSession()

            for (clip in clips) {
                if (cancelRequested) break
                val failureReason = decodeClipIntoSession(clip)
                if (failureReason != null) {
                    if (cancelRequested) break
                    reason = failureReason
                    return failResult(reason)
                }
            }

            if (cancelRequested) {
                reason = "cancelled"
                return failResult(reason)
            }

            codec!!.signalEndOfInputStream()
            val eosObserved = drainEncoder(endOfStream = true, deadlineMs = ENCODE_EOS_DEADLINE_MS)
            if (!eosObserved) {
                reason = "encoder_eos_drain_timeout"
                return failResult(reason)
            }

            if (!muxerStarted || writtenVideoSamples <= 0) {
                reason = "no_video_samples_written"
                return failResult(reason)
            }

            if (renderedFrames <= 0 || writtenVideoSamples != renderedFrames) {
                reason = "vulkan_sample_count_mismatch:written=$writtenVideoSamples:rendered=$renderedFrames"
                return failResult(reason)
            }

            muxer!!.stop()
            muxerStoppedCleanly = true

            val outFile = File(outputPath)
            val outSize = if (outFile.exists()) outFile.length() else 0L
            if (outSize <= 0L) {
                reason = "output_file_empty_or_missing"
                return failResult(reason)
            }

            succeeded = true
            reason = "success"
            Log.i(
                TAG,
                "VG_VULKAN_ENCODE_RESULT status=success rendered=$renderedFrames " +
                    "written=$writtenVideoSamples outputSize=$outSize",
            )
            return AndroidTimelineVideoEncoder.EncodeResult(true, reason, writtenVideoSamples, outSize)
        } catch (t: Throwable) {
            reason = "exception:${t.javaClass.simpleName}"
            Log.e(TAG, "vulkan encode failed: $t", t)
            return failResult(reason)
        } finally {
            if (muxerStarted && !muxerStoppedCleanly) {
                try { muxer?.stop() } catch (_: Throwable) {}
            }
            releaseAll()
            if (!succeeded) {
                try {
                    val f = File(outputPath)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    private fun failResult(reason: String): AndroidTimelineVideoEncoder.EncodeResult {
        Log.w(
            TAG,
            "VG_VULKAN_ENCODE_RESULT status=fail reason=$reason rendered=$renderedFrames " +
                "written=$writtenVideoSamples",
        )
        return AndroidTimelineVideoEncoder.EncodeResult(false, reason, writtenVideoSamples, 0L)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupEncoderMuxerAndSession() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = enc.createInputSurface()
        enc.start()
        codec = enc
        encoderInputSurface = surface
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        val createResult = nativeBridge.createAndroidTimelineVulkanExportSession(surface, width, height)
        if (!createResult.startsWith("status=OK;")) {
            throw IllegalStateException("vulkan_session_create_failed:${createResult.take(120)}")
        }
        nativeSessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
            ?: throw IllegalStateException("vulkan_session_id_parse_failed")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Per-clip decode -> native Vulkan render -> encoder drain
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns null on success, or a machine-readable failure reason string
    /// for any non-cancel decode/render failure. Every rendered frame is
    /// checked against the Opus P1 real-buffer geometry guard (see
    /// [renderImageIntoSession]) -- a decoder can produce a differently
    /// padded/cropped HardwareBuffer from frame to frame even within one
    /// clip.
    private fun decodeClipIntoSession(clip: AndroidTimelineVideoEncoder.ClipInput): String? {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var imageReader: ImageReader? = null
        var thread: HandlerThread? = null
        val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES + 2)
        try {
            extractor.setDataSource(clip.sourcePath)
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
            if (trackIndex < 0 || trackFormat == null) return "clip_no_video_track:${clip.sourcePath}"
            extractor.selectTrack(trackIndex)

            // The decoder-buffer source extent is now the clip's own actual
            // decoded dimensions -- no exact/swapped-exact match against the
            // encoder's fixed output geometry is required. The rotation is
            // applied by the native render transform, not by decoder/vendor
            // metadata (see the KEY_ROTATION zeroing below); [rotationDegrees]
            // must still be cardinal, and decoded dimensions must be
            // positive, or this fails closed before an ImageReader is even
            // created.
            if (clip.decodedWidth <= 0 || clip.decodedHeight <= 0) {
                return "vulkan_decoded_dims_invalid:" +
                    "decodedW=${clip.decodedWidth}:decodedH=${clip.decodedHeight}"
            }
            if (clip.rotationDegrees != 0 && clip.rotationDegrees != 90 &&
                clip.rotationDegrees != 180 && clip.rotationDegrees != 270
            ) {
                return "vulkan_rotation_unsupported:${clip.rotationDegrees}"
            }
            val sourceWidth = clip.decodedWidth
            val sourceHeight = clip.decodedHeight

            // Per-clip aspect-preserving-fit destination rect within the
            // fixed output surface; letterboxed/pillarboxed over black where
            // this clip's rotated display aspect ratio differs from the
            // output's. Fails closed if the computed rect would be invalid
            // (should not happen given the positive-dimension checks above,
            // but validated defensively since this is the destination rect
            // that gates native rendering).
            val destFitRect = computeAspectFitRect(
                outputWidth = width,
                outputHeight = height,
                decodedWidth = clip.decodedWidth,
                decodedHeight = clip.decodedHeight,
                rotationDegrees = clip.rotationDegrees,
            ) ?: return "vulkan_dest_fit_rect_invalid:" +
                "decodedW=${clip.decodedWidth}:decodedH=${clip.decodedHeight}:" +
                "rotation=${clip.rotationDegrees}:outW=$width:outH=$height"

            val trimStartUs = (clip.trimStartSeconds * 1_000_000L).toLong()
            if (trimStartUs > 0L) {
                extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }
            val trimEndUs = (clip.trimEndSeconds * 1_000_000L).toLong()

            thread = HandlerThread("VGVulkanExportImageReader").also { it.start() }
            val handler = Handler(thread.looper)

            val reader = ImageReader.newInstance(
                sourceWidth,
                sourceHeight,
                ImageFormat.PRIVATE,
                IMAGE_READER_MAX_IMAGES,
                HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE,
            )
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
                handler,
            )
            imageReader = reader

            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            val dec = MediaCodec.createDecoderByType(mime)
            // Zero any decoder/vendor KEY_ROTATION metadata before configure --
            // this class applies clip.rotationDegrees explicitly via the native
            // render transform, so leaving track KEY_ROTATION intact would
            // double-rotate the ImageReader buffer.
            val decodeFormat = MediaFormat(trackFormat)
            decodeFormat.setInteger(MediaFormat.KEY_ROTATION, 0)
            dec.configure(decodeFormat, reader.surface, null, 0)
            dec.start()
            decoder = dec

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var renderedFramesInClip = 0

            while (true) {
                if (cancelRequested && !inputDone) {
                    val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIdx >= 0) {
                        dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    }
                } else if (!inputDone) {
                    val inIdx = dec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inIdx >= 0) {
                        val buf = dec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0 || extractor.sampleTime > trimEndUs) {
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
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (info.size > 0) {
                        // Trim window is [trimStartUs, trimEndUs) — decoded pre-roll
                        // needed for the sync seek, and any frame at/after trimEnd,
                        // must be dropped rather than rendered.
                        val inWindow = info.presentationTimeUs >= trimStartUs &&
                            info.presentationTimeUs < trimEndUs
                        if (inWindow) {
                            dec.releaseOutputBuffer(outIdx, true)
                            val image = imageQueue.poll(IMAGE_ACQUIRE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                                ?: return "vulkan_image_acquire_timeout:${clip.sourcePath}"
                            val frameFailure = renderImageIntoSession(
                                image,
                                clip.rotationDegrees,
                                sourceWidth,
                                sourceHeight,
                                destFitRect,
                                clip.colorMatrix,
                            )
                            if (frameFailure != null) return frameFailure
                            renderedFramesInClip++
                        } else {
                            dec.releaseOutputBuffer(outIdx, false)
                        }
                    } else {
                        dec.releaseOutputBuffer(outIdx, false)
                    }
                    if (isEos) break
                }
                if (cancelRequested && inputDone && outIdx == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    // Cancellation requested and no more input pending — stop waiting for
                    // a decoder drain that may never come from a codec we've EOS'd.
                    break
                }
            }

            if (renderedFramesInClip == 0 && !cancelRequested) {
                return "no_frames_in_trim_window:${clip.sourcePath}"
            }
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "decodeClipIntoSession failed for ${clip.sourcePath}: $t", t)
            return "clip_decode_exception:${t.javaClass.simpleName}:${clip.sourcePath}"
        } finally {
            while (true) {
                val img = imageQueue.poll() ?: break
                try { img.close() } catch (_: Throwable) {}
            }
            try { decoder?.stop() } catch (_: Throwable) {}
            try { decoder?.release() } catch (_: Throwable) {}
            try { imageReader?.close() } catch (_: Throwable) {}
            try { thread?.quitSafely() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    /// Renders one decoded [image] into the native Vulkan session, then
    /// drains the encoder for the corresponding muxed sample. Closes
    /// [image]'s HardwareBuffer, then [image] itself, before returning on
    /// every path. Returns a machine-readable failure reason, or null.
    ///
    /// [rotationDegrees] is the clip's rotation (already validated to a
    /// cardinal 0/90/180/270 value by [decodeClipIntoSession]'s per-clip
    /// check, but re-checked here per frame since this method fails closed
    /// independently of those upstream gates) -- passed into the native
    /// crop-aware render seam so the Vulkan render transform, not
    /// decoder/vendor metadata, applies the rotation. [expectedCropWidth]/
    /// [expectedCropHeight] are this clip's actual decoded source extent
    /// ([decodeClipIntoSession]'s sourceWidth/sourceHeight, i.e.
    /// clip.decodedWidth/decodedHeight directly, unswapped) -- the real
    /// decoder crop is validated against this source extent. [destFitRect]
    /// is the per-clip aspect-preserving-fit destination sub-rect within the
    /// fixed output surface, computed once by [decodeClipIntoSession] via
    /// [computeAspectFitRect] and passed through unchanged for every frame
    /// of this clip. [colorMatrix] (Phase 10) is the active clip's raw
    /// (un-normalized) 20-element colorMatrix, passed through unchanged to
    /// the native Vulkan render seam -- null means identity (no filter); see
    /// [VanguardNativeBridge.renderAndroidTimelineVulkanExportFrameCropped].
    ///
    /// Enforces the Opus P1 real-buffer geometry guard on every frame (not
    /// just a clip's first frame): real decoder HardwareBuffers can be
    /// padded larger than the display crop even when track metadata (and
    /// this encoder's own width/height) reports matching dimensions, and
    /// that padding can in principle vary frame to frame. A crop that is a
    /// valid, same-size, even-aligned slice of the (possibly padded) buffer
    /// is rendered via the native crop-aware seam; anything else fails
    /// closed without rendering partial output.
    private fun renderImageIntoSession(
        image: Image,
        rotationDegrees: Int,
        expectedCropWidth: Int,
        expectedCropHeight: Int,
        destFitRect: DestFitRect,
        colorMatrix: FloatArray?,
    ): String? {
        var hwBuf: HardwareBuffer? = null
        try {
            if (rotationDegrees != 0 && rotationDegrees != 90 &&
                rotationDegrees != 180 && rotationDegrees != 270
            ) {
                return "vulkan_rotation_unsupported:$rotationDegrees"
            }

            hwBuf = image.hardwareBuffer
                ?: return "vulkan_decoder_buffer_geometry_mismatch:hardware_buffer_null"

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
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
            }

            // Read the crop rect before the image (and its buffer) is closed.
            val cropRect = image.cropRect
            val bufW = hwBuf.width
            val bufH = hwBuf.height

            if (cropRect.left < 0 || cropRect.top < 0 ||
                cropRect.right <= cropRect.left || cropRect.bottom <= cropRect.top ||
                cropRect.right > bufW || cropRect.bottom > bufH
            ) {
                return "vulkan_decoder_buffer_geometry_mismatch:" +
                    "bufW=$bufW:bufH=$bufH:crop=$cropRect"
            }

            val cropWidth = cropRect.right - cropRect.left
            val cropHeight = cropRect.bottom - cropRect.top
            if (cropWidth != expectedCropWidth || cropHeight != expectedCropHeight) {
                return "vulkan_decoder_crop_unsupported:size_mismatch:" +
                    "bufW=$bufW:bufH=$bufH:crop=$cropRect:" +
                    "expectedW=$expectedCropWidth:expectedH=$expectedCropHeight"
            }

            if (cropRect.left % 2 != 0 || cropRect.top % 2 != 0 ||
                cropRect.right % 2 != 0 || cropRect.bottom % 2 != 0
            ) {
                return "vulkan_decoder_crop_unsupported:odd_crop_bounds:crop=$cropRect"
            }

            val timelinePtsUs = renderedFrames * frameDurationUs
            val renderStr = nativeBridge.renderAndroidTimelineVulkanExportFrameCropped(
                sessionId = nativeSessionId!!,
                hardwareBuffer = hwBuf,
                width = width,
                height = height,
                cropLeft = cropRect.left,
                cropTop = cropRect.top,
                cropRight = cropRect.right,
                cropBottom = cropRect.bottom,
                rotationDegrees = rotationDegrees,
                destFitX = destFitRect.x,
                destFitY = destFitRect.y,
                destFitWidth = destFitRect.width,
                destFitHeight = destFitRect.height,
                timelinePtsUs = timelinePtsUs,
                frameIndex = renderedFrames,
                colorMatrix = colorMatrix,
            )
            if (!renderStr.startsWith("status=OK;")) {
                return "vulkan_render_failed:${renderStr.take(120)}"
            }
            renderedFrames++
            drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
            return null
        } finally {
            try { hwBuf?.close() } catch (_: Throwable) {}
            try { image.close() } catch (_: Throwable) {}
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Aspect-preserving-fit destination rect geometry
    // ─────────────────────────────────────────────────────────────────────────

    /// Destination sub-rect, in output pixel coordinates, that a clip's
    /// rotated display geometry is scaled/centered into within the fixed
    /// output surface. Always non-empty ([width]/[height] >= 1) and fully
    /// within the output surface ([x]/[y] >= 0, x+width <= outputWidth,
    /// y+height <= outputHeight) when returned by [computeAspectFitRect].
    private data class DestFitRect(val x: Int, val y: Int, val width: Int, val height: Int)

    /// Computes this clip's aspect-preserving-fit destination rect: the
    /// clip's rotated display geometry (decoded width/height, swapped for
    /// 90/270 since a 90/270 rotation transposes width/height in display
    /// space) is scaled down uniformly (never up) to fit within
    /// [outputWidth]x[outputHeight], then centered. Returns null only if the
    /// inputs are non-positive/non-cardinal or the resulting rect would
    /// somehow fail its own bounds -- callers treat null as a hard failure.
    ///
    /// fitWidth/fitHeight are coerced to [1, output] and then nudged to the
    /// nearest even value where possible (never exceeding output, never
    /// below 1) to avoid one-pixel parity drift downstream; the destination
    /// origin is recomputed from the (possibly nudged) fit size so the rect
    /// stays centered. When the clip's rotated display size already exactly
    /// matches the output size (no scaling needed) and the output
    /// dimensions are themselves even, this naturally produces the full
    /// output rect (x=0, y=0, width=outputWidth, height=outputHeight).
    private fun computeAspectFitRect(
        outputWidth: Int,
        outputHeight: Int,
        decodedWidth: Int,
        decodedHeight: Int,
        rotationDegrees: Int,
    ): DestFitRect? {
        if (outputWidth <= 0 || outputHeight <= 0 || decodedWidth <= 0 || decodedHeight <= 0) {
            return null
        }
        val (displayWidth, displayHeight) = when (rotationDegrees) {
            0, 180 -> decodedWidth to decodedHeight
            90, 270 -> decodedHeight to decodedWidth
            else -> return null
        }

        val scale = min(
            outputWidth.toDouble() / displayWidth.toDouble(),
            outputHeight.toDouble() / displayHeight.toDouble(),
        )
        var fitWidth = Math.round(displayWidth * scale).toInt().coerceIn(1, outputWidth)
        var fitHeight = Math.round(displayHeight * scale).toInt().coerceIn(1, outputHeight)
        fitWidth = forceEvenWherePossible(fitWidth, outputWidth)
        fitHeight = forceEvenWherePossible(fitHeight, outputHeight)

        val fitX = (outputWidth - fitWidth) / 2
        val fitY = (outputHeight - fitHeight) / 2
        if (fitX < 0 || fitY < 0 || fitX + fitWidth > outputWidth || fitY + fitHeight > outputHeight) {
            return null
        }
        return DestFitRect(fitX, fitY, fitWidth, fitHeight)
    }

    /// Nudges [value] to the nearest even number without exceeding [maxValue]
    /// or dropping below 1. Prefers decrementing (always safe once value >=
    /// 2); falls back to incrementing only when decrementing would reach 0
    /// (i.e. value == 1); leaves [value] as its original odd value in the
    /// rare case where neither adjustment is possible without violating
    /// [1, maxValue] (e.g. value == maxValue == 1).
    private fun forceEvenWherePossible(value: Int, maxValue: Int): Int {
        if (value % 2 == 0) return value
        val decremented = value - 1
        if (decremented >= 1) return decremented
        val incremented = value + 1
        return if (incremented <= maxValue) incremented else value
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Encoder output drain (fixed frame clock — mirrors AndroidTimelineVideoEncoder)
    // ─────────────────────────────────────────────────────────────────────────

    /// Drains encoder output into the muxer. When [endOfStream] is true,
    /// returns whether the encoder's own EOS buffer was actually observed
    /// before [deadlineMs] elapsed. When [endOfStream] is false (per-frame
    /// drain), always returns true.
    private fun drainEncoder(endOfStream: Boolean, deadlineMs: Long): Boolean {
        val enc = codec!!
        val mx = muxer!!
        val info = MediaCodec.BufferInfo()
        val deadline = System.currentTimeMillis() + deadlineMs
        var draining = true
        var eosObserved = false
        while (draining) {
            if (endOfStream && System.currentTimeMillis() > deadline) break
            val outIdx = enc.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) draining = false
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (videoTrackIndex < 0) {
                        videoTrackIndex = mx.addTrack(enc.outputFormat)
                        mx.start()
                        muxerStarted = true
                    }
                }
                outIdx >= 0 -> {
                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    if (!isConfig && info.size > 0 && muxerStarted && videoTrackIndex >= 0) {
                        val buf = enc.getOutputBuffer(outIdx)
                        if (buf != null) {
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            // Frozen mechanism: fixed frame clock, matching
                            // AndroidTimelineVideoEncoder's drain.
                            info.presentationTimeUs = writtenVideoSamples * frameDurationUs
                            mx.writeSampleData(videoTrackIndex, buf, info)
                            writtenVideoSamples++
                            if (totalExpectedSamples > 0) {
                                onProgress?.invoke(min(writtenVideoSamples.toDouble() / totalExpectedSamples, 1.0))
                            }
                        }
                    }
                    enc.releaseOutputBuffer(outIdx, false)
                    if (isEos) {
                        eosObserved = true
                        draining = false
                    }
                }
            }
        }
        return !endOfStream || eosObserved
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Cleanup
    // ─────────────────────────────────────────────────────────────────────────

    /// Destroys the native Vulkan session before releasing the encoder's own
    /// surface/codec/muxer, per the required cleanup ordering.
    private fun releaseAll() {
        val sid = nativeSessionId
        if (sid != null) {
            try { nativeBridge.destroyAndroidTimelineVulkanExportSession(sid) } catch (_: Throwable) {}
        }
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        try { muxer?.release() } catch (_: Throwable) {}
        try { encoderInputSurface?.release() } catch (_: Throwable) {}
    }

    companion object {
        private const val TAG = "VGTimelineVulkanEnc"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val IMAGE_ACQUIRE_TIMEOUT_MS = 2_000L
        private const val FENCE_WAIT_TIMEOUT_MS = 1_000L
        private const val ENCODE_DRAIN_DEADLINE_MS = 2_000L
        private const val ENCODE_EOS_DEADLINE_MS = 5_000L
        private const val IMAGE_READER_MAX_IMAGES = 3
    }
}
