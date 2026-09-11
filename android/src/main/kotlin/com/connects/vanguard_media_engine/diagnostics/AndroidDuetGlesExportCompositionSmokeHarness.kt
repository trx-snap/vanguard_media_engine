package com.connects.vanguard_media_engine.diagnostics

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.export.AndroidTimelineOverlayDescriptor
import com.connects.vanguard_media_engine.export.AndroidTimelineVideoEncoder
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Diagnostic-only Android Duet deterministic GLES export composition proof.
 *
 * Proof boundary: [PROOF_BOUNDARY].
 *
 * Drives the PRODUCTION [AndroidTimelineVideoEncoder] GLES/MediaCodec export route (the
 * same encoder AndroidTimelineExportSession routes hard-cut overlay exports through) with
 * a single STICKER overlay whose asset is a synthetic, deterministically-generated RGBA
 * PNG standing in for a pre-matted Duet foreground: four fixed-alpha quadrants (0, 255,
 * 128, 64) over one constant foreground color. This proves the existing export path can
 * carry a pre-matted, alpha-varying foreground composite through to a produced MP4 -- it
 * does NOT add a Duet export product surface, and performs no live human matting.
 *
 * Because the produced artifact is H.264/MP4 (lossy), pixel assertions compare RGB only,
 * within [LOSSY_RGB_TOLERANCE] per channel, against the expected GL_SRC_ALPHA /
 * GL_ONE_MINUS_SRC_ALPHA source-over blend of the foreground color over the baseline
 * (no-overlay) render at the same pixel. Sample points sit at the center of each
 * 64x64 alpha quadrant of the 128x128 overlay -- comfortably inside both the overlay's
 * own edges and the 256x256 encode canvas's edges.
 */
class AndroidDuetGlesExportCompositionSmokeHarness {

    companion object {
        private const val TAG = "VGDuetGlesExportComp"

        const val PROOF_BOUNDARY =
            "android_duet_gles_export_composition_rgba_matte_overlay_mediacodec_mp4_only"
        const val START_MARKER = "ANDROID_DUET_GLES_EXPORT_COMPOSITION_START"
        const val PASS_MARKER = "ANDROID_DUET_GLES_EXPORT_COMPOSITION_PHYSICAL_PASS"
        const val FAIL_MARKER = "ANDROID_DUET_GLES_EXPORT_COMPOSITION_PHYSICAL_FAIL"

        const val LOSSY_RGB_TOLERANCE = 36
        private const val MAX_MISMATCHES = 12

        private const val OVERLAY_SIZE = 128
        private const val FG_R = 230
        private const val FG_G = 40
        private const val FG_B = 180

        private val REQUIRED_GATES = listOf(
            "inputValidationOk",
            "sourceMetadataOk",
            "baselineEncodeOk",
            "compositionEncodeOk",
            "compositionFrameCountOk",
            "frameExtractOk",
            "outputMp4Ok",
            "alphaZeroPreservesBackgroundOk",
            "alphaFullForegroundOk",
            "alphaFractionalBlendOk",
            "cleanupOk",
        )

        private val NON_CLAIMS = listOf(
            "No real ML human matte quality.",
            "No per-frame GL_LUMINANCE mask upload inside export (DEC-V2-105 covers synthetic mask upload/blend separately).",
            "No live CameraX/OES preview lifecycle.",
            "No multi-track audio pass-2 mux or A/V sync.",
            "No ConnectsApp, Universal Editor UI, upload, share, caption, or backend admission wiring.",
            "No GPU delegate/TFLite/MediaPipe production promotion.",
            "No low-end/budget Android proof.",
        )
    }

    private data class AlphaSample(
        val label: String,
        val alpha: Int,
        val x: Int,
        val y: Int,
    )

    private data class ProbedVideoMetadata(
        val width: Int,
        val height: Int,
        val rotation: Int,
        val durationUs: Long,
    )

    /** Never throws. Returns a fail-shaped map on any invalid input or exception. */
    fun run(
        videoPath: String?,
        outputDir: String?,
        nativeBridge: VanguardNativeBridge?,
    ): Map<String, Any?> {
        Log.i(TAG, START_MARKER)

        val gates = LinkedHashMap<String, Boolean>()
        val details = LinkedHashMap<String, Any?>()
        val mismatches = mutableListOf<String>()
        val filesToClean = mutableListOf<File>()
        var firstFailureReason: String? = null
        var maxDelta = 0
        var sampleCount = 0

        fun noteFailure(reason: String) {
            if (firstFailureReason == null) firstFailureReason = reason
        }

        // ── Gate: input validation (no files created yet on failure) ──────────
        val vFile = videoPath?.let { File(it) }
        val outDirFile = outputDir?.let { File(it) }
        val inputValidationOk = vFile != null && vFile.exists() && vFile.isFile && vFile.canRead() &&
            outDirFile != null && outDirFile.exists() && outDirFile.isDirectory &&
            nativeBridge != null
        gates["inputValidationOk"] = inputValidationOk
        details["videoPath"] = videoPath
        details["outputDir"] = outputDir

        if (!inputValidationOk) {
            val reason = when {
                vFile == null || !vFile.exists() || !vFile.isFile || !vFile.canRead() ->
                    "invalid_video_path:$videoPath"
                outDirFile == null || !outDirFile.exists() || !outDirFile.isDirectory ->
                    "invalid_output_dir:$outputDir"
                else -> "native_bridge_null"
            }
            gates["cleanupOk"] = true
            return buildResult(false, reason, gates, mismatches, -1, 0, details)
        }

        var baselineEncodeOk = false
        var compositionEncodeOk = false
        var compositionFrameCountOk = false
        var outputMp4Ok = false
        var frameExtractOk = false
        var alphaZeroPreservesBackgroundOk = false
        var alphaFullForegroundOk = false
        var alphaFractionalBlendOk = false

        try {
            // ── Gate: source metadata probe ────────────────────────────────────
            val probed = probeVideoMetadata(videoPath!!)
            val sourceMetadataOk = probed.width > 0 && probed.height > 0 && probed.durationUs > 0L
            gates["sourceMetadataOk"] = sourceMetadataOk
            details["sourceWidth"] = probed.width
            details["sourceHeight"] = probed.height
            details["sourceRotation"] = probed.rotation
            details["sourceDurationUs"] = probed.durationUs

            if (!sourceMetadataOk) {
                noteFailure("source_metadata_invalid:w=${probed.width},h=${probed.height},dur=${probed.durationUs}")
            } else {
                val trimEndSeconds = min(1.0, probed.durationUs / 1_000_000.0).coerceAtLeast(0.5)
                val encodeWidth = 256
                val encodeHeight = 256
                val fps = 30
                val bitrateBps = 4_000_000
                val timestamp = System.currentTimeMillis()
                details["trimEndSeconds"] = trimEndSeconds

                val clip = AndroidTimelineVideoEncoder.ClipInput(
                    sourcePath = videoPath,
                    trimStartSeconds = 0.0,
                    trimEndSeconds = trimEndSeconds,
                    decodedWidth = probed.width,
                    decodedHeight = probed.height,
                    rotationDegrees = probed.rotation,
                    mediaKind = "video",
                )

                // ── Deterministic RGBA matte overlay PNG ───────────────────────
                val overlayPngFile = File(outDirFile!!, "duet_export_matte_overlay_${timestamp}.png")
                filesToClean.add(overlayPngFile)
                val overlayGenerated = generateMatteOverlayPng(overlayPngFile)
                details["overlayGenerated"] = overlayGenerated
                details["overlayPngPath"] = overlayPngFile.absolutePath
                details["overlayPngSizeBytes"] = if (overlayPngFile.exists()) overlayPngFile.length() else 0L

                if (!overlayGenerated) {
                    noteFailure("overlay_png_generation_failed")
                } else {
                    // ── Baseline encode (no overlays) ──────────────────────────
                    val baselineFile = File(outDirFile, "duet_export_composition_baseline_${timestamp}.mp4")
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
                    if (!baselineEncodeOk) noteFailure("baseline_encode_failed:${baselineResult.reason}")

                    // ── Composited encode (single STICKER overlay = matte PNG) ─
                    val overlayDescriptor = AndroidTimelineOverlayDescriptor(
                        overlayId = "duet_export_composition_matte",
                        type = AndroidTimelineOverlayDescriptor.Type.STICKER,
                        startTimeSeconds = 0.0,
                        durationSeconds = trimEndSeconds,
                        translationX = 64.0,
                        translationY = 64.0,
                        width = 128.0,
                        height = 128.0,
                        rotation = 0.0,
                        scale = 1.0,
                        opacity = 1.0,
                        zIndex = 1,
                        assetPath = overlayPngFile.absolutePath,
                    )

                    val compositedFile = File(outDirFile, "duet_export_composition_composited_${timestamp}.mp4")
                    filesToClean.add(compositedFile)
                    val compositedEncoder = AndroidTimelineVideoEncoder(
                        outputPath = compositedFile.absolutePath,
                        width = encodeWidth,
                        height = encodeHeight,
                        fps = fps,
                        bitrateBps = bitrateBps,
                        nativeBridge = nativeBridge,
                    )
                    val compositedResult = compositedEncoder.encode(
                        clips = listOf(clip),
                        transitions = emptyList(),
                        overlays = listOf(overlayDescriptor),
                    )
                    compositionEncodeOk = compositedResult.success &&
                        compositedFile.exists() &&
                        compositedFile.length() > 0L &&
                        compositedResult.writtenVideoSamples > 0
                    compositionFrameCountOk = compositedResult.overlayFrameCount > 0
                    outputMp4Ok = compositionEncodeOk
                    details["compositionSuccess"] = compositedResult.success
                    details["compositionReason"] = compositedResult.reason
                    details["compositionWrittenSamples"] = compositedResult.writtenVideoSamples
                    details["compositionOverlayFrameCount"] = compositedResult.overlayFrameCount
                    details["compositionSizeBytes"] = compositedFile.length()

                    if (!compositionEncodeOk) {
                        noteFailure("composition_encode_failed:${compositedResult.reason}")
                    } else if (!compositionFrameCountOk) {
                        noteFailure("composition_frame_count_zero:${compositedResult.overlayFrameCount}")
                    }

                    // ── Mid-frame extraction & pixel proof ─────────────────────
                    val midFrameUs = (trimEndSeconds * 1_000_000.0 / 2.0).toLong()
                    details["midFrameUs"] = midFrameUs

                    if (baselineEncodeOk && compositionEncodeOk) {
                        val baselineBitmap = extractFrame(baselineFile.absolutePath, midFrameUs)
                        val compositedBitmap = extractFrame(compositedFile.absolutePath, midFrameUs)

                        if (baselineBitmap != null && compositedBitmap != null &&
                            baselineBitmap.width == compositedBitmap.width &&
                            baselineBitmap.height == compositedBitmap.height &&
                            baselineBitmap.width == encodeWidth &&
                            baselineBitmap.height == encodeHeight
                        ) {
                            frameExtractOk = true

                            val samples = listOf(
                                AlphaSample("alphaZero", 0, 96, 96),
                                AlphaSample("alphaFull", 255, 160, 96),
                                AlphaSample("alphaHalf", 128, 96, 160),
                                AlphaSample("alphaQuarter", 64, 160, 160),
                            )

                            var zeroOk = true
                            var fullOk = true
                            var fractionalOk = true

                            for (sample in samples) {
                                val basePixel = baselineBitmap.getPixel(sample.x, sample.y)
                                val compPixel = compositedBitmap.getPixel(sample.x, sample.y)
                                val baseR = Color.red(basePixel)
                                val baseG = Color.green(basePixel)
                                val baseB = Color.blue(basePixel)
                                val actR = Color.red(compPixel)
                                val actG = Color.green(compPixel)
                                val actB = Color.blue(compPixel)

                                val a = sample.alpha / 255.0
                                val expR = (FG_R * a + baseR * (1.0 - a)).roundToInt()
                                val expG = (FG_G * a + baseG * (1.0 - a)).roundToInt()
                                val expB = (FG_B * a + baseB * (1.0 - a)).roundToInt()

                                val dR = abs(actR - expR)
                                val dG = abs(actG - expG)
                                val dB = abs(actB - expB)
                                val sampleMaxDelta = maxOf(dR, dG, dB)
                                maxDelta = maxOf(maxDelta, sampleMaxDelta)
                                sampleCount++

                                val withinTolerance = sampleMaxDelta <= LOSSY_RGB_TOLERANCE
                                when (sample.label) {
                                    "alphaZero" -> if (!withinTolerance) zeroOk = false
                                    "alphaFull" -> if (!withinTolerance) fullOk = false
                                    else -> if (!withinTolerance) fractionalOk = false
                                }

                                if (!withinTolerance && mismatches.size < MAX_MISMATCHES) {
                                    mismatches.add(
                                        "${sample.label}@(${sample.x},${sample.y}) alpha=${sample.alpha} " +
                                            "baselineRGB=($baseR,$baseG,$baseB) actualRGB=($actR,$actG,$actB) " +
                                            "expectedRGB=($expR,$expG,$expB) maxDelta=$sampleMaxDelta",
                                    )
                                }

                                details["sample_${sample.label}_baselineRgb"] = "$baseR,$baseG,$baseB"
                                details["sample_${sample.label}_actualRgb"] = "$actR,$actG,$actB"
                                details["sample_${sample.label}_expectedRgb"] = "$expR,$expG,$expB"
                                details["sample_${sample.label}_maxDelta"] = sampleMaxDelta
                            }

                            alphaZeroPreservesBackgroundOk = zeroOk
                            alphaFullForegroundOk = fullOk
                            alphaFractionalBlendOk = fractionalOk

                            if (!alphaZeroPreservesBackgroundOk) noteFailure("alpha_zero_background_mismatch:maxDelta=$maxDelta")
                            if (!alphaFullForegroundOk) noteFailure("alpha_full_foreground_mismatch:maxDelta=$maxDelta")
                            if (!alphaFractionalBlendOk) noteFailure("alpha_fractional_blend_mismatch:maxDelta=$maxDelta")
                        } else {
                            val bw = baselineBitmap?.width ?: -1
                            val bh = baselineBitmap?.height ?: -1
                            val cw = compositedBitmap?.width ?: -1
                            val ch = compositedBitmap?.height ?: -1
                            noteFailure("frame_extract_or_dimensions_invalid:baseline=${bw}x$bh,composited=${cw}x$ch")
                        }
                    } else {
                        noteFailure("frame_extraction_skipped_due_to_encode_failure")
                    }
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Exception during Duet GLES export composition harness run", t)
            noteFailure("exception:${t.javaClass.simpleName}:${t.message}")
            details["exception"] = "${t.javaClass.simpleName}:${t.message}"
        } finally {
            gates["baselineEncodeOk"] = baselineEncodeOk
            gates["compositionEncodeOk"] = compositionEncodeOk
            gates["compositionFrameCountOk"] = compositionFrameCountOk
            gates["outputMp4Ok"] = outputMp4Ok
            gates["frameExtractOk"] = frameExtractOk
            gates["alphaZeroPreservesBackgroundOk"] = alphaZeroPreservesBackgroundOk
            gates["alphaFullForegroundOk"] = alphaFullForegroundOk
            gates["alphaFractionalBlendOk"] = alphaFractionalBlendOk
            if (gates["sourceMetadataOk"] == null) gates["sourceMetadataOk"] = false

            for (f in filesToClean) {
                try {
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {
                }
            }
            val cleanupOk = filesToClean.all { !it.exists() }
            gates["cleanupOk"] = cleanupOk
            if (!cleanupOk) noteFailure("cleanup_failed_lingering_files")
        }

        details["maxDelta"] = maxDelta
        details["sampleCount"] = sampleCount

        val canonical = REQUIRED_GATES.all { gates[it] == true }
        gates["canonical"] = canonical
        val pass = canonical
        val failureReason = if (pass) "" else (firstFailureReason ?: "smoke_failed")

        return buildResult(pass, failureReason, gates, mismatches, maxDelta, sampleCount, details)
    }

    private fun generateMatteOverlayPng(outputFile: File): Boolean {
        var bitmap: Bitmap? = null
        return try {
            val size = OVERLAY_SIZE
            val half = size / 2
            val pixels = IntArray(size * size)
            for (y in 0 until size) {
                for (x in 0 until size) {
                    val alpha = when {
                        x < half && y < half -> 0
                        x >= half && y < half -> 255
                        x < half && y >= half -> 128
                        else -> 64
                    }
                    pixels[y * size + x] = Color.argb(alpha, FG_R, FG_G, FG_B)
                }
            }
            val created = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            created.setHasAlpha(true)
            created.setPremultiplied(false)
            created.setPixels(pixels, 0, size, 0, 0, size, size)
            bitmap = created
            FileOutputStream(outputFile).use { fos ->
                created.compress(Bitmap.CompressFormat.PNG, 100, fos)
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to generate matte overlay PNG at ${outputFile.absolutePath}: $t")
            false
        } finally {
            try {
                bitmap?.recycle()
            } catch (_: Throwable) {
            }
        }
    }

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
            try {
                extractor.release()
            } catch (_: Throwable) {
            }
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
                try {
                    mmr.release()
                } catch (_: Throwable) {
                }
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
            try {
                retriever.release()
            } catch (_: Throwable) {
            }
        }
    }

    private fun buildResult(
        pass: Boolean,
        failureReason: String,
        gates: Map<String, Boolean>,
        mismatches: List<String>,
        maxDelta: Int,
        sampleCount: Int,
        details: Map<String, Any?>,
    ): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        map["pass"] = pass
        map["status"] = if (pass) "PASS" else "FAIL"
        map["marker"] = if (pass) PASS_MARKER else FAIL_MARKER
        map["proofBoundary"] = PROOF_BOUNDARY
        map["gates"] = LinkedHashMap(gates)
        map["lossyRgbTolerance"] = LOSSY_RGB_TOLERANCE
        map["maxDelta"] = maxDelta
        map["sampleCount"] = sampleCount
        map["mismatches"] = mismatches
        map["details"] = LinkedHashMap(details)
        map["failureReason"] = failureReason
        map["nonClaims"] = NON_CLAIMS
        return map
    }
}
