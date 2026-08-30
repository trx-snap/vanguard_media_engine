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
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.math.floor

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
//   - video-only clips, speed == 1.0, no transitions, no overlays, no canvas
//     contentMode other than "fit", no per-clip transform/crop/freeze/
//     reverse/time-remap/dual-camera. Per-clip colorMatrix is accepted and
//     applied to decoded video frames by whichever backend renders the clip
//     (Vulkan-native color-matrix push constants, or the GLES OES program's
//     colorMatrix uniforms -- see AndroidExportRenderBackendSelector); still-
//     image clips accept/carry colorMatrix but never apply it.
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
    @Volatile private var activeEncoder: AndroidTimelineVideoPassEncoder? = null

    /** Requests cancellation of the in-flight export. Thread-safe, non-blocking. */
    fun requestCancel() {
        cancelRequested = true
        activeEncoder?.cancel()
    }

    /// [onProgress], when non-null, receives overall export progress in
    /// [0.0, 1.0]: pass-1 (video encode) sample progress is mapped into
    /// [0.0, PASS1_PROGRESS_SAMPLE_MAX] (strictly below 0.85) via the
    /// encoder's own sample-ratio progress; the exact 0.85 checkpoint is
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
                onError("EXPORT_FAILED", t.message ?: t.javaClass.simpleName)
            }
        }.start()
    }

    // ─────────────────────────────────────────────────────────────────────────

    private data class ParsedClip(
        val sourcePath: String,
        val trimStart: Double,
        val trimEnd: Double,
        val mediaKind: String,
        val colorMatrix: FloatArray? = null,
    )

    private data class ClipContext(
        val sourcePath: String,
        val trimStartSeconds: Double,
        val trimEndSeconds: Double,
        val decodedWidth: Int,
        val decodedHeight: Int,
        val rotationDegrees: Int,
        val mediaKind: String,
        val exifOrientation: Int = ExifInterface.ORIENTATION_NORMAL,
        val colorMatrix: FloatArray? = null,
    )

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
            parsedClips.add(ParsedClip(sourcePath, trimStart, trimEnd, mediaKind, colorMatrix))
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
                        exifOrientation = imageProbe.exifOrientation,
                        colorMatrix = clip.colorMatrix,
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
            clipContexts.add(
                ClipContext(
                    sourcePath = clip.sourcePath,
                    trimStartSeconds = clip.trimStart,
                    trimEndSeconds = clip.trimEnd,
                    decodedWidth = probe.width,
                    decodedHeight = probe.height,
                    rotationDegrees = normalizedRotation,
                    mediaKind = clip.mediaKind,
                    colorMatrix = clip.colorMatrix,
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
            logTerminal("cancelled_before_encode", backend = null)
            onError("EXPORT_CANCELLED", "exportTimeline: cancelled before encode started")
            return
        }

        val clipInputs = mutableListOf<AndroidTimelineVideoEncoder.ClipInput>()
        for (ctx in clipContexts) {
            var stillFrameCount = 0
            if (ctx.mediaKind == "image") {
                val duration = ctx.trimEndSeconds - ctx.trimStartSeconds
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
            clipInputs.add(
                AndroidTimelineVideoEncoder.ClipInput(
                    sourcePath = ctx.sourcePath,
                    trimStartSeconds = ctx.trimStartSeconds,
                    trimEndSeconds = ctx.trimEndSeconds,
                    decodedWidth = ctx.decodedWidth,
                    decodedHeight = ctx.decodedHeight,
                    rotationDegrees = ctx.rotationDegrees,
                    mediaKind = ctx.mediaKind,
                    stillFrameCount = stillFrameCount,
                    exifOrientation = ctx.exifOrientation,
                    colorMatrix = ctx.colorMatrix,
                ),
            )
        }

        // Session-owned diagnostics/lifecycle/native-bridge triple for this
        // export run -- reused for backend selection and, when Vulkan is
        // selected, for AndroidTimelineVulkanVideoEncoder, instead of each
        // owner constructing its own VanguardNativeBridge.
        val sessionDiagnostics = VanguardDiagnostics()
        val sessionLifecycleObserver = VanguardLifecycleObserver(sessionDiagnostics)
        val sessionNativeBridge = VanguardNativeBridge(sessionLifecycleObserver, sessionDiagnostics, null)

        val backendDecision = AndroidExportRenderBackendSelector().select(
            ExportRenderScope(
                clips = clipInputs,
                requestedWidth = requestWidth,
                requestedHeight = requestHeight,
            ),
            nativeBridge = sessionNativeBridge,
        )
        // Backend that actually produced pass-1's output -- starts as the
        // selector's decision, and is updated to GLES if a Vulkan attempt
        // fails and this session falls back mid-export. Every terminal log
        // after pass-1 reports this value, not the original selector decision.
        var effectiveBackend = backendDecision.actualBackend

        // Pass-1 progress is scaled into [0.0, PASS1_PROGRESS_SAMPLE_MAX]; a
        // GLES fallback attempt reuses the same scaled callback and restarts
        // its own sample-ratio progress from 0, so a max-seen clamp is
        // required to prevent the fallback from regressing progress already
        // emitted by a partially-progressed Vulkan attempt.
        var maxPass1ProgressSeen = 0.0
        fun emitPass1Progress(sampleRatio: Double) {
            val scaled = (sampleRatio * PASS1_PROGRESS_SAMPLE_MAX).coerceIn(0.0, PASS1_PROGRESS_SAMPLE_MAX)
            if (scaled > maxPass1ProgressSeen) {
                maxPass1ProgressSeen = scaled
                onProgress?.invoke(scaled)
            }
        }

        fun buildPass1Encoder(backend: ExportRenderBackend): AndroidTimelineVideoPassEncoder {
            return if (backend == ExportRenderBackend.VULKAN) {
                AndroidTimelineVulkanVideoEncoder(
                    outputPath = videoTempPath,
                    width = requestWidth,
                    height = requestHeight,
                    fps = requestFps,
                    bitrateBps = requestBitrate,
                    nativeBridge = sessionNativeBridge,
                )
            } else {
                AndroidTimelineVideoEncoder(
                    outputPath = videoTempPath,
                    width = requestWidth,
                    height = requestHeight,
                    fps = requestFps,
                    bitrateBps = requestBitrate,
                )
            }
        }

        // [activeEncoder] is always cleared in `finally`, even if an encoder
        // unexpectedly throws instead of returning a failed EncodeResult, so
        // a later requestCancel() never holds a reference to a dead encoder.
        fun encodeWithActiveTracking(enc: AndroidTimelineVideoPassEncoder): AndroidTimelineVideoEncoder.EncodeResult {
            activeEncoder = enc
            try {
                return enc.encode(clipInputs) { p -> emitPass1Progress(p) }
            } finally {
                activeEncoder = null
            }
        }

        var encoder = buildPass1Encoder(effectiveBackend)
        var encodeResult = encodeWithActiveTracking(encoder)

        if (!encodeResult.success && effectiveBackend == ExportRenderBackend.VULKAN &&
            !cancelRequested && encodeResult.reason != "cancelled"
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
        private const val MAX_STILL_FRAME_COUNT = 36_000

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

        // Clip-level wire keys for features not implemented by Unit C's minimal
        // hard-cut passthrough. Presence of any of these (non-null) means the
        // clip requires rendering behaviour this exporter does not perform --
        // rejecting explicitly avoids silently producing wrong output.
        // colorMatrix is intentionally absent from this list (Phase 10): it is
        // parsed and validated explicitly above, then carried through
        // ParsedClip/ClipContext/ClipInput and applied by whichever backend
        // renders the clip -- see AndroidTimelineVulkanVideoEncoder (Vulkan)
        // and AndroidTimelineVideoEncoder (GLES).
        private val UNSUPPORTED_CLIP_KEYS = listOf(
            "freezePTS",
            "dualCamera",
            "timeRemap",
            "transformTrack",
            "transform",
            "cropRect",
        )
    }
}
