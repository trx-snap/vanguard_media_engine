package com.connects.vanguard_media_engine.export

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.media.ExifInterface
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
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
import android.opengl.GLUtils
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// ── AndroidTimelineVideoEncoder (Export Unit C) ───────────────────────────────
//
// GLES fallback / frozen-export-path implementation of
// [AndroidTimelineVideoPassEncoder] for the production `exportTimeline`
// route. Vulkan is the preferred/default render backend for new export
// development (see AndroidExportRenderBackendSelector); this class remains
// the only implemented pass-1 render path until a Vulkan export baseline
// exists, and is not the architectural primary for future parity features --
// it must not grow new rendering behaviour beyond what it already does.
// Fully independent of the legacy `VanguardMediaCodecEncoder` (dev/proof
// path) -- no shared state, no MethodChannel calls, no onExportComplete
// callback. This class is never reused by legacy `startExport`.
//
// Real video frame transfer (Opus correction): each decoder output frame is
// released onto a SurfaceTexture-backed OES texture, then drawn by a GL
// passthrough shader into the encoder's own input EGL surface before
// eglSwapBuffers submits it to MediaCodec. This is a genuine GPU pixel
// transfer -- never a null-surface decode paired with a swapped-but-undrawn
// encoder surface, which was the legacy false-proof pattern this Unit
// replaces.
//
// PTS mechanism (frozen — do not change without re-verifying multi-clip
// continuity): fixed frame clock on encoder output. Each muxed sample's
// presentationTimeUs = writtenVideoSamples * frameDurationUs, mirroring
// AndroidDagRenderSmokeHarness's Phase-5 encoder drain. Because clips are
// concatenated hard-cut (no overlap), this produces a strictly increasing,
// gap-free PTS sequence across clip boundaries without any per-clip timestamp
// bookkeeping.
//
// Guardrails enforced upstream by AndroidTimelineExportSession (not here):
// video-only clips, speed == 1.0, canvas contentMode == "fit", clip rotation
// metadata normalized to 0/90/180/270.
//
// Canvas contentMode="fit" (Unit G): each clip's decoded frame is centered
// and aspect-preserving scaled to fit within the fixed encoder output surface
// over a black background, then rotated in output vertex space by the clip's
// rotation metadata -- see [updateClipGeometry]. Texture coordinates are
// left unrotated; SurfaceTexture's own transform matrix (uSTMatrix) remains
// the only texture-space transform. Vertex geometry is recomputed once per
// clip, not per frame.
//
// P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: a clip with [ClipInput.isReversed] set
// is rendered by [renderReversedClipIntoEncoder] instead of
// [decodeClipIntoEncoder] -- MediaMetadataRetriever.getFrameAtTime walks the
// clip's trim window backwards, and each Bitmap is uploaded as a plain 2D
// texture and drawn through the same still-image 2D program
// ([drawAndSubmitFrame2D]) a still-image clip uses, rather than the OES
// SurfaceTexture decode path. This is the only reversed-clip render route:
// AndroidTimelineVulkanVideoEncoder fails closed if it ever receives one.
//
// Phase 7.17-Android freeze frame: a video clip with a non-null
// [ClipInput.freezePTS] is rendered by [renderFreezeClipIntoEncoder] -- a
// sibling of the still-image and reversed routes -- which extracts exactly one
// source frame at that PTS via MediaMetadataRetriever.getFrameAtTime
// (OPTION_CLOSEST), uploads it once as a plain 2D texture, and draws it through
// the same [drawAndSubmitFrame2D] path for the clip's whole timeline hold
// (ceil(((trimEnd - trimStart) / speed) * fps) frames, floored at 1). Freeze
// clips never route to Vulkan or the GLES transition encoder
// (AndroidExportRenderBackendSelector keeps them on this encoder).
class AndroidTimelineVideoEncoder(
    private val outputPath: String,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrateBps: Int,
    // P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A: optional native bridge used
    // ONLY to composite overlays (see [drawAndSubmitFrame] /
    // AndroidTimelineGlesOverlayRenderSession) on the narrow
    // AndroidExportRenderBackendSelector.glesOverlayEligible shape. Callers
    // with no overlay-aware use of this encoder (existing constructor call
    // sites) keep working unchanged via the default.
    private val nativeBridge: VanguardNativeBridge? = null,
    // Android reference-video export: optional Context used ONLY to open a
    // `content://` ClipInput.sourcePath through the ContentResolver
    // (AndroidUriDataSourceHelper) in [decodeClipIntoEncoder] /
    // [renderReversedClipIntoEncoder]. POSIX sources never touch it. A
    // `content://` clip with a null Context fails closed through the same
    // clip_decode_exception / reversed_clip_render_exception reasons as any
    // other open failure -- it never crashes the encode. Diagnostics/harness
    // constructors keep working unchanged via the default.
    private val context: Context? = null,
    /**
     * Wire `canvas.contentMode` ("fit" | "fill"; only these two reach this
     * encoder). "fit" (default, byte-equivalent to this encoder's original
     * behaviour) letterboxes/pillarboxes each clip inside the canvas
     * (scale = min(canvas/display)). "fill" centers and crops each clip to
     * cover the canvas (scale = max(canvas/display)).
     */
    private val contentMode: String = "fit",
) : AndroidTimelineVideoPassEncoder {
    data class ClipInput(
        val sourcePath: String,
        val trimStartSeconds: Double,
        val trimEndSeconds: Double,
        val decodedWidth: Int,
        val decodedHeight: Int,
        val rotationDegrees: Int,
        val mediaKind: String = "video",
        val stillFrameCount: Int = 0,
        val speed: Double = 1.0,
        val exifOrientation: Int = ExifInterface.ORIENTATION_NORMAL,
        val colorMatrix: FloatArray? = null,
        // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A, extended by
        // P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A: optional clip-level
        // Beauty V2 smoothing intensity in [0.0, 1.0]; null means no beauty.
        // Consumed by the Vulkan-only production export route
        // (AndroidTimelineVulkanVideoEncoder) for solo/hard-cut-adjacent
        // video frames, and by this GLES encoder for the narrow hard-cut,
        // video-only shape AndroidExportRenderBackendSelector
        // .ExportRenderScope.glesBeautyEligible admits (see
        // [drawAndSubmitBeautyFrame]).
        val beautyIntensity: Double? = null,
        // P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: true when this (video) clip
        // must be rendered walking its trim window backwards -- see
        // [renderReversedClipIntoEncoder]. The Vulkan-only production route
        // (AndroidTimelineVulkanVideoEncoder) has no render support for this
        // and fails closed defensively if it ever receives one.
        val isReversed: Boolean = false,
        // P5-CLIP-STATIC-TRANSFORM-EXPORT-A: optional static clip transform
        // (uniform scale around the clip's fitted center plus a translation
        // already converted by AndroidTimelineExportSession into OUTPUT
        // pixels). Null means the plain centered aspect-fit placement.
        // Applied by AndroidTimelineVulkanVideoEncoder as a source crop +
        // in-bounds destination rect
        // (AndroidTimelineClipStaticTransformGeometry) and by this GLES
        // encoder's hard-cut route in vertex space ([updateClipGeometry]).
        // AndroidTimelineGlesTransitionVideoEncoder and the reversed-clip
        // normalization prepass do not apply it, so
        // AndroidExportRenderBackendSelector / AndroidTimelineExportSession
        // keep transformed clips away from those routes.
        val transform: StaticClipTransform? = null,
        // Phase 7.17-Android freeze frame: source-local PTS (seconds) of the
        // single frame this (video) clip holds for its whole trim window --
        // the trim window is a timeline hold, not a source window. Null means
        // a normal clip. Rendered only by this GLES encoder's
        // [renderFreezeClipIntoEncoder]; AndroidExportRenderBackendSelector
        // never routes a freeze clip to Vulkan or the GLES transition route.
        val freezePTS: Double? = null,
    )

    /// P5-CLIP-STATIC-TRANSFORM-EXPORT-A: the narrow static clip transform
    /// subset the Android export route renders -- see
    /// AndroidTimelineClipStaticTransformGeometry. [scale] is a finite,
    /// positive uniform scale applied around the fitted clip's center;
    /// [translationX]/[translationY] are finite output-pixel offsets
    /// (positive X = right, positive Y = down). Rotation, opacity and
    /// off-center anchors are not representable here; the session fails
    /// closed for them at parse time instead of constructing this value.
    data class StaticClipTransform(
        val scale: Double,
        val translationX: Double,
        val translationY: Double,
    )

    data class EncodeResult(
        val success: Boolean,
        val reason: String,
        val writtenVideoSamples: Int,
        val outputSizeBytes: Long,
        val beautyFrameCount: Int = 0,
        // P5-OVERLAYS-TRANSITION-COMP-N3: count of rendered frames (solo or
        // transition-overlap) that composited at least one active overlay.
        // Defaulted so pre-N3 callers/constructors remain valid.
        val overlayFrameCount: Int = 0,
        // P5-GLES-EXPORT-ES3-CONTEXT-READINESS: the GL major version
        // negotiated by [setupGlAndDecodeSurface] when it ran for this
        // encode call (2 or 3); stays at the default 2 for early rejects
        // that never reach GL setup.
        val glMajorVersion: Int = 2,
    )

    @Volatile private var cancelRequested = false

    /** Signals the encode loop to stop feeding new frames. Thread-safe. */
    override fun cancel() {
        cancelRequested = true
    }

    private val frameDurationUs = 1_000_000L / fps.coerceAtLeast(1)

    // ─── MediaCodec / MediaMuxer state ───────────────────────────────────────
    private var codec: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var videoTrackIndex = -1
    private var writtenVideoSamples = 0

    // ─── Pass-1 sample-ratio progress (owned solely by this encoder — no
    // knowledge of MethodChannel, Handler, or session pass weights) ─────────
    private var totalExpectedSamples = 0
    private var onProgress: ((Double) -> Unit)? = null

    // ─── EGL / GL state (bound to the encoder's input surface) ──────────────
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    // P5-GLES-EXPORT-ES3-CONTEXT-READINESS: the GL major version actually
    // negotiated by [setupGlAndDecodeSurface] -- 3 when an ES3 context was
    // created and GL_MAJOR_VERSION confirms it, 2 for the ES2 fallback path
    // or an ES2 context that doesn't expose GL_MAJOR_VERSION.
    private var glMajorVersion: Int = 2
    private var glProgram = 0
    private var oesTextureId = 0
    private var aPositionLoc = 0
    private var aTexCoordLoc = 0
    private var uSTMatrixLoc = 0
    // Phase 10: colorMatrix uniforms for the OES program. The 2D still-image
    // program has its own separate set of uniform locations below -- never
    // shared between the two draw paths.
    private var uColorMatrixRow0Loc = 0
    private var uColorMatrixRow1Loc = 0
    private var uColorMatrixRow2Loc = 0
    private var uColorMatrixRow3Loc = 0
    private var uColorMatrixOffsetLoc = 0
    private var framesSubmitted = 0

    // ─── 2D GL program (still-image clips) — distinct locations from the OES
    // program above; never reused between the two draw paths. ────────────────
    private var glProgram2D = 0
    private var aPositionLoc2D = 0
    private var aTexCoordLoc2D = 0
    private var uColorMatrixRow0Loc2D = 0
    private var uColorMatrixRow1Loc2D = 0
    private var uColorMatrixRow2Loc2D = 0
    private var uColorMatrixRow3Loc2D = 0
    private var uColorMatrixOffsetLoc2D = 0

    // ─── Decode-side transfer surface (OES texture target for the decoder) ──
    private var decodeSurfaceTexture: SurfaceTexture? = null
    private var decodeInputSurface: Surface? = null
    private val frameSyncLock = Object()
    private var frameAvailable = false
    private val stMatrix = FloatArray(16)

    // ─── GLES overlay compositing state (P5-GLES-EXPORT-OVERLAY-PRODUCTION-
    // ROUTE-A) -- populated only by the overlay-aware [encode] override
    // below, before delegating to the plain hard-cut [encode]. ─────────────
    private var pendingOverlays: List<AndroidTimelineOverlayDescriptor> = emptyList()
    private var glesOverlaySession: AndroidTimelineGlesOverlayRenderSession? = null
    private var overlayFramesRendered = 0

    // ─── GLES Beauty V2 compositing state (P5-GLES-EXPORT-BEAUTY-PRODUCTION-
    // ROUTE-A) -- populated only when [encode] is called with at least one
    // clip carrying a non-null [ClipInput.beautyIntensity]. ─────────────────
    private var glesBeautySession: AndroidTimelineGlesBeautyRenderSession? = null
    private var beautyFramesRendered = 0

    /// Overlay-aware entry point (see
    /// [AndroidTimelineVideoPassEncoder.encode]'s three-arg overload). An
    /// empty [overlays] delegates unchanged to the transition-aware
    /// [encode]. A non-empty [overlays] is accepted only for the narrow
    /// shape [AndroidExportRenderBackendSelector.ExportRenderScope
    /// .glesOverlayEligible] also requires -- hard-cut-only [transitions]
    /// and a non-null [nativeBridge] -- rejecting anything wider with a
    /// precise machine-readable reason rather than silently dropping the
    /// overlays. P5-GLES-EXPORT-STILL-IMAGE-OVERLAYS: a still-image clip is
    /// no longer rejected here -- [renderStillClipIntoEncoder] composites
    /// overlays on its existing GL_TEXTURE_2D base draw path via
    /// [drawAndSubmitFrame2D]/[compositeActiveOverlaysIfPresent], the same
    /// route video clips use. P5-GLES-EXPORT-BEAUTY-OVERLAYS: a clip
    /// carrying [ClipInput.beautyIntensity] is no longer rejected here
    /// either -- [drawAndSubmitBeautyFrame] composites overlays on top of
    /// its Beauty output via that same [compositeActiveOverlaysIfPresent]
    /// route, provided the wider request shape is still
    /// [AndroidExportRenderBackendSelector.ExportRenderScope
    /// .glesBeautyEligible] (hard-cut-only, video-only, non-reversed,
    /// colorMatrix-free, zero-rotation) upstream in the selector -- this
    /// encoder does not re-validate that shape beyond the hard-cut check
    /// already below. P5-GLES-EXPORT-REVERSED-CLIP-OVERLAYS: a reversed
    /// video clip ([ClipInput.isReversed]) is no longer rejected here either
    /// -- it is rendered by [renderReversedClipIntoEncoder], which draws
    /// each backwards-walked frame via [drawAndSubmitFrame2D] and then
    /// composites overlays through that same
    /// [compositeActiveOverlaysIfPresent] route, exactly like a still-image
    /// clip.
    override fun encode(
        clips: List<ClipInput>,
        transitions: List<AndroidTimelineTransitionDescriptor>,
        overlays: List<AndroidTimelineOverlayDescriptor>,
        onProgress: ((Double) -> Unit)?,
    ): EncodeResult {
        if (overlays.isEmpty()) {
            return encode(clips, transitions, onProgress)
        }
        if (transitions.any { !it.isHardCut }) {
            return EncodeResult(
                false,
                AndroidTimelineVideoPassEncoder.TRANSITIONS_UNSUPPORTED_BY_BACKEND_REASON,
                0,
                0L,
            )
        }
        if (nativeBridge == null) {
            return EncodeResult(false, "overlays_missing_native_bridge", 0, 0L)
        }
        // P5-GLES-EXPORT-REVERSED-CLIP-OVERLAYS: defensive fail-closed check
        // for reversed overlay shapes AndroidExportRenderBackendSelector
        // .glesOverlayEligible and AndroidTimelineExportSession should have
        // already excluded upstream -- a reversed non-video clip, a reversed
        // clip carrying rotation metadata (this encoder's
        // [renderReversedClipIntoEncoder] never applies rotation), or a
        // reversed clip paired with clip-level Beauty V2 (no reversed+Beauty
        // render route exists). A valid zero-rotation reversed video clip
        // without Beauty is left untouched and reaches
        // [renderReversedClipIntoEncoder] below exactly like today.
        clips.firstOrNull { it.isReversed && it.mediaKind != "video" }?.let {
            return EncodeResult(false, "reversed_overlay_non_video_unsupported:${it.sourcePath}", 0, 0L)
        }
        clips.firstOrNull { it.isReversed && it.rotationDegrees != 0 }?.let {
            return EncodeResult(false, "reversed_overlay_rotation_unsupported:${it.sourcePath}", 0, 0L)
        }
        clips.firstOrNull { it.isReversed && it.beautyIntensity != null }?.let {
            return EncodeResult(false, "reversed_overlay_beauty_unsupported:${it.sourcePath}", 0, 0L)
        }
        pendingOverlays = overlays
        return encode(clips, onProgress)
    }

    /// Encodes [clips] sequentially (hard-cut concatenation) into [outputPath]
    /// as a video-only MP4. Returns a structured result; never throws.
    ///
    /// [onProgress], when non-null, receives the pass-1 sample-write ratio in
    /// [0.0, 1.0] as each muxed sample is written (see [drainEncoder]). This
    /// encoder computes [totalExpectedSamples] once, up front, as the sum
    /// over [clips] of each clip's expected sample count -- still-image
    /// clips contribute [ClipInput.stillFrameCount]; video clips (including
    /// freeze-frame clips, whose trim window is their timeline hold)
    /// contribute ceil(((trimEndSeconds - trimStartSeconds) / speed) * fps),
    /// floored at 1. When the total is <= 0, no sample progress is emitted.
    ///
    /// Per-clip render route: still image -> [renderStillClipIntoEncoder];
    /// freeze frame ([ClipInput.freezePTS] non-null) ->
    /// [renderFreezeClipIntoEncoder]; reversed -> [renderReversedClipIntoEncoder];
    /// otherwise the forward decode route [decodeClipIntoEncoder].
    override fun encode(clips: List<ClipInput>, onProgress: ((Double) -> Unit)?): EncodeResult {
        this.onProgress = onProgress
        totalExpectedSamples = clips.sumOf { clip ->
            if (clip.mediaKind == "image") {
                clip.stillFrameCount
            } else {
                val speed = if (clip.speed > 0.0) clip.speed else 1.0
                ceil(((clip.trimEndSeconds - clip.trimStartSeconds) / speed) * fps).toInt().coerceAtLeast(1)
            }
        }
        var succeeded = false
        var muxerStoppedCleanly = false
        var reason = "not_run"
        try {
            // P5-GLES-EXPORT-ES3-CONTEXT-READINESS: reset before setup so a
            // reused encoder instance never reports a stale GL major version
            // from a prior successful encode() call if this call's GL setup
            // fails before [setupGlAndDecodeSurface] re-negotiates it.
            glMajorVersion = 2
            setupEncoderAndMuxer()
            setupGlAndDecodeSurface()

            if (pendingOverlays.isNotEmpty()) {
                when (
                    val prepareResult = AndroidTimelineGlesOverlayRenderSession.prepare(
                        pendingOverlays,
                    ) { cancelRequested }
                ) {
                    is AndroidTimelineGlesOverlayRenderSession.PrepareResult.Failure -> {
                        reason = "overlay_prepare_failed:${prepareResult.code}:${prepareResult.message}"
                        return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
                    }
                    is AndroidTimelineGlesOverlayRenderSession.PrepareResult.Success -> {
                        glesOverlaySession = prepareResult.session
                    }
                }
            }

            // P5-GLES-EXPORT-BEAUTY-PRODUCTION-ROUTE-A: preflight + GL
            // resource setup for any clip carrying Beauty V2 on this narrow
            // hard-cut, video-only GLES route -- see
            // AndroidExportRenderBackendSelector.ExportRenderScope
            // .glesBeautyEligible for the full request-shape admission gate
            // upstream of this encoder. Both checks below are a second,
            // encoder-owned defense layer, not the primary gate.
            if (clips.any { it.beautyIntensity != null }) {
                if (nativeBridge == null) {
                    reason = "beauty_v2_gles_missing_native_bridge"
                    return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
                }
                if (glMajorVersion < 3) {
                    reason = "beauty_v2_gles_es3_required:$glMajorVersion"
                    return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
                }
                val session = AndroidTimelineGlesBeautyRenderSession.prepare(width, height)
                if (session == null) {
                    reason = "beauty_v2_gles_render_session_setup_failed"
                    return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
                }
                glesBeautySession = session
            }

            for (clip in clips) {
                if (cancelRequested) break
                val failureReason = if (clip.mediaKind == "image") {
                    renderStillClipIntoEncoder(clip)
                } else if (clip.freezePTS != null) {
                    renderFreezeClipIntoEncoder(clip)
                } else if (clip.isReversed) {
                    renderReversedClipIntoEncoder(clip)
                } else {
                    decodeClipIntoEncoder(clip)
                }
                if (failureReason != null) {
                    if (cancelRequested) break
                    reason = failureReason
                    return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
                }
            }

            if (cancelRequested) {
                reason = "cancelled"
                return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
            }

            codec!!.signalEndOfInputStream()
            val eosObserved = drainEncoder(endOfStream = true, deadlineMs = ENCODE_EOS_DEADLINE_MS)
            if (!eosObserved) {
                reason = "encoder_eos_drain_timeout"
                return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
            }

            if (!muxerStarted || writtenVideoSamples <= 0) {
                reason = "no_video_samples_written"
                return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
            }

            muxer!!.stop()
            muxerStoppedCleanly = true

            val outFile = File(outputPath)
            val outSize = if (outFile.exists()) outFile.length() else 0L
            if (outSize <= 0L) {
                reason = "output_file_empty_or_missing"
                return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
            }

            succeeded = true
            reason = "success"
            return EncodeResult(
                true, reason, writtenVideoSamples, outSize,
                beautyFrameCount = beautyFramesRendered,
                overlayFrameCount = overlayFramesRendered,
                glMajorVersion = glMajorVersion,
            )
        } catch (t: Throwable) {
            reason = "exception:${t.javaClass.simpleName}"
            Log.e(TAG, "encode failed: $t", t)
            return EncodeResult(false, reason, writtenVideoSamples, 0L, glMajorVersion = glMajorVersion)
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

    private fun setupGlAndDecodeSurface() {
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
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0)
        val config = configs[0] ?: throw IllegalStateException("eglChooseConfig failed")

        // P5-GLES-EXPORT-ES3-CONTEXT-READINESS: attempt an ES3 context first
        // -- the EGL_RENDERABLE_TYPE config bit above stays EGL_OPENGL_ES2_BIT
        // (an ES3-capable driver creates an ES3 context from an ES2-bit
        // config; requiring an ES3-only config bit here would break the ES2
        // fallback on devices/configs that never advertise ES3). Falls back
        // to an ES2 context only when the ES3 attempt returns EGL_NO_CONTEXT.
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

        // Confirm the actually-negotiated GL major version rather than
        // trusting the requested EGL_CONTEXT_CLIENT_VERSION -- some drivers
        // silently promote an ES2 request to an ES3 context. GL_MAJOR_VERSION
        // is an ES3+ query; an ES2-only context leaves a GL error that must
        // be drained rather than left pending for the first real GL call.
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
            synchronized(frameSyncLock) {
                frameAvailable = true
                frameSyncLock.notifyAll()
            }
        }
        decodeSurfaceTexture = texture
        decodeInputSurface = Surface(texture)

        setupShaderProgram()
        setup2DShaderProgram()
    }

    private fun setupShaderProgram() {
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

        // Phase 10: highp precision + explicit 4x5 row-major colorMatrix
        // uniforms (four row vec4s + one offset vec4), matching Flutter/
        // Android ColorFilter.matrix. A null clip colorMatrix uploads
        // identity rows and a zero offset (see [uploadColorMatrixUniforms]),
        // so this shader always runs the same dot-product path whether or
        // not a filter is active -- no branching, no hidden fast path.
        val fragmentSrc = """
            #extension GL_OES_EGL_image_external : require
            precision highp float;
            varying vec2 vTextureCoord;
            uniform samplerExternalOES sTexture;
            uniform vec4 uColorMatrixRow0;
            uniform vec4 uColorMatrixRow1;
            uniform vec4 uColorMatrixRow2;
            uniform vec4 uColorMatrixRow3;
            uniform vec4 uColorMatrixOffset;
            void main() {
                vec4 rgba = texture2D(sTexture, vTextureCoord);
                vec4 outColor = vec4(
                    dot(uColorMatrixRow0, rgba) + uColorMatrixOffset.r,
                    dot(uColorMatrixRow1, rgba) + uColorMatrixOffset.g,
                    dot(uColorMatrixRow2, rgba) + uColorMatrixOffset.b,
                    dot(uColorMatrixRow3, rgba) + uColorMatrixOffset.a
                );
                gl_FragColor = clamp(outColor, 0.0, 1.0);
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
        glProgram = program
        aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
        uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")
        uColorMatrixRow0Loc = GLES20.glGetUniformLocation(program, "uColorMatrixRow0")
        uColorMatrixRow1Loc = GLES20.glGetUniformLocation(program, "uColorMatrixRow1")
        uColorMatrixRow2Loc = GLES20.glGetUniformLocation(program, "uColorMatrixRow2")
        uColorMatrixRow3Loc = GLES20.glGetUniformLocation(program, "uColorMatrixRow3")
        uColorMatrixOffsetLoc = GLES20.glGetUniformLocation(program, "uColorMatrixOffset")
    }

    /// Second GLES2 program used only for still-image clips: a plain 2D
    /// texture sampler with no uSTMatrix uniform (still images are uploaded
    /// directly via GLUtils.texImage2D, not through a SurfaceTexture). Kept
    /// fully separate from [setupShaderProgram]'s OES program and its
    /// attribute/uniform locations, but applies the same 4x5 row-major
    /// colorMatrix semantics via its own uniform set -- see
    /// [uploadColorMatrixUniforms].
    private fun setup2DShaderProgram() {
        val vertexSrc = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = aTextureCoord.xy;
            }
        """.trimIndent()

        val fragmentSrc = """
            precision highp float;
            varying vec2 vTextureCoord;
            uniform sampler2D sTexture;
            uniform vec4 uColorMatrixRow0;
            uniform vec4 uColorMatrixRow1;
            uniform vec4 uColorMatrixRow2;
            uniform vec4 uColorMatrixRow3;
            uniform vec4 uColorMatrixOffset;
            void main() {
                vec4 rgba = texture2D(sTexture, vTextureCoord);
                vec4 outColor = vec4(
                    dot(uColorMatrixRow0, rgba) + uColorMatrixOffset.r,
                    dot(uColorMatrixRow1, rgba) + uColorMatrixOffset.g,
                    dot(uColorMatrixRow2, rgba) + uColorMatrixOffset.b,
                    dot(uColorMatrixRow3, rgba) + uColorMatrixOffset.a
                );
                gl_FragColor = clamp(outColor, 0.0, 1.0);
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
            throw IllegalStateException("GL 2D program link failed: $log")
        }
        glProgram2D = program
        aPositionLoc2D = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoordLoc2D = GLES20.glGetAttribLocation(program, "aTextureCoord")
        uColorMatrixRow0Loc2D = GLES20.glGetUniformLocation(program, "uColorMatrixRow0")
        uColorMatrixRow1Loc2D = GLES20.glGetUniformLocation(program, "uColorMatrixRow1")
        uColorMatrixRow2Loc2D = GLES20.glGetUniformLocation(program, "uColorMatrixRow2")
        uColorMatrixRow3Loc2D = GLES20.glGetUniformLocation(program, "uColorMatrixRow3")
        uColorMatrixOffsetLoc2D = GLES20.glGetUniformLocation(program, "uColorMatrixOffset")
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

    // ─────────────────────────────────────────────────────────────────────────
    // Per-clip decode → GL transfer → encode
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns null on success, or a machine-readable failure reason string
    /// for any non-cancel decode/transfer failure.
    private fun decodeClipIntoEncoder(clip: ClipInput): String? {
        synchronized(frameSyncLock) { frameAvailable = false }
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
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

            val trimStartUs = (clip.trimStartSeconds * 1_000_000L).toLong()
            if (trimStartUs > 0L) {
                extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }
            val trimEndUs = (clip.trimEndSeconds * 1_000_000L).toLong()

            val clipSpeed = if (clip.speed > 0.0) clip.speed else 1.0
            val isUnitySpeed = Math.abs(clipSpeed - 1.0) < 0.0001
            val expectedFramesInClip = ceil(((clip.trimEndSeconds - clip.trimStartSeconds) / clipSpeed) * fps).toInt().coerceAtLeast(1)
            val sourceFps = if (trackFormat.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                try { trackFormat.getInteger(MediaFormat.KEY_FRAME_RATE) } catch (_: Throwable) { 0 }
            } else 0
            val nominalSourceIntervalUs = if (sourceFps in 1..240) {
                1_000_000L / sourceFps
            } else {
                1_000_000L / fps
            }
            var nextOutputFrameIndex = 0

            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            val dec = MediaCodec.createDecoderByType(mime)
            dec.configure(trackFormat, decodeInputSurface, null, 0)
            dec.start()
            decoder = dec

            val geometryFailure = updateClipGeometry(clip)
            if (geometryFailure != null) return geometryFailure

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
                                if (!awaitNewImage(FRAME_WAIT_TIMEOUT_MS)) {
                                    // Real transfer failed to arrive — report honestly, never fake success.
                                    return "frame_transfer_timeout:${clip.sourcePath}"
                                }
                                val drawFailure = if (clip.beautyIntensity != null) {
                                    drawAndSubmitBeautyFrame(clip.beautyIntensity)
                                } else {
                                    drawAndSubmitFrame(clip.colorMatrix)
                                }
                                if (drawFailure != null) return drawFailure
                                drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
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
                                    if (!awaitNewImage(FRAME_WAIT_TIMEOUT_MS)) {
                                        return "frame_transfer_timeout:${clip.sourcePath}"
                                    }
                                    for (r in 0 until repeatCount) {
                                        if (cancelRequested) break
                                        val drawFailure = if (clip.beautyIntensity != null) {
                                            drawAndSubmitBeautyFrame(clip.beautyIntensity)
                                        } else {
                                            drawAndSubmitFrame(clip.colorMatrix)
                                        }
                                        if (drawFailure != null) return drawFailure
                                        drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                                        renderedFramesInClip++
                                        nextOutputFrameIndex++
                                    }
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

            if (!isUnitySpeed && renderedFramesInClip > 0 && nextOutputFrameIndex < expectedFramesInClip && !cancelRequested) {
                while (nextOutputFrameIndex < expectedFramesInClip && !cancelRequested) {
                    val drawFailure = if (clip.beautyIntensity != null) {
                        drawAndSubmitBeautyFrame(clip.beautyIntensity)
                    } else {
                        drawAndSubmitFrame(clip.colorMatrix)
                    }
                    if (drawFailure != null) return drawFailure
                    drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                    renderedFramesInClip++
                    nextOutputFrameIndex++
                }
            }

            if (renderedFramesInClip == 0 && !cancelRequested) {
                return "no_frames_in_trim_window:${clip.sourcePath}"
            }
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "decodeClipIntoEncoder failed for ${clip.sourcePath}: $t", t)
            return "clip_decode_exception:${t.javaClass.simpleName}:${clip.sourcePath}"
        } finally {
            try { decoder?.stop() } catch (_: Throwable) {}
            try { decoder?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    /// Blocks until the decoder's SurfaceTexture reports a new frame, then
    /// calls updateTexImage(). Returns false on timeout (real failure, not faked).
    private fun awaitNewImage(timeoutMs: Long): Boolean {
        synchronized(frameSyncLock) {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (!frameAvailable) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0L) return false
                frameSyncLock.wait(remaining)
            }
            frameAvailable = false
        }
        decodeSurfaceTexture!!.updateTexImage()
        return true
    }

    private val texCoords = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)

    // Reused per-clip geometry buffers (Unit G) — uploaded once per clip via
    // [updateClipGeometry], never reallocated per frame. Vertex order is
    // BL, BR, TL, TR, matching the GL_TRIANGLE_STRIP draw call below.
    private val quadBuffer: FloatBuffer = ByteBuffer.allocateDirect(8 * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer()
    private val texBuffer: FloatBuffer = ByteBuffer.allocateDirect(texCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(texCoords)
            position(0)
        }

    // 2D texture coordinates (still-image clips) — flipped vertically
    // relative to [texCoords] so BitmapFactory's top-down row order lands
    // right-side-up in the encoder's bottom-up NDC output space.
    private val texCoords2D = floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)
    private val texBuffer2D: FloatBuffer = ByteBuffer.allocateDirect(texCoords2D.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(texCoords2D)
            position(0)
        }

    /// Computes the centered, aspect-preserving "fit" quad for [clip]'s
    /// decoded geometry against the fixed encoder output surface, rotates it
    /// by the clip's normalized rotation metadata, and uploads it into
    /// [quadBuffer]. Texture coordinates are left unrotated — SurfaceTexture's
    /// own transform matrix (uSTMatrix), applied in [drawAndSubmitFrame],
    /// remains the only texture-space transform; clip rotation metadata is
    /// applied entirely in output vertex space. Returns a failure reason
    /// string for degenerate geometry instead of throwing; never called with
    /// per-frame allocation.
    ///
    /// For still-image clips, EXIF orientation is baked into the uploaded
    /// texture's pixels (see [renderStillClipIntoEncoder] /
    /// AndroidStillImageDecoder.applyExifOrientation) rather than applied as
    /// a vertex-space rotation, so the fit geometry here must be computed
    /// against the EXIF-adjusted display bounds -- not the raw decode
    /// dimensions -- while [ClipInput.rotationDegrees] stays 0 for images.
    ///
    /// P5-CLIP-STATIC-TRANSFORM-EXPORT-A: when [ClipInput.transform] is
    /// non-null, the rotated fit quad is additionally scaled uniformly
    /// around the output center by [StaticClipTransform.scale] and then
    /// translated by the transform's output-pixel offsets (canvas Y-down is
    /// negated into NDC Y-up) -- the same placement
    /// AndroidTimelineClipStaticTransformGeometry derives for the Vulkan
    /// crop seam, expressed in vertex space. Any part of the quad that lands
    /// outside the output is clipped by the fixed viewport, so no
    /// destination-bounds work is needed on this backend. A transform whose
    /// values are not finite/positive fails closed here rather than
    /// rendering a degenerate quad.
    private fun updateClipGeometry(clip: ClipInput): String? {
        val decodedWidth: Int
        val decodedHeight: Int
        if (clip.mediaKind == "image") {
            val displayBounds = AndroidStillImageDecoder.getDisplayBounds(
                clip.decodedWidth, clip.decodedHeight, clip.exifOrientation,
            )
            decodedWidth = displayBounds.width
            decodedHeight = displayBounds.height
        } else {
            decodedWidth = clip.decodedWidth
            decodedHeight = clip.decodedHeight
        }
        if (decodedWidth <= 0 || decodedHeight <= 0 || width <= 0 || height <= 0) {
            return "invalid_geometry:${clip.sourcePath}"
        }

        val displayWidth: Float
        val displayHeight: Float
        if (clip.rotationDegrees == 90 || clip.rotationDegrees == 270) {
            displayWidth = decodedHeight.toFloat()
            displayHeight = decodedWidth.toFloat()
        } else {
            displayWidth = decodedWidth.toFloat()
            displayHeight = decodedHeight.toFloat()
        }
        val scale = min(width.toFloat() / displayWidth, height.toFloat() / displayHeight)
        val halfPixelX = decodedWidth.toFloat() * scale / 2f
        val halfPixelY = decodedHeight.toFloat() * scale / 2f

        // P5-CLIP-STATIC-TRANSFORM-EXPORT-A: uniform scale + output-pixel
        // translation applied after rotation, in pixel space (see doc).
        val transform = clip.transform
        val transformScale: Float
        val transformTxPixels: Float
        val transformTyPixels: Float
        if (transform != null) {
            if (!transform.scale.isFinite() || transform.scale <= 0.0 ||
                !transform.translationX.isFinite() || !transform.translationY.isFinite()
            ) {
                return "invalid_clip_transform:${clip.sourcePath}"
            }
            transformScale = transform.scale.toFloat()
            transformTxPixels = transform.translationX.toFloat()
            // Canvas/output Y is down; NDC Y is up.
            transformTyPixels = -transform.translationY.toFloat()
        } else {
            transformScale = 1f
            transformTxPixels = 0f
            transformTyPixels = 0f
        }

        // Mathematical positive angles are CCW; clip rotation metadata is
        // clockwise, hence the negated angle here.
        val radians = Math.toRadians(-clip.rotationDegrees.toDouble())
        val cosR = cos(radians).toFloat()
        val sinR = sin(radians).toFloat()
        fun rotatedPixel(x: Float, y: Float) = floatArrayOf(
            (x * cosR - y * sinR) * transformScale + transformTxPixels,
            (x * sinR + y * cosR) * transformScale + transformTyPixels,
        )
        // Rotate in pixel space first, then convert per-axis to NDC -- on
        // non-square canvases NDC is anisotropic, so rotating already-
        // normalized NDC coordinates would transpose/distort 90/270 fit.
        fun toNdc(p: FloatArray) =
            floatArrayOf(p[0] / (width.toFloat() / 2f), p[1] / (height.toFloat() / 2f))

        val bl = toNdc(rotatedPixel(-halfPixelX, -halfPixelY))
        val br = toNdc(rotatedPixel(halfPixelX, -halfPixelY))
        val tl = toNdc(rotatedPixel(-halfPixelX, halfPixelY))
        val tr = toNdc(rotatedPixel(halfPixelX, halfPixelY))

        quadBuffer.position(0)
        quadBuffer.put(floatArrayOf(bl[0], bl[1], br[0], br[1], tl[0], tl[1], tr[0], tr[1]))
        quadBuffer.position(0)
        return null
    }

    /// Draws the current OES texture (decoded frame) into the encoder's EGL
    /// surface and submits it via eglSwapBuffers. Real GPU frame transfer —
    /// the decoded pixels are drawn, not assumed.
    ///
    /// [colorMatrix], when non-null, is the active clip's 20-element (4x5
    /// row-major) filter, applied by the OES fragment shader for this frame
    /// only -- passed explicitly rather than held as encoder-wide mutable
    /// state, so per-clip filtering never leaks across a clip boundary.
    ///
    /// When [glesOverlaySession] is non-null (P5-GLES-EXPORT-OVERLAY-
    /// PRODUCTION-ROUTE-A), every overlay active at
    /// `framesSubmitted * frameDurationUs` is composited after this base
    /// draw and before presentation/swap (see [compositeActiveOverlaysIfPresent]).
    /// Returns a machine-readable failure reason on any overlay
    /// payload/draw/upload failure -- this frame is never submitted with a
    /// silently-dropped overlay -- or null on success.
    private fun drawAndSubmitFrame(colorMatrix: FloatArray?): String? {
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        decodeSurfaceTexture!!.getTransformMatrix(stMatrix)

        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(glProgram)

        quadBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc)
        GLES20.glVertexAttribPointer(aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)

        texBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc)
        GLES20.glVertexAttribPointer(aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuffer)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glUniformMatrix4fv(uSTMatrixLoc, 1, false, stMatrix, 0)
        uploadColorMatrixUniforms(
            colorMatrix,
            uColorMatrixRow0Loc,
            uColorMatrixRow1Loc,
            uColorMatrixRow2Loc,
            uColorMatrixRow3Loc,
            uColorMatrixOffsetLoc,
        )

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc)

        val overlayFailure = compositeActiveOverlaysIfPresent()
        if (overlayFailure != null) return overlayFailure

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, framesSubmitted * frameDurationUs * 1000L)
        framesSubmitted++
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        return null
    }

    /// Beauty-aware analogue of [drawAndSubmitFrame] for a video clip
    /// carrying a non-null [ClipInput.beautyIntensity] on the narrow
    /// production GLES Beauty V2 route (P5-GLES-EXPORT-BEAUTY-PRODUCTION-
    /// ROUTE-A). Resolves the current OES frame into [glesBeautySession]'s
    /// intermediate GL_TEXTURE_2D FBO through the same fit quad/
    /// SurfaceTexture matrix the plain OES draw path uses for this clip
    /// ([updateClipGeometry]/[stMatrix]), then renders Beauty V2 directly
    /// into the encoder's own default framebuffer (0, i.e. the current EGL
    /// surface) via the existing native
    /// `drawAndroidDagPhase5GlesExportBeautySeam` seam, then presents/swaps
    /// exactly like [drawAndSubmitFrame]. [glesBeautySession] and
    /// [nativeBridge] are guaranteed non-null, and [glMajorVersion]
    /// guaranteed >= 3, by [encode]'s upfront beauty preflight -- the
    /// defensive null/version checks here exist only so this method never
    /// silently no-ops if that invariant is ever violated. This narrow route
    /// never carries a still-image/reversed clip or a non-hard-cut
    /// transition (see [ExportRenderScope.glesBeautyEligible]).
    /// P5-GLES-EXPORT-BEAUTY-OVERLAYS: when [glesOverlaySession] is
    /// non-null, every overlay active at `framesSubmitted * frameDurationUs`
    /// is composited on top of this frame's Beauty output -- after the seam
    /// status above is validated and before presentation/swap below -- via
    /// [compositeActiveOverlaysIfPresent], the same pre-swap ordering
    /// [drawAndSubmitFrame] and [drawAndSubmitFrame2D] use. Returns a
    /// machine-readable failure reason on any overlay payload/draw/upload
    /// failure -- this frame is never submitted with a silently-dropped
    /// overlay -- or null on success.
    private fun drawAndSubmitBeautyFrame(intensity: Double): String? {
        val session = glesBeautySession ?: return "beauty_v2_gles_missing_native_bridge"
        val bridge = nativeBridge ?: return "beauty_v2_gles_missing_native_bridge"
        if (glMajorVersion < 3) return "beauty_v2_gles_es3_required:$glMajorVersion"

        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        decodeSurfaceTexture!!.getTransformMatrix(stMatrix)

        val resolveFailure = session.resolveOesFrameToTexture2d(
            oesTextureId, quadBuffer, texBuffer, stMatrix, width, height,
        )
        if (resolveFailure != null) return "beauty_v2_gles_render_failed:$resolveFailure"

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        val rawStatus = bridge.drawAndroidDagPhase5GlesExportBeautySeam(
            session.resolvedTextureId, 0, width, height, intensity.toFloat(),
        )
        val statusJson = try { JSONObject(rawStatus) } catch (t: Throwable) { null }
        val pass = statusJson?.optBoolean("pass", false) == true ||
            statusJson?.optString("status") == "PASS"
        if (!pass) {
            val failureDetail = statusJson?.optString("failureReason")?.takeIf { it.isNotEmpty() }
                ?: statusJson?.optString("status")?.takeIf { it.isNotEmpty() }
                ?: "unparseable_seam_response"
            return "beauty_v2_gles_render_failed:$failureDetail"
        }

        // P5-GLES-EXPORT-BEAUTY-OVERLAYS: composite overlays on top of the
        // Beauty output before presentation/swap -- must run after seam
        // status validation above (never composite onto a failed Beauty
        // draw) and before eglSwapBuffers below (never submit a frame with a
        // silently-dropped overlay).
        val overlayFailure = compositeActiveOverlaysIfPresent()
        if (overlayFailure != null) return overlayFailure

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, framesSubmitted * frameDurationUs * 1000L)
        framesSubmitted++
        beautyFramesRendered++
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        return null
    }

    /// Composites every overlay active at `framesSubmitted * frameDurationUs`
    /// (this frame's timeline instant) via [glesOverlaySession], when one is
    /// prepared -- a legal no-op when it is null (no overlays for this
    /// encode) or when no overlay is active at this instant. Returns a
    /// machine-readable failure reason on any failure, or null on success;
    /// never called with a non-null [glesOverlaySession] and a null
    /// [nativeBridge], since the overlay-aware [encode] override rejects
    /// that combination before this method can run.
    private fun compositeActiveOverlaysIfPresent(): String? {
        val session = glesOverlaySession ?: return null
        val bridge = nativeBridge ?: return "overlays_missing_native_bridge"
        val timelinePtsUs = framesSubmitted.toLong() * frameDurationUs
        return when (val result = session.drawActiveOverlays(bridge, timelinePtsUs, width, height)) {
            is AndroidTimelineGlesOverlayRenderSession.DrawResult.Success -> {
                if (result.activeOverlayCount > 0) overlayFramesRendered++
                null
            }
            is AndroidTimelineGlesOverlayRenderSession.DrawResult.Failure -> "overlay_draw_failed:${result.reason}"
        }
    }

    /// Uploads [colorMatrix] (20-element, 4x5 row-major -- R,G,B,A,offset per
    /// output channel) into the row/offset uniforms at the given locations --
    /// shared by both the OES program (see [drawAndSubmitFrame]) and the 2D
    /// still-image program (see [drawAndSubmitFrame2D]), each passing its own
    /// distinct uniform locations so the two programs' uniform state never
    /// cross-contaminates. A null [colorMatrix] uploads identity rows and a
    /// zero offset, so the shader's dot-product path is a no-op passthrough.
    /// The 5th (offset) column of each row is divided by 255.0 before upload,
    /// matching Flutter/Android ColorFilter.matrix's 0-255 offset convention
    /// against this shader's [0.0, 1.0] color space.
    private fun uploadColorMatrixUniforms(
        colorMatrix: FloatArray?,
        row0Loc: Int,
        row1Loc: Int,
        row2Loc: Int,
        row3Loc: Int,
        offsetLoc: Int,
    ) {
        if (colorMatrix == null) {
            GLES20.glUniform4f(row0Loc, 1f, 0f, 0f, 0f)
            GLES20.glUniform4f(row1Loc, 0f, 1f, 0f, 0f)
            GLES20.glUniform4f(row2Loc, 0f, 0f, 1f, 0f)
            GLES20.glUniform4f(row3Loc, 0f, 0f, 0f, 1f)
            GLES20.glUniform4f(offsetLoc, 0f, 0f, 0f, 0f)
            return
        }
        GLES20.glUniform4f(row0Loc, colorMatrix[0], colorMatrix[1], colorMatrix[2], colorMatrix[3])
        GLES20.glUniform4f(row1Loc, colorMatrix[5], colorMatrix[6], colorMatrix[7], colorMatrix[8])
        GLES20.glUniform4f(row2Loc, colorMatrix[10], colorMatrix[11], colorMatrix[12], colorMatrix[13])
        GLES20.glUniform4f(row3Loc, colorMatrix[15], colorMatrix[16], colorMatrix[17], colorMatrix[18])
        GLES20.glUniform4f(
            offsetLoc,
            colorMatrix[4] / 255.0f,
            colorMatrix[9] / 255.0f,
            colorMatrix[14] / 255.0f,
            colorMatrix[19] / 255.0f,
        )
    }

    /// Draws [textureId] (a plain 2D texture uploaded from a decoded still
    /// image) into the encoder's EGL surface and submits it via
    /// eglSwapBuffers, using the separate 2D program/locations — never the
    /// OES program or its uSTMatrix uniform.
    ///
    /// [colorMatrix], when non-null, is the active clip's 20-element (4x5
    /// row-major) filter, applied by the 2D fragment shader for this frame
    /// only -- same semantics/upload path as the OES program's
    /// [drawAndSubmitFrame], via the 2D program's own uniform locations.
    ///
    /// P5-GLES-EXPORT-STILL-IMAGE-OVERLAYS: when [glesOverlaySession] is
    /// non-null, every overlay active at `framesSubmitted * frameDurationUs`
    /// is composited after this base draw and before presentation/swap (see
    /// [compositeActiveOverlaysIfPresent]) -- the same ordering
    /// [drawAndSubmitFrame] uses for OES/video frames. Returns a
    /// machine-readable failure reason on any overlay payload/draw/upload
    /// failure -- this frame is never submitted with a silently-dropped
    /// overlay -- or null on success.
    private fun drawAndSubmitFrame2D(textureId: Int, colorMatrix: FloatArray?): String? {
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(glProgram2D)

        quadBuffer.position(0)
        GLES20.glEnableVertexAttribArray(aPositionLoc2D)
        GLES20.glVertexAttribPointer(aPositionLoc2D, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)

        texBuffer2D.position(0)
        GLES20.glEnableVertexAttribArray(aTexCoordLoc2D)
        GLES20.glVertexAttribPointer(aTexCoordLoc2D, 2, GLES20.GL_FLOAT, false, 0, texBuffer2D)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
        uploadColorMatrixUniforms(
            colorMatrix,
            uColorMatrixRow0Loc2D,
            uColorMatrixRow1Loc2D,
            uColorMatrixRow2Loc2D,
            uColorMatrixRow3Loc2D,
            uColorMatrixOffsetLoc2D,
        )

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(aPositionLoc2D)
        GLES20.glDisableVertexAttribArray(aTexCoordLoc2D)

        val overlayFailure = compositeActiveOverlaysIfPresent()
        if (overlayFailure != null) return overlayFailure

        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, framesSubmitted * frameDurationUs * 1000L)
        framesSubmitted++
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        return null
    }

    /// Decodes [clip]'s local still-image file (BitmapFactory, sample-size
    /// clamped to the current EGL context's GL_MAX_TEXTURE_SIZE), uploads it
    /// as a plain 2D texture, and draws it into the encoder for
    /// [ClipInput.stillFrameCount] frames -- the still-image analogue of
    /// [decodeClipIntoEncoder]. Returns null on success (including an
    /// early-cancelled loop), or a machine-readable failure reason string.
    private fun renderStillClipIntoEncoder(clip: ClipInput): String? {
        var textureId = 0
        var bitmapToRecycle: Bitmap? = null
        try {
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

            val maxTextureSize = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, maxTextureSize, 0)

            val inSampleSize = AndroidStillImageDecoder.computeInSampleSize(
                clip.decodedWidth, clip.decodedHeight, width, height, maxTextureSize[0], clip.exifOrientation,
            )
            val decoded = AndroidStillImageDecoder.decodeBitmap(clip.sourcePath, inSampleSize)
                ?: return "still_image_decode_failed:${clip.sourcePath}"
            bitmapToRecycle = decoded
            val oriented = AndroidStillImageDecoder.applyExifOrientation(decoded, clip.exifOrientation)
            bitmapToRecycle = oriented
            val bitmap = AndroidStillImageDecoder.clampToMaxTextureSize(oriented, maxTextureSize[0])
            bitmapToRecycle = bitmap

            val geometryFailure = updateClipGeometry(clip)
            if (geometryFailure != null) return geometryFailure

            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            textureId = textures[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            val texUploadError = GLES20.glGetError()
            bitmap.recycle()
            bitmapToRecycle = null
            if (texUploadError != GLES20.GL_NO_ERROR) {
                return "still_texture_upload_failed:$texUploadError:${clip.sourcePath}"
            }

            var framesRendered = 0
            for (i in 0 until clip.stillFrameCount) {
                if (cancelRequested) break
                val drawFailure = drawAndSubmitFrame2D(textureId, clip.colorMatrix)
                if (drawFailure != null) return drawFailure
                drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                framesRendered++
            }

            if (framesRendered == 0 && !cancelRequested) {
                return "no_frames_in_still_clip:${clip.sourcePath}"
            }
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "renderStillClipIntoEncoder failed for ${clip.sourcePath}: $t", t)
            return "still_clip_render_exception:${t.javaClass.simpleName}:${clip.sourcePath}"
        } finally {
            try { bitmapToRecycle?.recycle() } catch (_: Throwable) {}
            if (textureId != 0) {
                try { GLES20.glDeleteTextures(1, intArrayOf(textureId), 0) } catch (_: Throwable) {}
            }
        }
    }

    /// Renders a time-reversed frame sequence for [clip] (mediaKind ==
    /// "video", [ClipInput.isReversed] == true) via MediaMetadataRetriever
    /// bitmap extraction -- the reversed-video analogue of
    /// [decodeClipIntoEncoder], sharing [renderStillClipIntoEncoder]'s plain
    /// 2D texture upload + [drawAndSubmitFrame2D] draw path (so
    /// [ClipInput.colorMatrix] applies identically). Expected frame count
    /// matches the forward video formula: ceil((trimEnd - trimStart) *
    /// fps).coerceAtLeast(1). Frame i samples source timestamp
    /// trimEndExclusiveUs - (i + 1) * frameDurationUs -- walking the source
    /// backwards -- clamped into [trimStartUs, latestSourceUs] so
    /// ceil-derived overshoot never samples at/before trimStart or at/after
    /// the exclusive trimEnd. trimEndExclusiveUs is floored up to
    /// trimStartUs + 1 so a microsecond-scale trim that truncates trimStart
    /// and trimEnd to the same microsecond still yields a valid clamp range
    /// instead of throwing. A null
    /// Bitmap for any frame fails the whole clip immediately -- this backend
    /// must never duplicate a frame to paper over a decode gap. Returns null
    /// on success (including an early-cancelled loop), or a machine-readable
    /// failure reason string.
    private fun renderReversedClipIntoEncoder(clip: ClipInput): String? {
        val retriever = MediaMetadataRetriever()
        var textureId = 0
        var bitmapToRecycle: Bitmap? = null
        try {
            AndroidUriDataSourceHelper.setRetrieverDataSource(retriever, clip.sourcePath, context)
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

            val geometryFailure = updateClipGeometry(clip)
            if (geometryFailure != null) return geometryFailure

            val trimStartUs = (clip.trimStartSeconds * 1_000_000L).toLong()
            val trimEndExclusiveUs = (clip.trimEndSeconds * 1_000_000L).toLong()
                .coerceAtLeast(trimStartUs + 1L)
            val expectedFrames = ceil((clip.trimEndSeconds - clip.trimStartSeconds) * fps)
                .toInt().coerceAtLeast(1)

            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            textureId = textures[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

            var framesRendered = 0
            for (i in 0 until expectedFrames) {
                if (cancelRequested) break
                val idxUs = (i + 1).toLong() * frameDurationUs
                val latestSourceUs = trimEndExclusiveUs - 1L
                val sourceUs = (trimEndExclusiveUs - idxUs).coerceIn(trimStartUs, latestSourceUs)

                val frame = retriever.getFrameAtTime(sourceUs, MediaMetadataRetriever.OPTION_CLOSEST)
                    ?: return "reverse_frame_decode_failed:frame=$i:sourceUs=$sourceUs:${clip.sourcePath}"
                bitmapToRecycle = frame

                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
                GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, frame, 0)
                val texUploadError = GLES20.glGetError()
                frame.recycle()
                bitmapToRecycle = null
                if (texUploadError != GLES20.GL_NO_ERROR) {
                    return "reverse_texture_upload_failed:$texUploadError:frame=$i:${clip.sourcePath}"
                }

                val drawFailure = drawAndSubmitFrame2D(textureId, clip.colorMatrix)
                if (drawFailure != null) return drawFailure
                drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                framesRendered++
            }

            if (framesRendered == 0 && !cancelRequested) {
                return "no_frames_in_reversed_clip:${clip.sourcePath}"
            }
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "renderReversedClipIntoEncoder failed for ${clip.sourcePath}: $t", t)
            return "reversed_clip_render_exception:${t.javaClass.simpleName}:${clip.sourcePath}"
        } finally {
            try { bitmapToRecycle?.recycle() } catch (_: Throwable) {}
            if (textureId != 0) {
                try { GLES20.glDeleteTextures(1, intArrayOf(textureId), 0) } catch (_: Throwable) {}
            }
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    /// Phase 7.17-Android freeze frame: renders [clip] (mediaKind == "video",
    /// [ClipInput.freezePTS] non-null) as a single held source frame for its
    /// whole timeline hold -- the freeze analogue of [renderStillClipIntoEncoder]
    /// and a sibling of [renderReversedClipIntoEncoder], sharing their plain 2D
    /// texture upload + [drawAndSubmitFrame2D] draw path (so [ClipInput.colorMatrix]
    /// and overlay compositing apply identically). Exactly one frame is
    /// extracted via MediaMetadataRetriever.getFrameAtTime(freezePtsUs,
    /// OPTION_CLOSEST), uploaded once, and drawn
    /// ceil(((trimEnd - trimStart) / speed) * fps).coerceAtLeast(1) times --
    /// the same expected-sample count [encode] pre-computes for it. The
    /// retriever returns the frame already rotated into display orientation
    /// (the platform applies the track's rotation metadata to the Bitmap), so
    /// fit geometry is computed against the Bitmap's own extent with
    /// rotationDegrees = 0 -- never re-applying [ClipInput.rotationDegrees] --
    /// while [ClipInput.transform] still applies through [updateClipGeometry]
    /// exactly as on the hard-cut route. A null Bitmap fails the clip with a
    /// machine-readable reason -- this backend never substitutes another frame
    /// to paper over an extraction failure. Freeze combined with reverse or
    /// clip-level Beauty V2, or on a non-video clip, fails closed here as a
    /// second defense behind AndroidTimelineExportSession's own admission.
    /// Returns null on success (including an early-cancelled loop), or a
    /// machine-readable failure reason string.
    private fun renderFreezeClipIntoEncoder(clip: ClipInput): String? {
        val freezePts = clip.freezePTS ?: return "freeze_pts_missing:${clip.sourcePath}"
        if (!freezePts.isFinite() || freezePts < 0.0) {
            return "freeze_pts_invalid:$freezePts:${clip.sourcePath}"
        }
        if (clip.mediaKind != "video") return "freeze_non_video_unsupported:${clip.sourcePath}"
        if (clip.isReversed) return "freeze_reversed_unsupported:${clip.sourcePath}"
        if (clip.beautyIntensity != null) return "freeze_beauty_unsupported:${clip.sourcePath}"

        val retriever = MediaMetadataRetriever()
        var textureId = 0
        var bitmapToRecycle: Bitmap? = null
        try {
            AndroidUriDataSourceHelper.setRetrieverDataSource(retriever, clip.sourcePath, context)
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

            val clipSpeed = if (clip.speed > 0.0) clip.speed else 1.0
            val expectedFrames = ceil(((clip.trimEndSeconds - clip.trimStartSeconds) / clipSpeed) * fps)
                .toInt().coerceAtLeast(1)
            val freezePtsUs = (freezePts * 1_000_000.0).toLong()

            val frame = retriever.getFrameAtTime(freezePtsUs, MediaMetadataRetriever.OPTION_CLOSEST)
                ?: return "freeze_frame_decode_failed:freezePtsUs=$freezePtsUs:${clip.sourcePath}"
            bitmapToRecycle = frame

            val maxTextureSize = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_MAX_TEXTURE_SIZE, maxTextureSize, 0)
            // clampToMaxTextureSize recycles its input when it has to scale.
            val bitmap = AndroidStillImageDecoder.clampToMaxTextureSize(frame, maxTextureSize[0])
            bitmapToRecycle = bitmap
            if (bitmap.width <= 0 || bitmap.height <= 0) {
                return "freeze_frame_invalid_dimensions:${bitmap.width}x${bitmap.height}:${clip.sourcePath}"
            }
            val frameWidth = bitmap.width
            val frameHeight = bitmap.height

            // Display-oriented Bitmap extent, rotation already applied by the retriever.
            val geometryFailure = updateClipGeometry(
                clip.copy(decodedWidth = frameWidth, decodedHeight = frameHeight, rotationDegrees = 0),
            )
            if (geometryFailure != null) return geometryFailure

            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            textureId = textures[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            val texUploadError = GLES20.glGetError()
            bitmap.recycle()
            bitmapToRecycle = null
            if (texUploadError != GLES20.GL_NO_ERROR) {
                return "freeze_texture_upload_failed:$texUploadError:${clip.sourcePath}"
            }

            Log.i(
                TAG,
                "VG_EXPORT_FREEZE_CLIP source=${clip.sourcePath} freezePtsUs=$freezePtsUs " +
                    "frame=${frameWidth}x$frameHeight decoded=${clip.decodedWidth}x${clip.decodedHeight} " +
                    "rotation=${clip.rotationDegrees} holdFrames=$expectedFrames fps=$fps",
            )

            var framesRendered = 0
            for (i in 0 until expectedFrames) {
                if (cancelRequested) break
                val drawFailure = drawAndSubmitFrame2D(textureId, clip.colorMatrix)
                if (drawFailure != null) return drawFailure
                drainEncoder(endOfStream = false, deadlineMs = ENCODE_DRAIN_DEADLINE_MS)
                framesRendered++
            }

            if (framesRendered == 0 && !cancelRequested) {
                return "no_frames_in_freeze_clip:${clip.sourcePath}"
            }
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "renderFreezeClipIntoEncoder failed for ${clip.sourcePath}: $t", t)
            return "freeze_clip_render_exception:${t.javaClass.simpleName}:${clip.sourcePath}"
        } finally {
            try { bitmapToRecycle?.recycle() } catch (_: Throwable) {}
            if (textureId != 0) {
                try { GLES20.glDeleteTextures(1, intArrayOf(textureId), 0) } catch (_: Throwable) {}
            }
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Encoder output drain (fixed frame clock — frozen PTS mechanism)
    // ─────────────────────────────────────────────────────────────────────────

    /// Drains encoder output into the muxer. When [endOfStream] is true,
    /// returns whether the encoder's own EOS buffer was actually observed
    /// before [deadlineMs] elapsed (false means the drain timed out without
    /// seeing EOS — a real failure, not a fake completion). When
    /// [endOfStream] is false (per-frame drain), always returns true.
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
                            // AndroidDagRenderSmokeHarness's Phase-5 drain.
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
                // Close before EGL teardown -- glesOverlaySession.close() and
                // glesBeautySession.release() delete GL textures and require
                // this same context still current.
                glesOverlaySession?.close()
                glesOverlaySession = null
                glesBeautySession?.release()
                glesBeautySession = null
                if (glProgram != 0) GLES20.glDeleteProgram(glProgram)
                if (glProgram2D != 0) GLES20.glDeleteProgram(glProgram2D)
                if (oesTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
            } catch (_: Throwable) {}
        }

        try { encoderInputSurface?.release() } catch (_: Throwable) {}
        try { decodeInputSurface?.release() } catch (_: Throwable) {}
        try { decodeSurfaceTexture?.release() } catch (_: Throwable) {}

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
        private const val TAG = "VGTimelineVideoEnc"
        private const val DEQUEUE_TIMEOUT_US = 10_000L
        private const val FRAME_WAIT_TIMEOUT_MS = 2_000L
        private const val ENCODE_DRAIN_DEADLINE_MS = 2_000L
        private const val ENCODE_EOS_DEADLINE_MS = 5_000L
    }
}

// ── AndroidTimelineClipStaticTransformGeometry (P5-CLIP-STATIC-TRANSFORM-EXPORT-A) ──
//
// Pure placement geometry for the narrow static clip transform subset the
// Android export route accepts ([AndroidTimelineVideoEncoder.StaticClipTransform]:
// uniform scale around the fitted clip's center plus an output-pixel
// translation; zero rotation, full opacity, centered anchor). Owns no
// GL/Vulkan/codec state. Shared by AndroidTimelineExportSession (fail-closed
// validation before pass-1) and AndroidTimelineVulkanVideoEncoder (per-clip
// source crop + destination rect for the native cropped render seam, which
// requires the destination rect to lie fully inside the output).
//
// Model (output pixel space, top-left origin, Y down), matching the Dart
// builder's semantics (universal_editor_render_export_builder.dart):
//   1. the clip's rotated display extent (decoded width/height, swapped for
//      90/270) is centered and aspect-preserving-fit into the output
//      (fitScale = min(outW/displayW, outH/displayH)) -- the null-transform
//      placement;
//   2. that fitted rect is scaled by [scale] around the output center;
//   3. the result is translated by (translationX, translationY).
// The visible region is the intersection of that rendered rect with the
// output. The source crop is the display-space pre-image of the visible
// region, mapped back into decoded buffer orientation through the inverse
// of the clockwise cardinal rotation the native render transform applies
// (render_transform.h: 90 CW -> u = y, v = 1 - x; 180 -> u = 1 - x,
// v = 1 - y; 270 CW -> u = 1 - y, v = x), then rounded OUTWARD to
// even-aligned integers (the decoder crop guard requires even bounds); the
// destination rect is re-derived from that rounded crop so crop and
// destination stay a uniform scaling of each other, then clamped to the
// output. Rounding therefore never drops visible content; it can stretch
// the frame by at most two source pixels per clipped edge.
//
// Every failure (nothing visible, empty/odd/out-of-range crop, degenerate
// dimensions) is reported as a machine-readable reason; callers fail closed
// with UNSUPPORTED_EXPORT_FEATURE instead of exporting wrong framing.
internal object AndroidTimelineClipStaticTransformGeometry {
    /// Source crop in the clip's decoded (buffer-orientation, pre-rotation)
    /// pixel space, relative to the decoded extent's own origin, plus the
    /// destination rect in output pixel space. Both are non-empty; the crop
    /// bounds are even-aligned and inside the decoded extent, and the
    /// destination lies fully inside the output.
    data class Placement(
        val sourceLeft: Int,
        val sourceTop: Int,
        val sourceRight: Int,
        val sourceBottom: Int,
        val destX: Int,
        val destY: Int,
        val destWidth: Int,
        val destHeight: Int,
    )

    /// Exactly one of [placement] / [failure] is non-null.
    class Result private constructor(val placement: Placement?, val failure: String?) {
        companion object {
            fun success(placement: Placement) = Result(placement, null)
            fun failure(reason: String) = Result(null, reason)
        }
    }

    /// Sub-pixel slack absorbed before floor/ceil so float noise at an exact
    /// integer boundary never widens a crop by a full even step.
    private const val ROUNDING_EPSILON = 1e-6

    /// Computes the [Placement] for one clip, or a failure reason.
    /// [rotationDegrees] must be cardinal (0/90/180/270).
    fun compute(
        outputWidth: Int,
        outputHeight: Int,
        decodedWidth: Int,
        decodedHeight: Int,
        rotationDegrees: Int,
        transform: AndroidTimelineVideoEncoder.StaticClipTransform,
    ): Result {
        if (outputWidth <= 0 || outputHeight <= 0 || decodedWidth <= 0 || decodedHeight <= 0) {
            return Result.failure(
                "invalid_dimensions:outW=$outputWidth:outH=$outputHeight:" +
                    "decodedW=$decodedWidth:decodedH=$decodedHeight",
            )
        }
        val (displayWidth, displayHeight) = when (rotationDegrees) {
            0, 180 -> decodedWidth to decodedHeight
            90, 270 -> decodedHeight to decodedWidth
            else -> return Result.failure("unsupported_rotation:$rotationDegrees")
        }
        val scale = transform.scale
        val translationX = transform.translationX
        val translationY = transform.translationY
        if (!scale.isFinite() || scale <= 0.0 || !translationX.isFinite() || !translationY.isFinite()) {
            return Result.failure("invalid_transform_values:scale=$scale:tx=$translationX:ty=$translationY")
        }

        // 1-3: fit, scale around center, translate (all in output pixels).
        val fitScale = min(
            outputWidth.toDouble() / displayWidth.toDouble(),
            outputHeight.toDouble() / displayHeight.toDouble(),
        )
        val k = fitScale * scale // display px -> output px
        if (!k.isFinite() || k <= 0.0) {
            return Result.failure("degenerate_scale:fit=$fitScale:scale=$scale")
        }
        val renderedWidth = displayWidth * k
        val renderedHeight = displayHeight * k
        val centerX = outputWidth / 2.0 + translationX
        val centerY = outputHeight / 2.0 + translationY
        val renderedLeft = centerX - renderedWidth / 2.0
        val renderedTop = centerY - renderedHeight / 2.0
        val renderedRight = renderedLeft + renderedWidth
        val renderedBottom = renderedTop + renderedHeight

        // Visible region = rendered rect ∩ output.
        val visibleLeft = max(renderedLeft, 0.0)
        val visibleTop = max(renderedTop, 0.0)
        val visibleRight = min(renderedRight, outputWidth.toDouble())
        val visibleBottom = min(renderedBottom, outputHeight.toDouble())
        if (visibleRight - visibleLeft < 1.0 || visibleBottom - visibleTop < 1.0) {
            return Result.failure(
                "not_visible:rendered=${fmt(renderedLeft)},${fmt(renderedTop)}-" +
                    "${fmt(renderedRight)},${fmt(renderedBottom)}:outW=$outputWidth:outH=$outputHeight",
            )
        }

        // Display-space pre-image of the visible region.
        val cropLeftDisplay = ((visibleLeft - renderedLeft) / k).coerceIn(0.0, displayWidth.toDouble())
        val cropTopDisplay = ((visibleTop - renderedTop) / k).coerceIn(0.0, displayHeight.toDouble())
        val cropRightDisplay = ((visibleRight - renderedLeft) / k).coerceIn(0.0, displayWidth.toDouble())
        val cropBottomDisplay = ((visibleBottom - renderedTop) / k).coerceIn(0.0, displayHeight.toDouble())

        // Display -> decoded buffer orientation (inverse of the clockwise
        // cardinal rotation; see the file-level doc).
        val bufferLeft: Double
        val bufferTop: Double
        val bufferRight: Double
        val bufferBottom: Double
        when (rotationDegrees) {
            0 -> {
                bufferLeft = cropLeftDisplay; bufferTop = cropTopDisplay
                bufferRight = cropRightDisplay; bufferBottom = cropBottomDisplay
            }
            90 -> {
                // bx = dy ; by = decodedHeight - dx   (decodedHeight == displayWidth)
                bufferLeft = cropTopDisplay; bufferRight = cropBottomDisplay
                bufferTop = displayWidth - cropRightDisplay; bufferBottom = displayWidth - cropLeftDisplay
            }
            180 -> {
                bufferLeft = displayWidth - cropRightDisplay; bufferRight = displayWidth - cropLeftDisplay
                bufferTop = displayHeight - cropBottomDisplay; bufferBottom = displayHeight - cropTopDisplay
            }
            else -> { // 270
                // bx = decodedWidth - dy ; by = dx   (decodedWidth == displayHeight)
                bufferLeft = displayHeight - cropBottomDisplay; bufferRight = displayHeight - cropTopDisplay
                bufferTop = cropLeftDisplay; bufferBottom = cropRightDisplay
            }
        }

        // Outward, even-aligned integer crop inside the decoded extent.
        val sourceLeft = floorEven(bufferLeft)
        val sourceTop = floorEven(bufferTop)
        val sourceRight = ceilEven(bufferRight, decodedWidth)
        val sourceBottom = ceilEven(bufferBottom, decodedHeight)
        if (sourceLeft < 0 || sourceTop < 0 || sourceRight > decodedWidth || sourceBottom > decodedHeight ||
            sourceRight <= sourceLeft || sourceBottom <= sourceTop
        ) {
            return Result.failure(
                "crop_invalid:crop=$sourceLeft,$sourceTop-$sourceRight,$sourceBottom:" +
                    "decodedW=$decodedWidth:decodedH=$decodedHeight",
            )
        }
        if (sourceLeft % 2 != 0 || sourceTop % 2 != 0 || sourceRight % 2 != 0 || sourceBottom % 2 != 0) {
            return Result.failure(
                "crop_odd_bounds:crop=$sourceLeft,$sourceTop-$sourceRight,$sourceBottom:" +
                    "decodedW=$decodedWidth:decodedH=$decodedHeight",
            )
        }

        // Rounded crop back to display space, then forward to output space.
        val roundedLeftDisplay: Double
        val roundedTopDisplay: Double
        val roundedRightDisplay: Double
        val roundedBottomDisplay: Double
        when (rotationDegrees) {
            0 -> {
                roundedLeftDisplay = sourceLeft.toDouble(); roundedTopDisplay = sourceTop.toDouble()
                roundedRightDisplay = sourceRight.toDouble(); roundedBottomDisplay = sourceBottom.toDouble()
            }
            90 -> {
                roundedLeftDisplay = displayWidth - sourceBottom.toDouble()
                roundedRightDisplay = displayWidth - sourceTop.toDouble()
                roundedTopDisplay = sourceLeft.toDouble(); roundedBottomDisplay = sourceRight.toDouble()
            }
            180 -> {
                roundedLeftDisplay = displayWidth - sourceRight.toDouble()
                roundedRightDisplay = displayWidth - sourceLeft.toDouble()
                roundedTopDisplay = displayHeight - sourceBottom.toDouble()
                roundedBottomDisplay = displayHeight - sourceTop.toDouble()
            }
            else -> { // 270
                roundedLeftDisplay = sourceTop.toDouble(); roundedRightDisplay = sourceBottom.toDouble()
                roundedTopDisplay = displayHeight - sourceRight.toDouble()
                roundedBottomDisplay = displayHeight - sourceLeft.toDouble()
            }
        }
        val destLeft = Math.round(renderedLeft + roundedLeftDisplay * k).toInt().coerceIn(0, outputWidth)
        val destTop = Math.round(renderedTop + roundedTopDisplay * k).toInt().coerceIn(0, outputHeight)
        val destRight = Math.round(renderedLeft + roundedRightDisplay * k).toInt().coerceIn(0, outputWidth)
        val destBottom = Math.round(renderedTop + roundedBottomDisplay * k).toInt().coerceIn(0, outputHeight)
        val destWidth = destRight - destLeft
        val destHeight = destBottom - destTop
        if (destWidth < 1 || destHeight < 1) {
            return Result.failure(
                "dest_empty:dest=$destLeft,$destTop-$destRight,$destBottom:outW=$outputWidth:outH=$outputHeight",
            )
        }
        return Result.success(
            Placement(
                sourceLeft = sourceLeft,
                sourceTop = sourceTop,
                sourceRight = sourceRight,
                sourceBottom = sourceBottom,
                destX = destLeft,
                destY = destTop,
                destWidth = destWidth,
                destHeight = destHeight,
            ),
        )
    }

    private fun floorEven(value: Double): Int {
        val floored = kotlin.math.floor(value + ROUNDING_EPSILON).toInt().coerceAtLeast(0)
        return floored - (floored % 2)
    }

    private fun ceilEven(value: Double, maxValue: Int): Int {
        val ceiled = ceil(value - ROUNDING_EPSILON).toInt().coerceAtLeast(0)
        val even = if (ceiled % 2 == 0) ceiled else ceiled + 1
        return min(even, maxValue)
    }

    private fun fmt(value: Double): String = String.format(java.util.Locale.US, "%.1f", value)
}
