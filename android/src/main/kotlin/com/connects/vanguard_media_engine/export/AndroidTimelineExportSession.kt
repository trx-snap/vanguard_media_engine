package com.connects.vanguard_media_engine.export

import android.content.Context
import android.media.ExifInterface
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max

// ── AndroidTimelineExportSession (Export Unit C) ──────────────────────────────
//
// One-shot native handler for a single `exportTimeline` MethodChannel call.
// Owns argument/draft parsing, Unit C guardrail validation, pass-1 video
// encode -- via AndroidTimelineVulkanVideoEncoder when
// AndroidExportRenderBackendSelector resolves its narrow Vulkan safe scope,
// falling back mid-export to AndroidTimelineVideoEncoder (GLES) if that
// Vulkan attempt fails before pass-2/finalization and cancellation has not
// been requested, otherwise using AndroidTimelineVideoEncoder directly --
// and pass-2 audio mux/mixdown
// (via the existing Unit B audio foundation: AndroidAudioTrackSpec,
// AndroidAudioDirectCopyValidator, AndroidAudioMixdownEngine, AndroidAacEncoder,
// AndroidAudioRemuxer). Runs entirely on a background thread; never touches a
// MethodChannel or Flutter main-thread APIs directly -- results are delivered
// via [onSuccess]/[onError] callbacks, which AndroidEditorExportCoordinator
// posts to the main thread exactly once. Optional [onProgress] progress
// events (Phase 5-Unit T) are delivered the same way -- this class never
// touches a MethodChannel directly, even for progress.
//
// Scope (minimal hard-cut, sequential, local-video export -- Unit C, extended
// by Unit G with rotation metadata + canvas scaling normalization, and by
// Phase 10 with per-clip colorMatrix parity):
//   - video-only clips, speed == 1.0, no canvas
//     contentMode other than "fit", no per-clip crop/freeze/
//     time-remap/dual-camera/transformTrack.
//   - P5-CLIP-STATIC-TRANSFORM-EXPORT-A: a narrow static `clip.transform`
//     subset is accepted for VIDEO clips only: finite uniform scale
//     (scaleX ≈ scaleY, both > 0, at most MAX_CLIP_TRANSFORM_SCALE), finite
//     translationX/translationY (draft-canvas pixels, converted here into
//     requested-output pixels), rotation ≈ 0, opacity absent/≈ 1.0,
//     anchorX/anchorY absent/≈ 0.5. It is the shape the ConnectsApp
//     Universal Editor emits for TikTok-style crop/aspect/fill/pan framing.
//     Non-uniform scale, any rotation, partial opacity, off-center anchors,
//     a transform on a still-image or reversed clip, a requested output
//     whose aspect ratio differs from the draft canvas, or a transform whose
//     placement cannot be represented as an in-bounds crop (nothing visible,
//     empty/odd crop -- see AndroidTimelineClipStaticTransformGeometry) all
//     fail closed with UNSUPPORTED_EXPORT_FEATURE and a precise reason
//     before pass-1. `transformTrack` and `cropRect` stay unsupported.
//     Supported transforms keep Vulkan-first selection
//     (AndroidTimelineVulkanVideoEncoder renders them as a source crop +
//     in-bounds destination rect); the hard-cut GLES fallback
//     (AndroidTimelineVideoEncoder) applies the same placement in vertex
//     space, while the GLES transition route and reversed-clip
//     normalization are excluded by AndroidExportRenderBackendSelector.
//   - P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: a narrow reversed-video export
//     route. A hard-cut clip (forward or reversed) with isReversed=true is
//     accepted when it is a local video clip with zero rotation metadata;
//     it is rendered exclusively via AndroidTimelineVideoEncoder's GLES
//     fallback (renderReversedClipIntoEncoder) -- reversed clips never
//     route through Vulkan (AndroidExportRenderBackendSelector /
//     AndroidTimelineVulkanVideoEncoder both fail closed for them);
//     isReversed=true on a non-video clip fails closed with INVALID_ARG.
//     P5-REVERSE-COMPOSITION-NORMALIZATION-A: a reversed clip alongside a
//     non-hard-cut transition and/or clip-level Beauty V2 is no longer
//     rejected up front. Backend selection still runs on the original
//     (reversed) clips; when it commits GLES for such a scope
//     (ExportRenderScope.glesReverseNormalizationRequired), a pass-0
//     (AndroidTimelineReverseNormalizationPrepass) first re-encodes each
//     reversed clip into an owned forward, video-only temp via the same
//     GLES reverse renderer, and pass-1 then renders the replacement
//     forward clips (isReversed=false, trim [0, measured temp duration],
//     Beauty preserved) through the normal GLES transition/Beauty routes.
//     Those temps are owned per-export cache files deleted by the same
//     owned-temp cleanup as every other temp. Progress reserves
//     [0.0, PASS0_PROGRESS_WEIGHT] for pass-0 in that case and pass-1
//     sample progress is scaled from that floor. A reversed clip whose
//     shape is not normalizable (rotation, colorMatrix, non-video, invalid
//     dimensions) still fails closed with UNSUPPORTED_EXPORT_FEATURE at
//     backend selection. Hard-cut reversed-only and reversed+overlay-only
//     scopes never run pass-0.
//     P5-GLES-EXPORT-REVERSED-CLIP-OVERLAYS: a reversed clip alongside
//     timeline overlays is a supported production shape -- see
//     AndroidExportRenderBackendSelector.glesOverlayEligible. This route
//     never reads AndroidReverseSidecarCoordinator/Transcoder output -- those
//     sidecars remain preview/playback-only.
//   - P5-REVERSE-AUDIO-SIDECAR-EXPORT: a reversed hard-cut timeline carrying
//     audioSidecar tracks is admitted -- not blanket-rejected -- when every
//     parsed track's timing is valid on the reversed timeline's total
//     duration (AndroidTimelineAudioOverlapAdmission, reusing the same
//     admission gate as P5-TRANSITION-AUDIO-SIDECAR-EXPORT). Reversing a
//     clip's playback direction does not change its duration, so this
//     duration is simply the sum of each parsed clip's trimEnd - trimStart;
//     this gate never adjusts or clamps the already-computed wire values.
//     Admitted tracks route through the existing pass-2 mux/mixdown path
//     (AndroidTimelineAudioPass2Muxer) exactly like a forward hard-cut
//     timeline's audio tracks do.
//   - P5-COMPOSITOR-TRANS: compositor-owned clip overlap transitions
//     (AndroidTimelineTransitionDescriptor: dissolve/crossfade, slide*,
//     wipe*) between adjacent video clips, rendered by
//     AndroidTimelineVulkanVideoEncoder (Vulkan, preferred/default) or, for
//     the narrow shape AndroidExportRenderBackendSelector.ExportRenderScope
//     .glesTransitionEligible admits (P5-GLES-EXPORT-TRANSITION-PRODUCTION-
//     ROUTE-A: video-only clips, no non-normalizable reversed clip (see
//     P5-REVERSE-COMPOSITION-NORMALIZATION-A above), no clip-level Beauty V2,
//     no overlays, zero rotation metadata, crossfade/dissolve only),
//     AndroidTimelineGlesTransitionVideoEncoder. When neither backend can
//     take the scope (Vulkan unselectable and the scope is not GLES-
//     transition-eligible) the export fails closed with
//     UNSUPPORTED_EXPORT_FEATURE before pass-1, and a failed Vulkan pass-1
//     never falls back to GLES hard cuts. `fade` and any other unsupported
//     type fail closed at parse time; a non-crossfade non-hard-cut type on
//     an otherwise GLES-transition-eligible scope fails closed at GLES
//     render time instead (this route's own crossfade-only implementation).
//     A top-level `debugForceRenderBackend == "gles"` export argument is a
//     scoped, test-only force seam that routes an eligible transition scope
//     through GLES even when Vulkan would otherwise be selected first --
//     see AndroidExportRenderBackendSelector.select's
//     `debugForceGlesTransitionExport` parameter.
//   - P5-TRANSITION-AUDIO-SIDECAR-EXPORT: a transition timeline carrying
//     audioSidecar tracks is admitted -- not blanket-rejected -- when every
//     parsed track's timing is valid on the overlap-adjusted output
//     timeline (AndroidTimelineAudioOverlapAdmission). Dart is the single
//     source of truth for that timing (VGEditorDraft
//     .sequentialWithTransitions / flattenOriginalClipAudio); this gate
//     only validates the already-computed wire values, it never adjusts or
//     clamps them. Admitted tracks route through the existing pass-2
//     mux/mixdown path (AndroidTimelineAudioPass2Muxer) exactly like a
//     hard-cut timeline's audio tracks do.
//   - P5-OVERLAYS-TRANS Route-A N9, extended by P5-OVERLAYS-TRANSITION-COMP-N3
//     and P5-OVERLAYS-BEAUTY-SOLO: static sticker overlays
//     (AndroidTimelineOverlayDescriptor, up to 128 per export) composited by
//     AndroidTimelineVulkanVideoEncoder via the native
//     renderAndroidTimelineVulkanExportFrameCroppedWithOverlays seam on solo
//     frames, and via renderAndroidTimelineVulkanExportTransitionFrameWithOverlays
//     on transition overlap frames when the timeline also carries a
//     compositor transition. Overlay geometry is draft-canvas pixel space,
//     so overlays require the requested output to match the draft canvas
//     exactly; more than 128 overlays always fail closed with
//     UNSUPPORTED_EXPORT_FEATURE before pass-1 -- overlays have no GLES
//     fallback either way. Overlays alongside clip-level Beauty V2 are a
//     supported production shape on both solo and transition-overlap
//     frames: a solo frame carrying an active overlay on a beauty clip
//     renders through the combined
//     renderAndroidTimelineVulkanExportFrameCroppedWithOverlaysAndBeauty
//     seam, and a transition-overlap frame renders through
//     renderAndroidTimelineVulkanExportTransitionFrameWithOverlays's own
//     per-layer Beauty V2 params.
//   - Per-clip colorMatrix is accepted and
//     applied for both decoded video frames and still-image frames by
//     whichever backend renders the clip (Vulkan-native color-matrix push
//     constants for supported video clips, or the GLES program's colorMatrix
//     uniforms -- see AndroidExportRenderBackendSelector). Vulkan remains the
//     preferred/default backend for supported video clips within its narrow
//     safe scope; still-image clips fall outside that Vulkan scope and always
//     render via the GLES fallback (AndroidTimelineVideoEncoder), which
//     applies colorMatrix in its 2D still-image shader path.
//   - clip rotation metadata (0/90/180/270 after normalization) and decoded
//     clip dimensions that differ from each other or from the requested
//     output geometry are supported: each clip is centered and
//     aspect-preserving "fit"-scaled into the fixed output surface over a
//     black background (AndroidTimelineVideoEncoder).
//   - Anything outside this scope is rejected with UNSUPPORTED_EXPORT_FEATURE
//     rather than silently ignored -- a minimal exporter that ignores a
//     feature would silently produce wrong output, which this Unit must not do.
class AndroidTimelineExportSession(
    private val context: Context,
    private val reverseSidecarPathProvider: ((clipId: String) -> String?)? = null,
) {

    @Volatile private var cancelRequested = false
    @Volatile private var activeEncoder: AndroidTimelineVideoPassEncoder? = null

    /// Owned-temp cleanup for the in-flight [run], installed once its temp
    /// paths are known, so a Throwable escaping [run] (caught in [start])
    /// still deletes every owned temp -- including pass-0 normalized temps
    /// -- instead of leaking them in the cache directory.
    @Volatile private var ownedTempCleanup: (() -> Unit)? = null

    /** Requests cancellation of the in-flight export. Thread-safe, non-blocking. */
    fun requestCancel() {
        cancelRequested = true
        activeEncoder?.cancel()
    }

    /// [onProgress], when non-null, receives overall export progress in
    /// [0.0, 1.0]: pass-1 (video encode) sample progress is mapped into
    /// [0.0, PASS1_PROGRESS_SAMPLE_MAX] (strictly below 0.85) via the
    /// encoder's own sample-ratio progress -- or, when pass-0 reversed-clip
    /// normalization runs (P5-REVERSE-COMPOSITION-NORMALIZATION-A), pass-0
    /// is mapped into [0.0, PASS0_PROGRESS_WEIGHT] and pass-1 into
    /// [PASS0_PROGRESS_WEIGHT, PASS1_PROGRESS_SAMPLE_MAX], all strictly
    /// monotonic; the exact 0.85 checkpoint is
    /// emitted exactly once, immediately after pass-1 succeeds and the
    /// following cancel check passes; 0.98 is emitted immediately after
    /// pass-2 succeeds and the following cancel check passes. This session
    /// never emits 1.0 -- that terminal value is owned by
    /// AndroidEditorExportCoordinator. No progress is emitted after any
    /// cancel/error check fails.
    fun start(
        args: Map<*, *>?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (code: String, message: String?) -> Unit,
        onProgress: ((Double) -> Unit)? = null,
    ) {
        Thread {
            try {
                run(args, onSuccess, onError, onProgress)
            } catch (t: Throwable) {
                Log.e(TAG, "unhandled exception in export session: $t", t)
                try { ownedTempCleanup?.invoke() } catch (_: Throwable) {}
                onError("EXPORT_FAILED", t.message ?: t.javaClass.simpleName)
            } finally {
                ownedTempCleanup = null
            }
        }.start()
    }

    // ─────────────────────────────────────────────────────────────────────────

    private data class ParsedClip(
        val id: String?,
        val sourcePath: String,
        val trimStart: Double,
        val trimEnd: Double,
        val mediaKind: String,
        val speed: Double = 1.0,
        val colorMatrix: FloatArray? = null,
        val beautyIntensity: Double? = null,
        // P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: true when this clip must be
        // rendered walking its trim window backwards. See the admission gate
        // and guardrails around isReversed below for the narrow scope this
        // slice accepts.
        val isReversed: Boolean = false,
        // P5-CLIP-STATIC-TRANSFORM-EXPORT-A: accepted static transform with
        // translation still in DRAFT-CANVAS pixels (converted to output
        // pixels when the ClipInput is built). Null = no transform.
        val canvasTransform: AndroidTimelineVideoEncoder.StaticClipTransform? = null,
    )

    private data class ClipContext(
        val sourcePath: String,
        val trimStartSeconds: Double,
        val trimEndSeconds: Double,
        val decodedWidth: Int,
        val decodedHeight: Int,
        val rotationDegrees: Int,
        val mediaKind: String,
        val speed: Double = 1.0,
        val exifOrientation: Int = ExifInterface.ORIENTATION_NORMAL,
        val colorMatrix: FloatArray? = null,
        val beautyIntensity: Double? = null,
        val isReversed: Boolean = false,
        val canvasTransform: AndroidTimelineVideoEncoder.StaticClipTransform? = null,
    )

    /// P5-CLIP-STATIC-TRANSFORM-EXPORT-A: outcome of parsing one clip's
    /// optional `transform` wire map -- see [parseStaticClipTransform].
    private sealed class ClipTransformParse {
        object Absent : ClipTransformParse()
        data class Present(val transform: AndroidTimelineVideoEncoder.StaticClipTransform) : ClipTransformParse()
        data class Failure(val code: String, val message: String) : ClipTransformParse()
    }

    /// Parses the optional `clip.transform` map (VGClipTransformDescriptor
    /// wire shape: scaleX, scaleY, translationX, translationY, rotation,
    /// opacity, anchorX, anchorY -- every key optional with identity
    /// defaults) into the narrow static subset this route renders. A
    /// malformed/non-finite value is INVALID_ARG; a well-formed value
    /// outside the subset (non-uniform scale, oversized scale, rotation,
    /// partial opacity, off-center anchor) is UNSUPPORTED_EXPORT_FEATURE
    /// with the exact offending field. An effectively-identity transform
    /// parses as [ClipTransformParse.Absent]. Translation is returned in
    /// draft-canvas pixels, exactly as received.
    private fun parseStaticClipTransform(raw: Any?): ClipTransformParse {
        if (raw == null) return ClipTransformParse.Absent
        if (raw !is Map<*, *>) {
            return ClipTransformParse.Failure("INVALID_ARG", "exportTimeline: clip.transform must be a map")
        }
        val values = HashMap<String, Double>()
        for ((key, default) in CLIP_TRANSFORM_DEFAULTS) {
            val entry = raw[key]
            if (entry == null) {
                values[key] = default
                continue
            }
            val number = entry as? Number
                ?: return ClipTransformParse.Failure("INVALID_ARG", "exportTimeline: clip.transform.$key must be a number")
            val value = number.toDouble()
            if (!value.isFinite()) {
                return ClipTransformParse.Failure("INVALID_ARG", "exportTimeline: clip.transform.$key must be finite")
            }
            values[key] = value
        }
        val scaleX = values.getValue("scaleX")
        val scaleY = values.getValue("scaleY")
        val translationX = values.getValue("translationX")
        val translationY = values.getValue("translationY")
        val rotation = values.getValue("rotation")
        val opacity = values.getValue("opacity")
        val anchorX = values.getValue("anchorX")
        val anchorY = values.getValue("anchorY")

        if (scaleX <= 0.0 || scaleY <= 0.0) {
            return ClipTransformParse.Failure(
                "INVALID_ARG",
                "exportTimeline: clip.transform scaleX/scaleY must be > 0 (scaleX=$scaleX, scaleY=$scaleY)",
            )
        }
        if (abs(scaleX - scaleY) > CLIP_TRANSFORM_UNIFORM_SCALE_EPSILON * max(scaleX, scaleY)) {
            return ClipTransformParse.Failure(
                "UNSUPPORTED_EXPORT_FEATURE",
                "exportTimeline: clip.transform non-uniform scale is not supported " +
                    "(scaleX=$scaleX, scaleY=$scaleY)",
            )
        }
        val scale = (scaleX + scaleY) / 2.0
        if (scale > MAX_CLIP_TRANSFORM_SCALE) {
            return ClipTransformParse.Failure(
                "UNSUPPORTED_EXPORT_FEATURE",
                "exportTimeline: clip.transform scale $scale exceeds the supported maximum of $MAX_CLIP_TRANSFORM_SCALE",
            )
        }
        if (abs(rotation) > CLIP_TRANSFORM_ROTATION_EPSILON_RADIANS) {
            return ClipTransformParse.Failure(
                "UNSUPPORTED_EXPORT_FEATURE",
                "exportTimeline: clip.transform.rotation $rotation is not supported (only 0)",
            )
        }
        if (abs(opacity - 1.0) > CLIP_TRANSFORM_UNIT_EPSILON) {
            return ClipTransformParse.Failure(
                "UNSUPPORTED_EXPORT_FEATURE",
                "exportTimeline: clip.transform.opacity $opacity is not supported (only 1.0)",
            )
        }
        if (abs(anchorX - 0.5) > CLIP_TRANSFORM_UNIT_EPSILON || abs(anchorY - 0.5) > CLIP_TRANSFORM_UNIT_EPSILON) {
            return ClipTransformParse.Failure(
                "UNSUPPORTED_EXPORT_FEATURE",
                "exportTimeline: clip.transform anchor ($anchorX, $anchorY) is not supported (only 0.5, 0.5)",
            )
        }
        val isIdentity = abs(scale - 1.0) <= CLIP_TRANSFORM_IDENTITY_EPSILON &&
            abs(translationX) <= CLIP_TRANSFORM_IDENTITY_EPSILON &&
            abs(translationY) <= CLIP_TRANSFORM_IDENTITY_EPSILON
        if (isIdentity) return ClipTransformParse.Absent
        return ClipTransformParse.Present(
            AndroidTimelineVideoEncoder.StaticClipTransform(
                scale = scale,
                translationX = translationX,
                translationY = translationY,
            ),
        )
    }

    private fun run(
        args: Map<*, *>?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String?) -> Unit,
        onProgress: ((Double) -> Unit)? = null,
    ) {
        // ── 1. Top-level args / draft parsing ───────────────────────────────
        if (args == null) {
            onError("INVALID_ARG", "exportTimeline: arguments required")
            return
        }
        val draftMap = args["draft"] as? Map<*, *>
        if (draftMap == null) {
            onError("INVALID_ARG", "exportTimeline: draft required")
            return
        }

        // P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A / P5-GLES-EXPORT-
        // BEAUTY-PRODUCTION-ROUTE-A: a scoped, test-only force seam for
        // physical proof of the narrow GLES transition and GLES Beauty V2
        // production routes. Parsed once here; routed into exactly one of
        // `debugForceGlesTransitionExport` (non-hard-cut transition scopes)
        // or `debugForceGlesBeautyExport` (hard-cut Beauty scopes) further
        // below, once `transitions` and `hasBeautyClip` are known -- see the
        // backend-selection call below. Ignored (has no effect on any other
        // request shape) unless the scope backend selection resolves
        // against is also eligible for the corresponding narrow route -- see
        // AndroidExportRenderBackendSelector.select's own doc for the exact
        // fail-closed contract when this is set but the scope is not
        // eligible.
        val debugForceGlesRequested =
            (args["debugForceRenderBackend"] as? String)?.trim()?.equals("gles", ignoreCase = true) == true

        val rawClips = draftMap["clips"] as? List<*>
        if (rawClips == null || rawClips.isEmpty()) {
            onError("INVALID_ARG", "exportTimeline: draft.clips must be a non-empty list")
            return
        }
        val clipMaps = rawClips.filterIsInstance<Map<*, *>>()
        if (clipMaps.size != rawClips.size) {
            onError("INVALID_ARG", "exportTimeline: draft.clips contains malformed entries")
            return
        }

        // P5-COMPOSITOR-TRANS: transitions are parsed/validated against the
        // parsed clip order below (step 2b), once clip ids and trim windows
        // are known.
        val rawTransitions = draftMap["transitions"] as? List<*> ?: emptyList<Any?>()

        // P5-TRANSITION-AUDIO-SIDECAR-EXPORT: audioSidecar tracks are parsed
        // once, here, so the reversed-clip guardrail below, the transition
        // audio admission gate (step 2b), and pass-2 mux/mixdown (step 6)
        // all share one parsed AndroidAudioTrackSpec list instead of
        // re-parsing the raw wire list repeatedly.
        val rawSidecarTracks = ((draftMap["audioSidecar"] as? Map<*, *>)?.get("tracks") as? List<*>)
            ?: emptyList<Any?>()
        val (audioSpecs, _) = AndroidAudioTrackSpec.parseList(rawSidecarTracks)

        // P5-OVERLAYS-TRANS Route-A N9: overlay preflight parser and admission
        // gate. Static sticker overlays are validated here; feature-shape
        // gates that depend on request/canvas geometry, transitions, or
        // Beauty V2 run further below once that context is known (see the
        // "owned temps from here on" section and the post-clipInputs gates).
        val rawOverlays = draftMap["overlays"] as? List<*> ?: emptyList<Any?>()
        val overlays: List<AndroidTimelineOverlayDescriptor> =
            when (val parse = AndroidTimelineOverlayDescriptor.parseList(rawOverlays)) {
                is AndroidTimelineOverlayDescriptor.ParseResult.Failure -> {
                    onError(parse.code, parse.message)
                    return
                }
                is AndroidTimelineOverlayDescriptor.ParseResult.Success -> parse.overlays
            }

        val rawCanvas = draftMap["canvas"] as? Map<*, *>
        if (rawCanvas != null) {
            val contentMode = rawCanvas["contentMode"] as? String ?: "fit"
            if (contentMode != "fit") {
                onError(
                    "UNSUPPORTED_EXPORT_FEATURE",
                    "exportTimeline: canvas contentMode '$contentMode' is not supported",
                )
                return
            }
        }

        val draftCanvasWidth = (draftMap["canvasWidth"] as? Number)?.toInt()
        val draftCanvasHeight = (draftMap["canvasHeight"] as? Number)?.toInt()
        val draftFps = (draftMap["fps"] as? Number)?.toInt()
        if (draftCanvasWidth == null || draftCanvasWidth <= 0 ||
            draftCanvasHeight == null || draftCanvasHeight <= 0 ||
            draftFps == null || draftFps <= 0
        ) {
            onError("INVALID_ARG", "exportTimeline: draft.canvasWidth/canvasHeight/fps must be positive")
            return
        }

        // ── 2. Per-clip structural + feature guardrails ─────────────────────
        val parsedClips = mutableListOf<ParsedClip>()
        for (map in clipMaps) {
            val sourcePath = map["sourcePath"] as? String
            if (sourcePath.isNullOrEmpty()) {
                onError("INVALID_ARG", "exportTimeline: clip.sourcePath required")
                return
            }
            val mediaKind = map["mediaKind"] as? String ?: "video"
            if (mediaKind != "video" && mediaKind != "image") {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: clip.mediaKind '$mediaKind' is not supported")
                return
            }
            val fitMode = map["fitMode"] as? String
            if (fitMode != null && fitMode != "fit") {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: clip.fitMode '$fitMode' is not supported")
                return
            }
            val trimStart = (map["trimStartSeconds"] as? Number)?.toDouble()
            val trimEnd = (map["trimEndSeconds"] as? Number)?.toDouble()
            if (trimStart == null || trimEnd == null) {
                onError("INVALID_ARG", "exportTimeline: clip trimStartSeconds/trimEndSeconds required")
                return
            }
            if (trimEnd <= trimStart) {
                onError("INVALID_ARG", "exportTimeline: clip trimEndSeconds must be > trimStartSeconds")
                return
            }
            val speed = (map["speed"] as? Number)?.toDouble() ?: 1.0
            if (!speed.isFinite() || speed <= 0.0) {
                onError("INVALID_ARG", "exportTimeline: clip.speed must be finite and > 0.0 (got $speed)")
                return
            }
            // P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: reversed clips are accepted
            // for local video clips only -- a reversed clip on a still image
            // has no defined semantics here and fails closed with a
            // malformed-argument code rather than UNSUPPORTED_EXPORT_FEATURE.
            // The remaining reversed-clip guardrails (transitions/overlays/
            // Beauty V2/rotation, plus the P5-REVERSE-AUDIO-SIDECAR-EXPORT
            // audioSidecar timing admission) depend on context not yet
            // known at this point in per-clip parsing and are enforced
            // further below, once every clip has been parsed (and, for
            // rotation, probed).
            var isReversed = map["isReversed"] as? Boolean ?: false
            if (isReversed && mediaKind != "video") {
                onError(
                    "INVALID_ARG",
                    "exportTimeline: clip.isReversed is only supported for video clips " +
                        "(mediaKind '$mediaKind' with isReversed=true)",
                )
                return
            }
            var effectiveSourcePath = sourcePath
            var effectiveTrimStart = trimStart
            var effectiveTrimEnd = trimEnd
            val clipId = (map["id"] as? String)?.trim()
            if (isReversed && clipId != null) {
                val sidecarPath = reverseSidecarPathProvider?.invoke(clipId)
                if (sidecarPath != null && AndroidUriDataSourceHelper.isReadable(sidecarPath, context)) {
                    effectiveSourcePath = sidecarPath
                    isReversed = false
                    effectiveTrimStart = 0.0
                    effectiveTrimEnd = trimEnd - trimStart
                }
            }
            for (unsupportedKey in UNSUPPORTED_CLIP_KEYS) {
                if (map[unsupportedKey] != null) {
                    onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: clip.$unsupportedKey is not supported")
                    return
                }
            }
            // P5-CLIP-STATIC-TRANSFORM-EXPORT-A: `transform` is parsed into
            // the narrow static subset (see [parseStaticClipTransform]) and
            // admitted for forward VIDEO clips only -- the still-image and
            // reversed render routes never apply it, so it fails closed for
            // them rather than exporting unframed content. Placement
            // feasibility against the probed geometry is validated further
            // below, once decoded dimensions/rotation and the requested
            // output are known.
            val canvasTransform: AndroidTimelineVideoEncoder.StaticClipTransform? =
                when (val parse = parseStaticClipTransform(map["transform"])) {
                    is ClipTransformParse.Failure -> {
                        onError(parse.code, parse.message)
                        return
                    }
                    ClipTransformParse.Absent -> null
                    is ClipTransformParse.Present -> parse.transform
                }
            if (canvasTransform != null && mediaKind != "video") {
                onError(
                    "UNSUPPORTED_EXPORT_FEATURE",
                    "exportTimeline: clip.transform is only supported for video clips (mediaKind '$mediaKind')",
                )
                return
            }
            if (canvasTransform != null && isReversed) {
                onError(
                    "UNSUPPORTED_EXPORT_FEATURE",
                    "exportTimeline: clip.transform on a reversed clip is not supported",
                )
                return
            }
            // Phase 10: colorMatrix is accepted (not in UNSUPPORTED_CLIP_KEYS).
            // A missing/null key means no filter. When present it must be a
            // list of exactly 20 finite numbers (4x5 row-major, matching
            // Flutter's ColorFilter.matrix convention) -- anything else is a
            // precise INVALID_ARG rather than a silently-ignored filter.
            val rawColorMatrix = map["colorMatrix"]
            var colorMatrix: FloatArray? = null
            if (rawColorMatrix != null) {
                if (rawColorMatrix !is List<*> || rawColorMatrix.size != 20) {
                    onError(
                        "INVALID_ARG",
                        "exportTimeline: clip.colorMatrix must be a list of exactly 20 numbers",
                    )
                    return
                }
                val parsedMatrix = FloatArray(20)
                for ((index, entry) in rawColorMatrix.withIndex()) {
                    val number = entry as? Number
                    if (number == null) {
                        onError(
                            "INVALID_ARG",
                            "exportTimeline: clip.colorMatrix[$index] must be a number",
                        )
                        return
                    }
                    val value = number.toDouble()
                    if (!value.isFinite()) {
                        onError(
                            "INVALID_ARG",
                            "exportTimeline: clip.colorMatrix[$index] must be finite",
                        )
                        return
                    }
                    parsedMatrix[index] = value.toFloat()
                }
                colorMatrix = parsedMatrix
            }
            // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: parse optional per-clip
            // beautyIntensity. A missing/null key means no beauty (null).
            // When present it must be a finite number in [0.0, 1.0] --
            // anything else is a precise INVALID_ARG rather than a
            // silently-ignored/clamped value.
            val rawBeautyIntensity = map["beautyIntensity"]
            var beautyIntensity: Double? = null
            if (rawBeautyIntensity != null) {
                val beautyNumber = rawBeautyIntensity as? Number
                if (beautyNumber == null) {
                    onError(
                        "INVALID_ARG",
                        "exportTimeline: clip.beautyIntensity must be a number",
                    )
                    return
                }
                val beautyValue = beautyNumber.toDouble()
                if (!beautyValue.isFinite() || beautyValue < 0.0 || beautyValue > 1.0) {
                    onError(
                        "INVALID_ARG",
                        "exportTimeline: clip.beautyIntensity must be finite and in [0.0, 1.0]",
                    )
                    return
                }
                beautyIntensity = beautyValue
            }
            if (sourcePath.startsWith("http://") || sourcePath.startsWith("https://")) {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: remote clip sources are not supported")
                return
            }
            // Android reference-video export: a `content://` clip source is
            // admitted only for mediaKind == "video" and only when the
            // ContentResolver can open it right now
            // (AndroidUriDataSourceHelper.isReadable). Every pass-0/1/2
            // decoder/probe below opens it again through the same helper with
            // this session's [context]; a provider revocation mid-export then
            // surfaces as that stage's existing structured failure
            // (clip_decode_exception / open_exception / remux:<reason>)
            // rather than a crash. Still-image `content://` sources stay
            // fail-closed here with a precise reason -- the still-image
            // decode/probe path is File-based and is not part of this route.
            // Plain POSIX paths keep the byte-identical File.exists/canRead
            // preflight via the helper's non-content branch.
            val isContentUriSource = AndroidUriDataSourceHelper.isContentUri(effectiveSourcePath)
            if (isContentUriSource && mediaKind != "video") {
                onError(
                    "UNSUPPORTED_EXPORT_FEATURE",
                    "exportTimeline: content:// clip sources are only supported for video clips " +
                        "(mediaKind '$mediaKind'): $effectiveSourcePath",
                )
                return
            }
            if (!isContentUriSource && !effectiveSourcePath.startsWith("/")) {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: non-local clip sources are not supported")
                return
            }
            if (!AndroidUriDataSourceHelper.isReadable(effectiveSourcePath, context)) {
                onError("FILE_UNREADABLE", "exportTimeline: cannot read clip source: $effectiveSourcePath")
                return
            }
            parsedClips.add(
                ParsedClip(
                    id = clipId,
                    sourcePath = effectiveSourcePath,
                    trimStart = effectiveTrimStart,
                    trimEnd = effectiveTrimEnd,
                    mediaKind = mediaKind,
                    speed = speed,
                    colorMatrix = colorMatrix,
                    beautyIntensity = beautyIntensity,
                    isReversed = isReversed,
                    canvasTransform = canvasTransform,
                ),
            )
        }

        // P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: reversed clips are a narrow,
        // GLES-only production route (see AndroidTimelineVideoEncoder /
        // AndroidExportRenderBackendSelector). P5-REVERSE-COMPOSITION-
        // NORMALIZATION-A: a reversed clip alongside a transition or
        // clip-level Beauty V2 is no longer rejected here -- that scope is
        // evaluated by AndroidExportRenderBackendSelector on the original
        // clips (glesTransitionEligible / glesBeautyEligible admit a
        // normalizable reversed clip) and, when GLES is committed, pass-0
        // normalization below re-encodes each reversed clip into a forward
        // temp before pass-1. A non-normalizable reversed clip still fails
        // closed at backend selection. P5-GLES-EXPORT-REVERSED-CLIP-OVERLAYS:
        // reversed clips with overlays are not blanket-rejected here either --
        // a hard-cut, zero-rotation reversed VIDEO clip renders through the
        // same GLES overlay route a still-image clip already uses (see
        // AndroidExportRenderBackendSelector.glesOverlayEligible and
        // AndroidTimelineVideoEncoder.renderReversedClipIntoEncoder). A
        // reversed non-video clip still fails closed above at parse time
        // (isReversed is only accepted for mediaKind == "video"), and
        // rotation metadata on a reversed clip is still checked further below
        // (step 3), once each video clip has been probed -- both guards apply
        // regardless of whether overlays/transitions/Beauty are present.
        //
        // P5-REVERSE-AUDIO-SIDECAR-EXPORT: audioSidecar tracks are admitted
        // alongside a reversed hard-cut timeline -- not blanket-rejected --
        // when every parsed track's timing is valid on the reversed
        // timeline's total duration (sum of each parsed clip's trimEnd -
        // trimStart; reversing a clip's playback direction does not change
        // its duration). An invalid track still fails closed rather than
        // producing desynchronized output. When the draft also carries
        // transitions, this admission is deferred to the transition block
        // (step 2b) instead, which validates against the overlap-adjusted
        // duration -- the only duration that is correct for that shape.
        val anyReversed = parsedClips.any { it.isReversed }
        if (anyReversed && rawTransitions.isEmpty()) {
            if (audioSpecs.isNotEmpty()) {
                val reverseTimelineDurationSeconds = parsedClips
                    .sumOf { (it.trimEnd - it.trimStart) / it.speed }
                    .coerceAtLeast(0.0)
                when (
                    val admission = AndroidTimelineAudioOverlapAdmission.validate(
                        audioSpecs,
                        reverseTimelineDurationSeconds,
                    )
                ) {
                    is AndroidTimelineAudioOverlapAdmission.Result.Failure -> {
                        onError(admission.code, admission.message)
                        return
                    }
                    AndroidTimelineAudioOverlapAdmission.Result.Admitted -> {}
                }
            }
        }

        // ── 2b. Transitions: parse + bind to adjacent clips (P5-COMPOSITOR-TRANS) ──
        // Clip ids are preserved from the draft so fromClipId/toClipId bind to
        // the parsed clip order; adjacency, duplicate boundaries, durations and
        // the closed supported type set are validated by the descriptor
        // parser. `fade` (and any other unsupported type) fails closed there.
        val transitions: List<AndroidTimelineTransitionDescriptor> =
            when (
                val parse = AndroidTimelineTransitionDescriptor.parseList(
                    rawTransitions,
                    parsedClips.map { clip ->
                        AndroidTimelineTransitionDescriptor.ClipRef(
                            id = clip.id,
                            durationSeconds = (clip.trimEnd - clip.trimStart) / clip.speed,
                        )
                    },
                )
            ) {
                is AndroidTimelineTransitionDescriptor.ParseResult.Failure -> {
                    onError(parse.code, parse.message)
                    return
                }
                is AndroidTimelineTransitionDescriptor.ParseResult.Success -> parse.transitions
            }
        if (transitions.isNotEmpty()) {
            // Non-video clips (still images) are outside the Vulkan safe scope;
            // AndroidExportRenderBackendSelector resolves such a transition
            // timeline to UNAVAILABLE (transitions_require_vulkan:...) and the
            // check after backend selection below fails closed.
            //
            // P5-TRANSITION-AUDIO-SIDECAR-EXPORT: audioSidecar tracks are
            // admitted alongside a transition timeline only when every
            // parsed track's timing is valid on the overlap-adjusted output
            // timeline this session independently derives from the parsed
            // clip trim windows and transitions -- muxing an invalid track
            // under an overlap-shortened video would desynchronize audio, so
            // an invalid track still fails closed rather than producing
            // wrong output.
            if (audioSpecs.isNotEmpty()) {
                val overlapAdjustedDurationSeconds = AndroidTimelineTransitionDescriptor.timelineDurationSeconds(
                    parsedClips.map { (it.trimEnd - it.trimStart) / it.speed },
                    transitions,
                )
                when (
                    val admission = AndroidTimelineAudioOverlapAdmission.validate(
                        audioSpecs,
                        overlapAdjustedDurationSeconds,
                    )
                ) {
                    is AndroidTimelineAudioOverlapAdmission.Result.Failure -> {
                        onError(admission.code, admission.message)
                        return
                    }
                    AndroidTimelineAudioOverlapAdmission.Result.Admitted -> {}
                }
            }
        }

        // ── 3. Probe decoded geometry + rotation for every clip ─────────────
        val clipContexts = mutableListOf<ClipContext>()
        for (clip in parsedClips) {
            if (clip.mediaKind == "image") {
                val imageProbe = probeImageClip(clip.sourcePath)
                if (imageProbe == null) {
                    onError("FILE_UNREADABLE", "exportTimeline: no readable image data in ${clip.sourcePath}")
                    return
                }
                clipContexts.add(
                    ClipContext(
                        sourcePath = clip.sourcePath,
                        trimStartSeconds = clip.trimStart,
                        trimEndSeconds = clip.trimEnd,
                        decodedWidth = imageProbe.width,
                        decodedHeight = imageProbe.height,
                        rotationDegrees = 0,
                        mediaKind = clip.mediaKind,
                        speed = clip.speed,
                        exifOrientation = imageProbe.exifOrientation,
                        colorMatrix = clip.colorMatrix,
                        beautyIntensity = clip.beautyIntensity,
                        isReversed = clip.isReversed,
                        canvasTransform = clip.canvasTransform,
                    ),
                )
                continue
            }

            val probe = probeVideoTrack(clip.sourcePath)
            if (probe == null) {
                onError("FILE_UNREADABLE", "exportTimeline: no readable video track in ${clip.sourcePath}")
                return
            }
            val normalizedRotation = normalizeRotationDegrees(probe.rotationDegrees)
            if (normalizedRotation != 0 && normalizedRotation != 90 &&
                normalizedRotation != 180 && normalizedRotation != 270
            ) {
                onError(
                    "UNSUPPORTED_EXPORT_FEATURE",
                    "exportTimeline: clip rotation metadata ${probe.rotationDegrees} is not supported",
                )
                return
            }
            // P5-REVERSE-EXPORT-EXACT-GLES-ROUTE: this slice's reversed-clip
            // render route (AndroidTimelineVideoEncoder.renderReversedClipIntoEncoder)
            // does not apply clip rotation metadata -- avoiding reliance on
            // platform bitmap autorotation semantics -- so a reversed clip
            // with non-zero normalized rotation fails closed rather than
            // silently ignoring its rotation.
            if (clip.isReversed && normalizedRotation != 0) {
                onError(
                    "UNSUPPORTED_EXPORT_FEATURE",
                    "exportTimeline: reversed clips with rotation metadata are not supported",
                )
                return
            }
            clipContexts.add(
                ClipContext(
                    sourcePath = clip.sourcePath,
                    trimStartSeconds = clip.trimStart,
                    trimEndSeconds = clip.trimEnd,
                    decodedWidth = probe.width,
                    decodedHeight = probe.height,
                    rotationDegrees = normalizedRotation,
                    mediaKind = clip.mediaKind,
                    speed = clip.speed,
                    colorMatrix = clip.colorMatrix,
                    beautyIntensity = clip.beautyIntensity,
                    isReversed = clip.isReversed,
                    canvasTransform = clip.canvasTransform,
                ),
            )
        }

        // ── 4. Resolve request geometry / bitrate / output path ─────────────
        val requestWidth = (args["width"] as? Number)?.toInt() ?: draftCanvasWidth
        val requestHeight = (args["height"] as? Number)?.toInt() ?: draftCanvasHeight
        val requestFps = (args["fps"] as? Number)?.toInt() ?: draftFps
        val requestBitrate = (args["bitrateBps"] as? Number)?.toInt() ?: DEFAULT_BITRATE_BPS

        if (requestFps <= 0) {
            onError("INVALID_ARG", "exportTimeline: fps must be positive")
            return
        }
        if (requestBitrate <= 0) {
            onError("INVALID_ARG", "exportTimeline: bitrateBps must be positive")
            return
        }

        if (requestWidth <= 0 || requestWidth % 2 != 0 || requestHeight <= 0 || requestHeight % 2 != 0) {
            onError(
                "INVALID_ARG",
                "exportTimeline: requested output ${requestWidth}x$requestHeight must be positive even integers",
            )
            return
        }

        val requestedOutputPath = (args["outputPath"] as? String)?.trim()
        val exportId = UUID.randomUUID().toString()
        val outputPath = if (requestedOutputPath.isNullOrBlank()) {
            File(context.cacheDir, "vg_timeline_export_$exportId.mp4").absolutePath
        } else {
            requestedOutputPath
        }
        File(outputPath).parentFile?.mkdirs()

        // ── 5. Pass 1: video-only encode (owned temps from here on) ─────────
        val videoTempPath = File(context.cacheDir, "vg_timeline_export_video_$exportId.mp4").absolutePath
        val audioTempPath = File(context.cacheDir, "vg_timeline_export_audio_$exportId.m4a").absolutePath
        val finalTmpPath = "$outputPath.vgtmp"
        val roiSidecarPath = AndroidTimelineRoiSidecarEmitter.sidecarPathForVideoPath(outputPath)
        val roiSidecarTempPath = AndroidTimelineRoiSidecarEmitter.tempPathForSidecarPath(roiSidecarPath)

        // P5-REVERSE-COMPOSITION-NORMALIZATION-A: pass-0 owner. Constructed
        // unconditionally (it allocates nothing until [run] is invoked) so
        // its temps are part of this session's single owned-temp cleanup
        // from the very first exit path below, whether or not pass-0 ends up
        // running for this export.
        val reverseNormalization = AndroidTimelineReverseNormalizationPrepass(
            cacheDir = context.cacheDir,
            exportId = exportId,
            fps = requestFps,
            requestedWidth = requestWidth,
            requestedHeight = requestHeight,
            requestedBitrateBps = requestBitrate,
            context = context,
        )

        fun deleteOwnedTemps() {
            try { File(videoTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            try { File(audioTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            try { File(finalTmpPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            try { File(roiSidecarTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            reverseNormalization.deleteOwnedTemps()
        }
        ownedTempCleanup = { deleteOwnedTemps() }

        if (cancelRequested) {
            deleteOwnedTemps()
            logTerminal("cancelled_before_encode", backend = null)
            onError("EXPORT_CANCELLED", "exportTimeline: cancelled before encode started")
            return
        }

        // P5-OVERLAYS-TRANS Route-A N9: overlay descriptor geometry
        // (translationX/Y, width, height) is expressed in draft-canvas pixel
        // space, but the native overlay render seam
        // (renderAndroidTimelineVulkanExportFrameCroppedWithOverlays)
        // composites that geometry directly in the requested output's pixel
        // space. When the requested output differs from the draft canvas,
        // that geometry would silently land in the wrong place -- fail
        // closed instead of producing wrong output.
        if (overlays.isNotEmpty() &&
            (requestWidth != draftCanvasWidth || requestHeight != draftCanvasHeight)
        ) {
            deleteOwnedTemps()
            logTerminal("overlay_route_unsupported", backend = null)
            onError(
                "UNSUPPORTED_EXPORT_FEATURE",
                "exportTimeline: overlay export requires the requested output " +
                    "(${requestWidth}x$requestHeight) to match the draft canvas " +
                    "(${draftCanvasWidth}x$draftCanvasHeight) for Route-A",
            )
            return
        }

        // P5-CLIP-STATIC-TRANSFORM-EXPORT-A: clip transform translations are
        // draft-canvas pixels (the Dart builder's canvas), while every
        // encoder places clips in requested-output pixels. The two agree
        // only when the requested output is a uniform scaling of the draft
        // canvas; a differing aspect ratio would change the fit and silently
        // reframe the clip, so it fails closed instead. The translation is
        // scaled by the (uniform) output/canvas ratio below.
        val hasCanvasTransform = clipContexts.any { it.canvasTransform != null }
        val transformTranslationScale: Double
        if (hasCanvasTransform) {
            val aspectMismatch = abs(
                requestWidth.toDouble() * draftCanvasHeight - requestHeight.toDouble() * draftCanvasWidth,
            )
            if (aspectMismatch > CLIP_TRANSFORM_ASPECT_TOLERANCE * requestWidth.toDouble() * draftCanvasHeight) {
                deleteOwnedTemps()
                logTerminal("clip_transform_unsupported", backend = null)
                onError(
                    "UNSUPPORTED_EXPORT_FEATURE",
                    "exportTimeline: clip.transform requires the requested output " +
                        "(${requestWidth}x$requestHeight) to have the same aspect ratio as the draft canvas " +
                        "(${draftCanvasWidth}x$draftCanvasHeight)",
                )
                return
            }
            transformTranslationScale = requestWidth.toDouble() / draftCanvasWidth.toDouble()
        } else {
            transformTranslationScale = 1.0
        }

        val clipInputs = mutableListOf<AndroidTimelineVideoEncoder.ClipInput>()
        for (ctx in clipContexts) {
            var stillFrameCount = 0
            if (ctx.mediaKind == "image") {
                val duration = (ctx.trimEndSeconds - ctx.trimStartSeconds) / ctx.speed
                stillFrameCount = floor(duration * requestFps + 0.5).toInt().coerceAtLeast(1)
                if (stillFrameCount > MAX_STILL_FRAME_COUNT) {
                    deleteOwnedTemps()
                    onError(
                        "UNSUPPORTED_EXPORT_FEATURE",
                        "exportTimeline: still image clip frame count $stillFrameCount exceeds limit of $MAX_STILL_FRAME_COUNT",
                    )
                    return
                }
            }
            // P5-CLIP-STATIC-TRANSFORM-EXPORT-A: output-space transform, then
            // a fail-closed placement check against the probed geometry with
            // the exact computation AndroidTimelineVulkanVideoEncoder will
            // run per clip -- a transform that leaves nothing visible or
            // yields an empty/odd/out-of-range source crop is rejected here
            // with a precise reason rather than surfacing as a pass-1 render
            // failure (or, on the GLES fallback, as unframed/black output).
            var outputTransform: AndroidTimelineVideoEncoder.StaticClipTransform? = null
            val canvasTransform = ctx.canvasTransform
            if (canvasTransform != null) {
                val scaledTransform = AndroidTimelineVideoEncoder.StaticClipTransform(
                    scale = canvasTransform.scale,
                    translationX = canvasTransform.translationX * transformTranslationScale,
                    translationY = canvasTransform.translationY * transformTranslationScale,
                )
                outputTransform = scaledTransform
                val placement = AndroidTimelineClipStaticTransformGeometry.compute(
                    outputWidth = requestWidth,
                    outputHeight = requestHeight,
                    decodedWidth = ctx.decodedWidth,
                    decodedHeight = ctx.decodedHeight,
                    rotationDegrees = ctx.rotationDegrees,
                    transform = scaledTransform,
                )
                val resolved = placement.placement
                if (resolved == null) {
                    deleteOwnedTemps()
                    logTerminal("clip_transform_unsupported", backend = null)
                    onError(
                        "UNSUPPORTED_EXPORT_FEATURE",
                        "exportTimeline: clip.transform cannot be represented as an in-bounds crop " +
                            "(${placement.failure ?: "unresolved"}) for ${ctx.sourcePath}",
                    )
                    return
                }
                Log.i(
                    TAG,
                    "VG_EXPORT_CLIP_TRANSFORM source=${ctx.sourcePath} " +
                        "canvasScale=${canvasTransform.scale} canvasTx=${canvasTransform.translationX} " +
                        "canvasTy=${canvasTransform.translationY} translationScale=$transformTranslationScale " +
                        "decoded=${ctx.decodedWidth}x${ctx.decodedHeight} rotation=${ctx.rotationDegrees} " +
                        "crop=${resolved.sourceLeft},${resolved.sourceTop}-${resolved.sourceRight},${resolved.sourceBottom} " +
                        "dest=${resolved.destX},${resolved.destY}-${resolved.destWidth}x${resolved.destHeight} " +
                        "out=${requestWidth}x$requestHeight",
                )
            }
            clipInputs.add(
                AndroidTimelineVideoEncoder.ClipInput(
                    sourcePath = ctx.sourcePath,
                    trimStartSeconds = ctx.trimStartSeconds,
                    trimEndSeconds = ctx.trimEndSeconds,
                    decodedWidth = ctx.decodedWidth,
                    decodedHeight = ctx.decodedHeight,
                    rotationDegrees = ctx.rotationDegrees,
                    mediaKind = ctx.mediaKind,
                    speed = ctx.speed,
                    stillFrameCount = stillFrameCount,
                    exifOrientation = ctx.exifOrientation,
                    colorMatrix = ctx.colorMatrix,
                    beautyIntensity = ctx.beautyIntensity,
                    isReversed = ctx.isReversed,
                    transform = outputTransform,
                ),
            )
        }

        // P5-BEAUTY-V2-TRANSITION-COMP: clip-level Beauty V2 alongside a
        // compositor transition is supported -- both features independently
        // require the Vulkan backend (see AndroidExportRenderBackendSelector's
        // `requiresVulkan`), and AndroidTimelineVulkanVideoEncoder renders
        // per-layer Beauty V2 on both solo and transition-overlap frames.
        val hasBeautyClip = clipInputs.any { it.beautyIntensity != null }

        // P5-OVERLAYS-TRANSITION-COMP-N3: overlays alongside a transition
        // timeline are a supported production shape -- AndroidTimelineVulkanVideoEncoder
        // composites overlays on both solo frames and transition overlap
        // frames (see [renderTransitionPair]).
        //
        // P5-OVERLAYS-BEAUTY-SOLO: overlays alongside clip-level Beauty V2
        // are a supported production shape on every frame kind -- a solo
        // frame on a beauty clip carrying an active overlay renders through
        // the combined
        // renderAndroidTimelineVulkanExportFrameCroppedWithOverlaysAndBeauty
        // seam (see [renderSoloLayer]), and a transition-overlap frame
        // renders through renderAndroidTimelineVulkanExportTransitionFrameWithOverlays's
        // own per-layer Beauty V2 params (see [renderTransitionPair]). There
        // is no longer an admission gate here restricting overlays alongside
        // beauty to transition-overlap windows.
        if (overlays.size > MAX_OVERLAY_COUNT) {
            deleteOwnedTemps()
            logTerminal("overlay_route_unsupported", backend = null)
            onError(
                "UNSUPPORTED_EXPORT_FEATURE",
                "exportTimeline: overlay count ${overlays.size} exceeds the Route-A limit of $MAX_OVERLAY_COUNT overlays",
            )
            return
        }

        // Session-owned diagnostics/lifecycle/native-bridge triple for this
        // export run -- reused for backend selection and, when Vulkan is
        // selected, for AndroidTimelineVulkanVideoEncoder, instead of each
        // owner constructing its own VanguardNativeBridge.
        val sessionDiagnostics = VanguardDiagnostics()
        val sessionLifecycleObserver = VanguardLifecycleObserver(sessionDiagnostics)
        val sessionNativeBridge = VanguardNativeBridge(sessionLifecycleObserver, sessionDiagnostics, null)

        // P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A / P5-GLES-EXPORT-
        // BEAUTY-PRODUCTION-ROUTE-A: route the single top-level debug-force
        // request into exactly one of the two narrow force seams --
        // transition-force for a non-hard-cut transition scope, beauty-force
        // for a hard-cut Beauty scope. A scope that is both (a non-hard-cut
        // transition alongside a Beauty clip) only ever sets the transition
        // seam here, matching AndroidExportRenderBackendSelector.select's own
        // documented priority for that combination -- it already fails
        // closed with a `gles_transition_not_eligible:beauty_clip_present`
        // reason for such a scope (see
        // ExportRenderScope.glesTransitionIneligibleReason), so this session
        // never needs to also set the beauty seam for it.
        val hasNonHardCutTransitionForEncoder = transitions.any { !it.isHardCut }
        val debugForceGlesTransitionExport = debugForceGlesRequested && hasNonHardCutTransitionForEncoder
        val debugForceGlesBeautyExport =
            debugForceGlesRequested && !hasNonHardCutTransitionForEncoder && hasBeautyClip

        // P5-REVERSE-COMPOSITION-NORMALIZATION-A: selection always evaluates
        // the ORIGINAL clip inputs (reversed flags intact) -- reversed clips
        // are never rewritten before selection, so Vulkan keeps failing
        // closed for them and the selector's own normalizability predicates
        // decide GLES eligibility.
        val exportScope = ExportRenderScope(
            clips = clipInputs,
            requestedWidth = requestWidth,
            requestedHeight = requestHeight,
            transitions = transitions,
            overlays = overlays,
        )
        val backendDecision = AndroidExportRenderBackendSelector().select(
            exportScope,
            nativeBridge = sessionNativeBridge,
            debugForceGlesTransitionExport = debugForceGlesTransitionExport,
            debugForceGlesBeautyExport = debugForceGlesBeautyExport,
        )
        // P5-COMPOSITOR-TRANS / P5-OVERLAYS-TRANS: a transition timeline or
        // overlay list that cannot be routed to either Vulkan or (for a
        // narrow GLES-transition-eligible shape, per
        // P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A) GLES fails closed
        // here -- re-encoding either as plain hard cuts would be wrong
        // output. The branch below mirrors
        // AndroidExportRenderBackendSelector.requiresVulkanReasonPrefix's own
        // priority (transitions, then beauty, then overlays), plus the
        // dedicated debug-force-seam-ineligible reason.
        if (backendDecision.actualBackend == ExportRenderBackend.UNAVAILABLE) {
            deleteOwnedTemps()
            logTerminal("backend_unavailable", backendDecision.actualBackend)
            val errorMessage = when {
                backendDecision.reason.startsWith(AndroidExportRenderBackendSelector.GLES_TRANSITION_NOT_ELIGIBLE_REASON) ->
                    "exportTimeline: debugForceRenderBackend=gles requires a GLES-transition-eligible " +
                        "request (${backendDecision.reason})"
                backendDecision.reason.startsWith(AndroidExportRenderBackendSelector.GLES_BEAUTY_NOT_ELIGIBLE_REASON) ->
                    "exportTimeline: debugForceRenderBackend=gles requires a GLES-beauty-eligible " +
                        "request (${backendDecision.reason})"
                backendDecision.reason.startsWith(AndroidExportRenderBackendSelector.TRANSITIONS_REQUIRE_VULKAN_REASON) ->
                    "exportTimeline: transitions require the Vulkan export backend " +
                        "(${backendDecision.reason})"
                backendDecision.reason.startsWith(AndroidExportRenderBackendSelector.BEAUTY_REQUIRE_VULKAN_REASON) ->
                    "exportTimeline: Beauty V2 requires the Vulkan export backend " +
                        "(${backendDecision.reason})"
                backendDecision.reason.startsWith(AndroidExportRenderBackendSelector.OVERLAYS_REQUIRE_VULKAN_REASON) ->
                    "exportTimeline: overlay export requires the Vulkan export backend " +
                        "(${backendDecision.reason})"
                else ->
                    "exportTimeline: export backend unavailable (${backendDecision.reason})"
            }
            onError(
                "UNSUPPORTED_EXPORT_FEATURE",
                errorMessage,
            )
            return
        }
        // Backend that actually produced pass-1's output -- starts as the
        // selector's decision, and is updated to GLES if a Vulkan attempt
        // fails and this session falls back mid-export. Every terminal log
        // after pass-1 reports this value, not the original selector decision.
        var effectiveBackend = backendDecision.actualBackend

        // P5-REVERSE-COMPOSITION-NORMALIZATION-A: pass-0 runs only once GLES
        // is the committed backend for a reversed+transition and/or
        // reversed+Beauty scope. A reversed scope can never resolve to Vulkan
        // (AndroidExportRenderBackendSelector.vulkanScopeFailureReason), so
        // this is equivalent to "GLES was selected for such a scope", but
        // the backend check is kept explicit rather than assumed.
        val reverseNormalizationRequired =
            effectiveBackend == ExportRenderBackend.GLES && exportScope.glesReverseNormalizationRequired

        // Progress is strictly monotonic across pass-0 and pass-1: pass-0
        // (when it runs) is scaled into [0.0, PASS0_PROGRESS_WEIGHT], and
        // pass-1 sample progress into [pass1ProgressFloor,
        // PASS1_PROGRESS_SAMPLE_MAX] where the floor is PASS0_PROGRESS_WEIGHT
        // when pass-0 ran and 0.0 otherwise -- so every unaffected scope
        // keeps its exact existing pass-1 mapping. A GLES fallback attempt
        // reuses the same scaled pass-1 callback and restarts its own
        // sample-ratio progress from 0, so the max-seen clamp is required
        // to prevent the fallback (or pass-1 starting after pass-0) from
        // regressing progress already emitted.
        var maxProgressSeen = 0.0
        fun emitMonotonicProgress(value: Double) {
            if (value > maxProgressSeen) {
                maxProgressSeen = value
                onProgress?.invoke(value)
            }
        }
        val pass1ProgressFloor = if (reverseNormalizationRequired) PASS0_PROGRESS_WEIGHT else 0.0
        fun emitPass0Progress(ratio: Double) {
            emitMonotonicProgress((ratio * PASS0_PROGRESS_WEIGHT).coerceIn(0.0, PASS0_PROGRESS_WEIGHT))
        }
        fun emitPass1Progress(sampleRatio: Double) {
            val span = PASS1_PROGRESS_SAMPLE_MAX - pass1ProgressFloor
            val scaled = (pass1ProgressFloor + sampleRatio.coerceIn(0.0, 1.0) * span)
                .coerceIn(pass1ProgressFloor, PASS1_PROGRESS_SAMPLE_MAX)
            emitMonotonicProgress(scaled)
        }

        // ── 5a. Pass 0: reversed-clip normalization (GLES composition only) ──
        // Replaces each reversed clip with a forward clip over an owned temp
        // (see AndroidTimelineReverseNormalizationPrepass). Every other scope
        // passes [clipInputs] through untouched.
        var pass1ClipInputs: List<AndroidTimelineVideoEncoder.ClipInput> = clipInputs
        if (reverseNormalizationRequired) {
            if (cancelRequested) {
                deleteOwnedTemps()
                logTerminal("cancelled_before_normalization", effectiveBackend)
                onError("EXPORT_CANCELLED", "exportTimeline: cancelled before reversed-clip normalization")
                return
            }
            Log.i(
                TAG,
                "VG_EXPORT_REVERSE_NORMALIZATION_START backend=${effectiveBackend.wireName()} " +
                    "reversed=${clipInputs.count { it.isReversed }} " +
                    "transitions=${transitions.count { !it.isHardCut }} beauty=$hasBeautyClip",
            )
            when (
                val normalization = reverseNormalization.run(
                    clips = clipInputs,
                    isCancelled = { cancelRequested },
                    trackActiveEncoder = { enc -> activeEncoder = enc },
                    onProgress = { ratio -> emitPass0Progress(ratio) },
                )
            ) {
                is AndroidTimelineReverseNormalizationPrepass.Result.Failed -> {
                    deleteOwnedTemps()
                    if (normalization.cancelled || cancelRequested) {
                        logTerminal("cancelled_during_normalization", effectiveBackend)
                        onError("EXPORT_CANCELLED", "exportTimeline: cancelled during reversed-clip normalization")
                    } else {
                        logTerminal("pass0_failed", effectiveBackend)
                        onError(
                            "EXPORT_FAILED",
                            "exportTimeline: pass-0 reversed-clip normalization failed: ${normalization.reason}",
                        )
                    }
                    return
                }
                is AndroidTimelineReverseNormalizationPrepass.Result.Normalized -> {
                    pass1ClipInputs = normalization.clips
                    Log.i(
                        TAG,
                        "VG_EXPORT_REVERSE_NORMALIZATION_DONE normalized=${normalization.normalizedClipCount}",
                    )
                }
            }
            if (cancelRequested) {
                deleteOwnedTemps()
                logTerminal("cancelled_after_normalization", effectiveBackend)
                onError("EXPORT_CANCELLED", "exportTimeline: cancelled after reversed-clip normalization")
                return
            }
            emitMonotonicProgress(PASS0_PROGRESS_WEIGHT)
        }

        // P5-GLES-EXPORT-TRANSITION-PRODUCTION-ROUTE-A: only a GLES backend
        // decision for a scope actually carrying a non-hard-cut transition
        // routes through the narrow AndroidTimelineGlesTransitionVideoEncoder
        // -- every other GLES decision (hard-cut-only timelines, including
        // one with only `none` transition entries, and P5-GLES-EXPORT-BEAUTY-
        // PRODUCTION-ROUTE-A's hard-cut Beauty scopes) keeps using the
        // frozen AndroidTimelineVideoEncoder hard-cut path unchanged --
        // AndroidTimelineVideoEncoder itself routes a clip's Beauty V2 frame
        // through AndroidTimelineGlesBeautyRenderSession when
        // ClipInput.beautyIntensity is non-null (see its own [encode] doc).
        // [hasNonHardCutTransitionForEncoder] was already computed above,
        // before backend selection, to derive the debug-force routing.
        // Every pass-1 encoder receives this session's [context] so a
        // `content://` clip source admitted above can be opened by its
        // MediaExtractor/MediaMetadataRetriever through the ContentResolver
        // (AndroidUriDataSourceHelper); POSIX sources are unaffected.
        fun buildPass1Encoder(backend: ExportRenderBackend): AndroidTimelineVideoPassEncoder {
            return if (backend == ExportRenderBackend.VULKAN) {
                AndroidTimelineVulkanVideoEncoder(
                    outputPath = videoTempPath,
                    width = requestWidth,
                    height = requestHeight,
                    fps = requestFps,
                    bitrateBps = requestBitrate,
                    nativeBridge = sessionNativeBridge,
                    context = context,
                )
            } else if (hasNonHardCutTransitionForEncoder) {
                AndroidTimelineGlesTransitionVideoEncoder(
                    outputPath = videoTempPath,
                    width = requestWidth,
                    height = requestHeight,
                    fps = requestFps,
                    bitrateBps = requestBitrate,
                    nativeBridge = sessionNativeBridge,
                    context = context,
                )
            } else {
                AndroidTimelineVideoEncoder(
                    outputPath = videoTempPath,
                    width = requestWidth,
                    height = requestHeight,
                    fps = requestFps,
                    bitrateBps = requestBitrate,
                    nativeBridge = sessionNativeBridge,
                    context = context,
                )
            }
        }

        // [activeEncoder] is always cleared in `finally`, even if an encoder
        // unexpectedly throws instead of returning a failed EncodeResult, so
        // a later requestCancel() never holds a reference to a dead encoder.
        // Pass-1 always encodes [pass1ClipInputs] -- identical to
        // [clipInputs] unless pass-0 normalization replaced reversed clips.
        fun encodeWithActiveTracking(enc: AndroidTimelineVideoPassEncoder): AndroidTimelineVideoEncoder.EncodeResult {
            activeEncoder = enc
            try {
                return enc.encode(pass1ClipInputs, transitions, overlays) { p -> emitPass1Progress(p) }
            } finally {
                activeEncoder = null
            }
        }

        var encoder = buildPass1Encoder(effectiveBackend)
        var encodeResult = encodeWithActiveTracking(encoder)

        if (!encodeResult.success && effectiveBackend == ExportRenderBackend.VULKAN &&
            transitions.isNotEmpty() && !cancelRequested && encodeResult.reason != "cancelled"
        ) {
            // Transition timelines never fall back: GLES has no overlap route
            // and would re-encode the timeline as hard cuts.
            Log.i(TAG, "VG_EXPORT_BACKEND_FALLBACK_BLOCKED from=vulkan reason=${encodeResult.reason} transitions=${transitions.size}")
        }
        if (!encodeResult.success && effectiveBackend == ExportRenderBackend.VULKAN &&
            hasBeautyClip && !cancelRequested && encodeResult.reason != "cancelled"
        ) {
            // P5-BEAUTY-V2-PRODUCTION-EXPORT-ROUTE-A: clip-level Beauty V2 is
            // a Vulkan-only production route with no GLES fallback (see
            // AndroidExportRenderBackendSelector) -- a failed Vulkan attempt
            // never falls back to GLES here either. The surfaced reason is
            // prefixed with BEAUTY_REQUIRE_VULKAN_REASON unless the
            // underlying reason is already a precise beauty_v2_* reason from
            // the native render path.
            val underlyingReason = encodeResult.reason
            val beautyReason = if (underlyingReason.startsWith("beauty_v2_")) {
                underlyingReason
            } else {
                "${AndroidExportRenderBackendSelector.BEAUTY_REQUIRE_VULKAN_REASON}:$underlyingReason"
            }
            Log.i(TAG, "VG_EXPORT_BACKEND_FALLBACK_BLOCKED from=vulkan reason=$beautyReason beauty_v2=true")
            encodeResult = encodeResult.copy(reason = beautyReason)
        }
        if (!encodeResult.success && effectiveBackend == ExportRenderBackend.VULKAN &&
            overlays.isNotEmpty() && transitions.isEmpty() && !cancelRequested && encodeResult.reason != "cancelled"
        ) {
            // P5-OVERLAYS-TRANS Route-A N9: overlay compositing is a
            // Vulkan-only production route with no GLES fallback (mirrors
            // the transition/beauty blocks above) -- a failed Vulkan attempt
            // never falls back to GLES here either. The surfaced reason is
            // prefixed with OVERLAYS_REQUIRE_VULKAN_REASON unless the
            // underlying reason is already a precise overlay_*/overlays_*
            // reason from the native render path.
            //
            // Gated on transitions.isEmpty() (P5-OVERLAYS-TRANSITION-COMP-N3):
            // when a Vulkan failure carries transitions, the transitions
            // block above already emitted the single VG_EXPORT_BACKEND_FALLBACK_BLOCKED
            // row for this run -- this block must not also rewrite
            // encodeResult.reason (which could stomp a vulkan_transition_*
            // reason) or log a second row. Any overlay_*/overlays_* reason
            // the encoder itself raised on a transitions-carrying run still
            // passes through unprefixed via encodeResult.reason as-is.
            val underlyingReason = encodeResult.reason
            val overlayReason = if (underlyingReason.startsWith("overlay_") || underlyingReason.startsWith("overlays_")) {
                underlyingReason
            } else {
                "${AndroidExportRenderBackendSelector.OVERLAYS_REQUIRE_VULKAN_REASON}:$underlyingReason"
            }
            Log.i(TAG, "VG_EXPORT_BACKEND_FALLBACK_BLOCKED from=vulkan reason=$overlayReason overlays=${overlays.size}")
            encodeResult = encodeResult.copy(reason = overlayReason)
        }
        if (!encodeResult.success && effectiveBackend == ExportRenderBackend.VULKAN &&
            transitions.isEmpty() && !hasBeautyClip && overlays.isEmpty() && !cancelRequested && encodeResult.reason != "cancelled"
        ) {
            Log.i(TAG, "VG_EXPORT_BACKEND_FALLBACK from=vulkan to=gles reason=${encodeResult.reason}")
            try { File(videoTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            // Re-check cancellation after temp cleanup, immediately before
            // constructing/starting the GLES retry -- a requestCancel() that
            // lands in the gap between the Vulkan attempt ending and the GLES
            // retry starting has no in-flight encoder to signal, so it must
            // be observed here instead of racing the retry.
            if (!cancelRequested) {
                effectiveBackend = ExportRenderBackend.GLES
                encoder = buildPass1Encoder(effectiveBackend)
                encodeResult = encodeWithActiveTracking(encoder)
            } else {
                encodeResult = AndroidTimelineVideoEncoder.EncodeResult(false, "cancelled", 0, 0L)
            }
        }

        if (!encodeResult.success) {
            deleteOwnedTemps()
            if (cancelRequested || encodeResult.reason == "cancelled") {
                logTerminal("cancelled_during_encode", effectiveBackend)
                onError("EXPORT_CANCELLED", "exportTimeline: cancelled during video encode")
            } else {
                logTerminal("pass1_failed", effectiveBackend)
                onError("EXPORT_FAILED", "exportTimeline: pass-1 video encode failed: ${encodeResult.reason}")
            }
            return
        }

        if (cancelRequested) {
            deleteOwnedTemps()
            logTerminal("cancelled_after_encode", effectiveBackend)
            onError("EXPORT_CANCELLED", "exportTimeline: cancelled after video encode")
            return
        }
        onProgress?.invoke(PASS1_PROGRESS_WEIGHT)

        // ── 6. Pass 2: audio mux / mixdown ───────────────────────────────────
        // audioSpecs was already parsed once, above, before the transition
        // admission gate -- reused here rather than re-parsing the raw wire
        // list again.
        // [context] is threaded so an original-sound sidecar track whose url
        // is the clip's own `content://` source can be probed/decoded/remuxed
        // through the ContentResolver; the video/audio temps stay POSIX.
        val pass2Failure = AndroidTimelineAudioPass2Muxer(context = context).run(
            specs = audioSpecs,
            videoTempPath = videoTempPath,
            audioTempPath = audioTempPath,
            finalTmpPath = finalTmpPath,
        )
        if (pass2Failure != null) {
            deleteOwnedTemps()
            logTerminal("pass2_failed", effectiveBackend)
            onError("EXPORT_FAILED", "exportTimeline: pass-2 audio mux failed: $pass2Failure")
            return
        }

        if (cancelRequested) {
            deleteOwnedTemps()
            logTerminal("cancelled_after_audio_mux", effectiveBackend)
            onError("EXPORT_CANCELLED", "exportTimeline: cancelled after audio mux")
            return
        }
        onProgress?.invoke(PASS2_PROGRESS_CHECKPOINT)

        // ── 7. Finalize: measure duration on the completed temp, then rename ──
        // to the requested output. Rename only happens once every success
        // precondition is satisfied, so a pre-existing outputPath is never
        // clobbered by a partially-finalized export.
        val durationSeconds = probeMediaDurationSeconds(finalTmpPath)
        if (durationSeconds == null) {
            deleteOwnedTemps()
            logTerminal("finalize_failed", effectiveBackend)
            onError("EXPORT_FAILED", "exportTimeline: failed to measure output duration")
            return
        }

        // Sidecar-first finalization: the ROI sidecar is staged and finalized
        // before the video rename, so a sidecar failure never leaves behind a
        // finalized video with a missing/incorrect sidecar.
        if (!AndroidTimelineRoiSidecarEmitter.stageEmptySidecar(
                roiSidecarTempPath, requestWidth, requestHeight, durationSeconds,
            )
        ) {
            deleteOwnedTemps()
            logTerminal("finalize_failed", effectiveBackend)
            onError("EXPORT_FAILED", "exportTimeline: failed to stage ROI sidecar at $roiSidecarTempPath")
            return
        }
        if (!AndroidTimelineRoiSidecarEmitter.finalizeSidecar(roiSidecarTempPath, roiSidecarPath)) {
            deleteOwnedTemps()
            logTerminal("finalize_failed", effectiveBackend)
            onError("EXPORT_FAILED", "exportTimeline: failed to finalize ROI sidecar at $roiSidecarPath")
            return
        }

        val finalFile = File(finalTmpPath)
        val destFile = File(outputPath)
        if (!finalFile.renameTo(destFile)) {
            // The ROI sidecar has already been finalized at this point and is
            // not recoverable here -- wrong ROI is worse than empty ROI, and
            // this sidecar is empty either way, so it is left in place.
            deleteOwnedTemps()
            logTerminal("finalize_failed", effectiveBackend)
            onError("EXPORT_FAILED", "exportTimeline: failed to finalize output at $outputPath")
            return
        }
        try { File(videoTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
        try { File(audioTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
        // P5-REVERSE-COMPOSITION-NORMALIZATION-A: pass-0 temps are owned
        // per-export cache files and are never part of the finalized output.
        reverseNormalization.deleteOwnedTemps()

        logTerminal("success", effectiveBackend)
        onSuccess(
            mapOf(
                "success" to true,
                "path" to outputPath,
                "durationSeconds" to durationSeconds,
                "width" to requestWidth,
                "height" to requestHeight,
                "fps" to requestFps,
                "exportRoiSidecarPath" to roiSidecarPath,
                "renderBackend" to effectiveBackend.wireName(),
                "transitionCount" to transitions.size,
                "beautyClipCount" to clipInputs.count { it.beautyIntensity != null },
                "beautyFrameCount" to encodeResult.beautyFrameCount,
                "overlayCount" to overlays.size,
                "renderedOverlayFrameCount" to encodeResult.overlayFrameCount,
                "transformedClipCount" to clipInputs.count { it.transform != null },
            ),
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Terminal-state logging (one row per export run -- never per-frame)
    // ─────────────────────────────────────────────────────────────────────────

    /// Logs exactly one VG_EXPORT_TERMINAL row for a terminal exit from [run].
    /// [backend] is null only for the exit path preceding backend selection
    /// (cancelled before pass-1 encoder creation).
    private fun logTerminal(state: String, backend: ExportRenderBackend?) {
        Log.i(TAG, "VG_EXPORT_TERMINAL state=$state backend=${backend?.wireName() ?: "unset"}")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Probing helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Normalizes arbitrary (including negative) rotation-metadata degrees into
    /// the [0, 360) range. Callers must still validate the result is one of
    /// 0/90/180/270 -- this normalization alone does not guarantee that.
    private fun normalizeRotationDegrees(degrees: Int): Int = ((degrees % 360) + 360) % 360

    private data class VideoProbe(val width: Int, val height: Int, val rotationDegrees: Int)

    private data class ImageProbe(val width: Int, val height: Int, val exifOrientation: Int)

    private fun probeImageClip(path: String): ImageProbe? {
        val bounds = AndroidStillImageDecoder.probeBounds(path) ?: return null
        val exifOrientation = AndroidStillImageDecoder.readExifOrientation(path)
        return ImageProbe(bounds.width, bounds.height, exifOrientation)
    }

    private fun probeVideoTrack(path: String): VideoProbe? {
        val extractor = MediaExtractor()
        try {
            // POSIX path or `content://` URI -- the helper picks the overload.
            AndroidUriDataSourceHelper.setExtractorDataSource(extractor, path, context)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                    val width = format.getInteger(MediaFormat.KEY_WIDTH)
                    val height = format.getInteger(MediaFormat.KEY_HEIGHT)
                    val rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                        format.getInteger(MediaFormat.KEY_ROTATION)
                    } else {
                        0
                    }
                    return VideoProbe(width, height, rotation)
                }
            }
            return null
        } catch (t: Throwable) {
            Log.e(TAG, "probeVideoTrack failed for $path: $t")
            return null
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    private fun probeMediaDurationSeconds(path: String): Double? {
        val retriever = MediaMetadataRetriever()
        try {
            AndroidUriDataSourceHelper.setRetrieverDataSource(retriever, path, context)
            val ms = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: return null
            return ms / 1000.0
        } catch (t: Throwable) {
            Log.e(TAG, "probeMediaDurationSeconds failed for $path: $t")
            return null
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val TAG = "VGTimelineExportSession"
        private const val DEFAULT_BITRATE_BPS = 4_000_000
        private const val MAX_STILL_FRAME_COUNT = 36_000

        /// P5-OVERLAYS-TRANS Route-A N9: per-export overlay count limit --
        /// mirrors the native overlay texture store's own enforced maximum.
        private const val MAX_OVERLAY_COUNT = 128

        // Progress checkpoints (frozen — see [start] doc comment). PASS1_PROGRESS_WEIGHT is
        // the exact value emitted as the pass-1-complete checkpoint (after the post-pass-1
        // cancel check), so AndroidEditorExportCoordinator can recognize it by exact Double
        // equality and bypass its normal throttle. The encoder's own [0.0, 1.0] sample-ratio
        // progress is scaled into [0.0, PASS1_PROGRESS_SAMPLE_MAX] instead -- strictly below
        // PASS1_PROGRESS_WEIGHT -- so no sampled value can collide with, or precede an
        // unresolved cancel check for, the exact 0.85 checkpoint.
        private const val PASS1_PROGRESS_WEIGHT = 0.85
        private const val PASS1_PROGRESS_SAMPLE_MAX = 0.849999
        private const val PASS2_PROGRESS_CHECKPOINT = 0.98

        /// P5-REVERSE-COMPOSITION-NORMALIZATION-A: progress prefix reserved
        /// for pass-0 reversed-clip normalization when it runs. Pass-1 sample
        /// progress is then scaled into [PASS0_PROGRESS_WEIGHT,
        /// PASS1_PROGRESS_SAMPLE_MAX] instead of [0.0, PASS1_PROGRESS_SAMPLE_MAX];
        /// the exact PASS1_PROGRESS_WEIGHT checkpoint is unchanged. Not an
        /// exact-equality checkpoint for AndroidEditorExportCoordinator.
        private const val PASS0_PROGRESS_WEIGHT = 0.10

        // Clip-level wire keys for features not implemented by Unit C's minimal
        // hard-cut passthrough. Presence of any of these (non-null) means the
        // clip requires rendering behaviour this exporter does not perform --
        // rejecting explicitly avoids silently producing wrong output.
        // colorMatrix is intentionally absent from this list (Phase 10): it is
        // parsed and validated explicitly above, then carried through
        // ParsedClip/ClipContext/ClipInput and applied by whichever backend
        // renders the clip -- see AndroidTimelineVulkanVideoEncoder (Vulkan)
        // and AndroidTimelineVideoEncoder (GLES). `transform` is likewise
        // absent (P5-CLIP-STATIC-TRANSFORM-EXPORT-A): it is parsed by
        // [parseStaticClipTransform] into the narrow static subset that the
        // same two backends render, and everything outside that subset
        // still fails closed there. `transformTrack` and `cropRect` remain
        // unsupported.
        private val UNSUPPORTED_CLIP_KEYS = listOf(
            "freezePTS",
            "dualCamera",
            "timeRemap",
            "transformTrack",
            "cropRect",
        )

        // P5-CLIP-STATIC-TRANSFORM-EXPORT-A: `clip.transform` wire keys with
        // their VGClipTransformDescriptor identity defaults, and the
        // tolerances of the accepted static subset.
        private val CLIP_TRANSFORM_DEFAULTS = listOf(
            "scaleX" to 1.0,
            "scaleY" to 1.0,
            "translationX" to 0.0,
            "translationY" to 0.0,
            "rotation" to 0.0,
            "opacity" to 1.0,
            "anchorX" to 0.5,
            "anchorY" to 0.5,
        )

        /// Relative tolerance under which scaleX/scaleY count as one uniform scale.
        private const val CLIP_TRANSFORM_UNIFORM_SCALE_EPSILON = 1e-3

        /// |rotation| above this (radians) is a real rotation and fails closed.
        private const val CLIP_TRANSFORM_ROTATION_EPSILON_RADIANS = 1e-4

        /// Tolerance for opacity == 1.0 and anchorX/anchorY == 0.5.
        private const val CLIP_TRANSFORM_UNIT_EPSILON = 1e-3

        /// Scale == 1 / translation == 0 within this tolerance parses as no transform.
        private const val CLIP_TRANSFORM_IDENTITY_EPSILON = 1e-6

        /// Upper bound on the accepted uniform scale. The Universal Editor
        /// clamps its user scale to [1, 8] on top of a cover scale, so
        /// anything beyond this is not a product shape and would reduce the
        /// source crop to a handful of pixels.
        private const val MAX_CLIP_TRANSFORM_SCALE = 32.0

        /// Relative tolerance on requested-output vs draft-canvas aspect
        /// ratio for transformed clips (see the translation scaling above).
        private const val CLIP_TRANSFORM_ASPECT_TOLERANCE = 5e-3
    }
}
