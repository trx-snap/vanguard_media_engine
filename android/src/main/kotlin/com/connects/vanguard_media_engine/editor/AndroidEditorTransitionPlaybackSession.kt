package com.connects.vanguard_media_engine.editor

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.codec.AndroidDagPlaybackState
import com.connects.vanguard_media_engine.codec.AndroidDagSourceInspector
import com.connects.vanguard_media_engine.codec.AndroidDagSurfaceProducerLifecycleAdapter
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.export.AndroidTimelineExportSegment
import com.connects.vanguard_media_engine.export.AndroidTimelineExportSegmentPlanner
import com.connects.vanguard_media_engine.export.AndroidTimelineGlesTransitionDecodeSlot
import com.connects.vanguard_media_engine.export.AndroidTimelineGlesTransitionOverlapDecoder
import com.connects.vanguard_media_engine.export.AndroidTimelineTransitionDescriptor
import com.connects.vanguard_media_engine.export.AndroidTimelineVideoEncoder
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * ANDROID-EDITOR-TRANSITION-PREVIEW: editor preview playback for a timeline that carries
 * one or more non-hard-cut transitions ([AndroidTimelineTransitionDescriptor]), OR that
 * requests a "fill" canvas ([canvasContentMode]) over more than one clip -- a
 * mixed-orientation multi-clip draft whose canvas is fixed by its first clip needs this
 * session's canvas-aware cover-crop quad geometry even when every clip pair is a hard cut.
 *
 * Rendering contract -- the export-equivalent chain, so preview and export agree:
 *   MediaCodec -> OES SurfaceTexture decode slot ([AndroidTimelineGlesTransitionDecodeSlot])
 *   -> transform-matrix-aware, canvas-sized GL_TEXTURE_2D pre-resolve (offscreen FBO)
 *   -> VanguardNativeBridge.drawAndroidTimelineGlesTransitionExportFrame (the native
 *      GlesTimelineTransitionCompositor seam, all nine transition families)
 *   -> EGL window surface over the Flutter SurfaceProducer -> eglSwapBuffers.
 * A solo (non-overlap) frame draws its OES slot through the same fit/fill quad geometry
 * straight into the window surface, exactly like the export route's solo path.
 *
 * Timeline math is the export planner's, never re-derived here: [prepare] builds
 * [AndroidTimelineVideoEncoder.ClipInput] values from the coordinator-normalized clip specs
 * (reverse sidecars already substituted as forward clips, trims/speed already validated),
 * calls [AndroidTimelineExportSegmentPlanner.build] at [PREVIEW_FPS], and lays the resulting
 * Solo/Overlap segments out contiguously on the overlap-adjusted editor timeline.
 *
 * Scope (fail closed, never approximate): normal video clips, trims, `content://` sources,
 * speed, reverse-sidecar-normalized clips. Not supported on this route: freeze clips
 * (`freeze_clip_unsupported_on_transition_timeline`), still images, overlays, transforms,
 * colour matrices, Beauty -- the coordinator rejects the draft-level ones before this
 * session exists; this class re-checks what it can see.
 *
 * Original audio: one [AndroidEditorOriginalAudioPreviewRuntime] for the clip that "owns"
 * the current timeline instant -- the solo clip, or, inside an overlap, the outgoing clip
 * until the transition midpoint and the incoming clip from the midpoint on (a
 * deterministic cut-over; crossfading two original tracks is deferred). Added-audio lanes
 * stay owned by the coordinator.
 *
 * Concurrency: every command (prepare/play/pause/seek/dispose/gain) is serialized on the
 * session-owned orchestration [HandlerThread]; decode steps run synchronously on that thread
 * (the render loop is a self-re-posting runnable paced against a monotonic clock, never a
 * free-running thread). [sessionToken] is bumped on seek, surface loss/restore and dispose
 * so a stale tick, audio callback or surface event can never act on a superseded state.
 *
 * SurfaceTexture looper caveat (why [setupDecodeSlotsOnLooperlessThread] exists): the
 * export decode slot registers its frame-available listener with the one-argument overload,
 * which dispatches on the Looper of the thread that CONSTRUCTED the SurfaceTexture. If the
 * slots were constructed on this session's orchestration thread, `awaitNewImage` -- which
 * blocks that very thread -- could never receive the notification. The export route only
 * works because its worker thread has no Looper. The slots are therefore constructed on a
 * short-lived looper-less thread (with this session's EGL context current there, so the
 * SurfaceTextures attach to it), which makes their callbacks dispatch on the main Looper,
 * exactly as export does. `updateTexImage` still runs on the orchestration thread with the
 * same context current, which is what SurfaceTexture requires.
 *
 * Ownership: the coordinator owns this session and the [surfaceProducer]; this session
 * never releases the SurfaceProducer. Everything it creates (thread, EGL display/context/
 * surfaces, GL program/textures/FBOs, decode slots, decoders, native bridge, audio runtime)
 * is released exactly once, on the first of: prepare failure, decoder/GL failure, dispose.
 */
class AndroidEditorTransitionPlaybackSession(
    clipSpecs: List<AndroidEditorClipPlaybackSpec>,
    private val transitions: List<AndroidTimelineTransitionDescriptor>,
    private val surfaceProducer: TextureRegistry.SurfaceProducer,
    private val onTimelineFrame: (textureId: Long, ptsSeconds: Double, generationId: Long) -> Unit,
    private val onTimelineEOS: (textureId: Long) -> Unit,
    private val context: Context? = null,
    /**
     * Draft-requested canvas size (root `canvasWidth`/`canvasHeight`). When both are
     * positive, this canvas is used as-is instead of deriving it from the first
     * clip's post-rotation display size -- required for a mixed-orientation
     * [canvasContentMode] == "fill" draft, whose canvas is defined by the first
     * clip but must not be reshaped by a later clip of a different orientation.
     */
    private val requestedCanvasWidth: Int = 0,
    private val requestedCanvasHeight: Int = 0,
    /**
     * Wire `canvas.contentMode` ("fit" | "fill" | "blurFill"). "fill" centers and
     * crops each clip to cover the canvas (quad scale = max(canvas/display));
     * "fit" letterboxes/pillarboxes each clip inside the canvas (quad scale =
     * min(canvas/display)), byte-equivalent to this session's original
     * behaviour. "blurFill" (MULTI-VIDEO-BLURFILL) renders a clip whose display
     * aspect differs from the canvas as a blurred, dimmed cover-crop background
     * of the same frame under a centered sharp aspect-fit foreground, and an
     * aspect-matched clip as one sharp full-canvas frame; "fit" and "fill"
     * single-pass drawing is untouched.
     */
    private val canvasContentMode: String = "fit",
) : AndroidEditorPlaybackSession {

    companion object {
        private const val TAG = "EditorTransPlaybackSession"
        private const val LOG_PREFIX = "VG_EDITOR_TRANSITION_PREVIEW"

        /** Output cadence the segment plan is built at (export uses the request fps). */
        private const val PREVIEW_FPS = 30

        /** Same container/metadata slack policy as AndroidEditorSequentialPlaybackSession. */
        private const val TRIM_END_CLAMP_SLACK_US = 250_000L

        /** A due frame is presented when within this much of its wall-clock deadline. */
        private const val PRESENT_SLACK_NS = 500_000L

        /** Bound on the looper-less slot bootstrap and on audio runtime latches. */
        private const val BOOTSTRAP_TIMEOUT_MS = 5_000L

        /**
         * blurFill background: spacing between the 5x5 blur taps in normalized OES
         * texture coordinates (the grid spans ±2 steps). Defined in texture space so
         * the blur strength is independent of source resolution, and magnified on the
         * canvas by the cover-crop scale.
         */
        private const val BLUR_FILL_TEXEL_STEP = 0.012f

        /** blurFill background brightness multiplier (dimmed backdrop under the sharp frame). */
        private const val BLUR_FILL_DIM_FACTOR = 0.55f

        /** Relative aspect tolerance below which a clip counts as aspect-matched to the canvas. */
        private const val BLUR_FILL_ASPECT_EPSILON = 0.005f
    }

    // ── Immutable plan ─────────────────────────────────────────────────────

    private val requestedClipSpecs: List<AndroidEditorClipPlaybackSpec> = clipSpecs

    /** One contiguous timeline window of the plan, in plan (chronological) order. */
    private data class Span(
        val segment: AndroidTimelineExportSegment,
        val timelineStartUs: Long,
        val timelineEndUs: Long,
        /** Index of the clip that owns audio at the span start (solo: its clip; overlap: from). */
        val fromClipIndex: Int,
        /** Overlap only: the incoming clip (owns audio from the midpoint on). -1 for solo. */
        val toClipIndex: Int,
    ) {
        val durationUs: Long get() = timelineEndUs - timelineStartUs
        val isOverlap: Boolean get() = segment is AndroidTimelineExportSegment.Overlap
        val midpointUs: Long get() = timelineStartUs + durationUs / 2L
    }

    private data class ClipLayout(
        val spec: AndroidEditorClipPlaybackSpec,
        val input: AndroidTimelineVideoEncoder.ClipInput,
        val timelineStartUs: Long,
        val timelineDurationUs: Long,
        val hasAudio: Boolean,
        /**
         * Mode-resolved placement quad (BL, BR, TL, TR NDC): the aspect-fit quad for
         * "fit" and "blurFill", the cover-crop quad for "fill".
         */
        val quad: FloatArray,
        /** Aspect-fit quad (scale = min(canvas/display)). */
        val fitQuad: FloatArray,
        /** Aspect-fill (cover-crop) quad (scale = max(canvas/display)). */
        val fillQuad: FloatArray,
        /**
         * True only on a "blurFill" canvas when this clip's display aspect differs from
         * the canvas aspect: the frame renders as a blurred/dimmed [fillQuad] background
         * under a sharp [fitQuad] foreground. An aspect-matched clip draws a single sharp
         * full-canvas frame through [quad].
         */
        val blurFillMismatch: Boolean,
    )

    // ── Lifecycle flags ────────────────────────────────────────────────────

    private val disposed = AtomicBoolean(false)
    private val resourcesReleased = AtomicBoolean(false)
    private val surfaceLostFlag = AtomicBoolean(false)

    /** Bumped on seek, surface loss/restore and dispose; stale ticks/callbacks compare it. */
    private val sessionToken = AtomicLong(0L)

    /** Monotonic public timeline generation (bumped once per seek and per span activation). */
    private val publicGeneration = AtomicLong(0L)

    @Volatile private var orchThread: HandlerThread? = null
    @Volatile private var orchHandler: Handler? = null

    // ── Orchestration-thread-confined state ────────────────────────────────

    private var layouts: List<ClipLayout> = emptyList()
    private var spans: List<Span> = emptyList()
    private var totalDurationUs: Long = 0L
    private var canvasWidth = 0
    private var canvasHeight = 0
    private var state: AndroidDagPlaybackState = AndroidDagPlaybackState.Idle

    private var activeSpanIndex = -1
    private var activeDecoder: AndroidTimelineGlesTransitionOverlapDecoder? = null
    private var activePairIndex = 0
    private var activeExpectedPairs = 1
    private var pendingStep: AndroidTimelineGlesTransitionOverlapDecoder.Step.Frames? = null

    private var positionUs = 0L
    private var isPlaying = false
    private var currentGeneration = 0L
    private var anchorTimelineUs = 0L
    private var anchorWallNs = 0L
    private var tickRunnable: Runnable? = null

    // Bounded play (diagnostic) bookkeeping, mirroring the DAG session's contract.
    private var framesPresentedThisRun = 0
    private var targetFrameCount: Int? = null
    private var pendingPlayCallback: ((Map<String, Any?>) -> Unit)? = null

    /** Redraws the last presented frame (used after a surface restore). */
    private var lastPresent: (() -> String?)? = null

    // Original audio (owner clip = solo clip / overlap from-clip before midpoint, to-clip after).
    private var audioOwnerClipIndex = -1
    private var activeAudioRuntime: AndroidEditorOriginalAudioPreviewRuntime? = null
    private var originalGainByClipId: MutableMap<String, Float> = mutableMapOf()

    // Incoming clip's runtime, prepared asynchronously when an overlap span activates so
    // the midpoint cut-over does not stall the video loop on MediaPlayer.prepare.
    private var prewarmClipIndex = -1
    private var prewarmRuntime: AndroidEditorOriginalAudioPreviewRuntime? = null
    private var prewarmLatch: CountDownLatch? = null

    // ── EGL / GL (orchestration-thread-confined) ───────────────────────────

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglConfig: EGLConfig? = null
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglPbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var flutterSurface: Surface? = null
    private var lifecycleAdapter: AndroidDagSurfaceProducerLifecycleAdapter? = null
    private var nativeBridge: VanguardNativeBridge? = null

    /** Sharp OES program: its attribute/uniform locations belong to THIS program only. */
    private class OesProgramHandles(
        val program: Int,
        val aPositionLoc: Int,
        val aTexCoordLoc: Int,
        val uSTMatrixLoc: Int,
    )

    /**
     * Blur OES program (blurFill background): its own program and locations, never
     * shared with [OesProgramHandles] -- attribute/uniform locations are per program.
     */
    private class BlurOesProgramHandles(
        val program: Int,
        val aPositionLoc: Int,
        val aTexCoordLoc: Int,
        val uSTMatrixLoc: Int,
        val uTexelStepLoc: Int,
        val uDimFactorLoc: Int,
    )

    private var sharpProgram: OesProgramHandles? = null
    /** Compiled only for a "blurFill" canvas (see [setupGlOnOrch]). */
    private var blurProgram: BlurOesProgramHandles? = null
    private val texCoords = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
    private val quadBuffer: FloatBuffer = ByteBuffer.allocateDirect(8 * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer()
    private val texBuffer: FloatBuffer = ByteBuffer.allocateDirect(texCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(texCoords)
            position(0)
        }

    private val fromSlot = AndroidTimelineGlesTransitionDecodeSlot()
    private val toSlot = AndroidTimelineGlesTransitionDecodeSlot()
    private var slotsReady = false
    private var fromResolveTextureId = 0
    private var toResolveTextureId = 0
    private var fromResolveFboId = 0
    private var toResolveFboId = 0

    // ── prepare ────────────────────────────────────────────────────────────

    override fun prepare(onResult: (Map<String, Any?>) -> Unit) {
        if (requestedClipSpecs.isEmpty()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=empty_clip_list"))
            return
        }
        val hasRealTransition = transitions.any { !it.isHardCut }
        // A "fill" canvas with more than one clip is routed here for its cover-crop
        // quad geometry even when every adjacent pair is a hard cut (no transition).
        val isFillNoTransitionRoute =
            (canvasContentMode == "fill" || canvasContentMode == "blurFill") && requestedClipSpecs.size > 1
        if (!hasRealTransition && !isFillNoTransitionRoute) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=no_transitions_for_transition_route"))
            return
        }

        val ht = HandlerThread("EditorTransitionPlaybackOrch_${surfaceProducer.id()}").also {
            orchThread = it
            it.start()
        }
        val h = Handler(ht.looper).also { orchHandler = it }

        h.post {
            if (disposed.get()) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=disposed"))
                return@post
            }
            state = AndroidDagPlaybackState.Preparing
            val failure = prepareOnOrch()
            if (failure != null) {
                Log.w(TAG, "$LOG_PREFIX prepare_failed reason=$failure")
                state = AndroidDagPlaybackState.Failed
                releaseAllOnce()
                onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=$failure"))
                // The coordinator drops a session whose prepare failed without calling
                // dispose(); quit the orchestration thread here so nothing leaks. A later
                // dispose() sees a null handler (or a refused post) and completes immediately.
                orchHandler = null
                orchThread = null
                ht.quitSafely()
                return@post
            }
            state = AndroidDagPlaybackState.Paused
            onResult(mapOf(
                "pass" to true,
                "textureId" to surfaceProducer.id(),
                "width" to canvasWidth,
                "height" to canvasHeight,
                "durationUs" to totalDurationUs,
                "state" to state.name,
                "generationId" to currentGeneration,
                "raw" to "status=OK;route=transition;clipCount=${layouts.size};spans=${spans.size};" +
                    "transitions=${transitions.count { !it.isHardCut }};totalDurationUs=$totalDurationUs;" +
                    "canvas=${canvasWidth}x$canvasHeight",
            ))
        }
    }

    /** Must be called on the orchestration thread. Returns null on success, else a reason. */
    private fun prepareOnOrch(): String? {
        // ── 1. Inspect + normalize every clip into export ClipInputs ────────
        val inspected = ArrayList<Triple<AndroidEditorClipPlaybackSpec, AndroidTimelineVideoEncoder.ClipInput, Boolean>>()
        for ((index, spec) in requestedClipSpecs.withIndex()) {
            if (spec.freezePtsUs != null) {
                return "freeze_clip_unsupported_on_transition_timeline;clipId=${spec.clipId}"
            }
            val inspection = AndroidDagSourceInspector().inspect(spec.sourcePath, context)
            try {
                if (!inspection.pass) {
                    return "clip_inspect_failed;path=${spec.sourcePath};detail=${inspection.failureReason}"
                }
                if (inspection.width <= 0 || inspection.height <= 0) {
                    return "clip_invalid_geometry;path=${spec.sourcePath}"
                }
                if (spec.sourceTrimEndUs > inspection.durationUs + TRIM_END_CLAMP_SLACK_US) {
                    return "trim_exceeds_source_duration;path=${spec.sourcePath};" +
                        "trimEndUs=${spec.sourceTrimEndUs};sourceDurationUs=${inspection.durationUs}"
                }
                var normalized = spec
                if (inspection.durationUs > 0L && spec.sourceTrimEndUs > inspection.durationUs) {
                    val clampedTrimEndUs = inspection.durationUs
                    if (clampedTrimEndUs <= spec.sourceTrimStartUs) {
                        return "trim_clamp_collapsed_window;path=${spec.sourcePath}"
                    }
                    val effectiveSpeed = if (spec.speed > 0.0) spec.speed else 1.0
                    Log.i(TAG, "$LOG_PREFIX trim_end_clamped index=$index originalTrimEndUs=${spec.sourceTrimEndUs} " +
                        "clampedTrimEndUs=$clampedTrimEndUs sourceDurationUs=${inspection.durationUs}")
                    normalized = spec.copy(
                        sourceTrimEndUs = clampedTrimEndUs,
                        timelineDurationUs = ((clampedTrimEndUs - spec.sourceTrimStartUs) / effectiveSpeed).toLong(),
                    )
                }
                val input = AndroidTimelineVideoEncoder.ClipInput(
                    sourcePath = normalized.sourcePath,
                    trimStartSeconds = normalized.sourceTrimStartUs / 1_000_000.0,
                    trimEndSeconds = normalized.sourceTrimEndUs / 1_000_000.0,
                    decodedWidth = inspection.width,
                    decodedHeight = inspection.height,
                    rotationDegrees = inspection.rotationDegrees,
                    mediaKind = "video",
                    stillFrameCount = 0,
                    speed = if (normalized.speed > 0.0) normalized.speed else 1.0,
                    // Reverse sidecars were already normalized into forward clips by the
                    // coordinator; this route never receives isReversed=true.
                    isReversed = false,
                    freezePTS = null,
                )
                inspected.add(Triple(normalized, input, inspection.hasAudio))
                Log.i(TAG, "$LOG_PREFIX clip_inspect_result index=$index clipId=${spec.clipId} " +
                    "decoded=${inspection.width}x${inspection.height} rotation=${inspection.rotationDegrees} " +
                    "durationUs=${inspection.durationUs} hasAudio=${inspection.hasAudio} speed=${normalized.speed}")
            } finally {
                try { inspection.extractor?.release() } catch (_: Throwable) {}
            }
        }

        // ── 2. Canvas = requested draft canvas when valid, else first clip's
        //      display (post-rotation) size ──────────────────────────────────
        if (requestedCanvasWidth > 0 && requestedCanvasHeight > 0) {
            canvasWidth = requestedCanvasWidth
            canvasHeight = requestedCanvasHeight
        } else {
            val first = inspected.first().second
            val firstSwaps = first.rotationDegrees == 90 || first.rotationDegrees == 270
            canvasWidth = if (firstSwaps) first.decodedHeight else first.decodedWidth
            canvasHeight = if (firstSwaps) first.decodedWidth else first.decodedHeight
        }
        if (canvasWidth <= 0 || canvasHeight <= 0) return "canvas_invalid_geometry"

        // ── 3. Export planner (canonical overlap/solo timing) ───────────────
        val clipInputs = inspected.map { it.second }
        val plan = AndroidTimelineExportSegmentPlanner.build(clipInputs, transitions, PREVIEW_FPS)
        if (plan.failureReason != null || plan.segments.isEmpty()) {
            return "transition_plan_failed;detail=${plan.failureReason ?: "no_segments"}"
        }

        // Overlap-adjusted clip layout: each clip starts where the previous one ends minus
        // the transition it shares with it (the planner already validated the overlaps).
        val incomingByClip = HashMap<Int, AndroidTimelineTransitionDescriptor>()
        for (t in transitions) if (!t.isHardCut) incomingByClip[t.toClipIndex] = t
        val builtLayouts = ArrayList<ClipLayout>(inspected.size)
        var cursorUs = 0L
        for ((index, entry) in inspected.withIndex()) {
            val (spec, input, hasAudio) = entry
            val incomingUs = incomingByClip[index]?.let { (it.durationSeconds * 1_000_000.0).toLong() } ?: 0L
            val startUs = (cursorUs - incomingUs).coerceAtLeast(0L)
            val fitQuad = computeQuadOrNull(input.decodedWidth, input.decodedHeight, input.rotationDegrees, cover = false)
                ?: return "clip_invalid_geometry;path=${input.sourcePath}"
            val fillQuad = computeQuadOrNull(input.decodedWidth, input.decodedHeight, input.rotationDegrees, cover = true)
                ?: return "clip_invalid_geometry;path=${input.sourcePath}"
            val quad = if (canvasContentMode == "fill") fillQuad else fitQuad
            val blurFillMismatch = canvasContentMode == "blurFill" &&
                !isAspectMatchedToCanvas(input.decodedWidth, input.decodedHeight, input.rotationDegrees)
            if (canvasContentMode == "blurFill") {
                Log.i(TAG, "$LOG_PREFIX blurfill_layout index=$index clipId=${spec.clipId} " +
                    "decoded=${input.decodedWidth}x${input.decodedHeight} rotation=${input.rotationDegrees} " +
                    "canvas=${canvasWidth}x$canvasHeight mismatch=$blurFillMismatch")
            }
            builtLayouts.add(
                ClipLayout(spec, input, startUs, spec.timelineDurationUs, hasAudio, quad, fitQuad, fillQuad, blurFillMismatch),
            )
            cursorUs = startUs + spec.timelineDurationUs
        }
        layouts = builtLayouts
        totalDurationUs = cursorUs
        if (totalDurationUs <= 0L) return "timeline_duration_non_positive"

        // Map every planner segment onto a contiguous timeline window.
        val builtSpans = ArrayList<Span>(plan.segments.size)
        for (segment in plan.segments) {
            when (segment) {
                is AndroidTimelineExportSegment.Solo -> {
                    val clipIndex = clipInputs.indexOfFirst { it === segment.clip }
                    if (clipIndex < 0) return "plan_segment_unbound_clip"
                    val layout = layouts[clipIndex]
                    val speed = layout.input.speed
                    val startUs = layout.timelineStartUs +
                        (((segment.windowStartSeconds - layout.input.trimStartSeconds) / speed) * 1_000_000.0).toLong()
                    val endUs = layout.timelineStartUs +
                        (((segment.windowEndSeconds - layout.input.trimStartSeconds) / speed) * 1_000_000.0).toLong()
                    builtSpans.add(Span(segment, startUs, endUs, clipIndex, -1))
                }
                is AndroidTimelineExportSegment.Overlap -> {
                    val toIndex = segment.transition.toClipIndex
                    val fromIndex = segment.transition.fromClipIndex
                    if (toIndex !in layouts.indices || fromIndex !in layouts.indices) return "plan_segment_unbound_clip"
                    val startUs = layouts[toIndex].timelineStartUs
                    val endUs = startUs + (segment.transition.durationSeconds * 1_000_000.0).toLong()
                    builtSpans.add(Span(segment, startUs, endUs, fromIndex, toIndex))
                }
            }
        }
        // Spans must be chronological and non-empty; the planner guarantees ordering.
        for (i in 1 until builtSpans.size) {
            if (builtSpans[i].timelineStartUs < builtSpans[i - 1].timelineStartUs) return "plan_spans_not_chronological"
        }
        spans = builtSpans.filter { it.durationUs > 0L }
        if (spans.isEmpty()) return "plan_no_renderable_spans"
        Log.i(TAG, "$LOG_PREFIX plan_ready clips=${layouts.size} spans=${spans.size} " +
            "expectedSamples=${plan.expectedSamples} totalDurationUs=$totalDurationUs canvas=${canvasWidth}x$canvasHeight " +
            spans.joinToString(" ") { s ->
                val kind = if (s.isOverlap) "overlap" else "solo"
                "$kind[${s.timelineStartUs}..${s.timelineEndUs})"
            })

        // ── 4. EGL / GL / surface ───────────────────────────────────────────
        val glFailure = setupGlOnOrch()
        if (glFailure != null) return glFailure

        // ── 5. Land on frame 0, paused ─────────────────────────────────────
        return seekOnOrch(0L, resumeAfterSeek = false)
    }

    // ── EGL / GL setup ─────────────────────────────────────────────────────

    private fun setupGlOnOrch(): String? {
        try {
            eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (eglDisplay == EGL14.EGL_NO_DISPLAY) return "egl_get_display_failed"
            val version = IntArray(2)
            if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) return "egl_initialize_failed"
            val attribs = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, numConfigs, 0)
            val config = configs[0] ?: return "egl_choose_config_failed"
            eglConfig = config

            // ES3-first (falls back to ES2), mirroring the export encoders.
            eglContext = EGL14.eglCreateContext(
                eglDisplay, config, EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0,
            )
            if (eglContext == EGL14.EGL_NO_CONTEXT) {
                eglContext = EGL14.eglCreateContext(
                    eglDisplay, config, EGL14.EGL_NO_CONTEXT,
                    intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
                )
            }
            if (eglContext == EGL14.EGL_NO_CONTEXT) return "egl_create_context_failed"

            eglPbufferSurface = EGL14.eglCreatePbufferSurface(
                eglDisplay, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
            )
            if (eglPbufferSurface == EGL14.EGL_NO_SURFACE) return "egl_create_pbuffer_failed"
            if (!EGL14.eglMakeCurrent(eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext)) {
                return "egl_make_current_failed"
            }

            val majorVersionOut = IntArray(1)
            GLES20.glGetIntegerv(GLES30.GL_MAJOR_VERSION, majorVersionOut, 0)
            while (GLES20.glGetError() != GLES20.GL_NO_ERROR) { /* drain a failed ES2 query */ }

            setupOesProgram()
            if (canvasContentMode == "blurFill") setupBlurOesProgram()
            fromResolveTextureId = createRgba8Texture(canvasWidth, canvasHeight)
            toResolveTextureId = createRgba8Texture(canvasWidth, canvasHeight)
            if (fromResolveTextureId == 0 || toResolveTextureId == 0) return "resolve_texture_create_failed"
            fromResolveFboId = createFramebufferForTexture(fromResolveTextureId)
            toResolveFboId = createFramebufferForTexture(toResolveTextureId)
            if (fromResolveFboId == 0 || toResolveFboId == 0) return "resolve_fbo_incomplete"

            // Decode slots: constructed on a looper-less thread (see the class doc).
            val slotFailure = setupDecodeSlotsOnLooperlessThread()
            if (slotFailure != null) return slotFailure

            val diagnostics = VanguardDiagnostics()
            nativeBridge = VanguardNativeBridge(VanguardLifecycleObserver(diagnostics), diagnostics, null)

            // Flutter surface: register the lifecycle callback BEFORE the first getSurface().
            val adapter = AndroidDagSurfaceProducerLifecycleAdapter(
                onAvailable = { handleSurfaceAvailable() },
                onCleanup = { handleSurfaceCleanup() },
            ).also { lifecycleAdapter = it }
            @Suppress("DEPRECATION")
            surfaceProducer.setCallback(adapter)
            surfaceProducer.setSize(canvasWidth, canvasHeight)
            val windowFailure = createWindowSurfaceOnOrch()
            if (windowFailure != null) return windowFailure
            Log.i(TAG, "$LOG_PREFIX gl_ready canvas=${canvasWidth}x$canvasHeight glMajor=${majorVersionOut[0]} textureId=${surfaceProducer.id()}")
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "$LOG_PREFIX gl_setup_exception", t)
            return "gl_setup_exception:${t.javaClass.simpleName}"
        }
    }

    /**
     * Constructs both decode slots (GL texture + SurfaceTexture + Surface) on a short-lived
     * thread WITHOUT a Looper, with this session's EGL context current there, then hands the
     * context back to the orchestration thread. See the class doc for why.
     */
    private fun setupDecodeSlotsOnLooperlessThread(): String? {
        val display = eglDisplay
        val ctx = eglContext
        val pbuffer = eglPbufferSurface
        // Release from this thread first: a context may be current on one thread at a time.
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        var failure: String? = null
        val done = CountDownLatch(1)
        val worker = Thread({
            try {
                if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, ctx)) {
                    failure = "slot_bootstrap_make_current_failed"
                } else {
                    fromSlot.setup()
                    toSlot.setup()
                    val err = GLES20.glGetError()
                    if (err != GLES20.GL_NO_ERROR) failure = "slot_bootstrap_gl_error:$err"
                }
            } catch (t: Throwable) {
                failure = "slot_bootstrap_exception:${t.javaClass.simpleName}"
            } finally {
                try {
                    EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                } catch (_: Throwable) {}
                done.countDown()
            }
        }, "EditorTransitionSlotBootstrap_${surfaceProducer.id()}")
        worker.start()
        try {
            if (!done.await(BOOTSTRAP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                failure = failure ?: "slot_bootstrap_timeout"
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            failure = failure ?: "slot_bootstrap_interrupted"
        }
        if (!EGL14.eglMakeCurrent(display, pbuffer, pbuffer, ctx)) {
            return failure ?: "egl_make_current_after_bootstrap_failed"
        }
        if (failure == null) slotsReady = true
        return failure
    }

    /** Must be called on the orchestration thread with the EGL context current. */
    private fun createWindowSurfaceOnOrch(): String? {
        val config = eglConfig ?: return "egl_config_missing"
        val surface = try {
            surfaceProducer.getSurface().also { flutterSurface = it }
        } catch (t: Throwable) {
            return "surface_producer_get_surface_failed:${t.javaClass.simpleName}"
        }
        val window = EGL14.eglCreateWindowSurface(eglDisplay, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        if (window == null || window == EGL14.EGL_NO_SURFACE) {
            return "egl_create_window_surface_failed:0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        if (!EGL14.eglMakeCurrent(eglDisplay, window, window, eglContext)) {
            try { EGL14.eglDestroySurface(eglDisplay, window) } catch (_: Throwable) {}
            EGL14.eglMakeCurrent(eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext)
            return "egl_make_current_window_failed:0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        eglWindowSurface = window
        return null
    }

    private fun destroyWindowSurfaceOnOrch() {
        val window = eglWindowSurface
        eglWindowSurface = EGL14.EGL_NO_SURFACE
        flutterSurface = null
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return
        try { EGL14.eglMakeCurrent(eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext) } catch (_: Throwable) {}
        if (window != EGL14.EGL_NO_SURFACE) {
            try { EGL14.eglDestroySurface(eglDisplay, window) } catch (_: Throwable) {}
        }
    }

    private fun makeWindowCurrent(): Boolean {
        if (eglWindowSurface == EGL14.EGL_NO_SURFACE) return false
        return EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)
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
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("GL program link failed: $log")
        }
        sharpProgram = OesProgramHandles(
            program = program,
            aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition"),
            aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord"),
            uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix"),
        )
    }

    /**
     * MULTI-VIDEO-BLURFILL: the blurred/dimmed background program. Same vertex stage as the
     * sharp program (the SurfaceTexture `uSTMatrix` is applied identically), and a fragment
     * stage that averages a 5x5 binomial-weighted tap grid spaced by `uTexelStep` around the
     * transformed coordinate and scales the result by `uDimFactor`. A single pass straight
     * from the OES decoder texture: no intermediate targets, no mipmaps (OES cannot have
     * them). Compiled only when the canvas is "blurFill".
     */
    private fun setupBlurOesProgram() {
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
            uniform vec2 uTexelStep;
            uniform float uDimFactor;
            void main() {
                float w[5];
                w[0] = 1.0; w[1] = 4.0; w[2] = 6.0; w[3] = 4.0; w[4] = 1.0;
                vec3 acc = vec3(0.0);
                for (int y = 0; y < 5; y++) {
                    for (int x = 0; x < 5; x++) {
                        vec2 offset = vec2(float(x - 2), float(y - 2)) * uTexelStep;
                        acc += texture2D(sTexture, vTextureCoord + offset).rgb * (w[x] * w[y]);
                    }
                }
                gl_FragColor = vec4(acc * (uDimFactor / 256.0), 1.0);
            }
        """.trimIndent()
        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("GL blur program link failed: $log")
        }
        blurProgram = BlurOesProgramHandles(
            program = program,
            aPositionLoc = GLES20.glGetAttribLocation(program, "aPosition"),
            aTexCoordLoc = GLES20.glGetAttribLocation(program, "aTextureCoord"),
            uSTMatrixLoc = GLES20.glGetUniformLocation(program, "uSTMatrix"),
            uTexelStepLoc = GLES20.glGetUniformLocation(program, "uTexelStep"),
            uDimFactorLoc = GLES20.glGetUniformLocation(program, "uDimFactor"),
        )
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

    /// Centered quad (BL, BR, TL, TR NDC pairs) rotated by [rotationDegrees] -- the
    /// export encoders' geometry, re-derived against the canvas. With [cover] false
    /// (aspect fit, the original byte-equivalent behaviour) the clip is scaled by
    /// min(canvas/display), letterboxing/pillarboxing inside the canvas. With [cover]
    /// true (aspect fill) it is scaled by max(canvas/display): the quad extends past the
    /// ±1 NDC canvas bounds on one axis and is clipped there by the GPU's standard
    /// primitive clipping, producing a centered cover-crop with no extra geometry.
    private fun computeQuadOrNull(decodedWidth: Int, decodedHeight: Int, rotationDegrees: Int, cover: Boolean): FloatArray? {
        if (decodedWidth <= 0 || decodedHeight <= 0 || canvasWidth <= 0 || canvasHeight <= 0) return null
        val displayWidth: Float
        val displayHeight: Float
        if (rotationDegrees == 90 || rotationDegrees == 270) {
            displayWidth = decodedHeight.toFloat()
            displayHeight = decodedWidth.toFloat()
        } else {
            displayWidth = decodedWidth.toFloat()
            displayHeight = decodedHeight.toFloat()
        }
        val scale = if (cover) {
            max(canvasWidth.toFloat() / displayWidth, canvasHeight.toFloat() / displayHeight)
        } else {
            min(canvasWidth.toFloat() / displayWidth, canvasHeight.toFloat() / displayHeight)
        }
        val halfPixelX = decodedWidth.toFloat() * scale / 2f
        val halfPixelY = decodedHeight.toFloat() * scale / 2f
        val radians = Math.toRadians(-rotationDegrees.toDouble())
        val cosR = cos(radians).toFloat()
        val sinR = sin(radians).toFloat()
        fun rotatedPixel(x: Float, y: Float) = floatArrayOf(x * cosR - y * sinR, x * sinR + y * cosR)
        fun toNdc(p: FloatArray) =
            floatArrayOf(p[0] / (canvasWidth.toFloat() / 2f), p[1] / (canvasHeight.toFloat() / 2f))
        val bl = toNdc(rotatedPixel(-halfPixelX, -halfPixelY))
        val br = toNdc(rotatedPixel(halfPixelX, -halfPixelY))
        val tl = toNdc(rotatedPixel(-halfPixelX, halfPixelY))
        val tr = toNdc(rotatedPixel(halfPixelX, halfPixelY))
        return floatArrayOf(bl[0], bl[1], br[0], br[1], tl[0], tl[1], tr[0], tr[1])
    }

    /** True when the clip's post-rotation display aspect equals the canvas aspect (within tolerance). */
    private fun isAspectMatchedToCanvas(decodedWidth: Int, decodedHeight: Int, rotationDegrees: Int): Boolean {
        if (decodedWidth <= 0 || decodedHeight <= 0 || canvasWidth <= 0 || canvasHeight <= 0) return true
        val swaps = rotationDegrees == 90 || rotationDegrees == 270
        val displayWidth = (if (swaps) decodedHeight else decodedWidth).toFloat()
        val displayHeight = (if (swaps) decodedWidth else decodedHeight).toFloat()
        val cross = displayWidth * canvasHeight - displayHeight * canvasWidth
        return kotlin.math.abs(cross) <= BLUR_FILL_ASPECT_EPSILON * displayWidth * canvasHeight
    }

    // ── GL draw helpers (export-equivalent) ────────────────────────────────

    /**
     * Sharp draw of [slot] through [quad] with the sharp program. [clear] false skips the
     * black clear so the draw layers over what the bound framebuffer already holds (the
     * blurFill foreground over its blurred background).
     */
    private fun drawOesQuad(slot: AndroidTimelineGlesTransitionDecodeSlot, quad: FloatArray, clear: Boolean = true): String? {
        val p = sharpProgram ?: return "sharp_program_missing"
        GLES20.glViewport(0, 0, canvasWidth, canvasHeight)
        if (clear) {
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        }
        GLES20.glUseProgram(p.program)
        quadBuffer.position(0)
        quadBuffer.put(quad)
        quadBuffer.position(0)
        GLES20.glEnableVertexAttribArray(p.aPositionLoc)
        GLES20.glVertexAttribPointer(p.aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)
        texBuffer.position(0)
        GLES20.glEnableVertexAttribArray(p.aTexCoordLoc)
        GLES20.glVertexAttribPointer(p.aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuffer)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, slot.oesTextureId)
        GLES20.glUniformMatrix4fv(p.uSTMatrixLoc, 1, false, slot.transformMatrix, 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(p.aPositionLoc)
        GLES20.glDisableVertexAttribArray(p.aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glUseProgram(0)
        val err = GLES20.glGetError()
        return if (err == GLES20.GL_NO_ERROR) null else "gl_error:$err"
    }

    /**
     * MULTI-VIDEO-BLURFILL background: clears the bound framebuffer to black, then draws
     * [slot] through [quad] (the cover-crop quad) with the blur program -- blurred and
     * dimmed, SurfaceTexture transform applied exactly as the sharp draw does.
     */
    private fun drawBlurOesQuad(slot: AndroidTimelineGlesTransitionDecodeSlot, quad: FloatArray): String? {
        val p = blurProgram ?: return "blur_program_missing"
        GLES20.glViewport(0, 0, canvasWidth, canvasHeight)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(p.program)
        quadBuffer.position(0)
        quadBuffer.put(quad)
        quadBuffer.position(0)
        GLES20.glEnableVertexAttribArray(p.aPositionLoc)
        GLES20.glVertexAttribPointer(p.aPositionLoc, 2, GLES20.GL_FLOAT, false, 0, quadBuffer)
        texBuffer.position(0)
        GLES20.glEnableVertexAttribArray(p.aTexCoordLoc)
        GLES20.glVertexAttribPointer(p.aTexCoordLoc, 2, GLES20.GL_FLOAT, false, 0, texBuffer)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, slot.oesTextureId)
        GLES20.glUniformMatrix4fv(p.uSTMatrixLoc, 1, false, slot.transformMatrix, 0)
        GLES20.glUniform2f(p.uTexelStepLoc, BLUR_FILL_TEXEL_STEP, BLUR_FILL_TEXEL_STEP)
        GLES20.glUniform1f(p.uDimFactorLoc, BLUR_FILL_DIM_FACTOR)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(p.aPositionLoc)
        GLES20.glDisableVertexAttribArray(p.aTexCoordLoc)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES20.glUseProgram(0)
        val err = GLES20.glGetError()
        return if (err == GLES20.GL_NO_ERROR) null else "gl_error:$err"
    }

    /**
     * Draws one clip frame into the currently bound framebuffer according to its layout:
     * a "fit"/"fill" clip, or an aspect-matched "blurFill" clip, is one sharp draw through
     * [ClipLayout.quad]; a mismatched "blurFill" clip is a clear, the blurred/dimmed
     * cover-crop background, then the sharp aspect-fit foreground on top. Both the solo
     * present and the overlap pre-resolve go through here, so a transition blends two
     * already-normalized full-canvas blurFill frames.
     */
    private fun drawLayerToBoundFramebuffer(slot: AndroidTimelineGlesTransitionDecodeSlot, layout: ClipLayout): String? {
        if (!layout.blurFillMismatch) return drawOesQuad(slot, layout.quad)
        val backgroundFailure = drawBlurOesQuad(slot, layout.fillQuad)
        if (backgroundFailure != null) return "blur_background_failed:$backgroundFailure"
        return drawOesQuad(slot, layout.fitQuad, clear = false)
    }

    private fun resolveSlotToTexture2d(slot: AndroidTimelineGlesTransitionDecodeSlot, layout: ClipLayout, fboId: Int): String? {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        val drawFailure = drawLayerToBoundFramebuffer(slot, layout)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return drawFailure
    }

    /** Solo frame: OES slot -> window surface -> swap. */
    private fun presentSoloFrame(slot: AndroidTimelineGlesTransitionDecodeSlot, layout: ClipLayout): String? {
        if (!makeWindowCurrent()) return "surface_unavailable"
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        val drawFailure = drawLayerToBoundFramebuffer(slot, layout)
        if (drawFailure != null) return "solo_draw_failed:$drawFailure"
        if (!EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface)) {
            return "swap_failed:0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        return null
    }

    /** Transition pair: pre-resolve both slots, native transition draw, swap. */
    private fun presentTransitionPair(
        fromLayout: ClipLayout,
        toLayout: ClipLayout,
        progress: Double,
        transitionTypeCode: Int,
    ): String? {
        val bridge = nativeBridge ?: return "native_bridge_missing"
        if (!makeWindowCurrent()) return "surface_unavailable"
        val fromResolveFailure = resolveSlotToTexture2d(fromSlot, fromLayout, fromResolveFboId)
        if (fromResolveFailure != null) return "resolve_failed:from:$fromResolveFailure"
        val toResolveFailure = resolveSlotToTexture2d(toSlot, toLayout, toResolveFboId)
        if (toResolveFailure != null) return "resolve_failed:to:$toResolveFailure"

        // Kotlin owns the frame clear on the target surface; the native seam never clears.
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glViewport(0, 0, canvasWidth, canvasHeight)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        val status = bridge.drawAndroidTimelineGlesTransitionExportFrame(
            fromResolveTextureId, GLES20.GL_TEXTURE_2D,
            toResolveTextureId, GLES20.GL_TEXTURE_2D,
            canvasWidth, canvasHeight, transitionTypeCode, progress,
        )
        if (!status.startsWith("status=OK")) return "transition_render_failed:$status"
        if (!EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface)) {
            return "swap_failed:0x${Integer.toHexString(EGL14.eglGetError())}"
        }
        return null
    }

    // ── Timeline <-> source mapping ────────────────────────────────────────

    private fun sourcePtsForTimeline(layout: ClipLayout, timelineUs: Long): Long {
        val speed = layout.input.speed
        val trimStartUs = (layout.input.trimStartSeconds * 1_000_000.0).toLong()
        val trimEndUs = (layout.input.trimEndSeconds * 1_000_000.0).toLong()
        val offsetUs = ((timelineUs - layout.timelineStartUs).coerceAtLeast(0L) * speed).toLong()
        val maxUs = (trimEndUs - 1L).coerceAtLeast(trimStartUs)
        return (trimStartUs + offsetUs).coerceIn(trimStartUs, maxUs)
    }

    private fun timelineForSourcePts(layout: ClipLayout, sourcePtsUs: Long): Long {
        val speed = layout.input.speed
        val trimStartUs = (layout.input.trimStartSeconds * 1_000_000.0).toLong()
        return layout.timelineStartUs + ((sourcePtsUs - trimStartUs) / speed).toLong()
    }

    private fun spanIndexForTimeline(timelineUs: Long): Int {
        var idx = 0
        for (i in spans.indices) {
            if (spans[i].timelineStartUs <= timelineUs) idx = i else break
        }
        return idx
    }

    private fun timelinePtsForFrames(span: Span, frames: AndroidTimelineGlesTransitionOverlapDecoder.Step.Frames): Long {
        val from = frames.from
        val to = frames.to
        val raw = when {
            from != null -> timelineForSourcePts(layouts[span.fromClipIndex], from.presentationTimeUs)
            to != null && span.toClipIndex >= 0 -> timelineForSourcePts(layouts[span.toClipIndex], to.presentationTimeUs)
            to != null -> timelineForSourcePts(layouts[span.fromClipIndex], to.presentationTimeUs)
            else -> span.timelineStartUs
        }
        return raw.coerceIn(span.timelineStartUs, (span.timelineEndUs - 1L).coerceAtLeast(span.timelineStartUs))
    }

    // ── Span activation (decoder open) ─────────────────────────────────────

    /**
     * Must be called on the orchestration thread. Closes any active decoder and opens the
     * decoder for [spanIndex] starting at timeline [startTimelineUs] (clamped into the span).
     */
    private fun activateSpanOnOrch(spanIndex: Int, startTimelineUs: Long): String? {
        closeActiveDecoder()
        if (spanIndex !in spans.indices) return "span_index_out_of_range:$spanIndex"
        val span = spans[spanIndex]
        val startUs = startTimelineUs.coerceIn(span.timelineStartUs, (span.timelineEndUs - 1L).coerceAtLeast(span.timelineStartUs))
        val decoder: AndroidTimelineGlesTransitionOverlapDecoder
        when (val segment = span.segment) {
            is AndroidTimelineExportSegment.Solo -> {
                val layout = layouts[span.fromClipIndex]
                val windowStartUs = sourcePtsForTimeline(layout, startUs)
                decoder = AndroidTimelineGlesTransitionOverlapDecoder(
                    fromSource = AndroidTimelineGlesTransitionOverlapDecoder.Source(
                        "solo", segment.clip, windowStartUs / 1_000_000.0, segment.windowEndSeconds, fromSlot,
                    ),
                    toSource = null,
                    context = context,
                ) { disposed.get() }
                activeExpectedPairs = 1
                activePairIndex = 0
            }
            is AndroidTimelineExportSegment.Overlap -> {
                val fromLayout = layouts[span.fromClipIndex]
                val toLayout = layouts[span.toClipIndex]
                val fromWindowStartUs = sourcePtsForTimeline(fromLayout, startUs)
                val toWindowStartUs = sourcePtsForTimeline(toLayout, startUs)
                decoder = AndroidTimelineGlesTransitionOverlapDecoder(
                    fromSource = AndroidTimelineGlesTransitionOverlapDecoder.Source(
                        "from", segment.fromClip, fromWindowStartUs / 1_000_000.0, segment.fromWindowEndSeconds, fromSlot,
                    ),
                    toSource = AndroidTimelineGlesTransitionOverlapDecoder.Source(
                        "to", segment.toClip, toWindowStartUs / 1_000_000.0, segment.toWindowEndSeconds, toSlot,
                    ),
                    context = context,
                ) { disposed.get() }
                activeExpectedPairs = segment.transition.overlapFrameCount(PREVIEW_FPS).coerceAtLeast(1)
                val fraction = (startUs - span.timelineStartUs).toDouble() / span.durationUs.coerceAtLeast(1L).toDouble()
                activePairIndex = (fraction * activeExpectedPairs).toInt().coerceIn(0, activeExpectedPairs - 1)
            }
        }
        val openError = decoder.open()
        if (openError != null) return "decoder_open_failed:$openError"
        activeDecoder = decoder
        activeSpanIndex = spanIndex
        pendingStep = null
        if (span.isOverlap && startUs < span.midpointUs) {
            prewarmAudio(span.toClipIndex, span.midpointUs)
        } else {
            discardPrewarm()
        }
        return null
    }

    private fun closeActiveDecoder() {
        val decoder = activeDecoder
        activeDecoder = null
        pendingStep = null
        if (decoder != null) {
            try { decoder.close() } catch (_: Throwable) {}
        }
    }

    // ── Original audio ownership ───────────────────────────────────────────

    private fun audioOwnerForTimeline(spanIndex: Int, timelineUs: Long): Int {
        val span = spans.getOrNull(spanIndex) ?: return -1
        if (!span.isOverlap) return span.fromClipIndex
        return if (timelineUs < span.midpointUs) span.fromClipIndex else span.toClipIndex
    }

    /**
     * Must be called on the orchestration thread. Ensures the original-audio runtime belongs
     * to [ownerIndex], (re)creating and preroll-seeking it to [timelineUs] when the owner
     * changes; when [playing], the runtime is started. Blocks briefly on MediaPlayer prepare
     * (the sequential session's own latch pattern) so audio never runs ahead of video.
     */
    private fun ensureAudioOwner(ownerIndex: Int, timelineUs: Long, playing: Boolean, site: String) {
        if (ownerIndex == audioOwnerClipIndex) return
        val old = activeAudioRuntime
        activeAudioRuntime = null
        audioOwnerClipIndex = ownerIndex
        // Release the outgoing runtime asynchronously: its MediaPlayer teardown must not
        // stall the video loop, and it can never be reached again once detached here.
        old?.release(null)
        val layout = layouts.getOrNull(ownerIndex) ?: return
        val gain = originalGainByClipId[layout.spec.clipId] ?: layout.spec.originalAudioGain
        val sourcePtsUs = sourcePtsForTimeline(layout, timelineUs)

        // Adopt the prewarmed incoming runtime when it is the one being asked for.
        val prewarmed = prewarmRuntime
        if (prewarmed != null && prewarmClipIndex == ownerIndex) {
            val latch = prewarmLatch
            prewarmRuntime = null
            prewarmLatch = null
            prewarmClipIndex = -1
            if (latch != null) awaitLatch(latch)
            prewarmed.setVolumeGain(gain)
            activeAudioRuntime = prewarmed
            // Async re-seek to the exact cut-over instant; resumes on completion when playing.
            prewarmed.seek(sourcePtsUs, playing) {}
            Log.i(TAG, "$LOG_PREFIX audio_owner site=$site clipIndex=$ownerIndex runtime=prewarmed sourcePtsUs=$sourcePtsUs gain=$gain playing=$playing")
            return
        }
        discardPrewarm()

        if (!layout.hasAudio || gain <= 0.0f) {
            Log.i(TAG, "$LOG_PREFIX audio_owner site=$site clipIndex=$ownerIndex runtime=false hasAudio=${layout.hasAudio} gain=$gain")
            return
        }
        val runtime = AndroidEditorOriginalAudioPreviewRuntime(context, gain, layout.input.speed.toFloat())
        val latch = CountDownLatch(1)
        runtime.prepare(layout.spec.sourcePath, sourcePtsUs) { latch.countDown() }
        awaitLatch(latch)
        activeAudioRuntime = runtime
        Log.i(TAG, "$LOG_PREFIX audio_owner site=$site clipIndex=$ownerIndex runtime=true sourcePtsUs=$sourcePtsUs gain=$gain playing=$playing")
        if (playing) runtime.play()
    }

    /**
     * Must be called on the orchestration thread. Starts an asynchronous prepare of the
     * runtime for [clipIndex], prerolled at [timelineUs], to be adopted by [ensureAudioOwner].
     */
    private fun prewarmAudio(clipIndex: Int, timelineUs: Long) {
        if (clipIndex == audioOwnerClipIndex) return
        if (prewarmRuntime != null && prewarmClipIndex == clipIndex) return
        discardPrewarm()
        val layout = layouts.getOrNull(clipIndex) ?: return
        val gain = originalGainByClipId[layout.spec.clipId] ?: layout.spec.originalAudioGain
        if (!layout.hasAudio || gain <= 0.0f) return
        val runtime = AndroidEditorOriginalAudioPreviewRuntime(context, gain, layout.input.speed.toFloat())
        val latch = CountDownLatch(1)
        runtime.prepare(layout.spec.sourcePath, sourcePtsForTimeline(layout, timelineUs)) { latch.countDown() }
        prewarmClipIndex = clipIndex
        prewarmRuntime = runtime
        prewarmLatch = latch
    }

    private fun discardPrewarm() {
        val runtime = prewarmRuntime
        prewarmRuntime = null
        prewarmLatch = null
        prewarmClipIndex = -1
        runtime?.release(null)
    }

    private fun seekAudioTo(timelineUs: Long, resume: Boolean) {
        val runtime = activeAudioRuntime ?: return
        val layout = layouts.getOrNull(audioOwnerClipIndex) ?: return
        val sourcePtsUs = sourcePtsForTimeline(layout, timelineUs)
        val latch = CountDownLatch(1)
        runtime.seek(sourcePtsUs, resume) { latch.countDown() }
        awaitLatch(latch)
    }

    private fun awaitLatch(latch: CountDownLatch) {
        try {
            latch.await(BOOTSTRAP_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun releaseAudioRuntimeBlocking() {
        discardPrewarm()
        val old = activeAudioRuntime ?: return
        activeAudioRuntime = null
        audioOwnerClipIndex = -1
        val latch = CountDownLatch(1)
        old.release { latch.countDown() }
        awaitLatch(latch)
    }

    // ── seek core ──────────────────────────────────────────────────────────

    /**
     * Must be called on the orchestration thread. Stops any running loop, opens the decoder
     * for the span containing [targetUs], decodes and presents exactly one frame (held on the
     * texture, Paused), repositions audio, bumps the generation and emits the frame. Starts
     * the loop when [resumeAfterSeek]. Returns null on success.
     */
    private fun seekOnOrch(targetUs: Long, resumeAfterSeek: Boolean): String? {
        stopTick()
        resolvePendingPlay(pass = false, reason = "seek_interrupted", stateName = AndroidDagPlaybackState.Paused.name)
        val token = sessionToken.incrementAndGet()
        isPlaying = false
        activeAudioRuntime?.pause()
        if (surfaceLostFlag.get()) return "surface_lost"

        val clampedUs = targetUs.coerceIn(0L, (totalDurationUs - 1L).coerceAtLeast(0L))
        val spanIndex = spanIndexForTimeline(clampedUs)
        val activateFailure = activateSpanOnOrch(spanIndex, clampedUs)
        if (activateFailure != null) return activateFailure

        val decoder = activeDecoder ?: return "decoder_missing_after_activate"
        val step = decoder.nextStep()
        val frames = when (step) {
            is AndroidTimelineGlesTransitionOverlapDecoder.Step.Frames -> step
            AndroidTimelineGlesTransitionOverlapDecoder.Step.Exhausted -> return "seek_no_frame_in_window;spanIndex=$spanIndex"
            AndroidTimelineGlesTransitionOverlapDecoder.Step.Cancelled -> return "disposed"
            is AndroidTimelineGlesTransitionOverlapDecoder.Step.Failed -> return "seek_decode_failed:${step.reason}"
        }
        val span = spans[spanIndex]
        val presentFailure = presentFrames(span, frames)
        if (presentFailure != null) return presentFailure
        val renderedUs = timelinePtsForFrames(span, frames)
        positionUs = renderedUs
        currentGeneration = publicGeneration.incrementAndGet()
        state = AndroidDagPlaybackState.Paused
        onTimelineFrame(surfaceProducer.id(), renderedUs / 1_000_000.0, currentGeneration)

        val owner = audioOwnerForTimeline(spanIndex, renderedUs)
        if (owner == audioOwnerClipIndex) {
            seekAudioTo(renderedUs, resume = false)
        } else {
            ensureAudioOwner(owner, renderedUs, playing = false, site = "seek")
        }
        Log.i(TAG, "$LOG_PREFIX seek_rendered targetUs=$targetUs renderedUs=$renderedUs spanIndex=$spanIndex " +
            "overlap=${span.isOverlap} generation=$currentGeneration resume=$resumeAfterSeek token=$token")
        if (resumeAfterSeek) startPlaybackOnOrch()
        return null
    }

    // ── presentation dispatch ──────────────────────────────────────────────

    /** Presents [frames] for [span] and records a redraw closure for surface restore. */
    private fun presentFrames(span: Span, frames: AndroidTimelineGlesTransitionOverlapDecoder.Step.Frames): String? {
        val present: () -> String? = when (val segment = span.segment) {
            is AndroidTimelineExportSegment.Solo -> {
                val layout = layouts[span.fromClipIndex]
                ({ presentSoloFrame(fromSlot, layout) })
            }
            is AndroidTimelineExportSegment.Overlap -> {
                val fromLayout = layouts[span.fromClipIndex]
                val toLayout = layouts[span.toClipIndex]
                if (frames.from != null && frames.to != null) {
                    val progress = segment.transition.progressForOverlapFrame(activePairIndex, activeExpectedPairs)
                    val code = segment.transition.type.nativeCode
                    ({ presentTransitionPair(fromLayout, toLayout, progress, code) })
                } else if (frames.from != null) {
                    ({ presentSoloFrame(fromSlot, fromLayout) })
                } else {
                    ({ presentSoloFrame(toSlot, toLayout) })
                }
            }
        }
        val failure = present()
        if (failure == null) {
            lastPresent = present
            if (span.isOverlap && frames.from != null && frames.to != null) {
                activePairIndex = (activePairIndex + 1).coerceAtMost(activeExpectedPairs)
            }
        }
        return failure
    }

    // ── play / pause ───────────────────────────────────────────────────────

    override fun play(frameCount: Int?, onResult: (Map<String, Any?>) -> Unit) {
        val h = orchHandler
        if (h == null || disposed.get()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
            return
        }
        h.post {
            if (disposed.get() || spans.isEmpty()) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
                return@post
            }
            if (surfaceLostFlag.get() || state == AndroidDagPlaybackState.SurfaceLost) {
                onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=surface_lost"))
                return@post
            }
            if (state == AndroidDagPlaybackState.Failed) {
                onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=session_failed"))
                return@post
            }
            if (activeDecoder == null) {
                // At the end of the timeline (final EOS held): mirror the DAG session, which
                // completes again immediately rather than restarting.
                if (state == AndroidDagPlaybackState.Completed) {
                    onTimelineEOS(surfaceProducer.id())
                    onResult(mapOf("pass" to true, "state" to state.name, "raw" to "status=OK;completed=true;reason=already_at_end"))
                    return@post
                }
                val failure = activateSpanOnOrch(spanIndexForTimeline(positionUs), positionUs)
                if (failure != null) {
                    onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=$failure"))
                    return@post
                }
            }
            // A superseding play resolves a still-pending bounded play first (DAG contract).
            resolvePendingPlay(pass = false, reason = "superseded_by_play", stateName = AndroidDagPlaybackState.Playing.name)
            if (frameCount != null && frameCount > 0) {
                targetFrameCount = frameCount
                pendingPlayCallback = onResult
                framesPresentedThisRun = 0
                startPlaybackOnOrch()
                return@post
            }
            targetFrameCount = null
            startPlaybackOnOrch()
            onResult(mapOf(
                "pass" to true,
                "state" to state.name,
                "raw" to "status=OK;state=${state.name};positionUs=$positionUs;generationId=$currentGeneration",
            ))
        }
    }

    /** Must be called on the orchestration thread with an active decoder. */
    private fun startPlaybackOnOrch() {
        stopTick()
        isPlaying = true
        state = AndroidDagPlaybackState.Playing
        anchorTimelineUs = positionUs
        anchorWallNs = SystemClock.elapsedRealtimeNanos()
        val owner = audioOwnerForTimeline(activeSpanIndex, positionUs)
        if (owner != audioOwnerClipIndex) {
            ensureAudioOwner(owner, positionUs, playing = true, site = "play")
        } else {
            activeAudioRuntime?.play()
        }
        val token = sessionToken.get()
        val h = orchHandler ?: return
        val runnable = object : Runnable {
            override fun run() { renderTick(this, token) }
        }
        tickRunnable = runnable
        h.post(runnable)
        Log.i(TAG, "$LOG_PREFIX play_started positionUs=$positionUs spanIndex=$activeSpanIndex token=$token target=$targetFrameCount")
    }

    private fun stopTick() {
        val runnable = tickRunnable
        tickRunnable = null
        if (runnable != null) orchHandler?.removeCallbacks(runnable)
    }

    /** One paced step of the render loop; re-posts itself. Runs on the orchestration thread. */
    private fun renderTick(self: Runnable, token: Long) {
        if (tickRunnable !== self || disposed.get() || !isPlaying || sessionToken.get() != token || surfaceLostFlag.get()) {
            return
        }
        val decoder = activeDecoder
        if (decoder == null) {
            failPlayback("decoder_missing")
            return
        }
        val h = orchHandler ?: return
        val span = spans[activeSpanIndex]

        var frames = pendingStep
        if (frames == null) {
            when (val step = decoder.nextStep()) {
                is AndroidTimelineGlesTransitionOverlapDecoder.Step.Frames -> frames = step
                AndroidTimelineGlesTransitionOverlapDecoder.Step.Exhausted -> {
                    advanceSpanOnOrch(token)
                    if (tickRunnable === self && isPlaying) h.post(self)
                    return
                }
                AndroidTimelineGlesTransitionOverlapDecoder.Step.Cancelled -> return
                is AndroidTimelineGlesTransitionOverlapDecoder.Step.Failed -> {
                    failPlayback("decode_failed:${step.reason}")
                    return
                }
            }
            pendingStep = frames
        }

        // Pace against the monotonic anchor; never drop (the DAG pump's own policy).
        val ptsUs = timelinePtsForFrames(span, frames!!)
        val dueWallNs = anchorWallNs + (ptsUs - anchorTimelineUs) * 1_000L
        val nowNs = SystemClock.elapsedRealtimeNanos()
        if (nowNs + PRESENT_SLACK_NS < dueWallNs) {
            val delayMs = ((dueWallNs - nowNs) / 1_000_000L).coerceIn(1L, 1_000L)
            h.postDelayed(self, delayMs)
            return
        }

        val presentFailure = presentFrames(span, frames)
        pendingStep = null
        if (presentFailure != null) {
            if (surfaceLostFlag.get()) {
                // Flutter is tearing the Surface down under us (onSurfaceCleanup posted but not
                // yet run here). Stop quietly; the cleanup handler owns the SurfaceLost state.
                stopTick()
                isPlaying = false
                activeAudioRuntime?.pause()
                Log.i(TAG, "$LOG_PREFIX present_skipped_surface_lost reason=$presentFailure")
                return
            }
            failPlayback(presentFailure)
            return
        }
        positionUs = ptsUs
        onTimelineFrame(surfaceProducer.id(), ptsUs / 1_000_000.0, currentGeneration)

        // Original-audio cut-over at the overlap midpoint.
        val owner = audioOwnerForTimeline(activeSpanIndex, ptsUs)
        if (owner != audioOwnerClipIndex) ensureAudioOwner(owner, ptsUs, playing = true, site = "midpoint")

        framesPresentedThisRun++
        val target = targetFrameCount
        if (target != null && framesPresentedThisRun >= target) {
            stopTick()
            isPlaying = false
            activeAudioRuntime?.pause()
            state = AndroidDagPlaybackState.Paused
            resolvePendingPlay(pass = true, reason = "target_reached", stateName = state.name)
            return
        }
        h.post(self)
    }

    /** Must be called on the orchestration thread: moves to the next span or ends the timeline. */
    private fun advanceSpanOnOrch(token: Long) {
        val next = activeSpanIndex + 1
        if (next >= spans.size) {
            // Final EOS: hold the last frame, stop, pause audio, report.
            closeActiveDecoder()
            stopTick()
            isPlaying = false
            positionUs = (totalDurationUs - 1L).coerceAtLeast(0L)
            state = AndroidDagPlaybackState.Completed
            activeAudioRuntime?.pause()
            Log.i(TAG, "$LOG_PREFIX final_eos positionUs=$positionUs token=$token")
            resolvePendingPlay(pass = false, reason = "playback_end_before_target", stateName = state.name,
                passIfTargetReached = true)
            onTimelineEOS(surfaceProducer.id())
            return
        }
        val nextSpan = spans[next]
        val failure = activateSpanOnOrch(next, nextSpan.timelineStartUs)
        if (failure != null) {
            failPlayback("span_activation_failed:$failure")
            return
        }
        currentGeneration = publicGeneration.incrementAndGet()
        Log.i(TAG, "$LOG_PREFIX span_activated index=$next overlap=${nextSpan.isOverlap} " +
            "startUs=${nextSpan.timelineStartUs} generation=$currentGeneration")
    }

    private fun failPlayback(reason: String) {
        Log.w(TAG, "$LOG_PREFIX playback_failed reason=$reason positionUs=$positionUs spanIndex=$activeSpanIndex")
        stopTick()
        isPlaying = false
        state = AndroidDagPlaybackState.Failed
        activeAudioRuntime?.pause()
        closeActiveDecoder()
        resolvePendingPlay(pass = false, reason = reason, stateName = state.name)
    }

    /** Resolves a pending bounded-play callback exactly once. */
    private fun resolvePendingPlay(pass: Boolean, reason: String, stateName: String, passIfTargetReached: Boolean = false) {
        val callback = pendingPlayCallback ?: run {
            targetFrameCount = null
            return
        }
        val target = targetFrameCount
        val presented = framesPresentedThisRun
        pendingPlayCallback = null
        targetFrameCount = null
        val effectivePass = pass || (passIfTargetReached && target != null && presented >= target)
        val raw = if (effectivePass) {
            "status=OK;$reason;renderedFrames=$presented;targetFrameCount=$target"
        } else {
            "status=FAIL;reason=$reason;renderedFrames=$presented;targetFrameCount=$target"
        }
        callback(mapOf(
            "pass" to effectivePass,
            "state" to stateName,
            "renderedFrames" to presented,
            "targetFrameCount" to target,
            "lastPtsUs" to positionUs,
            "raw" to raw,
        ))
    }

    override fun pause(onResult: (Map<String, Any?>) -> Unit) {
        val h = orchHandler
        if (h == null || disposed.get()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
            return
        }
        h.post {
            if (disposed.get()) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
                return@post
            }
            stopTick()
            isPlaying = false
            activeAudioRuntime?.pause()
            if (state != AndroidDagPlaybackState.Failed && state != AndroidDagPlaybackState.SurfaceLost &&
                state != AndroidDagPlaybackState.Completed
            ) {
                state = AndroidDagPlaybackState.Paused
            }
            resolvePendingPlay(pass = true, reason = "paused", stateName = state.name)
            onResult(mapOf(
                "pass" to true,
                "state" to state.name,
                "raw" to "status=OK;state=${state.name};positionUs=$positionUs",
            ))
        }
    }

    // ── seek ───────────────────────────────────────────────────────────────

    override fun seek(targetGlobalPtsUs: Long, resumeAfterSeek: Boolean, onResult: (Map<String, Any?>) -> Unit) {
        val h = orchHandler
        if (h == null || disposed.get()) {
            onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
            return
        }
        h.post {
            if (disposed.get() || spans.isEmpty()) {
                onResult(mapOf("pass" to false, "raw" to "status=FAIL;reason=session_disposed_or_uninitialized"))
                return@post
            }
            if (state == AndroidDagPlaybackState.Failed) {
                onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=session_failed"))
                return@post
            }
            val failure = seekOnOrch(targetGlobalPtsUs, resumeAfterSeek)
            if (failure != null) {
                if (failure != "surface_lost") {
                    // A failed seek leaves nothing renderable; fail closed like the DAG session.
                    failPlayback(failure)
                }
                onResult(mapOf("pass" to false, "state" to state.name, "raw" to "status=FAIL;reason=$failure"))
                return@post
            }
            onResult(mapOf(
                "pass" to true,
                "state" to state.name,
                "seekTargetUs" to targetGlobalPtsUs,
                "seekRenderedPtsUs" to positionUs,
                "generationId" to currentGeneration,
                "raw" to "status=OK;state=${state.name};seekTargetUs=$targetGlobalPtsUs;" +
                    "seekRenderedPtsUs=$positionUs;generationId=$currentGeneration",
            ))
        }
    }

    // ── Surface loss / restore ─────────────────────────────────────────────

    private fun handleSurfaceCleanup() {
        surfaceLostFlag.set(true)
        val h = orchHandler ?: return
        h.post {
            if (disposed.get()) return@post
            sessionToken.incrementAndGet()
            stopTick()
            isPlaying = false
            activeAudioRuntime?.pause()
            resolvePendingPlay(pass = false, reason = "surface_cleanup", stateName = AndroidDagPlaybackState.SurfaceLost.name)
            destroyWindowSurfaceOnOrch()
            if (state != AndroidDagPlaybackState.Failed) state = AndroidDagPlaybackState.SurfaceLost
            Log.i(TAG, "$LOG_PREFIX surface_lost positionUs=$positionUs")
        }
    }

    private fun handleSurfaceAvailable() {
        val h = orchHandler ?: return
        h.post {
            if (disposed.get() || state == AndroidDagPlaybackState.Failed) return@post
            if (!surfaceLostFlag.get() && state != AndroidDagPlaybackState.SurfaceLost) return@post
            surfaceLostFlag.set(false)
            sessionToken.incrementAndGet()
            val failure = createWindowSurfaceOnOrch()
            if (failure != null) {
                Log.w(TAG, "$LOG_PREFIX surface_restore_failed reason=$failure")
                surfaceLostFlag.set(true)
                state = AndroidDagPlaybackState.SurfaceLost
                return@post
            }
            state = AndroidDagPlaybackState.Paused
            val redraw = lastPresent
            val redrawFailure = redraw?.invoke()
            Log.i(TAG, "$LOG_PREFIX surface_restored positionUs=$positionUs redraw=${redraw != null} " +
                "redrawFailure=${redrawFailure ?: "none"}")
            // Never auto-resume: the caller must call play(), exactly as the DAG session.
        }
    }

    // ── gains ──────────────────────────────────────────────────────────────

    override fun setOriginalTrackGain(clipId: String, gain: Float) {
        val clamped = gain.coerceIn(0.0f, 1.0f)
        orchHandler?.post {
            originalGainByClipId[clipId] = clamped
            val owner = layouts.getOrNull(audioOwnerClipIndex)
            if (owner != null && owner.spec.clipId == clipId) activeAudioRuntime?.setVolumeGain(clamped)
        }
    }

    override fun setAllOriginalTracksGain(gain: Float) {
        val clamped = gain.coerceIn(0.0f, 1.0f)
        orchHandler?.post {
            for (layout in layouts) originalGainByClipId[layout.spec.clipId] = clamped
            activeAudioRuntime?.setVolumeGain(clamped)
        }
    }

    // ── dispose ────────────────────────────────────────────────────────────

    override fun dispose(onResult: ((Map<String, Any?>) -> Unit)?) {
        if (!disposed.compareAndSet(false, true)) {
            onResult?.invoke(mapOf("pass" to true, "raw" to "status=OK;already_disposed"))
            return
        }
        sessionToken.incrementAndGet()
        val h = orchHandler
        if (h == null) {
            onResult?.invoke(mapOf("pass" to true, "raw" to "status=OK;disposed=true"))
            return
        }
        val posted = h.post {
            stopTick()
            isPlaying = false
            resolvePendingPlay(pass = false, reason = "session_disposed", stateName = AndroidDagPlaybackState.Disposed.name)
            releaseAllOnce()
            state = AndroidDagPlaybackState.Disposed
            onResult?.invoke(mapOf("pass" to true, "raw" to "status=OK;disposed=true"))
            val thread = orchThread
            orchThread = null
            orchHandler = null
            try { thread?.quitSafely() } catch (_: Throwable) {}
        }
        if (!posted) {
            // The orchestration looper already quit (prepare failure path); resources were
            // released there.
            onResult?.invoke(mapOf("pass" to true, "raw" to "status=OK;disposed=true;looper_already_quit"))
        }
    }

    /**
     * Must be called on the orchestration thread. Releases decoders, audio, GL objects, decode
     * slots, EGL surfaces/context/display, the native bridge and the surface callback exactly
     * once (prepare failure, playback failure teardown via dispose, or dispose).
     */
    private fun releaseAllOnce() {
        if (!resourcesReleased.compareAndSet(false, true)) return
        closeActiveDecoder()
        releaseAudioRuntimeBlocking()
        lastPresent = null
        try { surfaceProducer.setCallback(null) } catch (_: Throwable) {}
        lifecycleAdapter = null

        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            try {
                EGL14.eglMakeCurrent(eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext)
                sharpProgram?.let { GLES20.glDeleteProgram(it.program) }
                blurProgram?.let { GLES20.glDeleteProgram(it.program) }
                if (fromResolveFboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(fromResolveFboId), 0)
                if (toResolveFboId != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(toResolveFboId), 0)
                if (fromResolveTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(fromResolveTextureId), 0)
                if (toResolveTextureId != 0) GLES20.glDeleteTextures(1, intArrayOf(toResolveTextureId), 0)
                if (slotsReady) {
                    fromSlot.release()
                    toSlot.release()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX gl_release_error", t)
            }
        }
        sharpProgram = null
        blurProgram = null
        fromResolveFboId = 0
        toResolveFboId = 0
        fromResolveTextureId = 0
        toResolveTextureId = 0
        slotsReady = false

        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try { EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT) } catch (_: Throwable) {}
            if (eglWindowSurface != EGL14.EGL_NO_SURFACE) {
                try { EGL14.eglDestroySurface(eglDisplay, eglWindowSurface) } catch (_: Throwable) {}
            }
            if (eglPbufferSurface != EGL14.EGL_NO_SURFACE) {
                try { EGL14.eglDestroySurface(eglDisplay, eglPbufferSurface) } catch (_: Throwable) {}
            }
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                try { EGL14.eglDestroyContext(eglDisplay, eglContext) } catch (_: Throwable) {}
            }
            try { EGL14.eglTerminate(eglDisplay) } catch (_: Throwable) {}
        }
        eglWindowSurface = EGL14.EGL_NO_SURFACE
        eglPbufferSurface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglConfig = null
        flutterSurface = null
        nativeBridge = null
        Log.i(TAG, "$LOG_PREFIX released textureId=${surfaceProducer.id()}")
    }
}
