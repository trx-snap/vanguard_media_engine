package com.connects.vanguard_media_engine.export

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
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
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
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
// pass-2/finalization and cancellation has not been requested -- for
// hard-cut timelines only; a transition timeline never falls back -- this
// class itself never falls back; it only reports a distinct machine-readable
// failure reason and lets the caller decide.
//
// Frame path: MediaExtractor + MediaCodec decode -> ImageReader.PRIVATE
// (HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE, API 29+) -> native Vulkan session
// (VanguardNativeBridge.createAndroidTimelineVulkanExportSession /
// renderAndroidTimelineVulkanExportFrame / destroyAndroidTimelineVulkanExportSession),
// which renders the decoded HardwareBuffer directly into the MediaCodec
// encoder's own input Surface.
//
// P5-COMPOSITOR-TRANS: the transition-aware [encode] overload is the only
// production route for compositor-owned clip overlap transitions. The clip
// list plus validated transitions are planned into an ordered segment list:
// per clip a solo segment over the clip's trim window minus the overlap
// windows it lends to its incoming/outgoing transitions, and per transition
// an overlap segment pairing the outgoing clip's tail window with the
// incoming clip's head window (AndroidTimelineTransitionOverlapDecoder),
// each pair rendered through
// VanguardNativeBridge.renderAndroidTimelineVulkanExportTransitionFrame at
// progress (j + 1) / (N + 1). Output is therefore overlap-shortened: the
// muxed duration is the clip-duration sum minus the transition durations.
//
// P5-OVERLAYS-TRANS Route-A N9 / P5-OVERLAYS-TRANSITION-COMP-N3: the
// overlay-aware [encode] overload prepares validated static sticker overlays
// (AndroidTimelineOverlayRenderSession.prepare) once the native session
// exists, then renders every SOLO frame through
// VanguardNativeBridge.renderAndroidTimelineVulkanExportFrameCroppedWithOverlays
// instead of the plain cropped seam. As of N3, overlays are ALSO composited
// on transition overlap frames -- [renderTransitionPair] routes through
// VanguardNativeBridge.renderAndroidTimelineVulkanExportTransitionFrameWithOverlays.
//
// P5-OVERLAYS-BEAUTY-TRANSITION-OVERLAP-ONLY / P5-OVERLAYS-BEAUTY-SOLO:
// clip-level Beauty V2 alongside overlays is rendered through that same
// transition-overlap overlay seam -- unlike the (pre-P5-OVERLAYS-BEAUTY-SOLO)
// solo overlay seam, it accepts per-layer Beauty V2 params and applies Beauty
// before overlay placement -- so [renderTransitionPair] now passes each
// layer's actual beautyIntensity through instead of forcing it off. A solo
// (non-transition-overlap) active overlay alongside clip-level Beauty V2 is
// ALSO a supported production shape: [renderSoloLayer] routes that frame
// through the combined
// VanguardNativeBridge.renderAndroidTimelineVulkanExportFrameCroppedWithOverlaysAndBeauty
// seam instead, which applies Beauty before overlay placement exactly like
// the transition-overlap seam.
//
// PTS mechanism (must stay compatible with AndroidTimelineVideoEncoder's
// frozen fixed frame clock, since a mid-export fallback re-runs the same
// clips through the GLES encoder from sample 0): both the native-render
// timelinePtsUs and the muxed sample presentationTimeUs are
// `sampleIndex * frameDurationUs`, driven off this encoder's own
// [renderedFrames] / [writtenVideoSamples] counters respectively. Solo and
// transition frames share those counters, so the success invariant
// writtenVideoSamples == renderedFrames holds for both shapes.
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
//
// P5-CLIP-STATIC-TRANSFORM-EXPORT-A: a clip carrying
// AndroidTimelineVideoEncoder.ClipInput.transform (uniform scale + output-
// pixel translation, validated upstream by AndroidTimelineExportSession) is
// rendered through the very same cropped seam: [computeLayerPlacement]
// derives -- via AndroidTimelineClipStaticTransformGeometry -- the
// even-aligned source crop INSIDE the decoded extent that maps onto the
// visible part of the scaled/panned clip, plus the matching destination
// rect INSIDE the output. The native seam requires an in-bounds destination
// rect, so cover/fill framing is never expressed as out-of-bounds
// destination geometry; it is always expressed as a source crop. The
// decoder-buffer guard above still runs unchanged on every frame; the
// clip's source crop is applied as an offset inside the guarded decoder
// crop. A null transform keeps the byte-identical full-extent crop +
// centered aspect-fit placement.
class AndroidTimelineVulkanVideoEncoder(
    private val outputPath: String,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrateBps: Int,
    private val nativeBridge: VanguardNativeBridge,
    // Android reference-video export: optional Context used ONLY to open a
    // `content://` ClipInput.sourcePath through the ContentResolver
    // (AndroidUriDataSourceHelper) -- in [decodeClipIntoSession] and, via
    // AndroidTimelineTransitionOverlapDecoder, in the transition overlap
    // pipelines. POSIX sources never touch it. A `content://` clip with a
    // null Context fails closed through the existing clip_decode_exception /
    // open_exception reasons; it never crashes the encode. Harness
    // constructors keep working unchanged via the default.
    private val context: Context? = null,
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
    private var beautyFramesRendered = 0
    private var nativeSessionId: String? = null

    // P5-OVERLAYS-TRANS Route-A N9 / P5-OVERLAYS-TRANSITION-COMP-N3: non-null
    // only when this encode call carries non-empty overlays and
    // AndroidTimelineOverlayRenderSession.prepare succeeded -- see
    // [setupEncoderMuxerAndSession]. Both solo frames ([renderSoloLayer]) and
    // transition-overlap pairs ([renderTransitionPair]) go through their
    // overlay-aware native render seam when this is set.
    private var overlayRenderSession: AndroidTimelineOverlayRenderSession? = null

    // P5-OVERLAYS-TRANSITION-COMP-N3: count of rendered frames (solo or
    // transition-overlap) that composited at least one active overlay --
    // i.e. [overlayRenderSession] was set and its built frame payload
    // reported overlayCount > 0. Distinct from [renderedFrames]/
    // [writtenVideoSamples], which count every frame regardless of overlays.
    private var overlayFramesRendered = 0

    // ─── Pass-1 sample-ratio progress ─────────────────────────────────────────
    private var totalExpectedSamples = 0
    private var onProgress: ((Double) -> Unit)? = null

    /// Encodes [clips] sequentially (hard-cut concatenation) into [outputPath]
    /// as a video-only MP4, using the native Vulkan export session for every
    /// frame. Returns a structured result; never throws.
    override fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        onProgress: ((Double) -> Unit)?,
    ): AndroidTimelineVideoEncoder.EncodeResult = encode(clips, emptyList(), emptyList(), onProgress)

    /// Encodes [clips] with the validated, index-bound [transitions]
    /// (AndroidTimelineTransitionDescriptor.parseList output). An empty /
    /// hard-cut-only list is the plain sequential route; otherwise the
    /// overlap-shortened transition route described in the class doc.
    /// Returns a structured result; never throws.
    override fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        transitions: List<AndroidTimelineTransitionDescriptor>,
        onProgress: ((Double) -> Unit)?,
    ): AndroidTimelineVideoEncoder.EncodeResult =
        encode(clips, transitions, emptyList<AndroidTimelineOverlayDescriptor>(), onProgress)

    /// Encodes [clips] with the validated [transitions] and the validated,
    /// static-sticker [overlays] (AndroidTimelineOverlayDescriptor.parseList
    /// output; P5-OVERLAYS-TRANS Route-A N9, extended by
    /// P5-OVERLAYS-TRANSITION-COMP-N3 and P5-OVERLAYS-BEAUTY-SOLO). Overlays
    /// are rendered on solo frames through the native
    /// renderAndroidTimelineVulkanExportFrameCroppedWithOverlays seam (or,
    /// when the clip also carries Beauty V2, the combined
    /// renderAndroidTimelineVulkanExportFrameCroppedWithOverlaysAndBeauty
    /// seam -- see [renderSoloLayer]), and on transition overlap frames
    /// through renderAndroidTimelineVulkanExportTransitionFrameWithOverlays
    /// (see [renderTransitionPair]) -- overlays alongside clip-level Beauty
    /// V2 are a supported production shape on both the solo and
    /// transition-overlap routes.
    /// Returns a structured result; never throws.
    override fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        transitions: List<AndroidTimelineTransitionDescriptor>,
        overlays: List<AndroidTimelineOverlayDescriptor>,
        onProgress: ((Double) -> Unit)?,
    ): AndroidTimelineVideoEncoder.EncodeResult {
        this.onProgress = onProgress
        // P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: this Vulkan-first pass-1 route
        // has no reversed-clip render support -- AndroidExportRenderBackendSelector
        // already steers a plain reversed scope to the GLES encoder instead,
        // but this defensive check fails closed here too rather than relying
        // on that routing decision alone, since AndroidTimelineExportSession
        // constructs this encoder directly whenever the selector resolves
        // Vulkan.
        if (clips.any { it.isReversed }) {
            return failResult("vulkan_reverse_not_supported")
        }
        val nonHardCutTransitions = transitions.filter { !it.isHardCut }
        val plan = AndroidTimelineExportSegmentPlanner.build(clips, nonHardCutTransitions, fps)
        totalExpectedSamples = plan.expectedSamples
        if (plan.failureReason != null) {
            return failResult(plan.failureReason)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return failResult("api_below_29")
        }

        var succeeded = false
        var muxerStoppedCleanly = false
        var reason = "not_run"
        try {
            val setupFailure = setupEncoderMuxerAndSession(overlays)
            if (setupFailure != null) {
                reason = setupFailure
                return failResult(reason)
            }

            for (segment in plan.segments) {
                if (cancelRequested) break
                val failureReason = when (segment) {
                    is AndroidTimelineExportSegment.Solo -> decodeClipIntoSession(
                        segment.clip,
                        segment.windowStartSeconds,
                        segment.windowEndSeconds,
                    )
                    is AndroidTimelineExportSegment.Overlap -> encodeOverlapSegment(segment)
                }
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
                    "written=$writtenVideoSamples outputSize=$outSize " +
                    "transitions=${plan.segments.count { it is AndroidTimelineExportSegment.Overlap }} " +
                    "beautyFrames=$beautyFramesRendered overlayFrames=$overlayFramesRendered",
            )
            return AndroidTimelineVideoEncoder.EncodeResult(
                true,
                reason,
                writtenVideoSamples,
                outSize,
                beautyFrameCount = beautyFramesRendered,
                overlayFrameCount = overlayFramesRendered,
            )
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
                "written=$writtenVideoSamples beautyFrames=$beautyFramesRendered overlayFrames=$overlayFramesRendered",
        )
        return AndroidTimelineVideoEncoder.EncodeResult(
            false,
            reason,
            writtenVideoSamples,
            0L,
            beautyFrameCount = beautyFramesRendered,
            overlayFrameCount = overlayFramesRendered,
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    /// Sets up the encoder/muxer/native Vulkan session exactly as before, then
    /// -- once [nativeSessionId] is known -- prepares [overlays] (P5-OVERLAYS-
    /// TRANS Route-A N9) if non-empty. Encoder/muxer/session-creation failures
    /// are still reported by throwing, matching the pre-N9 behaviour (caught
    /// by [encode]'s outer try/catch, which still runs [releaseAll] via its
    /// `finally`). An overlay prepare failure is different: it is reported by
    /// returning a machine-readable failure reason (never null on failure)
    /// instead of throwing, so [encode] can return a structured
    /// `overlay_prepare_failed:...` [AndroidTimelineVideoEncoder.EncodeResult]
    /// rather than a generic `exception:...` one -- [encode]'s `finally` still
    /// runs [releaseAll] for this path too, since the early return happens
    /// inside its outer try block. Returns null on full success.
    private fun setupEncoderMuxerAndSession(overlays: List<AndroidTimelineOverlayDescriptor>): String? {
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
        val sessionId = createResult.substringAfter("sessionId=").substringBefore(";").ifEmpty { null }
            ?: throw IllegalStateException("vulkan_session_id_parse_failed")
        nativeSessionId = sessionId

        if (overlays.isNotEmpty()) {
            when (val prepareResult = AndroidTimelineOverlayRenderSession.prepare(sessionId, overlays, nativeBridge)) {
                is AndroidTimelineOverlayRenderSession.PrepareResult.Failure ->
                    return "overlay_prepare_failed:${prepareResult.code}:${prepareResult.message.take(120)}"
                is AndroidTimelineOverlayRenderSession.PrepareResult.Success ->
                    overlayRenderSession = prepareResult.session
            }
        }
        return null
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Per-clip decode -> native Vulkan render -> encoder drain
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns null on success, or a machine-readable failure reason string
    /// for any non-cancel decode/render failure. Every rendered frame is
    /// checked against the Opus P1 real-buffer geometry guard (see
    /// [renderImageIntoSession]) -- a decoder can produce a differently
    /// padded/cropped HardwareBuffer from frame to frame even within one
    /// clip. [windowStartSeconds] / [windowEndSeconds] is the end-exclusive
    /// source pts window to render (the clip's full trim window for hard-cut
    /// timelines; the overlap-shortened solo window for transition
    /// timelines).
    private fun decodeClipIntoSession(
        clip: AndroidTimelineVideoEncoder.ClipInput,
        windowStartSeconds: Double,
        windowEndSeconds: Double,
    ): String? {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var imageReader: ImageReader? = null
        var thread: HandlerThread? = null
        val imageQueue = LinkedBlockingQueue<Image>(IMAGE_READER_MAX_IMAGES + 2)
        try {
            AndroidUriDataSourceHelper.setExtractorDataSource(extractor, clip.sourcePath, context)
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

            // Per-clip placement: full-extent source crop + aspect-preserving-
            // fit destination rect within the fixed output surface
            // (letterboxed/pillarboxed over black where this clip's rotated
            // display aspect ratio differs from the output's), or -- for a
            // clip carrying a static transform -- the derived source crop +
            // in-bounds destination rect (see [computeLayerPlacement]). Fails
            // closed if the placement cannot be represented; this is the
            // geometry that gates native rendering.
            val placementResolution = computeLayerPlacement(clip)
            val placement = placementResolution.placement
                ?: return placementResolution.failure ?: "vulkan_layer_placement_unresolved"
            val clipTransform = clip.transform
            if (clipTransform != null) {
                Log.i(
                    TAG,
                    "VG_VULKAN_CLIP_TRANSFORM_PLACEMENT source=${clip.sourcePath} " +
                        "scale=${clipTransform.scale} tx=${clipTransform.translationX} " +
                        "ty=${clipTransform.translationY} rotation=${clip.rotationDegrees} " +
                        "decoded=${clip.decodedWidth}x${clip.decodedHeight} " +
                        "crop=${placement.sourceLeft},${placement.sourceTop}-" +
                        "${placement.sourceRight},${placement.sourceBottom} " +
                        "dest=${placement.dest.x},${placement.dest.y}-" +
                        "${placement.dest.width}x${placement.dest.height} out=${width}x$height",
                )
            }

            val trimStartUs = (windowStartSeconds * 1_000_000L).toLong()
            if (trimStartUs > 0L) {
                // Pre-roll from the sync sample at or before the window start.
                // CLOSEST_SYNC may land on a sync sample after trimStartUs (e.g.
                // the incoming post-transition solo window [0.5s, 2.0s) landing
                // on the 1.0s keyframe), silently dropping every frame between
                // the window start and that sync. The output loop below already
                // drops every decoded frame with presentationTimeUs < trimStartUs,
                // so pre-rolling from the previous sync only costs decode work,
                // never wrong frames. Mirrors AndroidTimelineTransitionOverlapDecoder.
                extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }
            val trimEndUs = (windowEndSeconds * 1_000_000L).toLong()

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

            val clipSpeed = if (clip.speed > 0.0) clip.speed else 1.0
            val isUnitySpeed = Math.abs(clipSpeed - 1.0) < 0.0001
            val expectedFramesInClip = ceil(((windowEndSeconds - windowStartSeconds) / clipSpeed) * fps).toInt().coerceAtLeast(1)
            val sourceFps = if (trackFormat.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                try { trackFormat.getInteger(MediaFormat.KEY_FRAME_RATE) } catch (_: Throwable) { 0 }
            } else 0
            val nominalSourceIntervalUs = if (sourceFps in 1..240) {
                1_000_000L / sourceFps
            } else {
                1_000_000L / fps
            }
            var nextOutputFrameIndex = 0

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
                        if (isUnitySpeed) {
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
                                    placement,
                                    clip.colorMatrix,
                                    clip.beautyIntensity,
                                )
                                if (frameFailure != null) return frameFailure
                                renderedFramesInClip++
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                        } else {
                            val inWindow = info.presentationTimeUs >= trimStartUs &&
                                info.presentationTimeUs < trimEndUs
                            if (inWindow) {
                                val pts = info.presentationTimeUs
                                var repeatCount = 0
                                while (nextOutputFrameIndex + repeatCount < expectedFramesInClip) {
                                    val targetUs = trimStartUs + ((nextOutputFrameIndex + repeatCount) * frameDurationUs * clipSpeed).toLong()
                                    if (targetUs < pts + nominalSourceIntervalUs) {
                                        repeatCount++
                                    } else {
                                        break
                                    }
                                }
                                if ((isEos || inputDone) && nextOutputFrameIndex + repeatCount < expectedFramesInClip) {
                                    repeatCount = expectedFramesInClip - nextOutputFrameIndex
                                }

                                if (repeatCount > 0) {
                                    dec.releaseOutputBuffer(outIdx, true)
                                    val image = imageQueue.poll(IMAGE_ACQUIRE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                                        ?: return "vulkan_image_acquire_timeout:${clip.sourcePath}"
                                    val frameFailure = renderImageIntoSession(
                                        image,
                                        clip.rotationDegrees,
                                        sourceWidth,
                                        sourceHeight,
                                        placement,
                                        clip.colorMatrix,
                                        clip.beautyIntensity,
                                        repeatCount,
                                    )
                                    if (frameFailure != null) return frameFailure
                                    renderedFramesInClip += repeatCount
                                    nextOutputFrameIndex += repeatCount
                                } else {
                                    dec.releaseOutputBuffer(outIdx, false)
                                }
                            } else {
                                dec.releaseOutputBuffer(outIdx, false)
                            }
                        }
                    } else {
                        dec.releaseOutputBuffer(outIdx, false)
                    }
                    if (isEos || (!isUnitySpeed && nextOutputFrameIndex >= expectedFramesInClip)) break
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
    /// decoder crop is validated against this source extent. [placement]
    /// is the per-clip source crop + destination sub-rect within the fixed
    /// output surface, computed once by [decodeClipIntoSession] via
    /// [computeLayerPlacement] and passed through unchanged for every frame
    /// of this clip. [colorMatrix] (Phase 10) is the active clip's raw
    /// (un-normalized) 20-element colorMatrix, passed through unchanged to
    /// the native Vulkan render seam -- null means identity (no filter); see
    /// [VanguardNativeBridge.renderAndroidTimelineVulkanExportFrameCropped].
    /// [beautyIntensity] (P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A) is the
    /// active clip's optional Beauty V2 intensity in [0.0, 1.0]; null means
    /// no beauty. Passed through unchanged to the native seam, which expands
    /// it into the full ramp using the cropped source extent.
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
        placement: LayerPlacement,
        colorMatrix: FloatArray?,
        beautyIntensity: Double?,
        repeatCount: Int = 1,
    ): String? {
        var hwBuf: HardwareBuffer? = null
        try {
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
            for (r in 0 until repeatCount) {
                if (cancelRequested) break
                val failure = renderSoloLayer(
                    hwBuf,
                    cropRect,
                    hwBuf.width,
                    hwBuf.height,
                    rotationDegrees,
                    expectedCropWidth,
                    expectedCropHeight,
                    placement,
                    colorMatrix,
                    beautyIntensity,
                )
                if (failure != null) return failure
            }
            return null
        } finally {
            try { hwBuf?.close() } catch (_: Throwable) {}
            try { image.close() } catch (_: Throwable) {}
        }
    }

    /// Validated native layer geometry (IntArray(9) wire layout of the
    /// transition seam: crop l/t/r/b, rotation, dest fit x/y/w/h) or a
    /// machine-readable failure reason. Exactly one of the two is non-null.
    private class LayerGeometry(val values: IntArray?, val failure: String?)

    /// The Opus P1 real-buffer geometry guard shared by the solo and
    /// transition routes: cardinal rotation, crop inside the buffer, crop
    /// size equal to the clip's decoded extent, even-aligned crop bounds.
    /// P5-CLIP-STATIC-TRANSFORM-EXPORT-A: the clip's [placement] source
    /// crop (relative to the decoded extent) is then applied as an offset
    /// inside that guarded decoder crop, so the native seam samples exactly
    /// the sub-rect the transform makes visible; the final crop is
    /// re-validated (inside the decoder crop, non-empty, even-aligned)
    /// before it is handed to native.
    private fun resolveLayerGeometry(
        cropRect: Rect,
        bufW: Int,
        bufH: Int,
        rotationDegrees: Int,
        expectedCropWidth: Int,
        expectedCropHeight: Int,
        placement: LayerPlacement,
    ): LayerGeometry {
        if (rotationDegrees != 0 && rotationDegrees != 90 &&
            rotationDegrees != 180 && rotationDegrees != 270
        ) {
            return LayerGeometry(null, "vulkan_rotation_unsupported:$rotationDegrees")
        }
        if (cropRect.left < 0 || cropRect.top < 0 ||
            cropRect.right <= cropRect.left || cropRect.bottom <= cropRect.top ||
            cropRect.right > bufW || cropRect.bottom > bufH
        ) {
            return LayerGeometry(
                null,
                "vulkan_decoder_buffer_geometry_mismatch:bufW=$bufW:bufH=$bufH:crop=$cropRect",
            )
        }
        val cropWidth = cropRect.right - cropRect.left
        val cropHeight = cropRect.bottom - cropRect.top
        if (cropWidth != expectedCropWidth || cropHeight != expectedCropHeight) {
            return LayerGeometry(
                null,
                "vulkan_decoder_crop_unsupported:size_mismatch:" +
                    "bufW=$bufW:bufH=$bufH:crop=$cropRect:" +
                    "expectedW=$expectedCropWidth:expectedH=$expectedCropHeight",
            )
        }
        if (cropRect.left % 2 != 0 || cropRect.top % 2 != 0 ||
            cropRect.right % 2 != 0 || cropRect.bottom % 2 != 0
        ) {
            return LayerGeometry(null, "vulkan_decoder_crop_unsupported:odd_crop_bounds:crop=$cropRect")
        }
        // Clip-level source crop, offset into the guarded decoder crop.
        val finalLeft = cropRect.left + placement.sourceLeft
        val finalTop = cropRect.top + placement.sourceTop
        val finalRight = cropRect.left + placement.sourceRight
        val finalBottom = cropRect.top + placement.sourceBottom
        if (finalLeft < cropRect.left || finalTop < cropRect.top ||
            finalRight > cropRect.right || finalBottom > cropRect.bottom ||
            finalRight <= finalLeft || finalBottom <= finalTop
        ) {
            return LayerGeometry(
                null,
                "vulkan_clip_transform_crop_outside_decoder_crop:" +
                    "crop=$cropRect:source=${placement.sourceLeft},${placement.sourceTop}-" +
                    "${placement.sourceRight},${placement.sourceBottom}",
            )
        }
        if (finalLeft % 2 != 0 || finalTop % 2 != 0 || finalRight % 2 != 0 || finalBottom % 2 != 0) {
            return LayerGeometry(
                null,
                "vulkan_clip_transform_crop_odd_bounds:final=$finalLeft,$finalTop-$finalRight,$finalBottom",
            )
        }
        val dest = placement.dest
        return LayerGeometry(
            intArrayOf(
                finalLeft, finalTop, finalRight, finalBottom,
                rotationDegrees,
                dest.x, dest.y, dest.width, dest.height,
            ),
            null,
        )
    }

    /// Renders one decoded layer solo through the cropped native seam, then
    /// drains the encoder. Does NOT close [hwBuf]; the caller owns it.
    private fun renderSoloLayer(
        hwBuf: HardwareBuffer,
        cropRect: Rect,
        bufW: Int,
        bufH: Int,
        rotationDegrees: Int,
        expectedCropWidth: Int,
        expectedCropHeight: Int,
        placement: LayerPlacement,
        colorMatrix: FloatArray?,
        beautyIntensity: Double?,
    ): String? {
        val geometry = resolveLayerGeometry(
            cropRect, bufW, bufH, rotationDegrees, expectedCropWidth, expectedCropHeight, placement,
        )
        val g = geometry.values ?: return geometry.failure ?: "vulkan_layer_geometry_unresolved"

        val timelinePtsUs = renderedFrames * frameDurationUs
        val session = overlayRenderSession
        val renderStr: String
        var overlayFrameCounted = false
        if (session == null) {
            renderStr = nativeBridge.renderAndroidTimelineVulkanExportFrameCropped(
                sessionId = nativeSessionId!!,
                hardwareBuffer = hwBuf,
                width = width,
                height = height,
                cropLeft = g[0],
                cropTop = g[1],
                cropRight = g[2],
                cropBottom = g[3],
                rotationDegrees = g[4],
                destFitX = g[5],
                destFitY = g[6],
                destFitWidth = g[7],
                destFitHeight = g[8],
                timelinePtsUs = timelinePtsUs,
                frameIndex = renderedFrames,
                colorMatrix = colorMatrix,
                beautyEnabled = beautyIntensity != null,
                beautyIntensity = (beautyIntensity ?: 0.0).toFloat(),
            )
        } else {
            // P5-OVERLAYS-TRANS Route-A N9 / P5-OVERLAYS-BEAUTY-SOLO: this
            // branch renders both plain solo segments and the unpaired solo
            // edge frames a transition overlap segment falls back to (see
            // [encodeOverlapSegment]). A beauty clip's solo frame carrying
            // one or more active overlays renders through the combined
            // renderAndroidTimelineVulkanExportFrameCroppedWithOverlaysAndBeauty
            // seam, which applies Beauty V2 before overlay placement; a
            // beauty clip's solo frame with zero active overlays still
            // renders through the plain cropped seam (byte-identical to the
            // pre-existing beauty-only behavior), and a non-beauty solo
            // frame still renders through the overlay-only cropped seam
            // (byte-identical to the pre-existing overlay-only behavior).
            val payload = when (val payloadResult = session.buildFramePayload(timelinePtsUs)) {
                is AndroidTimelineOverlayRenderSession.FramePayloadResult.Failure ->
                    return "overlay_payload_failed:${payloadResult.code}:${payloadResult.message.take(120)}"
                is AndroidTimelineOverlayRenderSession.FramePayloadResult.Success -> payloadResult.payload
            }
            if (beautyIntensity != null && payload.overlayCount > 0) {
                renderStr = nativeBridge.renderAndroidTimelineVulkanExportFrameCroppedWithOverlaysAndBeauty(
                    sessionId = nativeSessionId!!,
                    hardwareBuffer = hwBuf,
                    width = width,
                    height = height,
                    cropLeft = g[0],
                    cropTop = g[1],
                    cropRight = g[2],
                    cropBottom = g[3],
                    rotationDegrees = g[4],
                    destFitX = g[5],
                    destFitY = g[6],
                    destFitWidth = g[7],
                    destFitHeight = g[8],
                    timelinePtsUs = timelinePtsUs,
                    frameIndex = renderedFrames,
                    colorMatrix = colorMatrix,
                    overlayTextureHandles = payload.overlayTextureHandles,
                    overlayGeometry = payload.overlayGeometry,
                    overlayCount = payload.overlayCount,
                    beautyEnabled = true,
                    beautyIntensity = beautyIntensity.toFloat(),
                )
                if (renderStr.startsWith("status=OK;")) {
                    overlayFrameCounted = true
                }
            } else if (beautyIntensity != null) {
                renderStr = nativeBridge.renderAndroidTimelineVulkanExportFrameCropped(
                    sessionId = nativeSessionId!!,
                    hardwareBuffer = hwBuf,
                    width = width,
                    height = height,
                    cropLeft = g[0],
                    cropTop = g[1],
                    cropRight = g[2],
                    cropBottom = g[3],
                    rotationDegrees = g[4],
                    destFitX = g[5],
                    destFitY = g[6],
                    destFitWidth = g[7],
                    destFitHeight = g[8],
                    timelinePtsUs = timelinePtsUs,
                    frameIndex = renderedFrames,
                    colorMatrix = colorMatrix,
                    beautyEnabled = true,
                    beautyIntensity = beautyIntensity.toFloat(),
                )
            } else {
                renderStr = nativeBridge.renderAndroidTimelineVulkanExportFrameCroppedWithOverlays(
                    sessionId = nativeSessionId!!,
                    hardwareBuffer = hwBuf,
                    width = width,
                    height = height,
                    cropLeft = g[0],
                    cropTop = g[1],
                    cropRight = g[2],
                    cropBottom = g[3],
                    rotationDegrees = g[4],
                    destFitX = g[5],
                    destFitY = g[6],
                    destFitWidth = g[7],
                    destFitHeight = g[8],
                    timelinePtsUs = timelinePtsUs,
                    frameIndex = renderedFrames,
                    colorMatrix = colorMatrix,
                    overlayTextureHandles = payload.overlayTextureHandles,
                    overlayGeometry = payload.overlayGeometry,
                    overlayCount = payload.overlayCount,
                )
                if (renderStr.startsWith("status=OK;") && payload.overlayCount > 0) {
                    overlayFrameCounted = true
                }
            }
        }
        if (!renderStr.startsWith("status=OK;")) {
            return "vulkan_render_failed:${renderStr.take(120)}"
        }
        renderedFrames++
        if (overlayFrameCounted) {
            overlayFramesRendered++
        }
        if (beautyIntensity != null) {
            beautyFramesRendered++
        }
        drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
        return null
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Transition overlap segment (P5-COMPOSITOR-TRANS)
    // ─────────────────────────────────────────────────────────────────────────

    /// Renders one transition overlap: the outgoing clip's tail window and the
    /// incoming clip's head window are decoded in lockstep by
    /// AndroidTimelineTransitionOverlapDecoder and every pair is rendered
    /// through the native two-source transition seam at progress
    /// (j + 1) / (N + 1), N = the descriptor's overlap frame count at [fps].
    /// If one window ends a frame earlier than the other (decoder timing
    /// jitter), the remaining unpaired frames render solo through the cropped
    /// seam so no source frame is dropped and the muxed PTS clock stays
    /// continuous. Returns null on success or cancellation (the caller checks
    /// [cancelRequested]), else a machine-readable failure reason. Never
    /// throws; the decoder is always closed.
    private fun encodeOverlapSegment(segment: AndroidTimelineExportSegment.Overlap): String? {
        val transition = segment.transition
        val fromClip = segment.fromClip
        val toClip = segment.toClip
        for ((label, clip) in listOf("from" to fromClip, "to" to toClip)) {
            if (clip.decodedWidth <= 0 || clip.decodedHeight <= 0) {
                return "vulkan_decoded_dims_invalid:layer=$label:" +
                    "decodedW=${clip.decodedWidth}:decodedH=${clip.decodedHeight}"
            }
            if (clip.rotationDegrees != 0 && clip.rotationDegrees != 90 &&
                clip.rotationDegrees != 180 && clip.rotationDegrees != 270
            ) {
                return "vulkan_rotation_unsupported:layer=$label:${clip.rotationDegrees}"
            }
        }
        val fromResolution = computeLayerPlacement(fromClip)
        val fromFit = fromResolution.placement
            ?: return "vulkan_transition_layer_placement:layer=from:" +
                (fromResolution.failure ?: "vulkan_layer_placement_unresolved")
        val toResolution = computeLayerPlacement(toClip)
        val toFit = toResolution.placement
            ?: return "vulkan_transition_layer_placement:layer=to:" +
                (toResolution.failure ?: "vulkan_layer_placement_unresolved")

        val expectedOverlapFrames = transition.overlapFrameCount(fps)
        val decoder = AndroidTimelineTransitionOverlapDecoder(
            fromSource = AndroidTimelineTransitionOverlapDecoder.Source(
                label = "from",
                sourcePath = fromClip.sourcePath,
                windowStartSeconds = segment.fromWindowStartSeconds,
                windowEndSeconds = segment.fromWindowEndSeconds,
                decodedWidth = fromClip.decodedWidth,
                decodedHeight = fromClip.decodedHeight,
            ),
            toSource = AndroidTimelineTransitionOverlapDecoder.Source(
                label = "to",
                sourcePath = toClip.sourcePath,
                windowStartSeconds = segment.toWindowStartSeconds,
                windowEndSeconds = segment.toWindowEndSeconds,
                decodedWidth = toClip.decodedWidth,
                decodedHeight = toClip.decodedHeight,
            ),
            context = context,
            isCancelled = { cancelRequested },
        )

        var pairsRendered = 0
        var soloFromRendered = 0
        var soloToRendered = 0
        // P5-OVERLAYS-TRANSITION-COMP-N3: segment-local overlay-frame proof --
        // the class-wide [overlayFramesRendered] counter before/after this
        // segment's render loop, so the VG_VULKAN_TRANSITION_SEGMENT row below
        // can report how many of THIS segment's frames (pair or unpaired-solo
        // edge) actually composited an active overlay.
        val overlayFramesRenderedBeforeSegment = overlayFramesRendered
        try {
            val openFailure = decoder.open()
            if (openFailure != null) {
                return "vulkan_transition_decoder_open_failed:${transition.transitionId}:$openFailure"
            }
            while (true) {
                if (cancelRequested) return null
                when (val step = decoder.nextStep()) {
                    is AndroidTimelineTransitionOverlapDecoder.Step.Exhausted -> break
                    is AndroidTimelineTransitionOverlapDecoder.Step.Cancelled -> return null
                    is AndroidTimelineTransitionOverlapDecoder.Step.Failed ->
                        return "vulkan_transition_decode_failed:${transition.transitionId}:${step.reason}"
                    is AndroidTimelineTransitionOverlapDecoder.Step.Frames -> {
                        val fromFrame = step.from
                        val toFrame = step.to
                        try {
                            val failure = when {
                                fromFrame != null && toFrame != null -> {
                                    val progress = transition.progressForOverlapFrame(pairsRendered, expectedOverlapFrames)
                                    val result = renderTransitionPair(
                                        fromFrame, toFrame, transition, fromClip, toClip, fromFit, toFit, progress,
                                    )
                                    if (result == null) pairsRendered++
                                    result
                                }
                                fromFrame != null -> {
                                    // P5-BEAUTY-V2-TRANSITION-COMP: an unpaired edge
                                    // frame from the outgoing clip's own decode still
                                    // renders that clip's own beautyIntensity, exactly
                                    // like a solo hard-cut frame.
                                    val result = renderSoloLayer(
                                        fromFrame.hardwareBuffer, fromFrame.cropRect,
                                        fromFrame.bufferWidth, fromFrame.bufferHeight,
                                        fromClip.rotationDegrees, fromClip.decodedWidth, fromClip.decodedHeight,
                                        fromFit, fromClip.colorMatrix, beautyIntensity = fromClip.beautyIntensity,
                                    )
                                    if (result == null) soloFromRendered++
                                    result
                                }
                                toFrame != null -> {
                                    val result = renderSoloLayer(
                                        toFrame.hardwareBuffer, toFrame.cropRect,
                                        toFrame.bufferWidth, toFrame.bufferHeight,
                                        toClip.rotationDegrees, toClip.decodedWidth, toClip.decodedHeight,
                                        toFit, toClip.colorMatrix, beautyIntensity = toClip.beautyIntensity,
                                    )
                                    if (result == null) soloToRendered++
                                    result
                                }
                                else -> "vulkan_transition_empty_step"
                            }
                            if (failure != null) return failure
                        } finally {
                            fromFrame?.close()
                            toFrame?.close()
                        }
                    }
                }
            }
            val framesRendered = pairsRendered + soloFromRendered + soloToRendered
            if (framesRendered == 0 && !cancelRequested) {
                return "no_frames_in_transition_window:${transition.transitionId}"
            }
            val segmentOverlayFramesRendered = overlayFramesRendered - overlayFramesRenderedBeforeSegment
            Log.i(
                TAG,
                "VG_VULKAN_TRANSITION_SEGMENT transition=${transition.transitionId} " +
                    "type=${transition.type.wireName} pairs=$pairsRendered expected=$expectedOverlapFrames " +
                    "soloFrom=$soloFromRendered soloTo=$soloToRendered " +
                    "fromDecoded=${decoder.fromFramesProduced} toDecoded=${decoder.toFramesProduced} " +
                    "overlayFramesRendered=$segmentOverlayFramesRendered",
            )
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "encodeOverlapSegment failed for ${transition.transitionId}: $t", t)
            return "vulkan_transition_exception:${t.javaClass.simpleName}:${transition.transitionId}"
        } finally {
            decoder.close()
        }
    }

    /// Renders one overlap pair through the native two-source transition
    /// seam, then drains the encoder. Does NOT close either frame; the caller
    /// owns them. Both layers pass the same per-frame geometry guard as solo
    /// frames.
    ///
    /// P5-OVERLAYS-TRANSITION-COMP-N3, extended by
    /// P5-OVERLAYS-BEAUTY-TRANSITION-OVERLAP-ONLY: when [overlayRenderSession]
    /// is set, this builds that session's frame payload for [timelinePtsUs]
    /// (the same continuous output-frame clock solo frames use -- see the
    /// class doc's PTS mechanism note) and renders through the overlay-aware
    /// transition seam instead. Like [renderSoloLayer]'s own combined
    /// beauty+overlay seam (P5-OVERLAYS-BEAUTY-SOLO), this transition-overlap
    /// overlay seam accepts per-layer Beauty V2 params and applies Beauty
    /// before overlay placement, so [fromClip]'s and [toClip]'s actual
    /// beautyIntensity values are passed through rather than forced off. A
    /// payload build failure returns a machine-readable
    /// `overlay_payload_failed:<code>:<message>` reason instead of throwing.
    private fun renderTransitionPair(
        fromFrame: AndroidTimelineTransitionOverlapDecoder.Frame,
        toFrame: AndroidTimelineTransitionOverlapDecoder.Frame,
        transition: AndroidTimelineTransitionDescriptor,
        fromClip: AndroidTimelineVideoEncoder.ClipInput,
        toClip: AndroidTimelineVideoEncoder.ClipInput,
        fromFit: LayerPlacement,
        toFit: LayerPlacement,
        progress: Double,
    ): String? {
        val fromGeometry = resolveLayerGeometry(
            fromFrame.cropRect, fromFrame.bufferWidth, fromFrame.bufferHeight,
            fromClip.rotationDegrees, fromClip.decodedWidth, fromClip.decodedHeight, fromFit,
        )
        val fromValues = fromGeometry.values
            ?: return "vulkan_transition_layer_geometry:layer=from:${fromGeometry.failure}"
        val toGeometry = resolveLayerGeometry(
            toFrame.cropRect, toFrame.bufferWidth, toFrame.bufferHeight,
            toClip.rotationDegrees, toClip.decodedWidth, toClip.decodedHeight, toFit,
        )
        val toValues = toGeometry.values
            ?: return "vulkan_transition_layer_geometry:layer=to:${toGeometry.failure}"

        val timelinePtsUs = renderedFrames * frameDurationUs
        val session = overlayRenderSession
        val renderStr: String
        var overlayFrameCounted = false
        if (session == null) {
            renderStr = nativeBridge.renderAndroidTimelineVulkanExportTransitionFrame(
                sessionId = nativeSessionId!!,
                width = width,
                height = height,
                transitionTypeCode = transition.type.nativeCode,
                progress = progress,
                fromHardwareBuffer = fromFrame.hardwareBuffer,
                fromLayerGeometry = fromValues,
                fromColorMatrix = fromClip.colorMatrix,
                fromBeautyEnabled = fromClip.beautyIntensity != null,
                fromBeautyIntensity = (fromClip.beautyIntensity ?: 0.0).toFloat(),
                toHardwareBuffer = toFrame.hardwareBuffer,
                toLayerGeometry = toValues,
                toColorMatrix = toClip.colorMatrix,
                toBeautyEnabled = toClip.beautyIntensity != null,
                toBeautyIntensity = (toClip.beautyIntensity ?: 0.0).toFloat(),
                timelinePtsUs = timelinePtsUs,
                frameIndex = renderedFrames,
            )
        } else {
            val payload = when (val payloadResult = session.buildFramePayload(timelinePtsUs)) {
                is AndroidTimelineOverlayRenderSession.FramePayloadResult.Failure ->
                    return "overlay_payload_failed:${payloadResult.code}:${payloadResult.message.take(120)}"
                is AndroidTimelineOverlayRenderSession.FramePayloadResult.Success -> payloadResult.payload
            }
            renderStr = nativeBridge.renderAndroidTimelineVulkanExportTransitionFrameWithOverlays(
                sessionId = nativeSessionId!!,
                width = width,
                height = height,
                transitionTypeCode = transition.type.nativeCode,
                progress = progress,
                fromHardwareBuffer = fromFrame.hardwareBuffer,
                fromLayerGeometry = fromValues,
                fromColorMatrix = fromClip.colorMatrix,
                fromBeautyEnabled = fromClip.beautyIntensity != null,
                fromBeautyIntensity = (fromClip.beautyIntensity ?: 0.0).toFloat(),
                toHardwareBuffer = toFrame.hardwareBuffer,
                toLayerGeometry = toValues,
                toColorMatrix = toClip.colorMatrix,
                toBeautyEnabled = toClip.beautyIntensity != null,
                toBeautyIntensity = (toClip.beautyIntensity ?: 0.0).toFloat(),
                timelinePtsUs = timelinePtsUs,
                frameIndex = renderedFrames,
                overlayTextureHandles = payload.overlayTextureHandles,
                overlayGeometry = payload.overlayGeometry,
                overlayCount = payload.overlayCount,
            )
            if (renderStr.startsWith("status=OK;") && payload.overlayCount > 0) {
                overlayFrameCounted = true
            }
        }
        if (!renderStr.startsWith("status=OK;")) {
            return "vulkan_transition_render_failed:${renderStr.take(120)}"
        }
        renderedFrames++
        if (overlayFrameCounted) {
            overlayFramesRendered++
        }
        // P5-BEAUTY-V2-TRANSITION-COMP, extended by
        // P5-OVERLAYS-BEAUTY-TRANSITION-OVERLAP-ONLY: counted once per
        // rendered transition frame when either layer carries beauty,
        // mirroring the solo path's per-frame beautyFramesRendered
        // accounting. Also true on the overlay-aware branch above now that
        // it passes each layer's actual beautyIntensity through instead of
        // forcing it off.
        if (fromClip.beautyIntensity != null || toClip.beautyIntensity != null) {
            beautyFramesRendered++
        }
        drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
        return null
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

    /// Per-clip render placement: the source crop, relative to the clip's
    /// decoded extent (buffer orientation, pre-rotation; applied by
    /// [resolveLayerGeometry] as an offset inside the guarded decoder crop),
    /// plus the in-bounds destination rect. The full decoded extent + the
    /// centered aspect-fit rect for an untransformed clip; the
    /// AndroidTimelineClipStaticTransformGeometry result for a transformed
    /// clip (P5-CLIP-STATIC-TRANSFORM-EXPORT-A).
    private data class LayerPlacement(
        val sourceLeft: Int,
        val sourceTop: Int,
        val sourceRight: Int,
        val sourceBottom: Int,
        val dest: DestFitRect,
    )

    /// Exactly one of [placement] / [failure] is non-null.
    private class PlacementResolution(val placement: LayerPlacement?, val failure: String?)

    /// Resolves [clip]'s [LayerPlacement]. Untransformed clips keep the
    /// pre-existing full-extent crop + [computeAspectFitRect] placement
    /// (byte-identical native geometry); transformed clips route through
    /// AndroidTimelineClipStaticTransformGeometry and fail closed with a
    /// `vulkan_clip_transform_placement_invalid:<reason>` reason whenever
    /// the transform cannot be represented as an in-bounds crop/destination
    /// pair. AndroidTimelineExportSession runs the same computation before
    /// pass-1, so a failure here indicates a genuine invariant violation.
    private fun computeLayerPlacement(clip: AndroidTimelineVideoEncoder.ClipInput): PlacementResolution {
        val transform = clip.transform
        if (transform == null) {
            val fit = computeAspectFitRect(
                outputWidth = width,
                outputHeight = height,
                decodedWidth = clip.decodedWidth,
                decodedHeight = clip.decodedHeight,
                rotationDegrees = clip.rotationDegrees,
            ) ?: return PlacementResolution(
                null,
                "vulkan_dest_fit_rect_invalid:" +
                    "decodedW=${clip.decodedWidth}:decodedH=${clip.decodedHeight}:" +
                    "rotation=${clip.rotationDegrees}:outW=$width:outH=$height",
            )
            return PlacementResolution(
                LayerPlacement(0, 0, clip.decodedWidth, clip.decodedHeight, fit),
                null,
            )
        }
        val result = AndroidTimelineClipStaticTransformGeometry.compute(
            outputWidth = width,
            outputHeight = height,
            decodedWidth = clip.decodedWidth,
            decodedHeight = clip.decodedHeight,
            rotationDegrees = clip.rotationDegrees,
            transform = transform,
        )
        val placement = result.placement
            ?: return PlacementResolution(
                null,
                "vulkan_clip_transform_placement_invalid:${result.failure ?: "unresolved"}",
            )
        val dest = DestFitRect(placement.destX, placement.destY, placement.destWidth, placement.destHeight)
        if (dest.width < 1 || dest.height < 1 || dest.x < 0 || dest.y < 0 ||
            dest.x + dest.width > width || dest.y + dest.height > height
        ) {
            return PlacementResolution(
                null,
                "vulkan_clip_transform_placement_invalid:dest_out_of_bounds:" +
                    "dest=${dest.x},${dest.y}-${dest.width}x${dest.height}:outW=$width:outH=$height",
            )
        }
        return PlacementResolution(
            LayerPlacement(
                placement.sourceLeft, placement.sourceTop, placement.sourceRight, placement.sourceBottom, dest,
            ),
            null,
        )
    }

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

    /// Closes the overlay render session (P5-OVERLAYS-TRANS Route-A N9, if
    /// any overlays were prepared) before destroying the native Vulkan
    /// session, then releases the encoder's own surface/codec/muxer, per the
    /// required cleanup ordering. [AndroidTimelineOverlayRenderSession.close]
    /// never throws, but is still guarded defensively like every other
    /// cleanup step here.
    private fun releaseAll() {
        try { overlayRenderSession?.close() } catch (_: Throwable) {}
        overlayRenderSession = null
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
