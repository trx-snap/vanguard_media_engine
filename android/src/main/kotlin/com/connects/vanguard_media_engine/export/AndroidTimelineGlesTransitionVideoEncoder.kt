package com.connects.vanguard_media_engine.export

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLES30
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

// ── AndroidTimelineGlesTransitionVideoEncoder (P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A) ──
//
// Narrow production GLES pass-1 video encoder for a non-hard-cut transition
// timeline, used ONLY when AndroidExportRenderBackendSelector resolves the
// GLES backend for a scope that is
// [AndroidExportRenderBackendSelector.ExportRenderScope.glesTransitionEligible]
// (video or still-image clips -- P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS, see
// below -- no reversed clip,
// positive decoded/requested dimensions, standard 0/90/180/270 rotation
// metadata on every video clip and rotationDegrees == 0 on every still-image
// clip -- overlays are permitted, see the
// P5-GLES-EXPORT-TRANSITION-OVERLAYS paragraph below, and clip-level Beauty
// V2 is permitted on a video clip, including when also paired with overlays
// (P5-GLES-EXPORT-BEAUTY-TRANSITION-OVERLAYS), see the
// P5-GLES-EXPORT-BEAUTY-TRANSITIONS paragraph below -- a still-image clip may
// never carry Beauty, AND a scope mixing a still-image clip with a *video*
// clip that carries Beauty is equally out of scope, failing closed with
// `beauty_with_still_image_unsupported` before any segment renders -- see
// [encode]'s upfront guard and
// [AndroidExportRenderBackendSelector.ExportRenderScope.glesTransitionIneligibleReason])
// -- AndroidTimelineExportSession
// only ever constructs this class for that shape; see its `buildPass1Encoder`. This class defensively
// re-validates that same narrow shape per clip (see [validateClipShape]) and
// fails closed with a precise `gles_transition_not_eligible:<reason>` reason
// if it is ever handed something outside it, rather than trusting the caller
// blindly -- the same defense-in-depth pattern AndroidTimelineVideoEncoder's
// own overlay-aware [encode] override already uses.
//
// Routing: [AndroidTimelineExportSegmentPlanner] (the same renderer-neutral
// planner AndroidTimelineVulkanVideoEncoder uses) splits the timeline into
// Solo and Overlap segments. A Solo segment decodes and renders directly
// into the encoder's own EGL surface via a single OES decode pipeline --
// the same aspect-fit-into-canvas quad geometry and OES-to-encoder-surface
// draw AndroidTimelineVideoEncoder's frozen hard-cut path uses, just
// re-derived here since that class's geometry/draw helpers are private and
// this class must not expand its ownership. An Overlap segment decodes both
// sides concurrently (two independent OES decode pipelines stepped in
// lockstep via [AndroidTimelineGlesTransitionOverlapDecoder]), pre-resolves
// each decoded OES frame -- with its own SurfaceTexture transform matrix
// applied, through the same fit-into-canvas quad geometry the solo path uses
// -- into its own canvas-sized GL_TEXTURE_2D raster via an offscreen FBO
// blit, then hands both resolved 2D textures to the native
// GlesTimelineTransitionCompositor seam
// (VanguardNativeBridge.drawAndroidTimelineGlesTransitionExportFrame) for a
// transition draw at that pair's transition progress, before presenting
// and draining the shared encoder/muxer -- exactly the proof chain
// AndroidGlesDualOesTransitionSmokeHarness already physically validated,
// wired to real per-segment decode windows instead of one fixed diagnostic
// midpoint. A side whose window ends a frame earlier than the other (decoder
// timing jitter, not a real mismatch -- see
// AndroidTimelineTransitionOverlapDecoder's class doc for the same tolerance
// on the Vulkan route) renders its remaining unpaired frame(s) solo through
// the same OES-to-encoder-surface path, so no source frame is ever dropped.
//
// P5-GLES-EXPORT-TRANSITION-SLIDE-WIPE: every non-hard-cut
// AndroidTimelineTransitionDescriptor.Type member (crossfade, the four
// wipes, the four slides) draws through the native
// GlesTimelineTransitionCompositor seam at that pair's transition progress
// -- native transition math (vanguard::compositors::ComputeTransitionGeometry)
// already implements all nine families, so there is no remaining per-family
// rejection on this route.
//
// Encoder/muxer/EGL/dual-decode-slot resources are all owned by this class
// and released on every exit path (success, failure, exception, cancel) --
// see [releaseAll]. [cancel] is thread-safe and forwarded promptly: the
// segment loop checks it between segments, and both
// [AndroidTimelineGlesTransitionOverlapDecoder]'s pipelines check it on every
// decode step.
//
// P5-GLES-EXPORT-TRANSITION-OVERLAYS: this class also composites static
// timeline overlays for the same narrow scope, now that
// [AndroidExportRenderBackendSelector.ExportRenderScope.glesTransitionEligible]
// no longer excludes overlays -- see the overlay-aware four-arg [encode]
// override. Overlay textures are uploaded once via
// [AndroidTimelineGlesOverlayRenderSession.prepare] right after [setupGl]
// succeeds (on this class's own EGL context), then composited on top of
// every solo and transition-pair frame drawn to the encoder's own default
// framebuffer (see [compositeActiveOverlaysIfPresent]), before that frame's
// presentation timestamp is set and it is swapped -- reusing the same GLES
// overlay compositing route (AndroidTimelineGlesOverlayRenderSession and the
// native overlay bridge) AndroidTimelineVideoEncoder's hard-cut path already
// uses, rather than building a new one. Reversed, still-image, and
// colorMatrix clips remain outside this route's scope even when overlays are
// also requested -- [validateClipShape] and
// [AndroidExportRenderBackendSelector.ExportRenderScope.glesTransitionIneligibleReason]
// both still reject those independently of [encode]'s `overlays` argument.
//
// P5-GLES-EXPORT-BEAUTY-TRANSITIONS, widened by
// P5-GLES-EXPORT-BEAUTY-TRANSITION-OVERLAYS: this class also applies
// clip-level Beauty V2 for the same narrow scope, now that
// [AndroidExportRenderBackendSelector.ExportRenderScope.glesTransitionEligible]
// no longer excludes it, including when paired with overlays -- Beauty is
// applied before transition composition and overlays are composited after
// transition composition (see [compositeActiveOverlaysIfPresent]), so the
// two combine without conflict. The remaining bounded exclusion is Beauty
// paired with any still-image clip in the scope, which remains ineligible
// with reason `beauty_with_still_image_unsupported` even when the
// still-image clip itself carries no Beauty -- see
// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS below -- gated by the selector
// before this class is ever constructed for such a scope, and re-checked
// defensively in [encode] itself before [setupEncoderAndMuxer]/[setupGl]
// run, not by [validateClipShape] alone. A solo
// segment whose clip carries a non-null `beautyIntensity` resolves its OES
// frame to a 2D texture first, then applies the existing native Beauty seam
// (`VanguardNativeBridge.drawAndroidDagPhase5GlesExportBeautySeam`, the same
// seam AndroidTimelineVideoEncoder's hard-cut Beauty route uses) directly
// into the encoder's own default framebuffer -- see [drawSoloFrameFromSlot].
// An Overlap segment's transition pair applies Beauty per side (when
// requested) into a dedicated canvas-sized Beauty output texture before
// handing the active (post-Beauty or plain-resolved) texture ids to the
// native transition compositor seam -- see [drawTransitionPair] and
// [applyBeautySeam]. Every rendered frame where Beauty was applied -- one
// per solo frame, one per transition-pair output frame where either side
// requested Beauty -- increments [beautyFramesRendered], returned as
// `EncodeResult.beautyFrameCount`. Requesting Beauty on an ES2-only device
// (`glMajorVersion < 3`) fails closed with `beauty_v2_gles_es3_required:
// <version>` before any segment renders, mirroring
// AndroidTimelineVideoEncoder's own preflight.
//
// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: a still-image clip
// (`ClipInput.mediaKind == "image"`) has no decoder/OES pipeline on this
// route -- it is decoded, EXIF-oriented, and uploaded to a plain
// GL_TEXTURE_2D by [AndroidTimelineGlesTransitionImageRenderer] instead. A
// solo image segment renders `ceil(windowSeconds * fps).coerceAtLeast(1)`
// frames of that one static texture directly into framebuffer 0 (see
// [renderSoloImageSegment]/[drawImageSoloFrame]), the same frame-count
// formula a solo video segment's real decode naturally produces. An overlap
// segment resolves each side into the same canvas-sized GL_TEXTURE_2D
// targets ([fromResolveTextureId]/[toResolveTextureId]) regardless of media
// kind -- a video side via its decoder + [resolveSlotToTexture2d], a
// still-image side via the helper's `drawToFramebuffer` -- then hands both
// resolved ids to the same native transition compositor seam
// ([presentTransitionPairFrame]) a video/video pair already used; see
// [renderOverlapMixedSegment] and [renderOverlapImageImageSegment]. An
// image side is loaded/resolved once per segment (it never changes across
// that segment's pairs), while a video side is re-resolved every step from
// its live decoder output, exactly as the pre-existing video/video route
// does.
internal class AndroidTimelineGlesTransitionVideoEncoder(
    private val outputPath: String,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrateBps: Int,
    private val nativeBridge: VanguardNativeBridge,
) : AndroidTimelineVideoPassEncoder {

    @Volatile private var cancelRequested = false

    override fun cancel() {
        cancelRequested = true
    }

    private val frameDurationUs = 1_000_000L / fps.coerceAtLeast(1)

    // ─── MediaCodec / MediaMuxer state (shared across every segment) ─────────
    private var codec: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var videoTrackIndex = -1
    private var writtenVideoSamples = 0
    private var framesSubmitted = 0

    private var totalExpectedSamples = 0
    private var onProgress: ((Double) -> Unit)? = null

    // ─── EGL / GL state (shared across every segment) ────────────────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var glMajorVersion = 2

    // ─── GLES overlay compositing state (P5-GLES-EXPORT-TRANSITION-OVERLAYS) ─
    // Populated only by the overlay-aware four-arg [encode] override below,
    // before setup and per-segment rendering; reset in [releaseAll] so a
    // reused encoder instance never carries over a prior call's overlay
    // session or frame count.
    private var pendingOverlays: List<AndroidTimelineOverlayDescriptor> = emptyList()
    private var glesOverlaySession: AndroidTimelineGlesOverlayRenderSession? = null
    private var overlayFramesRendered = 0

    // ─── GLES Beauty V2 compositing state (P5-GLES-EXPORT-BEAUTY-TRANSITIONS) ─
    // [pendingClipsForSetup] is populated by [encode] before [setupGl] runs
    // (setupGl itself takes no clip argument) purely so setupGl can decide
    // whether to allocate the Beauty output resources below; reset in
    // [releaseAll] alongside the other per-call state so a reused encoder
    // instance never carries over a prior call's clip list. [beautyFromFboId]/
    // [beautyFromTextureId] and [beautyToFboId]/[beautyToTextureId] are the
    // canvas-sized post-Beauty output targets for a transition-pair's from/to
    // side respectively (see [drawTransitionPair]) -- the solo Beauty path
    // (see [drawSoloFrameFromSlot]) reuses the plain [fromResolveFboId]/
    // [toResolveFboId] resolve targets as its pre-Beauty source instead of
    // needing a dedicated pair, since solo and overlap segments never render
    // concurrently.
    private var pendingClipsForSetup: List<AndroidTimelineVideoEncoder.ClipInput> = emptyList()
    private var beautyFramesRendered = 0
    private var beautyFromTextureId = 0
    private var beautyToTextureId = 0
    private var beautyFromFboId = 0
    private var beautyToFboId = 0

    // Single OES program used both for the solo draw (straight to the
    // encoder's EGL surface) and the overlap pre-resolve draw (into an
    // offscreen canvas-sized 2D FBO) -- both are the same "sample one OES
    // texture through its SurfaceTexture transform matrix, draw a fit quad"
    // operation, differing only in which framebuffer is currently bound.
    private var oesProgram = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0
    private var uSTMatrixLoc = 0

    private val texCoords = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
    private val quadBuffer: FloatBuffer = ByteBuffer.allocateDirect(8 * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer()
    private val texBuffer: FloatBuffer = ByteBuffer.allocateDirect(texCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(texCoords)
            position(0)
        }

    // Two persistent decode slots -- solo segments decode onto [fromSlot]
    // only; overlap segments decode onto both concurrently. Created once in
    // [setupGl], released once in [releaseAll].
    private val fromSlot = AndroidTimelineGlesTransitionDecodeSlot()
    private val toSlot = AndroidTimelineGlesTransitionDecodeSlot()

    // Canvas-sized offscreen resolve targets for overlap pre-resolve (see
    // [resolveSlotToTexture2d]) -- sized once for the whole encode() call.
    // P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: also the resolve target a
    // still-image overlap side draws into (see [renderOverlapImageImageSegment]
    // / [renderOverlapMixedSegment]) -- a still-image side has no decoder
    // slot of its own, so it shares these same canvas-sized 2D targets
    // instead of needing a dedicated pair.
    private var fromResolveTextureId = 0
    private var toResolveTextureId = 0
    private var fromResolveFboId = 0
    private var toResolveFboId = 0

    // P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: still-image decode/orient/
    // upload/draw helper, usable on this class's own EGL context -- see its
    // own class doc. Set up once in [setupGl] (only when this call's clips
    // include at least one still image), released once in [releaseAll].
    private val imageRenderer = AndroidTimelineGlesTransitionImageRenderer()

    override fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        onProgress: ((Double) -> Unit)?,
    ): AndroidTimelineVideoEncoder.EncodeResult = encode(clips, emptyList(), onProgress)

    override fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        transitions: List<AndroidTimelineTransitionDescriptor>,
        onProgress: ((Double) -> Unit)?,
    ): AndroidTimelineVideoEncoder.EncodeResult = encode(clips, transitions, emptyList(), onProgress)

    /// P5-GLES-EXPORT-TRANSITION-OVERLAYS: overlay-aware entry point and the
    /// actual implementation for this encoder -- both the plain hard-cut
    /// two-arg [encode] overload and the transition-aware three-arg overload
    /// above delegate here with an empty [overlays] list, so this override
    /// (rather than [AndroidTimelineVideoPassEncoder]'s fail-closed default)
    /// is what runs for every call. A non-empty [overlays] is uploaded once
    /// via [AndroidTimelineGlesOverlayRenderSession.prepare] right after
    /// [setupGl] succeeds, then composited on top of every solo/transition-
    /// pair frame (see [compositeActiveOverlaysIfPresent]).
    override fun encode(
        clips: List<AndroidTimelineVideoEncoder.ClipInput>,
        transitions: List<AndroidTimelineTransitionDescriptor>,
        overlays: List<AndroidTimelineOverlayDescriptor>,
        onProgress: ((Double) -> Unit)?,
    ): AndroidTimelineVideoEncoder.EncodeResult {
        this.onProgress = onProgress
        pendingOverlays = overlays
        pendingClipsForSetup = clips
        var succeeded = false
        var muxerStoppedCleanly = false
        var reason = "not_run"
        try {
            glMajorVersion = 2
            val nonHardCutTransitions = transitions.filter { !it.isHardCut }

            val plan = AndroidTimelineExportSegmentPlanner.build(clips, transitions, fps)
            if (plan.failureReason != null) {
                reason = "gles_transition_plan_failed:${plan.failureReason}"
                return AndroidTimelineVideoEncoder.EncodeResult(
                    false, reason, 0, 0L,
                    beautyFrameCount = beautyFramesRendered, glMajorVersion = glMajorVersion,
                )
            }
            totalExpectedSamples = plan.expectedSamples

            // P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: defense-in-depth against a
            // caller that constructs this class directly rather than going
            // through AndroidExportRenderBackendSelector -- Beauty V2 combined
            // with any still-image clip in the scope is out of scope for this
            // route regardless of which clip carries the non-null
            // beautyIntensity (see [ExportRenderScope.glesTransitionIneligibleReason]
            // for the primary gate), so this fails closed before any encoder/EGL
            // resource is ever allocated.
            if (clips.any { it.mediaKind == "image" } && clips.any { it.beautyIntensity != null }) {
                reason = "gles_transition_not_eligible:beauty_with_still_image_unsupported"
                return AndroidTimelineVideoEncoder.EncodeResult(
                    false, reason, 0, 0L,
                    beautyFrameCount = beautyFramesRendered, glMajorVersion = glMajorVersion,
                )
            }

            setupEncoderAndMuxer()
            setupGl()

            if (clips.any { it.beautyIntensity != null } && glMajorVersion < 3) {
                reason = "beauty_v2_gles_es3_required:$glMajorVersion"
                return AndroidTimelineVideoEncoder.EncodeResult(
                    false, reason, writtenVideoSamples, 0L,
                    beautyFrameCount = beautyFramesRendered,
                    overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
                )
            }

            if (pendingOverlays.isNotEmpty()) {
                when (
                    val prepareResult = AndroidTimelineGlesOverlayRenderSession.prepare(pendingOverlays) { cancelRequested }
                ) {
                    is AndroidTimelineGlesOverlayRenderSession.PrepareResult.Failure -> {
                        reason = "overlay_prepare_failed:${prepareResult.code}:${prepareResult.message}"
                        return AndroidTimelineVideoEncoder.EncodeResult(
                            false, reason, writtenVideoSamples, 0L,
                            beautyFrameCount = beautyFramesRendered,
                            overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
                        )
                    }
                    is AndroidTimelineGlesOverlayRenderSession.PrepareResult.Success -> {
                        glesOverlaySession = prepareResult.session
                    }
                }
            }

            for (segment in plan.segments) {
                if (cancelRequested) break
                val failure = when (segment) {
                    is AndroidTimelineExportSegment.Solo -> renderSoloSegment(segment)
                    is AndroidTimelineExportSegment.Overlap -> renderOverlapSegment(segment)
                }
                if (failure != null) {
                    if (cancelRequested) break
                    reason = failure
                    return AndroidTimelineVideoEncoder.EncodeResult(
                        false, reason, writtenVideoSamples, 0L,
                        beautyFrameCount = beautyFramesRendered,
                        overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
                    )
                }
            }

            if (cancelRequested) {
                reason = "cancelled"
                return AndroidTimelineVideoEncoder.EncodeResult(
                    false, reason, writtenVideoSamples, 0L,
                    beautyFrameCount = beautyFramesRendered,
                    overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
                )
            }

            codec!!.signalEndOfInputStream()
            val eosObserved = drainEncoder(endOfStream = true, deadlineMs = ENCODE_EOS_DEADLINE_MS)
            if (!eosObserved) {
                reason = "encoder_eos_drain_timeout"
                return AndroidTimelineVideoEncoder.EncodeResult(
                    false, reason, writtenVideoSamples, 0L,
                    beautyFrameCount = beautyFramesRendered,
                    overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
                )
            }

            if (writtenVideoSamples != framesSubmitted) {
                reason = "gles_transition_sample_count_mismatch:written=$writtenVideoSamples:rendered=$framesSubmitted"
                return AndroidTimelineVideoEncoder.EncodeResult(
                    false, reason, writtenVideoSamples, 0L,
                    beautyFrameCount = beautyFramesRendered,
                    overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
                )
            }

            if (!muxerStarted || writtenVideoSamples <= 0) {
                reason = "no_video_samples_written"
                return AndroidTimelineVideoEncoder.EncodeResult(
                    false, reason, writtenVideoSamples, 0L,
                    beautyFrameCount = beautyFramesRendered,
                    overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
                )
            }

            muxer!!.stop()
            muxerStoppedCleanly = true

            val outFile = File(outputPath)
            val outSize = if (outFile.exists()) outFile.length() else 0L
            if (outSize <= 0L) {
                reason = "output_file_empty_or_missing"
                return AndroidTimelineVideoEncoder.EncodeResult(
                    false, reason, writtenVideoSamples, 0L,
                    beautyFrameCount = beautyFramesRendered,
                    overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
                )
            }

            succeeded = true
            reason = "success"
            Log.i(
                TAG,
                "VG_GLES_TRANSITION_ENCODE_RESULT status=success rendered=$framesSubmitted " +
                    "written=$writtenVideoSamples outputSize=$outSize transitions=${nonHardCutTransitions.size} " +
                    "beautyFrames=$beautyFramesRendered overlayFrames=$overlayFramesRendered glMajorVersion=$glMajorVersion",
            )
            return AndroidTimelineVideoEncoder.EncodeResult(
                true, reason, writtenVideoSamples, outSize,
                beautyFrameCount = beautyFramesRendered,
                overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
            )
        } catch (t: Throwable) {
            reason = "exception:${t.javaClass.simpleName}"
            Log.e(TAG, "encode failed: $t", t)
            return AndroidTimelineVideoEncoder.EncodeResult(
                false, reason, writtenVideoSamples, 0L,
                beautyFrameCount = beautyFramesRendered,
                overlayFrameCount = overlayFramesRendered, glMajorVersion = glMajorVersion,
            )
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

    // ─────────────────────────────────────────────────────────────────────────
    // Defensive shape re-validation (see class doc)
    // ─────────────────────────────────────────────────────────────────────────

    /// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: accepts a still-image clip
    /// (mediaKind == "image") on the same narrow terms
    /// [AndroidExportRenderBackendSelector.ExportRenderScope.glesTransitionIneligibleReason]
    /// gates upstream -- positive stillFrameCount, rotationDegrees == 0, no
    /// Beauty -- alongside the pre-existing video branch. Any mediaKind
    /// other than "video"/"image" fails closed.
    private fun validateClipShape(clip: AndroidTimelineVideoEncoder.ClipInput): String? {
        if (clip.isReversed) return "gles_transition_not_eligible:reversed_clip:${clip.sourcePath}"
        if (clip.colorMatrix != null) return "gles_transition_not_eligible:color_matrix:${clip.sourcePath}"
        if (clip.decodedWidth <= 0 || clip.decodedHeight <= 0) {
            return "gles_transition_invalid_geometry:${clip.sourcePath}"
        }
        return when (clip.mediaKind) {
            "video" -> {
                if (clip.rotationDegrees !in setOf(0, 90, 180, 270)) {
                    "gles_transition_not_eligible:unsupported_rotation:${clip.rotationDegrees}:${clip.sourcePath}"
                } else {
                    null
                }
            }
            "image" -> {
                if (clip.stillFrameCount <= 0) {
                    "gles_transition_not_eligible:invalid_still_frame_count:${clip.sourcePath}"
                } else if (clip.rotationDegrees != 0) {
                    "gles_transition_not_eligible:unsupported_rotation:${clip.rotationDegrees}:${clip.sourcePath}"
                } else if (clip.beautyIntensity != null) {
                    "gles_transition_not_eligible:beauty_still_image_unsupported:${clip.sourcePath}"
                } else {
                    null
                }
            }
            else -> "gles_transition_not_eligible:unknown_media_kind:${clip.mediaKind}:${clip.sourcePath}"
        }
    }

    /// Centered, aspect-preserving "fit" quad (BL, BR, TL, TR NDC pairs) rotated by [rotationDegrees].
    private fun computeFitQuadOrNull(decodedWidth: Int, decodedHeight: Int, rotationDegrees: Int): FloatArray? {
        if (decodedWidth <= 0 || decodedHeight <= 0 || width <= 0 || height <= 0) return null
        val displayWidth: Float
        val displayHeight: Float
        if (rotationDegrees == 90 || rotationDegrees == 270) {
            displayWidth = decodedHeight.toFloat()
            displayHeight = decodedWidth.toFloat()
        } else {
            displayWidth = decodedWidth.toFloat()
            displayHeight = decodedHeight.toFloat()
        }
        val scale = min(width.toFloat() / displayWidth, height.toFloat() / displayHeight)
        val halfPixelX = decodedWidth.toFloat() * scale / 2f
        val halfPixelY = decodedHeight.toFloat() * scale / 2f

        val radians = Math.toRadians(-rotationDegrees.toDouble())
        val cosR = cos(radians).toFloat()
        val sinR = sin(radians).toFloat()
        fun rotatedPixel(x: Float, y: Float) = floatArrayOf(x * cosR - y * sinR, x * sinR + y * cosR)
        fun toNdc(p: FloatArray) =
            floatArrayOf(p[0] / (width.toFloat() / 2f), p[1] / (height.toFloat() / 2f))

        val bl = toNdc(rotatedPixel(-halfPixelX, -halfPixelY))
        val br = toNdc(rotatedPixel(halfPixelX, -halfPixelY))
        val tl = toNdc(rotatedPixel(-halfPixelX, halfPixelY))
        val tr = toNdc(rotatedPixel(halfPixelX, halfPixelY))
        return floatArrayOf(bl[0], bl[1], br[0], br[1], tl[0], tl[1], tr[0], tr[1])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Segment rendering
    // ─────────────────────────────────────────────────────────────────────────

    private fun renderSoloSegment(segment: AndroidTimelineExportSegment.Solo): String? {
        val clip = segment.clip
        val shapeFailure = validateClipShape(clip)
        if (shapeFailure != null) return shapeFailure
        return when (clip.mediaKind) {
            "video" -> renderSoloVideoSegment(segment)
            "image" -> renderSoloImageSegment(segment)
            else -> "gles_transition_not_eligible:unknown_media_kind:${clip.mediaKind}:${clip.sourcePath}"
        }
    }

    private fun renderSoloVideoSegment(segment: AndroidTimelineExportSegment.Solo): String? {
        val clip = segment.clip
        val quad = computeFitQuadOrNull(clip.decodedWidth, clip.decodedHeight, clip.rotationDegrees)
            ?: return "gles_transition_invalid_geometry:${clip.sourcePath}"

        val decoder = AndroidTimelineGlesTransitionOverlapDecoder(
            fromSource = AndroidTimelineGlesTransitionOverlapDecoder.Source(
                "solo", clip, segment.windowStartSeconds, segment.windowEndSeconds, fromSlot,
            ),
            toSource = null,
        ) { cancelRequested }

        val openError = decoder.open()
        if (openError != null) return "gles_transition_decoder_open_failed:solo:$openError"

        try {
            var rendered = 0
            while (true) {
                when (val step = decoder.nextStep()) {
                    is AndroidTimelineGlesTransitionOverlapDecoder.Step.Frames -> {
                        val drawFailure = drawSoloFrameFromSlot(fromSlot, quad, clip.beautyIntensity)
                        if (drawFailure != null) return drawFailure
                        drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                        rendered++
                    }
                    AndroidTimelineGlesTransitionOverlapDecoder.Step.Exhausted -> return finishSolo(rendered, clip)
                    AndroidTimelineGlesTransitionOverlapDecoder.Step.Cancelled -> return finishSolo(rendered, clip)
                    is AndroidTimelineGlesTransitionOverlapDecoder.Step.Failed ->
                        return "gles_transition_decode_failed:solo:${step.reason}"
                }
            }
        } finally {
            decoder.close()
        }
    }

    private fun finishSolo(rendered: Int, clip: AndroidTimelineVideoEncoder.ClipInput): String? {
        if (rendered == 0 && !cancelRequested) return "gles_transition_no_frames_in_window:${clip.sourcePath}"
        return null
    }

    /// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: renders [clip]'s decoded/
    /// oriented/uploaded texture for `ceil(windowSeconds * fps).coerceAtLeast(1)`
    /// frames -- the segment-window-scoped frame count, not the clip's full
    /// [ClipInput.stillFrameCount] (which covers the clip's whole trim window,
    /// including any portion lent to an adjacent transition's overlap).
    private fun renderSoloImageSegment(segment: AndroidTimelineExportSegment.Solo): String? {
        val clip = segment.clip
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        val loadResult = imageRenderer.loadTexture(clip, width, height)
        val (textureId, quad) = when (loadResult) {
            is AndroidTimelineGlesTransitionImageRenderer.LoadResult.Failure ->
                return "gles_transition_image_load_failed:${loadResult.reason}"
            is AndroidTimelineGlesTransitionImageRenderer.LoadResult.Success ->
                loadResult.textureId to loadResult.quad
        }
        try {
            val frameCount = ceil(
                (segment.windowEndSeconds - segment.windowStartSeconds) * fps,
            ).toInt().coerceAtLeast(1)
            var rendered = 0
            for (i in 0 until frameCount) {
                if (cancelRequested) break
                val drawFailure = drawImageSoloFrame(textureId, quad)
                if (drawFailure != null) return drawFailure
                drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                rendered++
            }
            return finishSolo(rendered, clip)
        } finally {
            imageRenderer.deleteTexture(textureId)
        }
    }

    /// Draws [textureId] through [quad]'s fit geometry directly into the
    /// encoder's own EGL surface, then presents/swaps -- the still-image
    /// analogue of [drawSoloFrameFromSlot] (Beauty never applies to a
    /// still-image clip, so there is no beauty branch here).
    private fun drawImageSoloFrame(textureId: Int, quad: FloatArray): String? {
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        val drawFailure = imageRenderer.drawToFramebuffer(textureId, quad, 0, width, height)
        if (drawFailure != null) return "gles_transition_draw_failed:image_solo:$drawFailure"

        val overlayFailure = compositeActiveOverlaysIfPresent()
        if (overlayFailure != null) return overlayFailure

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, framesSubmitted * frameDurationUs * 1000L)
        framesSubmitted++
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        return null
    }

    /// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: dispatches on each side's
    /// media kind -- both video keeps the pre-existing dual-decoder route
    /// ([renderOverlapVideoVideoSegment]); either side an image is handled by
    /// [renderOverlapImageImageSegment] (both static) or
    /// [renderOverlapMixedSegment] (one decoder-driven side, one static).
    private fun renderOverlapSegment(segment: AndroidTimelineExportSegment.Overlap): String? {
        val fromShapeFailure = validateClipShape(segment.fromClip)
        if (fromShapeFailure != null) return fromShapeFailure
        val toShapeFailure = validateClipShape(segment.toClip)
        if (toShapeFailure != null) return toShapeFailure

        val fromIsImage = segment.fromClip.mediaKind == "image"
        val toIsImage = segment.toClip.mediaKind == "image"
        return when {
            fromIsImage && toIsImage -> renderOverlapImageImageSegment(segment)
            !fromIsImage && !toIsImage -> renderOverlapVideoVideoSegment(segment)
            else -> renderOverlapMixedSegment(segment, fromIsImage)
        }
    }

    private fun renderOverlapVideoVideoSegment(segment: AndroidTimelineExportSegment.Overlap): String? {
        val transition = segment.transition
        val fromQuad = computeFitQuadOrNull(
            segment.fromClip.decodedWidth, segment.fromClip.decodedHeight, segment.fromClip.rotationDegrees,
        ) ?: return "gles_transition_invalid_geometry:${segment.fromClip.sourcePath}"
        val toQuad = computeFitQuadOrNull(
            segment.toClip.decodedWidth, segment.toClip.decodedHeight, segment.toClip.rotationDegrees,
        ) ?: return "gles_transition_invalid_geometry:${segment.toClip.sourcePath}"

        val decoder = AndroidTimelineGlesTransitionOverlapDecoder(
            fromSource = AndroidTimelineGlesTransitionOverlapDecoder.Source(
                "from", segment.fromClip, segment.fromWindowStartSeconds, segment.fromWindowEndSeconds, fromSlot,
            ),
            toSource = AndroidTimelineGlesTransitionOverlapDecoder.Source(
                "to", segment.toClip, segment.toWindowStartSeconds, segment.toWindowEndSeconds, toSlot,
            ),
        ) { cancelRequested }

        val openError = decoder.open()
        if (openError != null) return "gles_transition_decoder_open_failed:${transition.transitionId}:$openError"

        try {
            val expectedPairs = transition.overlapFrameCount(fps)
            var pairsRendered = 0
            var fromDecodedCount = 0
            var toDecodedCount = 0

            loop@ while (true) {
                when (val step = decoder.nextStep()) {
                    is AndroidTimelineGlesTransitionOverlapDecoder.Step.Frames -> {
                        if (step.from != null) fromDecodedCount++
                        if (step.to != null) toDecodedCount++
                        val drawFailure: String?
                        if (step.from != null && step.to != null) {
                            val progress = transition.progressForOverlapFrame(pairsRendered, expectedPairs)
                            drawFailure = drawTransitionPair(
                                segment.fromClip, segment.toClip, fromQuad, toQuad, progress, transition.type.nativeCode,
                            )
                            if (drawFailure == null) pairsRendered++
                        } else if (step.from != null) {
                            drawFailure = drawSoloFrameFromSlot(fromSlot, fromQuad, segment.fromClip.beautyIntensity)
                        } else {
                            drawFailure = drawSoloFrameFromSlot(toSlot, toQuad, segment.toClip.beautyIntensity)
                        }
                        if (drawFailure != null) return drawFailure
                        drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                    }
                    AndroidTimelineGlesTransitionOverlapDecoder.Step.Exhausted -> break@loop
                    AndroidTimelineGlesTransitionOverlapDecoder.Step.Cancelled -> break@loop
                    is AndroidTimelineGlesTransitionOverlapDecoder.Step.Failed ->
                        return "gles_transition_decode_failed:${transition.transitionId}:${step.reason}"
                }
            }

            if (!cancelRequested && pairsRendered == 0 && fromDecodedCount == 0 && toDecodedCount == 0) {
                return "gles_transition_no_frames_in_window:${transition.transitionId}"
            }
            Log.i(
                TAG,
                "VG_GLES_TRANSITION_SEGMENT transition=${transition.transitionId} " +
                    "type=${transition.type.wireName} pairs=$pairsRendered expected=$expectedPairs " +
                    "fromDecoded=$fromDecodedCount toDecoded=$toDecodedCount",
            )
            return null
        } finally {
            decoder.close()
        }
    }

    /// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: both sides of this overlap are
    /// still images -- neither has a decoder, so both are loaded/resolved
    /// exactly once and every pair frame ([transition.overlapFrameCount])
    /// re-composites the same two static resolved textures at increasing
    /// progress, rather than stepping any decoder.
    private fun renderOverlapImageImageSegment(segment: AndroidTimelineExportSegment.Overlap): String? {
        val transition = segment.transition
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        val fromLoad = imageRenderer.loadTexture(segment.fromClip, width, height)
        val (fromTextureId, fromQuad) = when (fromLoad) {
            is AndroidTimelineGlesTransitionImageRenderer.LoadResult.Failure ->
                return "gles_transition_image_load_failed:from:${fromLoad.reason}"
            is AndroidTimelineGlesTransitionImageRenderer.LoadResult.Success ->
                fromLoad.textureId to fromLoad.quad
        }
        try {
            val toLoad = imageRenderer.loadTexture(segment.toClip, width, height)
            val (toTextureId, toQuad) = when (toLoad) {
                is AndroidTimelineGlesTransitionImageRenderer.LoadResult.Failure ->
                    return "gles_transition_image_load_failed:to:${toLoad.reason}"
                is AndroidTimelineGlesTransitionImageRenderer.LoadResult.Success ->
                    toLoad.textureId to toLoad.quad
            }
            try {
                val fromResolveFailure = imageRenderer.drawToFramebuffer(fromTextureId, fromQuad, fromResolveFboId, width, height)
                if (fromResolveFailure != null) return "gles_transition_resolve_failed:from:$fromResolveFailure"
                val toResolveFailure = imageRenderer.drawToFramebuffer(toTextureId, toQuad, toResolveFboId, width, height)
                if (toResolveFailure != null) return "gles_transition_resolve_failed:to:$toResolveFailure"

                val expectedPairs = transition.overlapFrameCount(fps)
                var pairsRendered = 0
                for (i in 0 until expectedPairs) {
                    if (cancelRequested) break
                    EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                    val progress = transition.progressForOverlapFrame(i, expectedPairs)
                    val presentFailure = presentTransitionPairFrame(
                        fromResolveTextureId, toResolveTextureId, progress, transition.type.nativeCode,
                    )
                    if (presentFailure != null) return presentFailure
                    pairsRendered++
                    drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                }
                if (!cancelRequested && pairsRendered == 0) {
                    return "gles_transition_no_frames_in_window:${transition.transitionId}"
                }
                Log.i(
                    TAG,
                    "VG_GLES_TRANSITION_SEGMENT transition=${transition.transitionId} " +
                        "type=${transition.type.wireName} pairs=$pairsRendered expected=$expectedPairs " +
                        "fromDecoded=static toDecoded=static",
                )
                return null
            } finally {
                imageRenderer.deleteTexture(toTextureId)
            }
        } finally {
            imageRenderer.deleteTexture(fromTextureId)
        }
    }

    /// P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: exactly one side of this
    /// overlap is a still image -- that side is loaded/resolved exactly once
    /// (it never changes across this segment's pairs) while the other
    /// (video) side is stepped through its own single-source
    /// [AndroidTimelineGlesTransitionOverlapDecoder] pipeline, resolved fresh
    /// every step, and (when it carries Beauty) run through the existing
    /// native Beauty seam before each pair draw -- exactly the per-side
    /// handling [renderOverlapVideoVideoSegment] already gives a video side.
    private fun renderOverlapMixedSegment(segment: AndroidTimelineExportSegment.Overlap, fromIsImage: Boolean): String? {
        val transition = segment.transition
        val imageClip = if (fromIsImage) segment.fromClip else segment.toClip
        val videoClip = if (fromIsImage) segment.toClip else segment.fromClip
        val videoSlot = if (fromIsImage) toSlot else fromSlot
        val videoWindowStart = if (fromIsImage) segment.toWindowStartSeconds else segment.fromWindowStartSeconds
        val videoWindowEnd = if (fromIsImage) segment.toWindowEndSeconds else segment.fromWindowEndSeconds
        val imageResolveFboId = if (fromIsImage) fromResolveFboId else toResolveFboId
        val videoResolveFboId = if (fromIsImage) toResolveFboId else fromResolveFboId
        val imageResolveTextureId = if (fromIsImage) fromResolveTextureId else toResolveTextureId
        val videoResolveTextureId = if (fromIsImage) toResolveTextureId else fromResolveTextureId
        val videoBeautyFboId = if (fromIsImage) beautyToFboId else beautyFromFboId
        val videoBeautyTextureId = if (fromIsImage) beautyToTextureId else beautyFromTextureId

        val videoQuad = computeFitQuadOrNull(videoClip.decodedWidth, videoClip.decodedHeight, videoClip.rotationDegrees)
            ?: return "gles_transition_invalid_geometry:${videoClip.sourcePath}"

        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        val imageLoad = imageRenderer.loadTexture(imageClip, width, height)
        val (imageTextureId, imageQuad) = when (imageLoad) {
            is AndroidTimelineGlesTransitionImageRenderer.LoadResult.Failure ->
                return "gles_transition_image_load_failed:${imageLoad.reason}"
            is AndroidTimelineGlesTransitionImageRenderer.LoadResult.Success ->
                imageLoad.textureId to imageLoad.quad
        }
        try {
            val imageResolveFailure = imageRenderer.drawToFramebuffer(imageTextureId, imageQuad, imageResolveFboId, width, height)
            if (imageResolveFailure != null) return "gles_transition_resolve_failed:image:$imageResolveFailure"

            val decoder = AndroidTimelineGlesTransitionOverlapDecoder(
                fromSource = AndroidTimelineGlesTransitionOverlapDecoder.Source(
                    "video", videoClip, videoWindowStart, videoWindowEnd, videoSlot,
                ),
                toSource = null,
            ) { cancelRequested }

            val openError = decoder.open()
            if (openError != null) return "gles_transition_decoder_open_failed:${transition.transitionId}:$openError"

            try {
                val expectedPairs = transition.overlapFrameCount(fps)
                var pairsRendered = 0
                var videoDecodedCount = 0

                loop@ while (true) {
                    when (val step = decoder.nextStep()) {
                        is AndroidTimelineGlesTransitionOverlapDecoder.Step.Frames -> {
                            if (step.from == null) continue@loop
                            videoDecodedCount++
                            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                            val videoResolveFailure = resolveSlotToTexture2d(videoSlot, videoQuad, videoResolveFboId)
                            if (videoResolveFailure != null) return "gles_transition_resolve_failed:video:$videoResolveFailure"

                            var videoActiveTextureId = videoResolveTextureId
                            val videoBeautyIntensity = videoClip.beautyIntensity
                            if (videoBeautyIntensity != null) {
                                val beautyFailure = applyBeautySeam(videoResolveTextureId, videoBeautyFboId, videoBeautyIntensity)
                                if (beautyFailure != null) return "gles_transition_beauty_failed:video:$beautyFailure"
                                videoActiveTextureId = videoBeautyTextureId
                                beautyFramesRendered++
                            }

                            val fromActiveTextureId = if (fromIsImage) imageResolveTextureId else videoActiveTextureId
                            val toActiveTextureId = if (fromIsImage) videoActiveTextureId else imageResolveTextureId
                            val progress = transition.progressForOverlapFrame(pairsRendered, expectedPairs)
                            val presentFailure = presentTransitionPairFrame(
                                fromActiveTextureId, toActiveTextureId, progress, transition.type.nativeCode,
                            )
                            if (presentFailure != null) return presentFailure
                            pairsRendered++
                            drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                        }
                        AndroidTimelineGlesTransitionOverlapDecoder.Step.Exhausted -> break@loop
                        AndroidTimelineGlesTransitionOverlapDecoder.Step.Cancelled -> break@loop
                        is AndroidTimelineGlesTransitionOverlapDecoder.Step.Failed ->
                            return "gles_transition_decode_failed:${transition.transitionId}:${step.reason}"
                    }
                }

                if (!cancelRequested && pairsRendered == 0 && videoDecodedCount == 0) {
                    return "gles_transition_no_frames_in_window:${transition.transitionId}"
                }
                Log.i(
                    TAG,
                    "VG_GLES_TRANSITION_SEGMENT transition=${transition.transitionId} " +
                        "type=${transition.type.wireName} pairs=$pairsRendered expected=$expectedPairs " +
                        "videoDecoded=$videoDecodedCount imageStatic=1",
                )
                return null
            } finally {
                decoder.close()
            }
        } finally {
            imageRenderer.deleteTexture(imageTextureId)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GL draw helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Draws [slot]'s current OES texture (already updateTexImage()'d),
    /// through [quad]'s fit geometry, directly into the encoder's own EGL
    /// surface, then presents/swaps -- the plain hard-cut draw path, used for
    /// solo segments and for any unpaired edge frame of an overlap segment.
    /// P5-GLES-EXPORT-BEAUTY-TRANSITIONS: when [beautyIntensity] is non-null,
    /// [slot]'s OES frame is first resolved into that slot's own plain 2D
    /// resolve target (reused as scratch here since solo and overlap draws
    /// never run concurrently), then the existing native Beauty seam is
    /// applied directly into framebuffer 0 via [applyBeautySeam] instead of
    /// the plain OES draw -- see [drawOesQuad] vs [applyBeautySeam].
    private fun drawSoloFrameFromSlot(
        slot: AndroidTimelineGlesTransitionDecodeSlot,
        quad: FloatArray,
        beautyIntensity: Double?,
    ): String? {
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        if (beautyIntensity != null) {
            val resolveFboId = if (slot === fromSlot) fromResolveFboId else toResolveFboId
            val resolveTextureId = if (slot === fromSlot) fromResolveTextureId else toResolveTextureId
            val resolveFailure = resolveSlotToTexture2d(slot, quad, resolveFboId)
            if (resolveFailure != null) return "gles_transition_draw_failed:solo:$resolveFailure"
            val beautyFailure = applyBeautySeam(resolveTextureId, 0, beautyIntensity)
            if (beautyFailure != null) return "gles_transition_draw_failed:solo:$beautyFailure"
            beautyFramesRendered++
        } else {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            val drawFailure = drawOesQuad(slot, quad)
            if (drawFailure != null) return "gles_transition_draw_failed:solo:$drawFailure"
        }

        val overlayFailure = compositeActiveOverlaysIfPresent()
        if (overlayFailure != null) return overlayFailure

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, framesSubmitted * frameDurationUs * 1000L)
        framesSubmitted++
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        return null
    }

    /// Pre-resolves both sides (with their own SurfaceTexture transform
    /// matrices applied, through their own fit geometry) into their
    /// canvas-sized 2D FBOs, then hands both resolved textures to the native
    /// transition compositor seam at [transitionTypeCode]
    /// (AndroidTimelineTransitionDescriptor.Type.nativeCode), then
    /// presents/swaps the encoder surface.
    /// P5-GLES-EXPORT-BEAUTY-TRANSITIONS: when [fromClip]/[toClip] carries a
    /// non-null `beautyIntensity`, that side's plain-resolved texture is run
    /// through the existing native Beauty seam into its own dedicated Beauty
    /// output texture ([beautyFromFboId]/[beautyFromTextureId] or
    /// [beautyToFboId]/[beautyToTextureId]) via [applyBeautySeam] first, and
    /// the post-Beauty texture id (rather than the plain resolve texture id)
    /// is what gets handed to the native transition compositor seam below.
    /// [beautyFramesRendered] is incremented once per output frame where
    /// either side requested Beauty, regardless of whether one or both sides
    /// did.
    private fun drawTransitionPair(
        fromClip: AndroidTimelineVideoEncoder.ClipInput,
        toClip: AndroidTimelineVideoEncoder.ClipInput,
        fromQuad: FloatArray,
        toQuad: FloatArray,
        progress: Double,
        transitionTypeCode: Int,
    ): String? {
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        val fromResolveFailure = resolveSlotToTexture2d(fromSlot, fromQuad, fromResolveFboId)
        if (fromResolveFailure != null) return "gles_transition_resolve_failed:from:$fromResolveFailure"
        val toResolveFailure = resolveSlotToTexture2d(toSlot, toQuad, toResolveFboId)
        if (toResolveFailure != null) return "gles_transition_resolve_failed:to:$toResolveFailure"

        var fromActiveTextureId = fromResolveTextureId
        val fromBeautyIntensity = fromClip.beautyIntensity
        if (fromBeautyIntensity != null) {
            val beautyFailure = applyBeautySeam(fromResolveTextureId, beautyFromFboId, fromBeautyIntensity)
            if (beautyFailure != null) return "gles_transition_beauty_failed:from:$beautyFailure"
            fromActiveTextureId = beautyFromTextureId
        }
        var toActiveTextureId = toResolveTextureId
        val toBeautyIntensity = toClip.beautyIntensity
        if (toBeautyIntensity != null) {
            val beautyFailure = applyBeautySeam(toResolveTextureId, beautyToFboId, toBeautyIntensity)
            if (beautyFailure != null) return "gles_transition_beauty_failed:to:$beautyFailure"
            toActiveTextureId = beautyToTextureId
        }
        if (fromBeautyIntensity != null || toBeautyIntensity != null) {
            beautyFramesRendered++
        }

        return presentTransitionPairFrame(fromActiveTextureId, toActiveTextureId, progress, transitionTypeCode)
    }

    /// Shared tail for every transition-pair draw (video/video, image/image,
    /// mixed) once both sides are already resolved (and, where applicable,
    /// Beauty-applied) into a canvas-sized GL_TEXTURE_2D id: clears the
    /// target (encoder) surface, hands both texture ids to the native
    /// transition compositor seam at [transitionTypeCode]
    /// (AndroidTimelineTransitionDescriptor.Type.nativeCode) and [progress],
    /// composites active overlays, then presents/swaps.
    private fun presentTransitionPairFrame(
        fromTextureId: Int,
        toTextureId: Int,
        progress: Double,
        transitionTypeCode: Int,
    ): String? {
        // Kotlin owns frame clear on the target (encoder) surface -- the
        // native seam never clears the framebuffer itself.
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        val status = nativeBridge.drawAndroidTimelineGlesTransitionExportFrame(
            fromTextureId,
            GLES20.GL_TEXTURE_2D,
            toTextureId,
            GLES20.GL_TEXTURE_2D,
            width,
            height,
            transitionTypeCode,
            progress,
        )
        if (!status.startsWith("status=OK")) {
            return "gles_transition_render_failed:$status"
        }

        val overlayFailure = compositeActiveOverlaysIfPresent()
        if (overlayFailure != null) return overlayFailure

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, framesSubmitted * frameDurationUs * 1000L)
        framesSubmitted++
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        return null
    }

    /// Draws [slot]'s current OES texture, through [quad]'s fit geometry,
    /// into [fboId] (a canvas-sized GL_TEXTURE_2D-backed FBO) instead of the
    /// default framebuffer. Leaves the default framebuffer bound on return.
    private fun resolveSlotToTexture2d(
        slot: AndroidTimelineGlesTransitionDecodeSlot,
        quad: FloatArray,
        fboId: Int,
    ): String? {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        val drawFailure = drawOesQuad(slot, quad)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return drawFailure
    }

    /// Shared draw body for both [drawSoloFrameFromSlot] and
    /// [resolveSlotToTexture2d]: clears the currently-bound framebuffer to
    /// black, draws [slot]'s OES texture through [quad] using [oesProgram],
    /// and reports the first GL error observed (if any). Callers own
    /// framebuffer binding and presentation.
    private fun drawOesQuad(slot: AndroidTimelineGlesTransitionDecodeSlot, quad: FloatArray): String? {
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(oesProgram)

        quadBuffer.position(0)
        quadBuffer.put(quad)
        quadBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)

        texBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuffer)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, slot.oesTextureId)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, slot.transformMatrix, 0)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glUseProgram(0)

        val err = GLES20.glGetError()
        return if (err == GLES20.GL_NO_ERROR) null else "gl_error:$err"
    }

    /// P5-GLES-EXPORT-BEAUTY-TRANSITIONS: applies the existing native Beauty
    /// V2 seam (`VanguardNativeBridge.drawAndroidDagPhase5GlesExportBeautySeam`
    /// -- the same seam AndroidTimelineVideoEncoder's hard-cut Beauty route
    /// uses) to an already-resolved GL_TEXTURE_2D [sourceTextureId], drawing
    /// into [targetFboId] (0 for the encoder's own default framebuffer, for
    /// the solo path; one of the dedicated Beauty output FBOs for an overlap
    /// side). Leaves the default framebuffer bound on return. Returns a
    /// machine-readable failure reason on any GL/native/parse failure, or
    /// null on success.
    private fun applyBeautySeam(sourceTextureId: Int, targetFboId: Int, intensity: Double): String? {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, targetFboId)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        val rawStatus = nativeBridge.drawAndroidDagPhase5GlesExportBeautySeam(
            sourceTextureId, 0, width, height, intensity.toFloat(),
        )
        val statusJson = try { JSONObject(rawStatus) } catch (t: Throwable) { null }
        val pass = statusJson?.optBoolean("pass", false) == true ||
            statusJson?.optString("status") == "PASS"
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        if (!pass) {
            val failureDetail = statusJson?.optString("failureReason")?.takeIf { it.isNotEmpty() }
                ?: statusJson?.optString("status")?.takeIf { it.isNotEmpty() }
                ?: "unparseable_seam_response"
            return "beauty_v2_gles_render_failed:$failureDetail"
        }
        return null
    }

    /// P5-GLES-EXPORT-TRANSITION-OVERLAYS: composites every overlay active
    /// at this frame's timeline instant (`framesSubmitted * frameDurationUs`)
    /// via [glesOverlaySession], when one is prepared -- a legal no-op when
    /// it is null (no overlays for this encode call) or when no overlay is
    /// active at this instant. Callers must invoke this after the base solo
    /// or transition-pair draw, while framebuffer 0 is still bound/current,
    /// and before `eglPresentationTimeANDROID`/`framesSubmitted++`/
    /// `eglSwapBuffers` -- see [drawSoloFrameFromSlot] and
    /// [drawTransitionPair]. Returns a machine-readable failure reason on
    /// any failure (the frame is never presented/swapped with a
    /// silently-dropped overlay), or null on success.
    private fun compositeActiveOverlaysIfPresent(): String? {
        val session = glesOverlaySession ?: return null
        val timelinePtsUs = framesSubmitted.toLong() * frameDurationUs
        return when (val result = session.drawActiveOverlays(nativeBridge, timelinePtsUs, width, height)) {
            is AndroidTimelineGlesOverlayRenderSession.DrawResult.Success -> {
                if (result.activeOverlayCount > 0) overlayFramesRendered++
                null
            }
            is AndroidTimelineGlesOverlayRenderSession.DrawResult.Failure -> "overlay_draw_failed:${result.reason}"
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupEncoderAndMuxer() {
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
    }

    private fun setupGl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) throw IllegalStateException("eglGetDisplay failed")
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw IllegalStateException("eglInitialize failed")
        }

        val attribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0)
        val config = configs[0] ?: throw IllegalStateException("eglChooseConfig failed")

        // ES3-first (falls back to ES2), mirroring AndroidTimelineVideoEncoder.
        val contextAttribsEs3 = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribsEs3, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            val contextAttribsEs2 = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            eglContext = EGL14.eglCreateContext(eglDisplay, config, EGL14.EGL_NO_CONTEXT, contextAttribsEs2, 0)
        }
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw IllegalStateException("eglCreateContext failed")

        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, config, encoderInputSurface, surfaceAttribs, 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw IllegalStateException("eglCreateWindowSurface failed")

        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw IllegalStateException("eglMakeCurrent failed")
        }

        val majorVersionOut = IntArray(1)
        GLES20.glGetIntegerv(GLES30.GL_MAJOR_VERSION, majorVersionOut, 0)
        val majorVersionQueryError = GLES20.glGetError()
        glMajorVersion = if (majorVersionQueryError == GLES20.GL_NO_ERROR && majorVersionOut[0] >= 3) {
            majorVersionOut[0]
        } else {
            while (GLES20.glGetError() != GLES20.GL_NO_ERROR) {
                // Drain any remaining pending GL error from the failed query.
            }
            2
        }

        fromSlot.setup()
        toSlot.setup()
        setupOesProgram()

        // P5-GLES-EXPORT-STILL-IMAGE-TRANSITIONS: only compiled when this
        // call's clips actually include a still image, mirroring the Beauty
        // resource-allocation gate below.
        if (pendingClipsForSetup.any { it.mediaKind == "image" }) {
            imageRenderer.setup()
        }

        fromResolveTextureId = createRgba8Texture(width, height)
        toResolveTextureId = createRgba8Texture(width, height)
        if (fromResolveTextureId == 0 || toResolveTextureId == 0) {
            throw IllegalStateException("resolve texture creation failed")
        }
        fromResolveFboId = createFramebufferForTexture(fromResolveTextureId)
        if (fromResolveFboId == 0) throw IllegalStateException("resolve fbo incomplete: from")
        toResolveFboId = createFramebufferForTexture(toResolveTextureId)
        if (toResolveFboId == 0) throw IllegalStateException("resolve fbo incomplete: to")

        // P5-GLES-EXPORT-BEAUTY-TRANSITIONS: only allocated when this call's
        // clips actually request Beauty V2 -- the ES3 requirement itself is
        // checked by the caller right after [setupGl] returns (using
        // [glMajorVersion] negotiated above), so a precise
        // `beauty_v2_gles_es3_required:<version>` EncodeResult reason can be
        // returned directly instead of collapsing into a generic thrown-
        // exception reason.
        if (pendingClipsForSetup.any { it.beautyIntensity != null }) {
            beautyFromTextureId = createRgba8Texture(width, height)
            beautyToTextureId = createRgba8Texture(width, height)
            if (beautyFromTextureId == 0 || beautyToTextureId == 0) {
                throw IllegalStateException("beauty texture creation failed")
            }
            beautyFromFboId = createFramebufferForTexture(beautyFromTextureId)
            if (beautyFromFboId == 0) throw IllegalStateException("beauty fbo incomplete: from")
            beautyToFboId = createFramebufferForTexture(beautyToTextureId)
            if (beautyToFboId == 0) throw IllegalStateException("beauty fbo incomplete: to")
        }
    }

    private fun setupOesProgram() {
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            uniform mat4 uSTMatrix;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = (uSTMatrix * aTextureCoord).xy;
            }
        """.trimIndent()
        val fragmentSrc = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTextureCoord);
            }
        """.trimIndent()

        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("GL program link failed: $log")
        }
        oesProgram = program
        aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
        uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("GL shader compile failed: $log")
        }
        return shader
    }

    private fun createRgba8Texture(w: Int, h: Int): Int {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        val id = textures[0]
        if (id == 0) return 0
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        return if (GLES20.glGetError() == GLES20.GL_NO_ERROR) id else 0
    }

    private fun createFramebufferForTexture(textureId: Int): Int {
        val fbos = IntArray(1)
        GLES20.glGenFramebuffers(1, fbos, 0)
        val fbo = fbos[0]
        if (fbo == 0) return 0
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, textureId, 0)
        val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return if (status == GLES20.GL_FRAMEBUFFER_COMPLETE) fbo else 0
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Encoder output drain (fixed frame clock, matching AndroidTimelineVideoEncoder)
    // ─────────────────────────────────────────────────────────────────────────

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

    private fun releaseAll() {
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        try { muxer?.release() } catch (_: Throwable) {}

        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                // Close before GL texture/FBO/program teardown --
                // glesOverlaySession.close() deletes GL textures and
                // requires this same context still current.
                glesOverlaySession?.close()
                imageRenderer.release()
                if (oesProgram != 0) GLES20.glDeleteProgram(oesProgram)
                if (fromResolveFboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(fromResolveFboId), 0)
                if (toResolveFboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(toResolveFboId), 0)
                if (fromResolveTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(fromResolveTextureId), 0)
                if (toResolveTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(toResolveTextureId), 0)
                // P5-GLES-EXPORT-BEAUTY-TRANSITIONS: deleted before EGL
                // context destruction below, same as the plain resolve
                // FBOs/textures above -- a no-op (0) when Beauty was never
                // requested/allocated for this call.
                if (beautyFromFboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(beautyFromFboId), 0)
                if (beautyToFboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(beautyToFboId), 0)
                if (beautyFromTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(beautyFromTextureId), 0)
                if (beautyToTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(beautyToTextureId), 0)
                fromSlot.release()
                toSlot.release()
            } catch (_: Throwable) {}
        }
        // Reset regardless of whether GL setup ever ran this call, so a
        // reused encoder instance can never composite a stale (already
        // closed) overlay session or carry over a prior call's overlay
        // frame count / pending overlay list into its next encode() call.
        glesOverlaySession = null
        overlayFramesRendered = 0
        pendingOverlays = emptyList()
        // P5-GLES-EXPORT-BEAUTY-TRANSITIONS: reset regardless of whether GL
        // Beauty setup ever ran (or partially ran before a failure) this
        // call, mirroring the overlay state reset above.
        beautyFramesRendered = 0
        pendingClipsForSetup = emptyList()
        beautyFromTextureId = 0
        beautyToTextureId = 0
        beautyFromFboId = 0
        beautyToFboId = 0

        try { encoderInputSurface?.release() } catch (_: Throwable) {}

        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            } catch (_: Throwable) {}
            if (eglSurface != EGL14.EGL_NO_SURFACE) {
                try { EGL14.eglDestroySurface(eglDisplay, eglSurface) } catch (_: Throwable) {}
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
            }
            try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val TAG = "VGGlesTransitionEnc"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val ENCODE_DRAIN_DEADLINE_MS = 2_000L
        private const val ENCODE_EOS_DEADLINE_MS = 5_000L
    }
}
