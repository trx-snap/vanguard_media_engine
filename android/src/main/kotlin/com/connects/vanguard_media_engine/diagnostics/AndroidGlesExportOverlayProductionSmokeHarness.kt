package com.connects.vanguard_media_engine.diagnostics

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.export.AndroidTimelineOverlayDescriptor
import com.connects.vanguard_media_engine.export.AndroidTimelineOverlayKeyframe
import com.connects.vanguard_media_engine.export.AndroidTimelineVideoEncoder
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * P5-GLES-EXPORT-OVERLAY-PRODUCTION-ROUTE-A, extended by
 * P5-GLES-EXPORT-STILL-IMAGE-OVERLAYS: physical smoke harness verifying that the
 * production [AndroidTimelineVideoEncoder] directly executes GLES overlay composition via
 * [VanguardNativeBridge] on caller-current context, for both video and still-image clips.
 *
 * Proof boundary: [PROOF_BOUNDARY].
 *
 * Directly drives [AndroidTimelineVideoEncoder] (forcing GLES even on Vulkan-capable devices)
 * with a real video clip, verifying:
 * 1. Input validation & video source metadata inspection (width, height, rotation, duration).
 * 2. Baseline lane: clean encode without overlays.
 * 3. Overlay lane: encode with sticker, text, emoji-type ASCII, and dynamic keyframed overlays.
 *    Verifies encode success and overlayFrameCount > 0.
 * 4. Pixel proof: extracts mid-frame bitmaps from baseline and overlay renders, confirms non-blank
 *    content and matching dimensions, and asserts meaningful RGB delta in the overlay region.
 * 5. Fail-closed gate: rejects null nativeBridge ("overlays_missing_native_bridge") without
 *    writing output.
 * 6. Still-image overlay lane: encodes a still-image clip with the same overlay set on GLES,
 *    reusing [AndroidTimelineVideoEncoder]'s existing still-image GL_TEXTURE_2D base draw path.
 *    Verifies encode success, non-empty output, writtenVideoSamples > 0, and
 *    overlayFrameCount > 0.
 * 7. Reversed video overlay lane (P5-GLES-EXPORT-REVERSED-CLIP-OVERLAYS): encodes a
 *    zero-rotation reversed video clip ([reversedVideoPath], falling back to [videoPath])
 *    with the same overlay set on GLES, reusing
 *    [AndroidTimelineVideoEncoder]'s `renderReversedClipIntoEncoder` ->
 *    `drawAndSubmitFrame2D` -> `compositeActiveOverlaysIfPresent` route. Verifies encode
 *    success, non-empty output, writtenVideoSamples > 0, and overlayFrameCount > 0; fails
 *    closed with a precise reason if the resolved source has invalid metadata or non-zero
 *    rotation.
 * 8. Guaranteed cleanup of all created output files.
 */
class AndroidGlesExportOverlayProductionSmokeHarness {

    companion object {
        private const val TAG = "VGGlesExportOverlayProd"
        const val PROOF_BOUNDARY =
            "production_android_timeline_gles_overlay_export_forced_encoder_route_a"
        const val PASS_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE5_GLES_EXPORT_OVERLAY_PRODUCTION_PHYSICAL_SMOKE_FAIL"

        // P5-GLES-EXPORT-ES3-CONTEXT-READINESS: minimum GL major version
        // asserted (Gate 10, [glMajorVersionOk]) for the current SM-A566B
        // physical fleet device -- an ES3-negotiating driver. This is a
        // lower bound, never an exact-equality check, since a driver may
        // promote an ES2 context request to ES3 and expose a higher major
        // version in the future; the gate fails closed if any encode
        // negotiates below this value.
        const val EXPECTED_PHYSICAL_MIN_GL_MAJOR_VERSION = 3
    }

    fun run(
        videoPath: String?,
        stickerPath: String?,
        outputDir: String?,
        nativeBridge: VanguardNativeBridge?,
        reversedVideoPath: String? = null,
    ): Map<String, Any?> {
        val filesToClean = mutableListOf<File>()

        var inputValidationOk = false
        var sourceMetadataOk = false
        var baselineEncodeOk = false
        var overlayEncodeOk = false
        var overlayFrameCountOk = false
        var frameExtractOk = false
        var pixelDeltaOk = false
        var missingBridgeRejectedOk = false
        var stillImageOverlayEncodeOk = false
        var reversedVideoOverlayEncodeOk = false
        var glMajorVersionOk = false
        var cleanupOk = false

        var firstFailureReason: String? = null
        val details = LinkedHashMap<String, Any?>()

        try {
            // ── Gate 1: Input validation ──────────────────────────────────────────
            val vFile = videoPath?.let { File(it) }
            val sFile = stickerPath?.let { File(it) }
            val outDirFile = outputDir?.let { File(it) }

            if (vFile == null || !vFile.exists() || !vFile.isFile || !vFile.canRead()) {
                firstFailureReason = "invalid_video_path:$videoPath"
                return makeResultMap(
                    pass = false,
                    failureReason = firstFailureReason,
                    inputValidationOk = false,
                    sourceMetadataOk = false,
                    baselineEncodeOk = false,
                    overlayEncodeOk = false,
                    overlayFrameCountOk = false,
                    frameExtractOk = false,
                    pixelDeltaOk = false,
                    missingBridgeRejectedOk = false,
                    stillImageOverlayEncodeOk = false,
                    reversedVideoOverlayEncodeOk = false,
                    glMajorVersionOk = false,
                    cleanupOk = true,
                    details = mapOf("error" to firstFailureReason),
                )
            }

            if (sFile == null || !sFile.exists() || !sFile.isFile || !sFile.canRead()) {
                firstFailureReason = "invalid_sticker_path:$stickerPath"
                return makeResultMap(
                    pass = false,
                    failureReason = firstFailureReason,
                    inputValidationOk = false,
                    sourceMetadataOk = false,
                    baselineEncodeOk = false,
                    overlayEncodeOk = false,
                    overlayFrameCountOk = false,
                    frameExtractOk = false,
                    pixelDeltaOk = false,
                    missingBridgeRejectedOk = false,
                    stillImageOverlayEncodeOk = false,
                    reversedVideoOverlayEncodeOk = false,
                    glMajorVersionOk = false,
                    cleanupOk = true,
                    details = mapOf("error" to firstFailureReason),
                )
            }

            if (outDirFile == null || !outDirFile.exists() || !outDirFile.isDirectory) {
                firstFailureReason = "invalid_output_dir:$outputDir"
                return makeResultMap(
                    pass = false,
                    failureReason = firstFailureReason,
                    inputValidationOk = false,
                    sourceMetadataOk = false,
                    baselineEncodeOk = false,
                    overlayEncodeOk = false,
                    overlayFrameCountOk = false,
                    frameExtractOk = false,
                    pixelDeltaOk = false,
                    missingBridgeRejectedOk = false,
                    stillImageOverlayEncodeOk = false,
                    reversedVideoOverlayEncodeOk = false,
                    glMajorVersionOk = false,
                    cleanupOk = true,
                    details = mapOf("error" to firstFailureReason),
                )
            }

            if (nativeBridge == null) {
                firstFailureReason = "native_bridge_null"
                return makeResultMap(
                    pass = false,
                    failureReason = firstFailureReason,
                    inputValidationOk = false,
                    sourceMetadataOk = false,
                    baselineEncodeOk = false,
                    overlayEncodeOk = false,
                    overlayFrameCountOk = false,
                    frameExtractOk = false,
                    pixelDeltaOk = false,
                    missingBridgeRejectedOk = false,
                    stillImageOverlayEncodeOk = false,
                    reversedVideoOverlayEncodeOk = false,
                    glMajorVersionOk = false,
                    cleanupOk = true,
                    details = mapOf("error" to firstFailureReason),
                )
            }

            inputValidationOk = true
            details["videoPath"] = videoPath
            details["stickerPath"] = stickerPath
            details["outputDir"] = outputDir

            // ── Gate 2: Source metadata extraction ────────────────────────────────
            val probedSource = probeVideoMetadata(videoPath)
            val sourceWidth = probedSource.width
            val sourceHeight = probedSource.height
            val sourceRotation = probedSource.rotation
            val sourceDurationUs = probedSource.durationUs

            sourceMetadataOk = sourceWidth > 0 && sourceHeight > 0 && sourceDurationUs > 0L
            details["sourceWidth"] = sourceWidth
            details["sourceHeight"] = sourceHeight
            details["sourceRotation"] = sourceRotation
            details["sourceDurationUs"] = sourceDurationUs

            if (!sourceMetadataOk) {
                firstFailureReason = "source_metadata_invalid:w=$sourceWidth,h=$sourceHeight,dur=$sourceDurationUs"
                return makeResultMap(
                    pass = false,
                    failureReason = firstFailureReason,
                    inputValidationOk = inputValidationOk,
                    sourceMetadataOk = false,
                    baselineEncodeOk = false,
                    overlayEncodeOk = false,
                    overlayFrameCountOk = false,
                    frameExtractOk = false,
                    pixelDeltaOk = false,
                    missingBridgeRejectedOk = false,
                    stillImageOverlayEncodeOk = false,
                    reversedVideoOverlayEncodeOk = false,
                    glMajorVersionOk = false,
                    cleanupOk = true,
                    details = details,
                )
            }

            val trimEndSeconds = min(1.0, sourceDurationUs / 1_000_000.0).coerceAtLeast(0.5)
            val encodeWidth = 256
            val encodeHeight = 256
            val fps = 30
            val bitrateBps = 2_000_000
            val timestamp = System.currentTimeMillis()
            details["trimEndSeconds"] = trimEndSeconds

            val clip = AndroidTimelineVideoEncoder.ClipInput(
                sourcePath = videoPath,
                trimStartSeconds = 0.0,
                trimEndSeconds = trimEndSeconds,
                decodedWidth = sourceWidth,
                decodedHeight = sourceHeight,
                rotationDegrees = sourceRotation,
                mediaKind = "video",
            )

            // ── Gate 3: Baseline encode (no overlays) ─────────────────────────────
            val baselineFile = File(outDirFile, "p5_prod_baseline_${timestamp}.mp4")
            filesToClean.add(baselineFile)
            val baselineEncoder = AndroidTimelineVideoEncoder(
                outputPath = baselineFile.absolutePath,
                width = encodeWidth,
                height = encodeHeight,
                fps = fps,
                bitrateBps = bitrateBps,
                nativeBridge = null,
            )
            val baselineResult = baselineEncoder.encode(
                clips = listOf(clip),
                transitions = emptyList(),
                overlays = emptyList(),
            )
            baselineEncodeOk = baselineResult.success &&
                baselineFile.exists() &&
                baselineFile.length() > 0L &&
                baselineResult.writtenVideoSamples > 0
            details["baselineSuccess"] = baselineResult.success
            details["baselineReason"] = baselineResult.reason
            details["baselineWrittenSamples"] = baselineResult.writtenVideoSamples
            details["baselineSizeBytes"] = baselineFile.length()

            if (!baselineEncodeOk && firstFailureReason == null) {
                firstFailureReason = "baseline_encode_failed:${baselineResult.reason}"
            }

            // ── Gate 4 & 5: Overlay encode (sticker + text + emoji ASCII + keyframes)
            val overlays = listOf(
                AndroidTimelineOverlayDescriptor(
                    overlayId = "prod_sticker_keyframed",
                    type = AndroidTimelineOverlayDescriptor.Type.STICKER,
                    startTimeSeconds = 0.0,
                    durationSeconds = trimEndSeconds,
                    translationX = 40.0,
                    translationY = 40.0,
                    width = 96.0,
                    height = 96.0,
                    rotation = 0.0,
                    scale = 1.0,
                    opacity = 1.0,
                    zIndex = 1,
                    assetPath = stickerPath,
                    keyframes = listOf(
                        AndroidTimelineOverlayKeyframe(
                            timeSeconds = 0.0,
                            translationX = 32.0,
                            translationY = 32.0,
                            width = 88.0,
                            height = 88.0,
                            rotation = 0.0,
                            scale = 1.0,
                            opacity = 1.0,
                            interpolation = AndroidTimelineOverlayKeyframe.Interpolation.LINEAR,
                        ),
                        AndroidTimelineOverlayKeyframe(
                            timeSeconds = trimEndSeconds,
                            translationX = 72.0,
                            translationY = 72.0,
                            width = 104.0,
                            height = 104.0,
                            rotation = 0.0,
                            scale = 1.0,
                            opacity = 0.95,
                            interpolation = AndroidTimelineOverlayKeyframe.Interpolation.LINEAR,
                        ),
                    ),
                ),
                AndroidTimelineOverlayDescriptor(
                    overlayId = "prod_text_layer",
                    type = AndroidTimelineOverlayDescriptor.Type.TEXT,
                    startTimeSeconds = 0.0,
                    durationSeconds = trimEndSeconds,
                    translationX = 20.0,
                    translationY = 12.0,
                    width = 216.0,
                    height = 48.0,
                    rotation = 0.0,
                    scale = 1.0,
                    opacity = 1.0,
                    zIndex = 2,
                    textContent = "Vanguard GLES",
                ),
                AndroidTimelineOverlayDescriptor(
                    overlayId = "prod_emoji_layer",
                    type = AndroidTimelineOverlayDescriptor.Type.EMOJI,
                    startTimeSeconds = 0.0,
                    durationSeconds = trimEndSeconds,
                    translationX = 96.0,
                    translationY = 150.0,
                    width = 64.0,
                    height = 64.0,
                    rotation = 0.0,
                    scale = 1.0,
                    opacity = 1.0,
                    zIndex = 3,
                    textContent = ":-)",
                ),
            )

            val overlayFile = File(outDirFile, "p5_prod_overlay_${timestamp}.mp4")
            filesToClean.add(overlayFile)
            val overlayEncoder = AndroidTimelineVideoEncoder(
                outputPath = overlayFile.absolutePath,
                width = encodeWidth,
                height = encodeHeight,
                fps = fps,
                bitrateBps = bitrateBps,
                nativeBridge = nativeBridge,
            )
            val overlayResult = overlayEncoder.encode(
                clips = listOf(clip),
                transitions = emptyList(),
                overlays = overlays,
            )
            overlayEncodeOk = overlayResult.success &&
                overlayFile.exists() &&
                overlayFile.length() > 0L &&
                overlayResult.writtenVideoSamples > 0
            overlayFrameCountOk = overlayResult.overlayFrameCount > 0

            details["overlaySuccess"] = overlayResult.success
            details["overlayReason"] = overlayResult.reason
            details["overlayWrittenSamples"] = overlayResult.writtenVideoSamples
            details["overlayFrameCount"] = overlayResult.overlayFrameCount
            details["overlaySizeBytes"] = overlayFile.length()

            if (!overlayEncodeOk && firstFailureReason == null) {
                firstFailureReason = "overlay_encode_failed:${overlayResult.reason}"
            } else if (!overlayFrameCountOk && firstFailureReason == null) {
                firstFailureReason = "overlay_frame_count_zero:${overlayResult.overlayFrameCount}"
            }

            // ── Gates 6 & 7: Pixel proof (mid-frame extraction & RGB delta) ──────
            val midFrameUs = (trimEndSeconds * 1_000_000.0 / 2.0).toLong()
            details["midFrameUs"] = midFrameUs

            if (baselineEncodeOk && overlayEncodeOk) {
                val baselineBitmap = extractFrame(baselineFile.absolutePath, midFrameUs)
                val overlayBitmap = extractFrame(overlayFile.absolutePath, midFrameUs)

                if (baselineBitmap != null && overlayBitmap != null) {
                    val bw = baselineBitmap.width
                    val bh = baselineBitmap.height
                    val ow = overlayBitmap.width
                    val oh = overlayBitmap.height

                    if (bw == ow && bh == oh && bw > 0 && bh > 0) {
                        frameExtractOk = true
                        val bStats = computeMeanRgb(baselineBitmap)
                        val oStats = computeMeanRgb(overlayBitmap)
                        val bAvg = (bStats.first + bStats.second + bStats.third) / 3.0
                        val oAvg = (oStats.first + oStats.second + oStats.third) / 3.0
                        val bNonBlank = bAvg in 3.0..252.0
                        val oNonBlank = oAvg in 3.0..252.0

                        details["baselineMeanRgb"] = "${bStats.first},${bStats.second},${bStats.third}"
                        details["overlayMeanRgb"] = "${oStats.first},${oStats.second},${oStats.third}"
                        details["baselineNonBlank"] = bNonBlank
                        details["overlayNonBlank"] = oNonBlank

                        // Sample overlay region (center 60% of canvas)
                        val xStart = (bw * 0.2).toInt().coerceIn(0, bw - 1)
                        val xEnd = (bw * 0.8).toInt().coerceIn(xStart + 1, bw)
                        val yStart = (bh * 0.2).toInt().coerceIn(0, bh - 1)
                        val yEnd = (bh * 0.8).toInt().coerceIn(yStart + 1, bh)

                        var changedPixels = 0
                        var sampledPixels = 0
                        var totalDelta = 0.0

                        var y = yStart
                        while (y < yEnd) {
                            var x = xStart
                            while (x < xEnd) {
                                val pBase = baselineBitmap.getPixel(x, y)
                                val pOver = overlayBitmap.getPixel(x, y)
                                val dr = abs(Color.red(pBase) - Color.red(pOver))
                                val dg = abs(Color.green(pBase) - Color.green(pOver))
                                val db = abs(Color.blue(pBase) - Color.blue(pOver))
                                val delta = dr + dg + db
                                if (delta > 20) {
                                    changedPixels++
                                }
                                totalDelta += delta
                                sampledPixels++
                                x += 2
                            }
                            y += 2
                        }

                        val meanDelta = if (sampledPixels > 0) totalDelta / sampledPixels else 0.0
                        details["changedPixels"] = changedPixels
                        details["sampledPixels"] = sampledPixels
                        details["meanDelta"] = meanDelta

                        pixelDeltaOk = bNonBlank && oNonBlank && changedPixels >= 50 && meanDelta >= 5.0
                        if (!pixelDeltaOk && firstFailureReason == null) {
                            firstFailureReason = "pixel_delta_insufficient:changed=$changedPixels,mean=$meanDelta,bNonBlank=$bNonBlank,oNonBlank=$oNonBlank"
                        }
                    } else if (firstFailureReason == null) {
                        firstFailureReason = "extracted_dimensions_mismatch:baseline=${bw}x${bh},overlay=${ow}x${oh}"
                    }
                } else if (firstFailureReason == null) {
                    firstFailureReason = "extract_mid_frame_null"
                }
            }

            // ── Gate 8: Fail-closed on missing nativeBridge ────────────────────────
            val failBridgeFile = File(outDirFile, "p5_prod_fail_bridge_${timestamp}.mp4")
            filesToClean.add(failBridgeFile)
            val nullBridgeEncoder = AndroidTimelineVideoEncoder(
                outputPath = failBridgeFile.absolutePath,
                width = encodeWidth,
                height = encodeHeight,
                fps = fps,
                bitrateBps = bitrateBps,
                nativeBridge = null,
            )
            val failBridgeResult = nullBridgeEncoder.encode(
                clips = listOf(clip),
                transitions = emptyList(),
                overlays = overlays,
            )
            missingBridgeRejectedOk = !failBridgeResult.success &&
                failBridgeResult.reason == "overlays_missing_native_bridge" &&
                (!failBridgeFile.exists() || failBridgeFile.length() == 0L)
            details["missingBridgeRejectedReason"] = failBridgeResult.reason

            if (!missingBridgeRejectedOk && firstFailureReason == null) {
                firstFailureReason = "missing_bridge_gate_failed:${failBridgeResult.success}:${failBridgeResult.reason}"
            }

            // ── Gate 9: Still-image clip with overlays succeeds on GLES ───────────
            val stillOverlayFile = File(outDirFile, "p5_prod_still_overlay_${timestamp}.mp4")
            filesToClean.add(stillOverlayFile)
            val imageClip = AndroidTimelineVideoEncoder.ClipInput(
                sourcePath = stickerPath,
                trimStartSeconds = 0.0,
                trimEndSeconds = 1.0,
                decodedWidth = 256,
                decodedHeight = 256,
                rotationDegrees = 0,
                mediaKind = "image",
                stillFrameCount = 30,
            )
            val stillOverlayEncoder = AndroidTimelineVideoEncoder(
                outputPath = stillOverlayFile.absolutePath,
                width = encodeWidth,
                height = encodeHeight,
                fps = fps,
                bitrateBps = bitrateBps,
                nativeBridge = nativeBridge,
            )
            val stillOverlayResult = stillOverlayEncoder.encode(
                clips = listOf(imageClip),
                transitions = emptyList(),
                overlays = overlays,
            )
            stillImageOverlayEncodeOk = stillOverlayResult.success &&
                stillOverlayFile.exists() &&
                stillOverlayFile.length() > 0L &&
                stillOverlayResult.writtenVideoSamples > 0 &&
                stillOverlayResult.overlayFrameCount > 0
            details["stillImageOverlaySuccess"] = stillOverlayResult.success
            details["stillImageOverlayReason"] = stillOverlayResult.reason
            details["stillImageOverlayWrittenSamples"] = stillOverlayResult.writtenVideoSamples
            details["stillImageOverlayFrameCount"] = stillOverlayResult.overlayFrameCount
            details["stillImageOverlaySizeBytes"] = stillOverlayFile.length()

            if (!stillImageOverlayEncodeOk && firstFailureReason == null) {
                firstFailureReason = "still_image_overlay_encode_failed:${stillOverlayResult.success}:" +
                    "${stillOverlayResult.reason}:samples=${stillOverlayResult.writtenVideoSamples}:" +
                    "overlayFrames=${stillOverlayResult.overlayFrameCount}"
            }

            // ── Gate 10: Reversed video clip with overlays succeeds on GLES
            // (P5-GLES-EXPORT-REVERSED-CLIP-OVERLAYS) -- requires a
            // zero-rotation source, resolved from [reversedVideoPath] when
            // supplied, falling back to [videoPath] otherwise ─────────────
            val reversedSourcePath = reversedVideoPath ?: videoPath
            val reversedProbed = probeVideoMetadata(reversedSourcePath)
            val reversedSourceMetadataOk = reversedProbed.width > 0 &&
                reversedProbed.height > 0 &&
                reversedProbed.durationUs > 0L

            details["reversedVideoPath"] = reversedVideoPath
            details["reversedSourceWidth"] = reversedProbed.width
            details["reversedSourceHeight"] = reversedProbed.height
            details["reversedSourceRotation"] = reversedProbed.rotation
            details["reversedSourceDurationUs"] = reversedProbed.durationUs

            var reversedOverlayGlMajorVersion = 2
            val reversedOverlayFile = File(outDirFile, "p5_prod_reversed_overlay_${timestamp}.mp4")
            filesToClean.add(reversedOverlayFile)

            if (!reversedSourceMetadataOk) {
                val reason = "reversed_overlay_source_metadata_invalid:w=${reversedProbed.width}," +
                    "h=${reversedProbed.height},dur=${reversedProbed.durationUs}"
                details["reversedOverlaySuccess"] = false
                details["reversedOverlayReason"] = reason
                if (firstFailureReason == null) firstFailureReason = reason
            } else if (reversedProbed.rotation != 0) {
                val reason = "reversed_overlay_source_rotation_unsupported:${reversedProbed.rotation}"
                details["reversedOverlaySuccess"] = false
                details["reversedOverlayReason"] = reason
                if (firstFailureReason == null) firstFailureReason = reason
            } else {
                val reversedTrimEndSeconds = min(1.0, reversedProbed.durationUs / 1_000_000.0)
                val reversedClip = AndroidTimelineVideoEncoder.ClipInput(
                    sourcePath = reversedSourcePath,
                    trimStartSeconds = 0.0,
                    trimEndSeconds = reversedTrimEndSeconds,
                    decodedWidth = reversedProbed.width,
                    decodedHeight = reversedProbed.height,
                    rotationDegrees = reversedProbed.rotation,
                    mediaKind = "video",
                    isReversed = true,
                )
                val reversedOverlayEncoder = AndroidTimelineVideoEncoder(
                    outputPath = reversedOverlayFile.absolutePath,
                    width = encodeWidth,
                    height = encodeHeight,
                    fps = fps,
                    bitrateBps = bitrateBps,
                    nativeBridge = nativeBridge,
                )
                val reversedOverlayResult = reversedOverlayEncoder.encode(
                    clips = listOf(reversedClip),
                    transitions = emptyList(),
                    overlays = overlays,
                )
                reversedOverlayGlMajorVersion = reversedOverlayResult.glMajorVersion
                reversedVideoOverlayEncodeOk = reversedOverlayResult.success &&
                    reversedOverlayFile.exists() &&
                    reversedOverlayFile.length() > 0L &&
                    reversedOverlayResult.writtenVideoSamples > 0 &&
                    reversedOverlayResult.overlayFrameCount > 0
                details["reversedOverlaySuccess"] = reversedOverlayResult.success
                details["reversedOverlayReason"] = reversedOverlayResult.reason
                details["reversedOverlayWrittenSamples"] = reversedOverlayResult.writtenVideoSamples
                details["reversedOverlayFrameCount"] = reversedOverlayResult.overlayFrameCount
                details["reversedOverlaySizeBytes"] = reversedOverlayFile.length()

                if (!reversedVideoOverlayEncodeOk && firstFailureReason == null) {
                    firstFailureReason = "reversed_overlay_encode_failed:${reversedOverlayResult.success}:" +
                        "${reversedOverlayResult.reason}:samples=${reversedOverlayResult.writtenVideoSamples}:" +
                        "overlayFrames=${reversedOverlayResult.overlayFrameCount}"
                }
            }
            details["reversedOverlayGlMajorVersion"] = reversedOverlayGlMajorVersion

            // ── Gate 11: GL major version negotiation (P5-GLES-EXPORT-ES3-
            // CONTEXT-READINESS) ─────────────────────────────────────────────
            // Proves the baseline, overlay, still-image-overlay, and
            // reversed-video-overlay encodes all negotiated the same GL
            // major version, and that it is at least
            // [EXPECTED_PHYSICAL_MIN_GL_MAJOR_VERSION] (3 on the current
            // SM-A566B physical fleet device) -- a lower-bound assertion,
            // not exact equality to 3, since a driver may promote an ES2
            // context request to an ES3 (or higher) context. An ES2
            // fallback on this device fails this gate rather than silently
            // passing the physical ES3-readiness proof.
            val baselineGlMajorVersion = baselineResult.glMajorVersion
            val overlayGlMajorVersion = overlayResult.glMajorVersion
            val stillImageOverlayGlMajorVersion = stillOverlayResult.glMajorVersion
            glMajorVersionOk = baselineEncodeOk &&
                overlayEncodeOk &&
                stillImageOverlayEncodeOk &&
                reversedVideoOverlayEncodeOk &&
                baselineGlMajorVersion == overlayGlMajorVersion &&
                baselineGlMajorVersion == stillImageOverlayGlMajorVersion &&
                baselineGlMajorVersion == reversedOverlayGlMajorVersion &&
                baselineGlMajorVersion >= EXPECTED_PHYSICAL_MIN_GL_MAJOR_VERSION
            details["baselineGlMajorVersion"] = baselineGlMajorVersion
            details["overlayGlMajorVersion"] = overlayGlMajorVersion
            details["stillImageOverlayGlMajorVersion"] = stillImageOverlayGlMajorVersion
            details["expectedPhysicalMinGlMajorVersion"] = EXPECTED_PHYSICAL_MIN_GL_MAJOR_VERSION
            details["glMajorVersionDetails"] =
                "baseline=$baselineGlMajorVersion overlay=$overlayGlMajorVersion " +
                    "stillImageOverlay=$stillImageOverlayGlMajorVersion " +
                    "reversedOverlay=$reversedOverlayGlMajorVersion " +
                    "expectedPhysicalMin=$EXPECTED_PHYSICAL_MIN_GL_MAJOR_VERSION(SM-A566B)"

            if (!glMajorVersionOk && firstFailureReason == null) {
                firstFailureReason = "gl_major_version_gate_failed:baseline=$baselineGlMajorVersion:" +
                    "overlay=$overlayGlMajorVersion:still=$stillImageOverlayGlMajorVersion:" +
                    "reversed=$reversedOverlayGlMajorVersion:" +
                    "expectedMin=$EXPECTED_PHYSICAL_MIN_GL_MAJOR_VERSION"
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Exception during smoke harness run", t)
            if (firstFailureReason == null) {
                firstFailureReason = "exception:${t.javaClass.simpleName}:${t.message}"
            }
            details["exception"] = "${t.javaClass.simpleName}:${t.message}"
        } finally {
            // ── Gate 12: Cleanup ──────────────────────────────────────────────────
            for (f in filesToClean) {
                try {
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
            cleanupOk = filesToClean.all { !it.exists() }
            if (!cleanupOk && firstFailureReason == null) {
                firstFailureReason = "cleanup_failed_lingering_files"
            }
        }

        // ── Gate 13: Canonical route verification ─────────────────────────────
        val canonical = inputValidationOk &&
            sourceMetadataOk &&
            baselineEncodeOk &&
            overlayEncodeOk &&
            overlayFrameCountOk &&
            frameExtractOk &&
            pixelDeltaOk &&
            missingBridgeRejectedOk &&
            stillImageOverlayEncodeOk &&
            reversedVideoOverlayEncodeOk &&
            glMajorVersionOk &&
            cleanupOk

        val pass = canonical
        val failureReason = if (pass) "" else (firstFailureReason ?: "smoke_failed")

        return makeResultMap(
            pass = pass,
            failureReason = failureReason,
            inputValidationOk = inputValidationOk,
            sourceMetadataOk = sourceMetadataOk,
            baselineEncodeOk = baselineEncodeOk,
            overlayEncodeOk = overlayEncodeOk,
            overlayFrameCountOk = overlayFrameCountOk,
            frameExtractOk = frameExtractOk,
            pixelDeltaOk = pixelDeltaOk,
            missingBridgeRejectedOk = missingBridgeRejectedOk,
            stillImageOverlayEncodeOk = stillImageOverlayEncodeOk,
            reversedVideoOverlayEncodeOk = reversedVideoOverlayEncodeOk,
            glMajorVersionOk = glMajorVersionOk,
            cleanupOk = cleanupOk,
            details = details,
        )
    }

    /// Width/height/rotation/duration probed from a video source, via
    /// [MediaExtractor] first, falling back to [MediaMetadataRetriever] for
    /// any field [MediaExtractor] could not resolve. Shared by Gate 2 (the
    /// primary [videoPath] source) and the reversed-video overlay lane (Gate
    /// 10, [reversedVideoPath] ?: [videoPath]) so both probe identically.
    private data class ProbedVideoMetadata(
        val width: Int,
        val height: Int,
        val rotation: Int,
        val durationUs: Long,
    )

    private fun probeVideoMetadata(path: String): ProbedVideoMetadata {
        var width = 0
        var height = 0
        var rotation = 0
        var durationUs = 0L

        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val count = extractor.trackCount
            for (i in 0 until count) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/")) {
                    if (format.containsKey(MediaFormat.KEY_WIDTH)) {
                        width = format.getInteger(MediaFormat.KEY_WIDTH)
                    }
                    if (format.containsKey(MediaFormat.KEY_HEIGHT)) {
                        height = format.getInteger(MediaFormat.KEY_HEIGHT)
                    }
                    if (format.containsKey(MediaFormat.KEY_DURATION)) {
                        durationUs = format.getLong(MediaFormat.KEY_DURATION)
                    }
                    if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                        rotation = format.getInteger(MediaFormat.KEY_ROTATION)
                    }
                    break
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "MediaExtractor read failed on $path: $t")
        } finally {
            try { extractor.release() } catch (_: Throwable) {}
        }

        if (width <= 0 || height <= 0 || durationUs <= 0L) {
            val mmr = MediaMetadataRetriever()
            try {
                mmr.setDataSource(path)
                val wStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                val hStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                val rotStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                val durStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                if (width <= 0 && wStr != null) width = wStr.toIntOrNull() ?: 0
                if (height <= 0 && hStr != null) height = hStr.toIntOrNull() ?: 0
                if (rotation == 0 && rotStr != null) rotation = rotStr.toIntOrNull() ?: 0
                if (durationUs <= 0L && durStr != null) {
                    val durMs = durStr.toLongOrNull() ?: 0L
                    durationUs = durMs * 1000L
                }
            } catch (t: Throwable) {
                Log.w(TAG, "MediaMetadataRetriever fallback failed on $path: $t")
            } finally {
                try { mmr.release() } catch (_: Throwable) {}
            }
        }

        return ProbedVideoMetadata(width, height, rotation, durationUs)
    }

    private fun extractFrame(videoPath: String, timeUs: Long): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(videoPath)
            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to extract frame from $videoPath at ${timeUs}us: $t")
            null
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    private fun computeMeanRgb(bitmap: Bitmap): Triple<Double, Double, Double> {
        val w = bitmap.width
        val h = bitmap.height
        val stepX = max(1, w / 32)
        val stepY = max(1, h / 32)

        var totalR = 0.0
        var totalG = 0.0
        var totalB = 0.0
        var count = 0L

        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val pixel = bitmap.getPixel(x, y)
                totalR += Color.red(pixel)
                totalG += Color.green(pixel)
                totalB += Color.blue(pixel)
                count++
                x += stepX
            }
            y += stepY
        }

        if (count == 0L) return Triple(0.0, 0.0, 0.0)
        return Triple(totalR / count, totalG / count, totalB / count)
    }

    private fun makeResultMap(
        pass: Boolean,
        failureReason: String,
        inputValidationOk: Boolean,
        sourceMetadataOk: Boolean,
        baselineEncodeOk: Boolean,
        overlayEncodeOk: Boolean,
        overlayFrameCountOk: Boolean,
        frameExtractOk: Boolean,
        pixelDeltaOk: Boolean,
        missingBridgeRejectedOk: Boolean,
        stillImageOverlayEncodeOk: Boolean,
        reversedVideoOverlayEncodeOk: Boolean,
        glMajorVersionOk: Boolean,
        cleanupOk: Boolean,
        details: Map<String, Any?>,
    ): Map<String, Any?> {
        val canonical = inputValidationOk &&
            sourceMetadataOk &&
            baselineEncodeOk &&
            overlayEncodeOk &&
            overlayFrameCountOk &&
            frameExtractOk &&
            pixelDeltaOk &&
            missingBridgeRejectedOk &&
            stillImageOverlayEncodeOk &&
            reversedVideoOverlayEncodeOk &&
            glMajorVersionOk &&
            cleanupOk

        val map = LinkedHashMap<String, Any?>()
        map["pass"] = pass
        map["status"] = if (pass) "PASS" else "FAIL"
        map["marker"] = if (pass) PASS_MARKER else FAIL_MARKER
        map["proofBoundary"] = PROOF_BOUNDARY
        map["failureReason"] = failureReason

        map["inputValidationOk"] = inputValidationOk
        map["sourceMetadataOk"] = sourceMetadataOk
        map["baselineEncodeOk"] = baselineEncodeOk
        map["overlayEncodeOk"] = overlayEncodeOk
        map["overlayFrameCountOk"] = overlayFrameCountOk
        map["frameExtractOk"] = frameExtractOk
        map["pixelDeltaOk"] = pixelDeltaOk
        map["missingBridgeRejectedOk"] = missingBridgeRejectedOk
        map["stillImageOverlayEncodeOk"] = stillImageOverlayEncodeOk
        map["reversedVideoOverlayEncodeOk"] = reversedVideoOverlayEncodeOk
        map["glMajorVersionOk"] = glMajorVersionOk
        map["cleanupOk"] = cleanupOk
        map["canonical"] = canonical

        map["details"] = details
        return map
    }
}
