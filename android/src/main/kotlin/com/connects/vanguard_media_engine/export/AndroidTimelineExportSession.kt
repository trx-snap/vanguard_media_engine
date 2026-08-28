package com.connects.vanguard_media_engine.export

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.File
import java.util.UUID
import kotlin.math.abs

// ── AndroidTimelineExportSession (Export Unit C) ──────────────────────────────
//
// One-shot native handler for a single `exportTimeline` MethodChannel call.
// Owns argument/draft parsing, Unit C guardrail validation, pass-1 video
// encode (via AndroidTimelineVideoEncoder), and pass-2 audio mux/mixdown
// (via the existing Unit B audio foundation: AndroidAudioTrackSpec,
// AndroidAudioDirectCopyValidator, AndroidAudioMixdownEngine, AndroidAacEncoder,
// AndroidAudioRemuxer). Runs entirely on a background thread; never touches a
// MethodChannel or Flutter main-thread APIs directly -- results are delivered
// via [onSuccess]/[onError] callbacks, which AndroidEditorExportCoordinator
// posts to the main thread exactly once. No progress events are emitted for
// Unit C (out of scope for the minimal hard-cut export slice).
//
// Scope (minimal hard-cut, sequential, local-video export -- Unit C, extended
// by Unit G with rotation metadata + canvas scaling normalization):
//   - video-only clips, speed == 1.0, no transitions, no overlays, no canvas
//     contentMode other than "fit", no per-clip transform/crop/freeze/
//     reverse/time-remap/dual-camera/color-matrix.
//   - clip rotation metadata (0/90/180/270 after normalization) and decoded
//     clip dimensions that differ from each other or from the requested
//     output geometry are supported: each clip is centered and
//     aspect-preserving "fit"-scaled into the fixed output surface over a
//     black background (AndroidTimelineVideoEncoder).
//   - Anything outside this scope is rejected with UNSUPPORTED_EXPORT_FEATURE
//     rather than silently ignored -- a minimal exporter that ignores a
//     feature would silently produce wrong output, which this Unit must not do.
class AndroidTimelineExportSession(private val context: Context) {

    @Volatile private var cancelRequested = false
    @Volatile private var activeEncoder: AndroidTimelineVideoEncoder? = null

    /** Requests cancellation of the in-flight export. Thread-safe, non-blocking. */
    fun requestCancel() {
        cancelRequested = true
        activeEncoder?.cancel()
    }

    fun start(
        args: Map<*, *>?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (code: String, message: String?) -> Unit,
    ) {
        Thread {
            try {
                run(args, onSuccess, onError)
            } catch (t: Throwable) {
                Log.e(TAG, "unhandled exception in export session: $t", t)
                onError("EXPORT_FAILED", t.message ?: t.javaClass.simpleName)
            }
        }.start()
    }

    // ─────────────────────────────────────────────────────────────────────────

    private data class ParsedClip(val sourcePath: String, val trimStart: Double, val trimEnd: Double)

    private data class ClipContext(
        val sourcePath: String,
        val trimStartSeconds: Double,
        val trimEndSeconds: Double,
        val decodedWidth: Int,
        val decodedHeight: Int,
        val rotationDegrees: Int,
    )

    private fun run(
        args: Map<*, *>?,
        onSuccess: (Map<String, Any?>) -> Unit,
        onError: (String, String?) -> Unit,
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

        val transitions = draftMap["transitions"] as? List<*> ?: emptyList<Any?>()
        if (transitions.isNotEmpty()) {
            onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: transitions are not supported")
            return
        }

        val overlays = draftMap["overlays"] as? List<*> ?: emptyList<Any?>()
        if (overlays.isNotEmpty()) {
            onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: overlays are not supported")
            return
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
            if (mediaKind != "video") {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: clip.mediaKind '$mediaKind' is not supported")
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
            if (speed != 1.0) {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: clip.speed != 1.0 is not supported")
                return
            }
            val isReversed = map["isReversed"] as? Boolean ?: false
            if (isReversed) {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: clip.isReversed is not supported")
                return
            }
            for (unsupportedKey in UNSUPPORTED_CLIP_KEYS) {
                if (map[unsupportedKey] != null) {
                    onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: clip.$unsupportedKey is not supported")
                    return
                }
            }
            if (sourcePath.startsWith("http://") || sourcePath.startsWith("https://")) {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: remote clip sources are not supported")
                return
            }
            if (!sourcePath.startsWith("/")) {
                onError("UNSUPPORTED_EXPORT_FEATURE", "exportTimeline: non-local clip sources are not supported")
                return
            }
            val file = File(sourcePath)
            if (!file.exists() || !file.canRead()) {
                onError("FILE_UNREADABLE", "exportTimeline: cannot read clip source: $sourcePath")
                return
            }
            parsedClips.add(ParsedClip(sourcePath, trimStart, trimEnd))
        }

        // ── 3. Probe decoded geometry + rotation for every clip ─────────────
        val clipContexts = mutableListOf<ClipContext>()
        for (clip in parsedClips) {
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
            clipContexts.add(
                ClipContext(
                    sourcePath = clip.sourcePath,
                    trimStartSeconds = clip.trimStart,
                    trimEndSeconds = clip.trimEnd,
                    decodedWidth = probe.width,
                    decodedHeight = probe.height,
                    rotationDegrees = normalizedRotation,
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

        fun deleteOwnedTemps() {
            try { File(videoTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            try { File(audioTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            try { File(finalTmpPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
            try { File(roiSidecarTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
        }

        if (cancelRequested) {
            deleteOwnedTemps()
            onError("EXPORT_CANCELLED", "exportTimeline: cancelled before encode started")
            return
        }

        val encoder = AndroidTimelineVideoEncoder(
            outputPath = videoTempPath,
            width = requestWidth,
            height = requestHeight,
            fps = requestFps,
            bitrateBps = requestBitrate,
        )
        activeEncoder = encoder

        val encodeResult = encoder.encode(
            clipContexts.map {
                AndroidTimelineVideoEncoder.ClipInput(
                    sourcePath = it.sourcePath,
                    trimStartSeconds = it.trimStartSeconds,
                    trimEndSeconds = it.trimEndSeconds,
                    decodedWidth = it.decodedWidth,
                    decodedHeight = it.decodedHeight,
                    rotationDegrees = it.rotationDegrees,
                )
            },
        )
        activeEncoder = null

        if (!encodeResult.success) {
            deleteOwnedTemps()
            if (cancelRequested || encodeResult.reason == "cancelled") {
                onError("EXPORT_CANCELLED", "exportTimeline: cancelled during video encode")
            } else {
                onError("EXPORT_FAILED", "exportTimeline: pass-1 video encode failed: ${encodeResult.reason}")
            }
            return
        }

        if (cancelRequested) {
            deleteOwnedTemps()
            onError("EXPORT_CANCELLED", "exportTimeline: cancelled after video encode")
            return
        }

        // ── 6. Pass 2: audio mux / mixdown ───────────────────────────────────
        val rawSidecar = draftMap["audioSidecar"] as? Map<*, *>
        val rawTracks = (rawSidecar?.get("tracks") as? List<*>) ?: emptyList<Any?>()
        val (specs, _) = AndroidAudioTrackSpec.parseList(rawTracks)

        val pass2Failure = runPass2Audio(
            specs = specs,
            videoTempPath = videoTempPath,
            audioTempPath = audioTempPath,
            finalTmpPath = finalTmpPath,
        )
        if (pass2Failure != null) {
            deleteOwnedTemps()
            onError("EXPORT_FAILED", "exportTimeline: pass-2 audio mux failed: $pass2Failure")
            return
        }

        if (cancelRequested) {
            deleteOwnedTemps()
            onError("EXPORT_CANCELLED", "exportTimeline: cancelled after audio mux")
            return
        }

        // ── 7. Finalize: measure duration on the completed temp, then rename ──
        // to the requested output. Rename only happens once every success
        // precondition is satisfied, so a pre-existing outputPath is never
        // clobbered by a partially-finalized export.
        val durationSeconds = probeMediaDurationSeconds(finalTmpPath)
        if (durationSeconds == null) {
            deleteOwnedTemps()
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
            onError("EXPORT_FAILED", "exportTimeline: failed to stage ROI sidecar at $roiSidecarTempPath")
            return
        }
        if (!AndroidTimelineRoiSidecarEmitter.finalizeSidecar(roiSidecarTempPath, roiSidecarPath)) {
            deleteOwnedTemps()
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
            onError("EXPORT_FAILED", "exportTimeline: failed to finalize output at $outputPath")
            return
        }
        try { File(videoTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
        try { File(audioTempPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}

        onSuccess(
            mapOf(
                "success" to true,
                "path" to outputPath,
                "durationSeconds" to durationSeconds,
                "width" to requestWidth,
                "height" to requestHeight,
                "fps" to requestFps,
                "exportRoiSidecarPath" to roiSidecarPath,
            ),
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pass 2: audio mux / mixdown helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Returns null on success, or a machine-readable failure reason string.
    private fun runPass2Audio(
        specs: List<AndroidAudioTrackSpec>,
        videoTempPath: String,
        audioTempPath: String,
        finalTmpPath: String,
    ): String? {
        if (specs.isEmpty()) {
            val remux = AndroidAudioRemuxer.remux(videoTempPath, null, finalTmpPath)
            return if (remux.success) null else "remux:${remux.reason}"
        }

        if (tryDirectCopy(specs, videoTempPath)) {
            val track = specs.first()
            val remux = AndroidAudioRemuxer.remux(videoTempPath, track.url, finalTmpPath)
            if (remux.success) return null
            return "direct_copy_remux:${remux.reason}"
        }

        val mix = AndroidAudioMixdownEngine.mix(specs)
        if (!mix.success || mix.pcm == null) {
            return "mixdown:${mix.reason}"
        }
        val aacResult = AndroidAacEncoder.encodePcm16ToM4a(
            pcm = mix.pcm,
            sampleRate = mix.sampleRate,
            channelCount = mix.channelCount,
            outputPath = audioTempPath,
        )
        if (!aacResult.success) {
            return "aac_encode:${aacResult.reason}"
        }
        val remux = AndroidAudioRemuxer.remux(videoTempPath, audioTempPath, finalTmpPath)
        return if (remux.success) null else "mixdown_remux:${remux.reason}"
    }

    /// Unit C direct-copy eligibility additionally requires (beyond Unit B's
    /// validator): sourceTrimStart ≈ 0.0, and the track duration must match
    /// both the probed source audio duration and the pass-1 video duration
    /// within 50 ms. Any mismatch falls back to the mixdown path.
    private fun tryDirectCopy(specs: List<AndroidAudioTrackSpec>, videoTempPath: String): Boolean {
        val verdict = AndroidAudioDirectCopyValidator.validate(specs)
        if (!verdict.eligible) return false

        val track = specs.first()
        if (abs(track.sourceTrimStart) > TRIM_START_TOLERANCE_SECONDS) return false

        val sourceAudioDuration = probeMediaDurationSeconds(track.url) ?: return false
        val pass1VideoDuration = probeMediaDurationSeconds(videoTempPath) ?: return false

        if (abs(track.duration - sourceAudioDuration) > DURATION_TOLERANCE_SECONDS) return false
        if (abs(track.duration - pass1VideoDuration) > DURATION_TOLERANCE_SECONDS) return false

        return true
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Probing helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Normalizes arbitrary (including negative) rotation-metadata degrees into
    /// the [0, 360) range. Callers must still validate the result is one of
    /// 0/90/180/270 -- this normalization alone does not guarantee that.
    private fun normalizeRotationDegrees(degrees: Int): Int = ((degrees % 360) + 360) % 360

    private data class VideoProbe(val width: Int, val height: Int, val rotationDegrees: Int)

    private fun probeVideoTrack(path: String): VideoProbe? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
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
            retriever.setDataSource(path)
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
        private const val TRIM_START_TOLERANCE_SECONDS = 0.001
        private const val DURATION_TOLERANCE_SECONDS = 0.05

        // Clip-level wire keys for features not implemented by Unit C's minimal
        // hard-cut passthrough. Presence of any of these (non-null) means the
        // clip requires rendering behaviour this exporter does not perform --
        // rejecting explicitly avoids silently producing wrong output.
        private val UNSUPPORTED_CLIP_KEYS = listOf(
            "freezePTS",
            "dualCamera",
            "timeRemap",
            "transformTrack",
            "transform",
            "colorMatrix",
            "cropRect",
        )
    }
}
