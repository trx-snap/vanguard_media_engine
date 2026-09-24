package com.connects.vanguard_media_engine.duet

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.system.Os
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.export.AndroidAudioTrackSpec
import com.connects.vanguard_media_engine.export.AndroidExportRenderBackendSelector
import com.connects.vanguard_media_engine.export.AndroidTimelineAudioPass2Muxer
import com.connects.vanguard_media_engine.export.AndroidTimelineOverlayDescriptor
import com.connects.vanguard_media_engine.export.AndroidTimelineVideoEncoder
import com.connects.vanguard_media_engine.export.AndroidTimelineVideoPassEncoder
import com.connects.vanguard_media_engine.export.AndroidTimelineVulkanVideoEncoder
import com.connects.vanguard_media_engine.export.ExportRenderBackend
import com.connects.vanguard_media_engine.export.ExportRenderScope
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.min

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-SLICE-5B-A / 4B: Descriptor-bound Android offline Duet export session.
// ─────────────────────────────────────────────────────────────────────────────
//
// Claims:
//   - Synthetic route (no `segmentAssets`): descriptor-bound Android offline
//     video-only composited MP4; source video decode/encode path via
//     AndroidTimelineVideoEncoder; synthetic foreground geometry route via
//     AndroidDuetLayoutGeometry.
//   - Real-take route (Slice 4B, exactly one `segmentAssets` entry): source +
//     recorded segment composited by AndroidDuetOfflineCompositorVideoEncoder
//     (pip / splitTopBottom / splitLeftRight -- the latter honoring
//     layoutConfig.isSideSwapped and aspect-fitting both layers -- with
//     creator overlays above), then source + mic audio mixed/muxed by
//     AndroidTimelineAudioPass2Muxer.
//   - Real-take greenScreen route: a take recorded with
//     layoutConfig.isPreComposited == true already IS the final composited
//     picture (AndroidDuetPreviewCompositor draws the live preview scene into
//     the take encoder), so the video pass is a hardlink/copy of the segment
//     into the video temp followed by the same audio pass; the offline
//     AndroidDuetGreenScreenOfflineCompositorVideoEncoder is kept only for
//     older descriptors without that flag.
//   - Every native export failure is logged once as
//     ANDROID_DUET_EXPORT_ERROR code=<code> message=<message> (see postError)
//     so a physical run exposes the exact failure in logcat.
//   - Atomic final output (write to tmp, rename on success, delete on failure).
//
// Non-claims:
//   - No live camera, no ML/human matte, no iOS.
//   - No ConnectsApp/Universal Editor/upload/backend wiring.
//   - No rendered pixel assertion (synthetic foreground is magenta rectangle).
//   - No speed remap / audio time-stretch for real-take export.
//   - No low-end Android proof.

/**
 * Manages one descriptor-bound offline Duet export at a time.
 *
 * Only one export may be active concurrently. Concurrent calls receive an
 * `export_busy` error code and do not crash or corrupt state.
 *
 * Background work runs on a [ExecutorService] (single-thread). All callbacks
 * are posted back to [mainHandler] (main thread). [disposeAll] shuts down the
 * executor idempotently.
 */
class AndroidDuetExportSession(private val mainHandler: Handler) {

    // ── State ─────────────────────────────────────────────────────────────────

    private val busy = AtomicBoolean(false)
    @Volatile private var disposed = false
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "duet-export-bg").also { it.isDaemon = true }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * Thin entry point called by [AndroidDuetMethodHandler] with the raw [safeArgs]
     * map from Dart. All argument extraction and validation happen here, not in the
     * handler.
     *
     * @param safeArgs Raw method-channel args map (non-null; handler ensures this).
     * @param callback Called on the main thread with (resultMap?, errStr?).
     *                 errStr is encoded as "code|message" on failure.
     */
    @Suppress("UNCHECKED_CAST")
    fun startExportFromArgs(
        safeArgs: Map<String, Any?>,
        callback: (Map<String, Any?>?, String?) -> Unit,
    ) {
        // ── Disposed guard ────────────────────────────────────────────────────
        if (disposed) {
            postError(callback, "export_busy",
                "exportDuetComposition: export session has been disposed.")
            return
        }

        // ── Concurrency guard ─────────────────────────────────────────────────
        if (!busy.compareAndSet(false, true)) {
            postError(callback, "export_busy",
                "exportDuetComposition: another export is already active.")
            return
        }

        // ── Parse and validate (on caller's thread; cheap checks) ─────────────
        val descriptorMap = safeArgs["descriptor"] as? Map<String, Any?>
        val outputPath    = safeArgs["outputPath"] as? String
        val targetSizeMap = safeArgs["targetSize"] as? Map<String, Any?>
        val videoBitRate  = (safeArgs["videoBitRate"] as? Number)?.toInt() ?: 8_000_000
        // Slice 4B: top-level real-take segment list (absent/empty = synthetic route).
        val segmentAssetsRaw = safeArgs["segmentAssets"]

        val parseResult = parseAndValidate(
            descriptorMap, outputPath, targetSizeMap, videoBitRate, segmentAssetsRaw,
        )
        if (parseResult is ParseResult.Failure) {
            busy.set(false)
            postError(callback, parseResult.code, parseResult.message)
            return
        }
        val params = (parseResult as ParseResult.Success).params

        // ── Dispatch to background ────────────────────────────────────────────
        executor.submit {
            runExport(params, callback)
        }
    }

    /**
     * Shuts down the background executor idempotently. Marks this session as
     * disposed so no further exports can start. Clears busy so no pending
     * caller is permanently blocked.
     */
    fun disposeAll() {
        disposed = true
        busy.set(false)
        executor.shutdown()
    }

    // ── Internal: parsing ─────────────────────────────────────────────────────

    private data class ExportParams(
        val sourceFilePath: String,
        val trimStartSec: Double,
        val trimEndSec: Double,
        val outputPath: String,
        val targetWidth: Int,
        val targetHeight: Int,
        val videoBitRate: Int,
        val layoutMode: String,
        val foregroundTransform: NativeForegroundTransform?,
        val greenScreenBackground: AndroidDuetGreenScreenBackground,
        // Creator overlays parsed from Dart descriptor["overlays"]. Empty when absent.
        val creatorOverlays: List<AndroidTimelineOverlayDescriptor>,
        // Slice 4B: the single validated real-take segment path, or null for
        // the synthetic export route.
        val realSegmentPath: String?,
        // Slice 4B audio mix (descriptor fields; defaults 1.0/1.0/false/false).
        // Consumed only by the real-take route.
        val sourceAudioGain: Double,
        val micAudioGain: Double,
        val sourceAudioMuted: Boolean,
        val micAudioMuted: Boolean,
        // Slice 4B PiP placement inputs from layoutConfig (real-take route only).
        val pipNormalizedRect: PipNormalizedRect?,
        val pipAnchor: String?,
        // layoutConfig.isSideSwapped (Dart VGDuetLayoutConfig wire key). Only
        // meaningful for splitLeftRight: false = source left / camera right,
        // true = camera left / source right. Default false.
        val isSideSwapped: Boolean,
        // layoutConfig.isPreComposited: the recorded greenScreen take already
        // holds the final composited picture (see runRealTakeExport). Only
        // meaningful for greenScreen; absent/false selects the offline
        // compositor fallback. Default false.
        val isPreComposited: Boolean,
    )

    /** Normalized (0..1 canvas fraction) PiP camera rect from layoutConfig.pipNormalizedRect. */
    private data class PipNormalizedRect(
        val left: Double,
        val top: Double,
        val width: Double,
        val height: Double,
    )

    private sealed class ParseResult {
        data class Success(val params: ExportParams) : ParseResult()
        data class Failure(val code: String, val message: String) : ParseResult()
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseAndValidate(
        descriptorMap: Map<String, Any?>?,
        outputPath: String?,
        targetSizeMap: Map<String, Any?>?,
        videoBitRate: Int,
        segmentAssetsRaw: Any?,
    ): ParseResult {
        // top-level presence
        if (descriptorMap == null) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: 'descriptor' argument is missing.")
        }
        if (outputPath.isNullOrBlank()) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: 'outputPath' argument is missing or blank.")
        }
        if (targetSizeMap == null) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: 'targetSize' argument is missing.")
        }

        // target size
        val targetWidth  = (targetSizeMap["width"]  as? Number)?.toInt() ?: 0
        val targetHeight = (targetSizeMap["height"] as? Number)?.toInt() ?: 0
        if (targetWidth <= 0 || targetHeight <= 0) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: targetSize dimensions must be > 0 " +
                    "(got ${targetWidth}x${targetHeight}).")
        }

        // bit rate
        if (videoBitRate <= 0) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: videoBitRate must be > 0 (got $videoBitRate).")
        }

        // outputPath existence and parent-dir writability
        val outFile = File(outputPath)
        if (outFile.exists()) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: outputPath already exists: $outputPath")
        }
        val parentDir = outFile.parentFile
        if (parentDir != null && !parentDir.exists()) {
            parentDir.mkdirs()
        }
        if (parentDir == null || !parentDir.canWrite()) {
            return ParseResult.Failure("composition_failed",
                "exportDuetComposition: output parent directory is not writable: " +
                    "${parentDir?.absolutePath ?: "<null>"}")
        }

        // source
        val sourceMap      = descriptorMap["source"] as? Map<*, *>
        val sourceFilePath = (sourceMap?.get("filePath") as? String)?.trim() ?: ""
        if (sourceFilePath.isEmpty()) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: descriptor.source.filePath is missing or blank.")
        }
        val sourceFile = File(sourceFilePath)
        if (!sourceFile.exists() || !sourceFile.canRead()) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: source file does not exist or is not readable: " +
                    sourceFilePath)
        }

        // trim window
        val trimMap      = descriptorMap["trimWindow"] as? Map<*, *>
        val trimStartSec = (trimMap?.get("startSeconds") as? Number)?.toDouble() ?: 0.0
        val trimEndSec   = (trimMap?.get("endSeconds")   as? Number)?.toDouble() ?: -1.0
        if (trimEndSec <= trimStartSec) {
            return ParseResult.Failure("source_invalid",
                "exportDuetComposition: trimWindow.endSeconds ($trimEndSec) must be > " +
                    "startSeconds ($trimStartSec).")
        }

        // layout mode, optional foreground transform, and green-screen background
        val layoutMap     = descriptorMap["layoutConfig"] as? Map<*, *>
        val layoutMode    = (layoutMap?.get("mode") as? String) ?: "pip"
        val fgTransform   = parseForegroundTransform(layoutMap)
        val greenScreenBg = AndroidDuetGreenScreenBackground.parse(
            layoutMap?.get("greenScreenBackground") as? Map<*, *>
        )
        val isPreComposited = layoutMode == "greenScreen" &&
            (layoutMap?.get("isPreComposited") as? Boolean) == true

        // A pre-composited take already carries its (video / solid / image)
        // background baked in, so only the offline-compositor fallback is
        // limited to the source-video background.
        if (layoutMode == "greenScreen" && !isPreComposited &&
            greenScreenBg.type != AndroidDuetGreenScreenBackgroundType.VIDEO
        ) {
            return ParseResult.Failure(
                "unsupported_export_feature",
                "exportDuetComposition: static/image green-screen backgrounds are preview-only for now; offline export requires a future compositor."
            )
        }

        // ── Audio mix fields (Slice 4B) ──────────────────────────────────────
        // Defaults match the Dart VGDuetCompositionDescriptor.fromMap contract
        // (gain 1.0, unmuted). Non-finite gains degrade to 0.0 so they can
        // never reach the muxer.
        val rawSourceAudioGain = (descriptorMap["sourceAudioGain"] as? Number)?.toDouble() ?: 1.0
        val rawMicAudioGain    = (descriptorMap["micAudioGain"]    as? Number)?.toDouble() ?: 1.0
        val sourceAudioGain  = if (rawSourceAudioGain.isFinite()) rawSourceAudioGain else 0.0
        val micAudioGain     = if (rawMicAudioGain.isFinite())    rawMicAudioGain    else 0.0
        val sourceAudioMuted = descriptorMap["sourceAudioMuted"] as? Boolean ?: false
        val micAudioMuted    = descriptorMap["micAudioMuted"]    as? Boolean ?: false

        // ── PiP placement inputs (Slice 4B; real-take route only) ────────────
        val pipNormalizedRect = parsePipNormalizedRect(layoutMap?.get("pipNormalizedRect") as? Map<*, *>)
        val pipAnchor         = layoutMap?.get("pipAnchor") as? String

        // ── splitLeftRight side swap (real-take route only) ──────────────────
        val isSideSwapped = layoutMap?.get("isSideSwapped") as? Boolean ?: false

        // ── Real-take segmentAssets (Slice 4B) ───────────────────────────────
        // Top-level MethodChannel arg. Absent/null/empty preserves the synthetic
        // export route exactly. A non-empty list must contain exactly one
        // non-blank readable path, and the real-take route supports only
        // pip / splitTopBottom (unswapped) / splitLeftRight (isSideSwapped
        // honored) at initialSpeed 1.0. Wording mirrors
        // ios/Classes/VGDuetExportSession.swift.
        var realSegmentPath: String? = null
        if (segmentAssetsRaw != null) {
            val segmentAssets = segmentAssetsRaw as? List<*>
                ?: return ParseResult.Failure("source_invalid",
                    "exportDuetComposition: segmentAssets must be a list of file paths.")
            if (segmentAssets.isNotEmpty()) {
                if (segmentAssets.size != 1) {
                    return ParseResult.Failure("unsupported_export_feature",
                        "exportDuetComposition: multiple segmentAssets are not supported in this slice; " +
                            "exactly one real-take segment is required.")
                }
                val candidatePath = (segmentAssets[0] as? String)?.trim() ?: ""
                if (candidatePath.isEmpty()) {
                    return ParseResult.Failure("source_invalid",
                        "exportDuetComposition: segmentAssets[0] is empty.")
                }
                val segmentFile = File(candidatePath)
                if (!segmentFile.isFile || !segmentFile.canRead()) {
                    return ParseResult.Failure("source_invalid",
                        "exportDuetComposition: segment file is missing or not readable: $candidatePath")
                }
                if (layoutMode != "pip" && layoutMode != "splitTopBottom" &&
                    layoutMode != "splitLeftRight" && layoutMode != "greenScreen"
                ) {
                    return ParseResult.Failure("unsupported_export_feature",
                        "exportDuetComposition: real-take export only supports layoutConfig.mode " +
                            "'pip', 'splitTopBottom', 'splitLeftRight', or 'greenScreen'; got $layoutMode.")
                }
                val initialSpeed = (descriptorMap["initialSpeed"] as? Number)?.toDouble() ?: 1.0
                if (!initialSpeed.isFinite() || abs(initialSpeed - 1.0) >= 0.0001) {
                    return ParseResult.Failure("unsupported_export_feature",
                        "exportDuetComposition: real-take export requires initialSpeed 1.0 " +
                            "(got $initialSpeed); source video speed remapping and source audio " +
                            "time-stretching are not supported for offline export in this slice.")
                }
                if (layoutMode == "splitTopBottom" &&
                    (layoutMap?.get("isTopBottomSwapped") as? Boolean) == true
                ) {
                    return ParseResult.Failure("unsupported_export_feature",
                        "exportDuetComposition: isTopBottomSwapped is not supported by the " +
                            "export compositor in this slice.")
                }
                realSegmentPath = candidatePath
            }
        }

        // ── Creator overlays (optional; missing key = empty list) ─────────────
        // Rotation in AndroidTimelineOverlayDescriptor is radians (parsed from
        // the Dart VGOverlayDescriptor wire format which already uses radians).
        // parseList validates all fields; any failure fails the export closed.
        val rawOverlaysEntry = descriptorMap["overlays"]
        val creatorOverlays: List<AndroidTimelineOverlayDescriptor> = if (rawOverlaysEntry == null) {
            emptyList()
        } else {
            val rawList = rawOverlaysEntry as? List<*>
                ?: return ParseResult.Failure(
                    "source_invalid",
                    "exportDuetComposition: descriptor.overlays must be a list.",
                )
            when (val overlayParseResult = AndroidTimelineOverlayDescriptor.parseList(rawList)) {
                is AndroidTimelineOverlayDescriptor.ParseResult.Success -> overlayParseResult.overlays
                is AndroidTimelineOverlayDescriptor.ParseResult.Failure -> return ParseResult.Failure(
                    overlayParseResult.code.lowercase(),
                    "exportDuetComposition: ${overlayParseResult.message}",
                )
            }
        }

        return ParseResult.Success(
            ExportParams(
                sourceFilePath         = sourceFilePath,
                trimStartSec           = trimStartSec,
                trimEndSec             = trimEndSec,
                outputPath             = outputPath,
                targetWidth            = targetWidth,
                targetHeight           = targetHeight,
                videoBitRate           = videoBitRate,
                layoutMode             = layoutMode,
                foregroundTransform    = fgTransform,
                greenScreenBackground  = greenScreenBg,
                creatorOverlays        = creatorOverlays,
                realSegmentPath        = realSegmentPath,
                sourceAudioGain        = sourceAudioGain,
                micAudioGain           = micAudioGain,
                sourceAudioMuted       = sourceAudioMuted,
                micAudioMuted          = micAudioMuted,
                pipNormalizedRect      = pipNormalizedRect,
                pipAnchor              = pipAnchor,
                isSideSwapped          = isSideSwapped,
                isPreComposited        = isPreComposited,
            )
        )
    }

    /**
     * Parses `layoutConfig.pipNormalizedRect` ({left, top, width, height} as
     * 0..1 canvas fractions). Returns null when absent, malformed, non-finite,
     * or non-positive in size, so the caller falls back to the default PiP
     * placement instead of rendering a degenerate rect.
     */
    private fun parsePipNormalizedRect(rectMap: Map<*, *>?): PipNormalizedRect? {
        if (rectMap == null) return null
        val left   = (rectMap["left"]   as? Number)?.toDouble() ?: return null
        val top    = (rectMap["top"]    as? Number)?.toDouble() ?: return null
        val width  = (rectMap["width"]  as? Number)?.toDouble() ?: return null
        val height = (rectMap["height"] as? Number)?.toDouble() ?: return null
        if (!left.isFinite() || !top.isFinite() || !width.isFinite() || !height.isFinite()) return null
        if (width <= 0.0 || height <= 0.0) return null
        return PipNormalizedRect(left = left, top = top, width = width, height = height)
    }

    /**
     * Parses a [NativeForegroundTransform] from `layoutConfig`'s
     * `foregroundTransform` sub-map. Missing or wrong-type `scale` defaults
     * to `1.0` (matching the Dart `VGDuetForegroundTransform.fromMap`
     * contract); the resulting scale must still be finite and positive, or
     * null is returned (full-canvas identity). Offset/anchor components
     * default per-field (offset -> 0.0, anchor -> 0.5) on missing,
     * wrong-type, or non-finite values. `rotationDegrees` defaults to `0.0`
     * on missing, wrong-type, or non-finite values.
     */
    @Suppress("UNCHECKED_CAST")
    private fun parseForegroundTransform(layoutMap: Map<*, *>?): NativeForegroundTransform? {
        val fgMap  = layoutMap?.get("foregroundTransform") as? Map<*, *> ?: return null
        val scale  = (fgMap["scale"] as? Number)?.toDouble() ?: 1.0
        if (!scale.isFinite() || scale <= 0.0) return null
        val offsetMap  = fgMap["offset"] as? Map<*, *>
        val rawOffsetX = (offsetMap?.get("x") as? Number)?.toDouble() ?: Double.NaN
        val rawOffsetY = (offsetMap?.get("y") as? Number)?.toDouble() ?: Double.NaN
        val anchorMap  = fgMap["anchor"] as? Map<*, *>
        val rawAnchorX = (anchorMap?.get("x") as? Number)?.toDouble() ?: Double.NaN
        val rawAnchorY = (anchorMap?.get("y") as? Number)?.toDouble() ?: Double.NaN
        val offsetX = if (rawOffsetX.isFinite()) rawOffsetX else 0.0
        val offsetY = if (rawOffsetY.isFinite()) rawOffsetY else 0.0
        val anchorX = if (rawAnchorX.isFinite()) rawAnchorX else 0.5
        val anchorY = if (rawAnchorY.isFinite()) rawAnchorY else 0.5
        val rawRotation = (fgMap["rotationDegrees"] as? Number)?.toDouble() ?: 0.0
        val rotationDegrees = if (rawRotation.isFinite()) rawRotation else 0.0
        return NativeForegroundTransform(
            scale   = scale,
            offsetX = offsetX,
            offsetY = offsetY,
            anchorX = anchorX,
            anchorY = anchorY,
            rotationDegrees = rotationDegrees,
        )
    }

    // ── Internal: encode ──────────────────────────────────────────────────────

    private fun runExport(
        params: ExportParams,
        callback: (Map<String, Any?>?, String?) -> Unit,
    ) {
        // Slice 4B: a validated real-take segment routes to the offline
        // compositor + audio pass; everything below is the unchanged
        // synthetic magenta-overlay route.
        val realSegmentPath = params.realSegmentPath
        if (realSegmentPath != null) {
            runRealTakeExport(params, realSegmentPath, callback)
            return
        }

        val tmpPath = params.outputPath + ".tmp"
        val tmpFile = File(tmpPath)
        var overlayFile: File? = null
        try {
            // ── Probe source metadata ─────────────────────────────────────────
            val sourceDurationUs  = probeSourceDurationUs(params.sourceFilePath)
            val sourceDurationSec = sourceDurationUs / 1_000_000.0

            val effectiveTrimEndSec =
                if (params.trimEndSec > 0.0 && params.trimEndSec <= sourceDurationSec) {
                    params.trimEndSec
                } else {
                    sourceDurationSec
                }
            val trimDurationSec = effectiveTrimEndSec - params.trimStartSec
            if (trimDurationSec <= 0.0) {
                throw ExportException("source_invalid",
                    "exportDuetComposition: trim window produces zero-duration clip.")
            }

            // Probe source video dimensions and rotation for ClipInput.
            val (srcWidth, srcHeight, srcRotation) =
                probeSourceDimensionsAndRotation(params.sourceFilePath)

            // ── Compute foreground overlay rect ───────────────────────────────
            val canvasW     = params.targetWidth.toDouble()
            val canvasH     = params.targetHeight.toDouble()
            val layoutRects = computeLayoutRects(
                layoutMode = params.layoutMode,
                canvasW    = canvasW,
                canvasH    = canvasH,
                transform  = params.foregroundTransform,
            )
            val fgRect = layoutRects.camera

            // ── Generate rect-sized synthetic PNG ─────────────────────────────
            // PNG is exactly fgRect.width × fgRect.height (not full-canvas).
            // The overlay descriptor then places it at (fgRect.left, fgRect.top).
            // This avoids double-applying the geometry.
            val overlayDir = tmpFile.parentFile
                ?: File(params.outputPath).parentFile
                ?: File(".")
            overlayFile = generateSyntheticOverlay(
                dir         = overlayDir,
                bmpWidth    = maxOf(1, fgRect.width.toInt()),
                bmpHeight   = maxOf(1, fgRect.height.toInt()),
            )

            // ── Build STICKER overlay descriptor ─────────────────────────────
            // Places the rect-sized PNG with exact dimensions, sized fgRect.width
            // x fgRect.height. Rotation carries the parsed foreground transform's
            // rotationDegrees (already validated finite, default 0.0) so exported
            // foreground rotation matches the live preview. The timeline overlay
            // renderer rotates a sticker around its own bounding-box center, but
            // the preview compositor rotates the foreground around
            // foregroundTransform.anchor. To keep anchor-pivot parity for this
            // synthetic export path, the overlay's placement (translationX/Y) is
            // compensated below: fgRect's own center is rotated around the anchor
            // pivot by rotationDegrees, and the overlay is placed so its
            // (unrotated) bounding-box center lands on that rotated point. For a
            // center anchor or zero rotation this reduces exactly to
            // fgRect.left/top.
            val fgRotationDegrees = params.foregroundTransform?.rotationDegrees ?: 0.0
            val fgAnchorX = params.foregroundTransform?.anchorX ?: 0.5
            val fgAnchorY = params.foregroundTransform?.anchorY ?: 0.5
            val overlayOrigin = computeAnchorPivotOverlayOrigin(
                fgRect          = fgRect,
                anchorX         = fgAnchorX,
                anchorY         = fgAnchorY,
                rotationDegrees = fgRotationDegrees,
            )
            // AndroidTimelineOverlayDescriptor.rotation is radians.
            // fgRotationDegrees is in degrees; convert to radians here.
            val syntheticForegroundOverlay = AndroidTimelineOverlayDescriptor(
                overlayId        = "duet_synthetic_fg",
                type             = AndroidTimelineOverlayDescriptor.Type.STICKER,
                startTimeSeconds = 0.0,
                durationSeconds  = trimDurationSec,
                translationX     = overlayOrigin.first,
                translationY     = overlayOrigin.second,
                width            = fgRect.width,
                height           = fgRect.height,
                rotation         = Math.toRadians(fgRotationDegrees),
                scale            = 1.0,
                opacity          = 1.0,
                zIndex           = 1,
                assetPath        = overlayFile.absolutePath,
            )

            // ── Apply z-order policy to creator overlays ──────────────────────
            // Synthetic foreground is zIndex=1. Creator overlays must render
            // above it: effectiveZIndex = max(2, userZIndex + 2), Int-overflow-safe.
            // Creator overlay rotation is already in radians from Dart/VGOverlayDescriptor.
            val adjustedCreatorOverlays = params.creatorOverlays.map { overlay ->
                val safeZIndex = if (overlay.zIndex > Int.MAX_VALUE - 2) Int.MAX_VALUE
                                 else maxOf(2, overlay.zIndex + 2)
                overlay.copy(zIndex = safeZIndex)
            }

            // Combined overlay list: synthetic foreground first, then creator overlays.
            val allOverlays = listOf(syntheticForegroundOverlay) + adjustedCreatorOverlays

            // ── Encode via selector-routed backend (clips + overlay) ──────────
            val fps = 30
            val diagnostics = VanguardDiagnostics()
            val lifecycleObserver = VanguardLifecycleObserver(diagnostics)
            val nativeBridge = VanguardNativeBridge(
                lifecycleObserver = lifecycleObserver,
                diagnostics       = diagnostics,
                codecAdapter      = null,
            )

            val clip = AndroidTimelineVideoEncoder.ClipInput(
                sourcePath       = params.sourceFilePath,
                trimStartSeconds = params.trimStartSec,
                trimEndSeconds   = effectiveTrimEndSec,
                decodedWidth     = srcWidth,
                decodedHeight    = srcHeight,
                rotationDegrees  = srcRotation,
                mediaKind        = "video",
            )

            val exportScope = ExportRenderScope(
                clips           = listOf(clip),
                requestedWidth  = params.targetWidth,
                requestedHeight = params.targetHeight,
                transitions     = emptyList(),
                overlays        = allOverlays,
            )
            val backendDecision = AndroidExportRenderBackendSelector().select(
                exportScope,
                nativeBridge = nativeBridge,
            )
            if (backendDecision.actualBackend == ExportRenderBackend.UNAVAILABLE) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: export backend unavailable (${backendDecision.reason})")
            }

            fun buildEncoder(backend: ExportRenderBackend): AndroidTimelineVideoPassEncoder {
                return if (backend == ExportRenderBackend.VULKAN) {
                    AndroidTimelineVulkanVideoEncoder(
                        outputPath   = tmpPath,
                        width        = params.targetWidth,
                        height       = params.targetHeight,
                        fps          = fps,
                        bitrateBps   = params.videoBitRate,
                        nativeBridge = nativeBridge,
                    )
                } else {
                    AndroidTimelineVideoEncoder(
                        outputPath   = tmpPath,
                        width        = params.targetWidth,
                        height       = params.targetHeight,
                        fps          = fps,
                        bitrateBps   = params.videoBitRate,
                        nativeBridge = nativeBridge,
                    )
                }
            }

            var effectiveBackend = backendDecision.actualBackend
            var renderBackendFallbackReason: String? = null
            var encodeResult = buildEncoder(effectiveBackend).encode(
                clips       = listOf(clip),
                transitions = emptyList(),
                overlays    = allOverlays,
                onProgress  = null,
            )

            if (!encodeResult.success && effectiveBackend == ExportRenderBackend.VULKAN &&
                !exportScope.requiresVulkan && encodeResult.reason != "cancelled"
            ) {
                renderBackendFallbackReason = encodeResult.reason
                try { tmpFile.takeIf { it.exists() }?.delete() } catch (_: Exception) {}
                effectiveBackend = ExportRenderBackend.GLES
                encodeResult = buildEncoder(effectiveBackend).encode(
                    clips       = listOf(clip),
                    transitions = emptyList(),
                    overlays    = allOverlays,
                    onProgress  = null,
                )
            }

            if (!encodeResult.success) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: encoder returned failure: ${encodeResult.reason}")
            }
            if (encodeResult.overlayFrameCount <= 0) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: overlay route rendered no frames " +
                        "(overlayFrameCount=${encodeResult.overlayFrameCount}); " +
                        "synthetic foreground geometry route claim cannot be made.")
            }

            // ── Atomic rename ─────────────────────────────────────────────────
            val outFile = File(params.outputPath)
            if (!tmpFile.renameTo(outFile)) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: failed to rename tmp to final output.")
            }

            val durationMs    = (trimDurationSec * 1000.0).toLong().coerceAtLeast(1L)
            val fileSizeBytes = outFile.length()

            postSuccess(callback, mapOf(
                "outputPath"    to params.outputPath,
                "durationMs"    to durationMs,
                "fileSizeBytes" to fileSizeBytes,
                "renderBackend" to effectiveBackend.wireName(),
                "preferredRenderBackend" to backendDecision.preferredBackend.wireName(),
                "renderBackendReason" to backendDecision.reason,
                "renderBackendFallbackReason" to renderBackendFallbackReason,
                "vulkanSupported" to backendDecision.vulkanSupported,
                "glesSupported" to backendDecision.glesSupported,
            ))
        } catch (ex: ExportException) {
            safeDelete(tmpFile)
            postError(callback, ex.code, ex.message ?: "exportDuetComposition failed.")
        } catch (ex: Exception) {
            safeDelete(tmpFile)
            postError(callback, "composition_failed",
                "exportDuetComposition: unexpected error: ${ex.message}")
        } finally {
            overlayFile?.let { safeDelete(it) }
            busy.set(false)
        }
    }

    // ── Internal: real-take export (Slice 4B) ─────────────────────────────────

    /**
     * Real-take route: composites the trimmed source and the recorded
     * [segmentPath] into `outputPath.video.tmp` via
     * [AndroidDuetOfflineCompositorVideoEncoder] (or the offline green-screen
     * compositor), then runs the existing audio pass-2 muxer (source + mic
     * mix, or a video-only remux when both are muted/silent) into
     * `outputPath.tmp`, and renames that to `outputPath` only after success.
     * A pre-composited greenScreen take (layoutConfig.isPreComposited) skips
     * the video composite entirely: the segment is staged into the video
     * temp by hardlink/copy ([stagePreCompositedSegment]) and goes straight
     * to the audio pass. Every temp is deleted on failure; the video/audio
     * temps are deleted on success as well. The original segment file is
     * never handed to a helper that could delete it and is never deleted
     * here.
     */
    private fun runRealTakeExport(
        params: ExportParams,
        segmentPath: String,
        callback: (Map<String, Any?>?, String?) -> Unit,
    ) {
        val videoTmpPath = params.outputPath + ".video.tmp"
        val audioTmpPath = params.outputPath + ".audio.tmp"
        val finalTmpPath = params.outputPath + ".tmp"
        val videoTmpFile = File(videoTmpPath)
        val audioTmpFile = File(audioTmpPath)
        val finalTmpFile = File(finalTmpPath)
        var succeeded = false
        try {
            // Never inherit stale temps from an earlier aborted run.
            safeDelete(videoTmpFile)
            safeDelete(audioTmpFile)
            safeDelete(finalTmpFile)

            // ── Probe durations; export = min(trim window, recorded segment) ──
            val sourceDurationSec = probeSourceDurationUs(params.sourceFilePath) / 1_000_000.0
            val effectiveTrimEndSec =
                if (params.trimEndSec > 0.0 && params.trimEndSec <= sourceDurationSec) {
                    params.trimEndSec
                } else {
                    sourceDurationSec
                }
            val trimDurationSec = effectiveTrimEndSec - params.trimStartSec
            if (trimDurationSec <= 0.0) {
                throw ExportException("source_invalid",
                    "exportDuetComposition: trim window produces zero-duration clip.")
            }
            val segmentDurationSec = probeSourceDurationUs(segmentPath) / 1_000_000.0
            if (!segmentDurationSec.isFinite() || segmentDurationSec <= 0.0) {
                throw ExportException("source_invalid",
                    "exportDuetComposition: recorded segment has no readable duration: $segmentPath")
            }
            val effectiveExportDurationSec = min(trimDurationSec, segmentDurationSec)
            if (!effectiveExportDurationSec.isFinite() || effectiveExportDurationSec <= 0.0) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: effective real-take export duration is zero " +
                        "(trim ${trimDurationSec}s, segment ${segmentDurationSec}s).")
            }

            val (srcWidth, srcHeight, srcRotation) = probeSourceDimensionsAndRotation(params.sourceFilePath)
            val (segWidth, segHeight, segRotation) = probeSourceDimensionsAndRotation(segmentPath)
            val srcRotationNormalized = normalizeRotationDegrees(srcRotation)
            val segRotationNormalized = normalizeRotationDegrees(segRotation)

            // ── Layout rects for the real-take compositor ─────────────────────
            val canvasW = params.targetWidth.toDouble()
            val canvasH = params.targetHeight.toDouble()
            val layoutRects = computeRealTakeLayoutRects(
                params, canvasW, canvasH, segWidth, segHeight, segRotationNormalized,
            )

            // ── Creator overlays: same z-order policy as the synthetic route ──
            // The composited dual-video frame is the base; creator overlays
            // render above it with effectiveZIndex = max(2, userZIndex + 2),
            // Int-overflow-safe. Rotation is already radians from Dart.
            val adjustedCreatorOverlays = params.creatorOverlays.map { overlay ->
                val safeZIndex = if (overlay.zIndex > Int.MAX_VALUE - 2) Int.MAX_VALUE
                                 else maxOf(2, overlay.zIndex + 2)
                overlay.copy(zIndex = safeZIndex)
            }

            // ── Pass 1: video composite ───────────────────────────────────────
            //
            // layoutMode == "greenScreen" with isPreComposited: the take is
            // already the final composited picture (live preview scene drawn
            // into the take encoder), so it is staged as the video temp
            // without decoding or re-encoding a single frame.
            // layoutMode == "greenScreen" without the flag (older descriptors)
            // routes to the sibling offline compositor (ML Kit CPU
            // SelfieSegmenter, source-video background). All other real-take
            // modes (pip, splitTopBottom, splitLeftRight) go through the
            // existing AndroidDuetOfflineCompositorVideoEncoder; their
            // PiP/Split behavior is NOT changed.
            val preComposited = params.layoutMode == "greenScreen" && params.isPreComposited
            if (preComposited) {
                val staged = stagePreCompositedSegment(segmentPath, videoTmpFile)
                Log.i(
                    TAG,
                    "ANDROID_DUET_EXPORT_PRECOMPOSITED_BYPASS segment=${segWidth}x$segHeight rot=$segRotationNormalized " +
                        "segmentSec=${"%.3f".format(segmentDurationSec)} exportSec=${"%.3f".format(effectiveExportDurationSec)} " +
                        "target=${params.targetWidth}x${params.targetHeight} staged=$staged bytes=${videoTmpFile.length()}",
                )
            } else if (params.layoutMode == "greenScreen") {
                // Green-screen compositor: source video background, camera foreground
                // keyed by ML Kit CPU SelfieSegmenter, composited in cameraRect.
                val gsEncoder = AndroidDuetGreenScreenOfflineCompositorVideoEncoder(
                    outputPath = videoTmpPath,
                    width      = params.targetWidth,
                    height     = params.targetHeight,
                    fps        = REAL_TAKE_FPS,
                    bitrateBps = params.videoBitRate,
                )
                val gsResult = gsEncoder.encode(
                    source = AndroidDuetGreenScreenOfflineCompositorVideoEncoder.VideoInput(
                        label              = "source",
                        sourcePath         = params.sourceFilePath,
                        startOffsetSeconds = params.trimStartSec,
                        rotationDegrees    = srcRotationNormalized,
                        hintWidth          = srcWidth,
                        hintHeight         = srcHeight,
                    ),
                    sourceRect = layoutRects.source,
                    camera = AndroidDuetGreenScreenOfflineCompositorVideoEncoder.VideoInput(
                        label              = "camera",
                        sourcePath         = segmentPath,
                        startOffsetSeconds = 0.0,
                        rotationDegrees    = segRotationNormalized,
                        hintWidth          = segWidth,
                        hintHeight         = segHeight,
                    ),
                    cameraRect      = layoutRects.camera,
                    durationSeconds = effectiveExportDurationSec,
                    // Defect 1 fix: pass foreground free-rotation so the rotated-quad
                    // blend path matches live preview.  Zero/null → identity (no rotation).
                    foregroundRotationDegrees = params.foregroundTransform?.rotationDegrees ?: 0.0,
                    foregroundAnchorX         = params.foregroundTransform?.anchorX ?: 0.5,
                    foregroundAnchorY         = params.foregroundTransform?.anchorY ?: 0.5,
                )
                if (!gsResult.success) {
                    throw ExportException("composition_failed",
                        "exportDuetComposition: green-screen video pass failed: ${gsResult.reason}")
                }
            } else {
                val diagnostics = VanguardDiagnostics()
                val lifecycleObserver = VanguardLifecycleObserver(diagnostics)
                val nativeBridge = VanguardNativeBridge(
                    lifecycleObserver = lifecycleObserver,
                    diagnostics       = diagnostics,
                    codecAdapter      = null,
                )
                val encoder = AndroidDuetOfflineCompositorVideoEncoder(
                    outputPath   = videoTmpPath,
                    width        = params.targetWidth,
                    height       = params.targetHeight,
                    fps          = REAL_TAKE_FPS,
                    bitrateBps   = params.videoBitRate,
                    nativeBridge = nativeBridge,
                )
                val isSplitLeftRight = params.layoutMode == "splitLeftRight"
                val layerScaleMode = if (isSplitLeftRight) {
                    AndroidDuetLayerScaleMode.ASPECT_FIT
                } else {
                    AndroidDuetLayerScaleMode.ASPECT_FILL
                }
                val encodeResult = encoder.encode(
                    source = AndroidDuetOfflineCompositorVideoEncoder.VideoInput(
                        label              = "source",
                        sourcePath         = params.sourceFilePath,
                        startOffsetSeconds = params.trimStartSec,
                        rotationDegrees    = srcRotationNormalized,
                        hintWidth          = srcWidth,
                        hintHeight         = srcHeight,
                    ),
                    sourceRect = layoutRects.source,
                    camera = AndroidDuetOfflineCompositorVideoEncoder.VideoInput(
                        label              = "camera",
                        sourcePath         = segmentPath,
                        startOffsetSeconds = 0.0,
                        rotationDegrees    = segRotationNormalized,
                        hintWidth          = segWidth,
                        hintHeight         = segHeight,
                    ),
                    cameraRect      = layoutRects.camera,
                    durationSeconds = effectiveExportDurationSec,
                    overlays        = adjustedCreatorOverlays,
                    sourceScaleMode = layerScaleMode,
                    cameraScaleMode = layerScaleMode,
                )
                if (!encodeResult.success) {
                    throw ExportException("composition_failed",
                        "exportDuetComposition: real-take video pass failed: ${encodeResult.reason}")
                }
            }
            if (!videoTmpFile.exists() || videoTmpFile.length() <= 0L) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: real-take video pass produced no output.")
            }

            // ── Pass 2: audio mix / mux ───────────────────────────────────────
            // The mic lane is read from the staged copy on the pre-composited
            // route (same bytes as the segment) so the original take file is
            // never handed to any helper.
            val micAudioPath = if (preComposited) videoTmpPath else segmentPath
            val audioSpecs = buildRealTakeAudioSpecs(params, micAudioPath, effectiveExportDurationSec)
            val audioFailure = AndroidTimelineAudioPass2Muxer(context = null).run(
                specs         = audioSpecs,
                videoTempPath = videoTmpPath,
                audioTempPath = audioTmpPath,
                finalTmpPath  = finalTmpPath,
            )
            if (audioFailure != null) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: real-take audio pass failed: $audioFailure")
            }
            if (!finalTmpFile.exists() || finalTmpFile.length() <= 0L) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: final output missing or empty after audio pass.")
            }

            // ── Atomic rename ─────────────────────────────────────────────────
            val outFile = File(params.outputPath)
            if (!finalTmpFile.renameTo(outFile)) {
                throw ExportException("composition_failed",
                    "exportDuetComposition: failed to rename tmp to final output.")
            }
            succeeded = true

            val durationMs    = (effectiveExportDurationSec * 1000.0).toLong().coerceAtLeast(1L)
            val fileSizeBytes = outFile.length()

            postSuccess(callback, mapOf(
                "outputPath"    to params.outputPath,
                "durationMs"    to durationMs,
                "fileSizeBytes" to fileSizeBytes,
                "renderBackend" to REAL_TAKE_RENDER_BACKEND,
                "preferredRenderBackend" to REAL_TAKE_RENDER_BACKEND,
                "renderBackendReason" to
                    if (preComposited) "duet_real_take_precomposited_remux" else "duet_real_take_offline_compositor",
                "renderBackendFallbackReason" to null,
                "glesSupported" to true,
            ))
        } catch (ex: ExportException) {
            postError(callback, ex.code, ex.message ?: "exportDuetComposition failed.")
        } catch (ex: Exception) {
            postError(callback, "composition_failed",
                "exportDuetComposition: unexpected error: ${ex.message}")
        } finally {
            safeDelete(videoTmpFile)
            safeDelete(audioTmpFile)
            if (!succeeded) safeDelete(finalTmpFile)
            busy.set(false)
        }
    }

    /**
     * Stages a pre-composited greenScreen take at [videoTmpFile] for the audio
     * pass: a hardlink when the filesystem allows it (same volume, no bytes
     * copied), else a full copy. Then validates the staged file is non-empty,
     * byte-for-byte the segment's size, and carries a readable video track.
     * Only ever reads [segmentPath]; the original take file is never moved,
     * truncated or deleted (the caller's `finally` deletes the staged temp,
     * which for a hardlink only drops that directory entry). Returns the
     * staging method used, for the structured log.
     */
    private fun stagePreCompositedSegment(segmentPath: String, videoTmpFile: File): String {
        val segmentFile = File(segmentPath)
        val segmentBytes = segmentFile.length()
        if (!segmentFile.isFile || segmentBytes <= 0L) {
            throw ExportException("source_invalid",
                "exportDuetComposition: pre-composited segment is missing or empty: $segmentPath")
        }
        safeDelete(videoTmpFile)
        var method = "hardlink"
        try {
            Os.link(segmentFile.absolutePath, videoTmpFile.absolutePath)
        } catch (t: Throwable) {
            // Cross-volume, unsupported filesystem or permission: copy instead.
            safeDelete(videoTmpFile)
            method = "copy"
            try {
                segmentFile.copyTo(videoTmpFile, overwrite = true)
            } catch (copyError: Throwable) {
                safeDelete(videoTmpFile)
                throw ExportException("composition_failed",
                    "exportDuetComposition: could not stage the pre-composited segment " +
                        "(hardlink: ${t.message}; copy: ${copyError.message}).")
            }
        }
        val stagedBytes = videoTmpFile.length()
        if (!videoTmpFile.isFile || stagedBytes <= 0L || stagedBytes != segmentBytes) {
            safeDelete(videoTmpFile)
            throw ExportException("composition_failed",
                "exportDuetComposition: staged pre-composited segment is invalid " +
                    "($stagedBytes bytes staged, $segmentBytes expected, via $method).")
        }
        if (!hasReadableVideoTrack(videoTmpFile.absolutePath)) {
            safeDelete(videoTmpFile)
            throw ExportException("composition_failed",
                "exportDuetComposition: staged pre-composited segment has no readable video track.")
        }
        return method
    }

    /** True when [path] opens in MediaExtractor and exposes at least one `video/` track. */
    private fun hasReadableVideoTrack(path: String): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            (0 until extractor.trackCount).any { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            }
        } catch (t: Throwable) {
            Log.w(TAG, "pre-composited segment probe failed: ${t.javaClass.simpleName}: ${t.message}")
            false
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }
    }

    /**
     * Real-take layout: splitTopBottom is the unswapped 50/50 vertical split
     * (swap was rejected at parse time); splitLeftRight is the 50/50
     * horizontal split with `layoutConfig.isSideSwapped` honored (source
     * left / camera right by default, camera left / source right when
     * swapped -- AndroidDuetLayoutGeometry.splitLeftRight); pip is a
     * full-canvas source with the camera at `layoutConfig.pipNormalizedRect`
     * when present and positive, else the conservative anchored default.
     * Valid Dart rects are preserved as-is (the compositor's scissor clips
     * any overflow).
     */
    private fun computeRealTakeLayoutRects(
        params: ExportParams,
        canvasW: Double,
        canvasH: Double,
        segWidth: Int,
        segHeight: Int,
        segRotation: Int,
    ): VGDuetLayoutRects {
        if (params.layoutMode == "splitTopBottom") {
            return AndroidDuetLayoutGeometry.splitTopBottom(canvasW, canvasH, false)
        }
        if (params.layoutMode == "splitLeftRight") {
            return AndroidDuetLayoutGeometry.splitLeftRight(canvasW, canvasH, params.isSideSwapped)
        }
        if (params.layoutMode == "greenScreen") {
            // Source rect = full canvas (background video fills canvas).
            // Camera rect = transform-derived overlay placement for the keyed foreground.
            return AndroidDuetLayoutGeometry.greenScreen(canvasW, canvasH, params.foregroundTransform)
        }
        val source = AndroidDuetLayoutGeometry.pipSourceRect(canvasW, canvasH)
        val normalized = params.pipNormalizedRect
        if (normalized != null) {
            val rect = AndroidDuetLayoutGeometry.pipCameraRect(
                canvasW, canvasH,
                normalized.left, normalized.top, normalized.width, normalized.height,
            )
            if (rect.width > 0.0 && rect.height > 0.0) {
                return VGDuetLayoutRects(source = source, camera = rect)
            }
        }
        return VGDuetLayoutRects(
            source = source,
            camera = defaultPipCameraRect(canvasW, canvasH, params.pipAnchor, segWidth, segHeight, segRotation),
        )
    }

    /**
     * Default PiP camera rect matching the iOS real-take fallback intent:
     * about 35% of the canvas width, a small margin, anchored per
     * `layoutConfig.pipAnchor` (default bottomRight), with height following
     * the recorded segment's upright aspect (9:16 when unknown) and scaled
     * down uniformly if it would not fit the canvas.
     */
    private fun defaultPipCameraRect(
        canvasW: Double,
        canvasH: Double,
        pipAnchor: String?,
        segWidth: Int,
        segHeight: Int,
        segRotation: Int,
    ): VGDuetPixelRect {
        val margin = canvasW * DEFAULT_PIP_MARGIN_FRACTION
        var pipW = canvasW * DEFAULT_PIP_WIDTH_FRACTION
        val aspectHOverW = if (segWidth > 0 && segHeight > 0) {
            if (segRotation == 90 || segRotation == 270) {
                segWidth.toDouble() / segHeight.toDouble()
            } else {
                segHeight.toDouble() / segWidth.toDouble()
            }
        } else {
            16.0 / 9.0
        }
        var pipH = pipW * aspectHOverW
        val maxH = canvasH - 2.0 * margin
        if (maxH > 0.0 && pipH > maxH) {
            val scale = maxH / pipH
            pipH = maxH
            pipW *= scale
        }
        val anchorLeft = pipAnchor == "topLeft" || pipAnchor == "bottomLeft"
        val anchorTop  = pipAnchor == "topLeft" || pipAnchor == "topRight"
        val left = if (anchorLeft) margin else canvasW - margin - pipW
        val top  = if (anchorTop)  margin else canvasH - margin - pipH
        return VGDuetPixelRect(left = left, top = top, width = pipW, height = pipH)
    }

    /**
     * Audio sidecar specs for the real-take route. Both tracks start at
     * output time 0 and span the effective export duration: the source track
     * reads from the trim start, the mic track is the recorded segment's own
     * audio from its origin. Muted or effectively silent tracks are omitted;
     * an empty list makes the pass-2 muxer perform a video-only remux
     * (intentional silent output, not an error).
     */
    private fun buildRealTakeAudioSpecs(
        params: ExportParams,
        segmentPath: String,
        durationSec: Double,
    ): List<AndroidAudioTrackSpec> {
        val specs = ArrayList<AndroidAudioTrackSpec>(2)
        if (!params.sourceAudioMuted && params.sourceAudioGain > 0.0001) {
            specs.add(
                AndroidAudioTrackSpec(
                    trackId         = "duet_source_audio",
                    url             = params.sourceFilePath,
                    startTime       = 0.0,
                    duration        = durationSec,
                    volume          = params.sourceAudioGain,
                    role            = "original",
                    fadeInSeconds   = 0.0,
                    fadeOutSeconds  = 0.0,
                    sourceTrimStart = params.trimStartSec,
                    volumeKeyframes = null,
                    mixGain         = 1.0,
                )
            )
        }
        if (!params.micAudioMuted && params.micAudioGain > 0.0001) {
            specs.add(
                AndroidAudioTrackSpec(
                    trackId         = "duet_mic_audio",
                    url             = segmentPath,
                    startTime       = 0.0,
                    duration        = durationSec,
                    volume          = params.micAudioGain,
                    role            = "voiceover",
                    fadeInSeconds   = 0.0,
                    fadeOutSeconds  = 0.0,
                    sourceTrimStart = 0.0,
                    volumeKeyframes = null,
                    mixGain         = 1.0,
                )
            )
        }
        return specs
    }

    /** Normalizes probed rotation to 0/90/180/270; anything else degrades to 0. */
    private fun normalizeRotationDegrees(degrees: Int): Int {
        val wrapped = ((degrees % 360) + 360) % 360
        return if (wrapped == 90 || wrapped == 180 || wrapped == 270) wrapped else 0
    }

    // ── Internal: layout ──────────────────────────────────────────────────────

    private fun computeLayoutRects(
        layoutMode: String,
        canvasW:    Double,
        canvasH:    Double,
        transform:  NativeForegroundTransform?,
    ): VGDuetLayoutRects {
        return when (layoutMode) {
            "greenScreen"    -> AndroidDuetLayoutGeometry.greenScreen(canvasW, canvasH, transform)
            "splitLeftRight" -> AndroidDuetLayoutGeometry.splitLeftRight(canvasW, canvasH, false)
            "splitTopBottom" -> AndroidDuetLayoutGeometry.splitTopBottom(canvasW, canvasH, false)
            else -> {
                val full = VGDuetPixelRect(0.0, 0.0, canvasW, canvasH)
                VGDuetLayoutRects(source = full, camera = full)
            }
        }
    }

    /**
     * Computes the overlay placement (left, top) whose unrotated bounding-box
     * center, after rotating [fgRect]'s own center by [rotationDegrees]
     * (clockwise-positive, matching the existing center-anchor rotation
     * proof) around the anchor pivot within [fgRect], lands on the rotated
     * point. The anchor pivot is `(fgRect.left + anchorX * fgRect.width,
     * fgRect.top + anchorY * fgRect.height)`. For anchor (0.5, 0.5) or
     * rotationDegrees == 0.0 this reduces exactly to (fgRect.left, fgRect.top).
     */
    private fun computeAnchorPivotOverlayOrigin(
        fgRect: VGDuetPixelRect,
        anchorX: Double,
        anchorY: Double,
        rotationDegrees: Double,
    ): Pair<Double, Double> {
        val centerX = fgRect.left + fgRect.width / 2.0
        val centerY = fgRect.top + fgRect.height / 2.0
        val pivotX  = fgRect.left + anchorX * fgRect.width
        val pivotY  = fgRect.top + anchorY * fgRect.height
        val theta = Math.toRadians(rotationDegrees)
        val cosT = Math.cos(theta)
        val sinT = Math.sin(theta)
        val dx = centerX - pivotX
        val dy = centerY - pivotY
        val shiftedCenterX = pivotX + dx * cosT - dy * sinT
        val shiftedCenterY = pivotY + dx * sinT + dy * cosT
        return Pair(shiftedCenterX - fgRect.width / 2.0, shiftedCenterY - fgRect.height / 2.0)
    }

    // ── Internal: metadata probe ──────────────────────────────────────────────

    private fun probeSourceDurationUs(filePath: String): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(filePath)
            val ms = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            ms * 1000L
        } catch (e: Exception) {
            throw ExportException("source_invalid",
                "exportDuetComposition: failed to probe source metadata for " +
                    "$filePath: ${e.message}")
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    /**
     * Probes width, height, and rotation from the source file.
     * Falls back gracefully if metadata extraction fails.
     *
     * @return Triple(widthPx, heightPx, rotationDegrees)
     */
    private fun probeSourceDimensionsAndRotation(filePath: String): Triple<Int, Int, Int> {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(filePath)
            val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 1920
            val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 1080
            val rot = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
            Triple(w, h, rot)
        } catch (e: Exception) {
            Triple(1920, 1080, 0) // graceful fallback
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    // ── Internal: synthetic overlay generation ────────────────────────────────

    /**
     * Generates a rect-sized (not full-canvas) solid magenta PNG.
     * The overlay descriptor positions it at fgRect.left/top so geometry
     * is applied exactly once. No ML, no camera, no rendered-pixel claim.
     *
     * @return the temporary PNG [File]; caller must delete after encode.
     */
    private fun generateSyntheticOverlay(
        dir:       File,
        bmpWidth:  Int,
        bmpHeight: Int,
    ): File {
        val bmp    = Bitmap.createBitmap(bmpWidth, bmpHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        // Deep-pink solid fill — synthetic foreground placeholder
        val paint = Paint().apply {
            color = Color.argb(255, 255, 20, 147)
            style = Paint.Style.FILL
            isAntiAlias = false
        }
        canvas.drawRect(0f, 0f, bmpWidth.toFloat(), bmpHeight.toFloat(), paint)

        val overlayFile = File(dir, "duet_export_synthetic_fg_${System.nanoTime()}.png")
        FileOutputStream(overlayFile).use { out ->
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        bmp.recycle()
        return overlayFile
    }

    // ── Internal: reply helpers ───────────────────────────────────────────────

    private fun postSuccess(
        callback: (Map<String, Any?>?, String?) -> Unit,
        result: Map<String, Any?>,
    ) { mainHandler.post { callback(result, null) } }

    /**
     * Delivers a failure to Dart and logs it exactly once with a stable logcat
     * marker (one row per failed export -- never per-frame), so a physical run
     * exposes the native reason even when the app only surfaces a generic
     * "failed to render" message.
     */
    private fun postError(
        callback: (Map<String, Any?>?, String?) -> Unit,
        code: String,
        message: String,
    ) {
        Log.e(TAG, "ANDROID_DUET_EXPORT_ERROR code=$code message=$message")
        mainHandler.post { callback(null, "$code|$message") }
    }

    private fun safeDelete(file: File) {
        try { file.delete() } catch (_: Exception) {}
    }

    // ── Internal: typed exception ─────────────────────────────────────────────

    private class ExportException(val code: String, message: String) : Exception(message)

    companion object {
        private const val TAG = "VGDuetExportSession"
        /** Fixed output frame rate for the real-take offline compositor. */
        private const val REAL_TAKE_FPS = 30
        /** Wire name reported for the real-take route; never claims Vulkan. */
        private const val REAL_TAKE_RENDER_BACKEND = "gles_duet_offline"
        /** Default PiP fallback (iOS parity): ~35% canvas width, ~1.8% margin. */
        private const val DEFAULT_PIP_WIDTH_FRACTION = 0.35
        private const val DEFAULT_PIP_MARGIN_FRACTION = 0.018
    }
}
