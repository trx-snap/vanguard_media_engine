package com.connects.vanguard_media_engine.duet

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaMetadataRetriever
import android.os.Handler
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.export.AndroidExportRenderBackendSelector
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

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-SLICE-5B-A: Descriptor-bound Android offline Duet export session.
// ─────────────────────────────────────────────────────────────────────────────
//
// Claims (this slice only):
//   - Descriptor-bound Android offline video-only composited MP4.
//   - Source video decode/encode path via AndroidTimelineVideoEncoder.
//   - Synthetic foreground geometry route via AndroidDuetLayoutGeometry.
//   - Atomic final output (write to tmp, rename on success, delete on failure).
//
// Non-claims:
//   - No live camera, no ML/human matte, no audio/mic/sync, no iOS.
//   - No ConnectsApp/Universal Editor/upload/backend wiring.
//   - No rendered pixel assertion (synthetic foreground is magenta rectangle).
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

        val parseResult = parseAndValidate(descriptorMap, outputPath, targetSizeMap, videoBitRate)
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

        if (layoutMode == "greenScreen" &&
            greenScreenBg.type != AndroidDuetGreenScreenBackgroundType.VIDEO
        ) {
            return ParseResult.Failure(
                "unsupported_export_feature",
                "exportDuetComposition: static/image green-screen backgrounds are preview-only for now; offline export requires a future compositor."
            )
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
                greenScreenBackground = greenScreenBg,
            )
        )
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
            // Places the rect-sized PNG at fgRect.left/top with exact dimensions.
            // Rotation carries the parsed foreground transform's rotationDegrees
            // (already validated finite, default 0.0) so exported foreground
            // rotation matches the live preview. This routes through the timeline
            // overlay's own rotation handling and does not yet express non-center
            // anchor-pivot parity with the preview compositor.
            val fgRotationDegrees = params.foregroundTransform?.rotationDegrees ?: 0.0
            val overlayDescriptor = AndroidTimelineOverlayDescriptor(
                overlayId        = "duet_synthetic_fg",
                type             = AndroidTimelineOverlayDescriptor.Type.STICKER,
                startTimeSeconds = 0.0,
                durationSeconds  = trimDurationSec,
                translationX     = fgRect.left,
                translationY     = fgRect.top,
                width            = fgRect.width,
                height           = fgRect.height,
                rotation         = fgRotationDegrees,
                scale            = 1.0,
                opacity          = 1.0,
                zIndex           = 1,
                assetPath        = overlayFile.absolutePath,
            )

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
                overlays        = listOf(overlayDescriptor),
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
                overlays    = listOf(overlayDescriptor),
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
                    overlays    = listOf(overlayDescriptor),
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

    private fun postError(
        callback: (Map<String, Any?>?, String?) -> Unit,
        code: String,
        message: String,
    ) { mainHandler.post { callback(null, "$code|$message") } }

    private fun safeDelete(file: File) {
        try { file.delete() } catch (_: Exception) {}
    }

    // ── Internal: typed exception ─────────────────────────────────────────────

    private class ExportException(val code: String, message: String) : Exception(message)
}
