package com.connects.vanguard_media_engine.duet

import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.HandlerThread
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.UUID

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-SLICE-3: Android native session lifecycle, clock & decoder integration
// ─────────────────────────────────────────────────────────────────────────────
//
// Responsibilities:
//   - Validates local .mp4/.mov source via MediaMetadataRetriever / MediaExtractor.
//   - Manages the Duet session state machine (initialized → recording → paused / completed → stopped).
//   - Integrates AndroidDuetPreviewClock for timing math, speed scaling, trim window cursors, rollback.
//   - Integrates AndroidDuetSourceVideoDecoder for preparing, priming at trimStart, and stepping/seeking.
//   - Enforces single active session invariant.
//   - Threading: probe runs on probeThread; decoder work runs on decoderThread;
//     replies always on main thread.
//   - Asynchronous decoder release without blocking the main thread.
//   - Auto-stop: if trimEnd is reached, enters COMPLETED state; stopDuetRecording returns descriptor.

// ─────────────────────────────────────────────────────────────────────────────
// State machine
// ─────────────────────────────────────────────────────────────────────────────

enum class VGDuetSessionState {
    INITIALIZED, RECORDING, PAUSED, COMPLETED, STOPPED
}

// ─────────────────────────────────────────────────────────────────────────────
// Source probe result
// ─────────────────────────────────────────────────────────────────────────────

data class VGDuetAndroidSourceProbeResult(
    val durationMs: Int,
    val hasVideoTrack: Boolean,
    val hasAudioTrack: Boolean,
)

// ─────────────────────────────────────────────────────────────────────────────
// Session
// ─────────────────────────────────────────────────────────────────────────────

class VGDuetAndroidSession(
    val sessionId: String,
    val sourceMap: Map<String, Any?>,
    val trimWindowMap: Map<String, Any?>,
    layoutConfigMapInit: Map<String, Any?>,
    speedInit: Double,
    sourceGainInit: Double,
    micGainInit: Double,
    val trimStartMs: Int,
    val trimEndMs: Int,
    val previewClock: AndroidDuetPreviewClock,
    var decoder: AndroidDuetSourceVideoDecoder?,
) {
    var layoutConfigMap: Map<String, Any?> = layoutConfigMapInit
    var speedMultiplier: Double = speedInit
    var sourceGain: Double = sourceGainInit
    var micGain: Double = micGainInit
    var state: VGDuetSessionState = VGDuetSessionState.INITIALIZED
    var probeResult: VGDuetAndroidSourceProbeResult? = null

    // Slice 4A: preview surface producer attachment.
    // Allocated on attachDuetPreviewTexture, released on detach/stop/dispose.
    var previewProducer: AndroidDuetPreviewSurfaceProducer? = null
    // Original dimensions and layout rects stored on first attach;
    // returned verbatim on repeated (idempotent) attach calls.
    var previewWidthPx:    Int? = null
    var previewHeightPx:   Int? = null
    var previewLayoutRects: Map<String, Any>? = null

    fun startSegment() {
        previewClock.startSegment()
    }

    fun commitSegment() {
        previewClock.commitSegment()
    }

    fun deleteLastSegment(): Boolean {
        return previewClock.deleteLastSegment()
    }

    fun totalDurationMs(): Int = previewClock.totalDurationMs()
    fun segmentCount(): Int = previewClock.segmentCount()

    fun buildStopResult(): Map<String, Any?> {
        val segmentMaps = previewClock.segments.map { it.toMap() }
        val descriptor: Map<String, Any?> = mapOf(
            "source"           to sourceMap,
            "layoutConfig"     to layoutConfigMap,
            "trimWindow"       to trimWindowMap,
            "initialSpeed"     to speedMultiplier,
            "segments"         to segmentMaps,
            "sourceAudioGain"  to sourceGain,
            "micAudioGain"     to micGain,
            "sourceAudioMuted" to (sourceGain < 0.0001),
            "micAudioMuted"    to (micGain < 0.0001),
        )
        return mapOf(
            "compositionDescriptor" to descriptor,
            "totalDurationMs"       to maxOf(1, totalDurationMs()),
            "segmentCount"          to maxOf(1, segmentCount()),
            "segmentAssets"         to emptyList<String>(),
            "proofOutputPath"       to null,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Coordinator
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Owns the single active Duet session and all lifecycle transitions.
 *
 * All public methods are called on the main thread by AndroidDuetMethodHandler.
 * File probing runs on probeThread; decoder operations run on decoderThread.
 */
class AndroidDuetSessionCoordinator(
    private val mainHandler: Handler,
    private val textureRegistry: TextureRegistry? = null,
) {

    companion object {
        private val VALID_SPEEDS = setOf(0.3, 0.5, 1.0, 2.0, 3.0)
        private const val SPEED_EPSILON = 0.001

        fun isValidSpeed(speed: Double): Boolean =
            VALID_SPEEDS.any { Math.abs(it - speed) < SPEED_EPSILON }

        fun validatePipRect(rectMap: Map<*, *>): String? {
            val left   = (rectMap["left"]   as? Number)?.toDouble() ?: return "PiP rect missing 'left'."
            val top    = (rectMap["top"]    as? Number)?.toDouble() ?: return "PiP rect missing 'top'."
            val width  = (rectMap["width"]  as? Number)?.toDouble() ?: return "PiP rect missing 'width'."
            val height = (rectMap["height"] as? Number)?.toDouble() ?: return "PiP rect missing 'height'."
            if (left < 0 || top < 0 || width <= 0 || height <= 0)
                return "PiP rect has invalid values (left=$left, top=$top, w=$width, h=$height)."
            if (left + width > 1.0 || top + height > 1.0)
                return "PiP rect exceeds canvas bounds (right=${left+width}, bottom=${top+height})."
            return null
        }

        /** Probes a local .mp4/.mov file. Intended to be called off main thread. */
        fun probeSource(filePath: String): Result<VGDuetAndroidSourceProbeResult> {
            val lower = filePath.lowercase()
            if (!lower.endsWith(".mp4") && !lower.endsWith(".mov")) {
                return Result.failure(IllegalArgumentException(
                    "Source file must be .mp4 or .mov (got '$filePath')"))
            }

            // Resolve to plain path from file:// URI
            val resolvedPath = if (filePath.startsWith("file://")) {
                try {
                    java.net.URI(filePath).path ?: filePath
                } catch (_: Exception) {
                    return Result.failure(IllegalArgumentException("Invalid file:// URI: '$filePath'"))
                }
            } else {
                filePath
            }

            if (!File(resolvedPath).exists()) {
                return Result.failure(IllegalArgumentException(
                    "Source file does not exist at path: '$resolvedPath'"))
            }

            // Probe duration and tracks via MediaMetadataRetriever
            val retriever = MediaMetadataRetriever()
            val durationMs: Int
            try {
                retriever.setDataSource(resolvedPath)
                val durStr = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?: return Result.failure(IllegalArgumentException(
                        "Could not read duration from '$resolvedPath'"))
                durationMs = durStr.toIntOrNull()
                    ?: return Result.failure(IllegalArgumentException(
                        "Duration is not a valid integer: '$durStr'"))
                if (durationMs <= 0) {
                    return Result.failure(IllegalArgumentException(
                        "Source file has zero or negative duration: '$resolvedPath'"))
                }
            } catch (e: Exception) {
                return Result.failure(IllegalArgumentException(
                    "Failed to read metadata from '$resolvedPath': ${e.message}"))
            } finally {
                try { retriever.release() } catch (_: Exception) {}
            }

            // Check video/audio tracks via MediaExtractor
            val extractor = MediaExtractor()
            var hasVideoTrack = false
            var hasAudioTrack = false
            try {
                extractor.setDataSource(resolvedPath)
                for (i in 0 until extractor.trackCount) {
                    val fmt = extractor.getTrackFormat(i)
                    val mime = fmt.getString(android.media.MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/")) hasVideoTrack = true
                    if (mime.startsWith("audio/")) hasAudioTrack = true
                }
            } catch (e: Exception) {
                return Result.failure(IllegalArgumentException(
                    "Failed to inspect tracks from '$resolvedPath': ${e.message}"))
            } finally {
                try { extractor.release() } catch (_: Exception) {}
            }

            if (!hasVideoTrack) {
                return Result.failure(IllegalArgumentException(
                    "Source file has no video track: '$resolvedPath'"))
            }

            return Result.success(VGDuetAndroidSourceProbeResult(
                durationMs    = durationMs,
                hasVideoTrack = true,
                hasAudioTrack = hasAudioTrack,
            ))
        }

        fun validateTrimWindow(trimStartMs: Int, trimEndMs: Int, sourceDurationMs: Int): String? {
            if (trimStartMs < 0) return "Trim start must be >= 0 (got $trimStartMs ms)."
            if (trimEndMs <= trimStartMs)
                return "Trim end ($trimEndMs ms) must be > trim start ($trimStartMs ms)."
            if (trimEndMs - trimStartMs < 1000)
                return "Trim window duration must be >= 1.0 s (got ${trimEndMs - trimStartMs} ms)."
            if (trimStartMs >= sourceDurationMs)
                return "Trim start ($trimStartMs ms) must be < source duration ($sourceDurationMs ms)."
            if (trimEndMs > sourceDurationMs)
                return "Trim end ($trimEndMs ms) exceeds source duration ($sourceDurationMs ms)."
            return null
        }
    }

    // ── State ─────────────────────────────────────────────────────────────────

    @Volatile private var activeSession: VGDuetAndroidSession? = null
    @Volatile private var pendingSessionId: String? = null
    private val canceledProbeIds = mutableSetOf<String>()

    // Dedicated background threads (never block main thread)
    private val probeThread = HandlerThread("vg.duet.probe").also { it.start() }
    private val probeHandler = Handler(probeThread.looper)

    private val decoderThread = HandlerThread("vg.duet.decoder").also { it.start() }
    private val decoderHandler = Handler(decoderThread.looper)

    // ── initialize ────────────────────────────────────────────────────────────

    fun initializeSession(
        sourceMap: Map<String, Any?>,
        trimWindowMap: Map<String, Any?>,
        layoutConfigMap: Map<String, Any?>,
        speed: Double,
        sourceGain: Double,
        micGain: Double,
        reply: (String?, String?) -> Unit, // (sessionId?, errorMessage?)
    ) {
        if (activeSession != null || pendingSessionId != null) {
            reply(null, errorMsg("session_conflict",
                "A Duet session is already active. Dispose it before initializing a new one."))
            return
        }

        val trimStartSec = (trimWindowMap["startSeconds"] as? Number)?.toDouble()
        val trimEndSec   = (trimWindowMap["endSeconds"]   as? Number)?.toDouble()
        if (trimStartSec == null || trimEndSec == null) {
            reply(null, errorMsg("source_invalid",
                "initializeDuetSession: trimWindow is missing startSeconds/endSeconds."))
            return
        }
        val trimStartMs = (trimStartSec * 1000).toInt()
        val trimEndMs   = (trimEndSec   * 1000).toInt()

        val filePath = (sourceMap["filePath"] as? String)?.trim() ?: ""
        if (filePath.isEmpty()) {
            reply(null, errorMsg("source_invalid",
                "initializeDuetSession: source.filePath is empty or missing."))
            return
        }
        if (!isValidSpeed(speed)) {
            reply(null, errorMsg("source_invalid",
                "initializeDuetSession: speed $speed is not one of $VALID_SPEEDS."))
            return
        }
        if (sourceGain < 0.0 || sourceGain > 1.0) {
            reply(null, errorMsg("source_invalid",
                "initializeDuetSession: sourceGain must be in [0.0, 1.0]."))
            return
        }
        if (micGain < 0.0 || micGain > 1.0) {
            reply(null, errorMsg("source_invalid",
                "initializeDuetSession: micGain must be in [0.0, 1.0]."))
            return
        }

        val sessionId = UUID.randomUUID().toString()
        pendingSessionId = sessionId

        probeHandler.post {
            val probeResult = probeSource(filePath)

            val probVal = probeResult.getOrNull()
            if (probVal == null) {
                mainHandler.post {
                    if (pendingSessionId == sessionId) {
                        pendingSessionId = null
                    }
                    if (canceledProbeIds.contains(sessionId)) {
                        canceledProbeIds.remove(sessionId)
                        return@post
                    }
                    val msg = probeResult.exceptionOrNull()?.message
                        ?: "Source probe failed for '$filePath'."
                    reply(null, errorMsg("source_invalid", msg))
                }
                return@post
            }

            val trimErr = validateTrimWindow(trimStartMs, trimEndMs, probVal.durationMs)
            if (trimErr != null) {
                mainHandler.post {
                    if (pendingSessionId == sessionId) {
                        pendingSessionId = null
                    }
                    if (canceledProbeIds.contains(sessionId)) {
                        canceledProbeIds.remove(sessionId)
                        return@post
                    }
                    reply(null, errorMsg("source_invalid", trimErr))
                }
                return@post
            }

            // Prime decoder on decoderHandler at trimStartMs
            decoderHandler.post {
                val decoder = AndroidDuetSourceVideoDecoder(filePath = filePath)
                var prepErr: String? = null
                try {
                    // Slice 4B-A: headless sink for now; a compositor-owned Surface
                    // arrives via rebindOutputSurface in a later slice.
                    decoder.prepare(trimStartMs.toLong(), outputSurface = null)
                } catch (e: Exception) {
                    prepErr = e.message ?: "Failed to prepare decoder."
                }

                mainHandler.post {
                    if (pendingSessionId == sessionId) {
                        pendingSessionId = null
                    }
                    if (canceledProbeIds.contains(sessionId)) {
                        canceledProbeIds.remove(sessionId)
                        decoderHandler.post { decoder.release() }
                        return@post
                    }

                    if (prepErr != null) {
                        decoderHandler.post { decoder.release() }
                        reply(null, errorMsg("source_invalid", prepErr))
                        return@post
                    }

                    val clock = AndroidDuetPreviewClock(
                        trimStartMs = trimStartMs,
                        trimEndMs   = trimEndMs,
                        initialSpeed = speed,
                    )

                    val session = VGDuetAndroidSession(
                        sessionId           = sessionId,
                        sourceMap           = sourceMap,
                        trimWindowMap       = trimWindowMap,
                        layoutConfigMapInit = layoutConfigMap,
                        speedInit           = speed,
                        sourceGainInit      = sourceGain,
                        micGainInit         = micGain,
                        trimStartMs         = trimStartMs,
                        trimEndMs           = trimEndMs,
                        previewClock        = clock,
                        decoder             = decoder,
                    )
                    session.probeResult = probVal
                    activeSession = session
                    reply(sessionId, null)
                }
            }
        }
    }

    // ── updateLayout ──────────────────────────────────────────────────────────

    fun updateLayout(sessionId: String, layoutConfigMap: Map<String, Any?>, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "updateDuetLayout", reply) ?: return
        if (session.state == VGDuetSessionState.STOPPED) {
            reply(null, invalidState("updateDuetLayout", "stopped")); return
        }
        if (layoutConfigMap["mode"] == "pip") {
            @Suppress("UNCHECKED_CAST")
            val rectMap = layoutConfigMap["pipNormalizedRect"] as? Map<*, *>
            if (rectMap != null) {
                val err = validatePipRect(rectMap)
                if (err != null) { reply(null, errorMsg("source_invalid", err)); return }
            }
        }
        session.layoutConfigMap = layoutConfigMap
        reply(null, null)
    }

    // ── setRecordingSpeed ─────────────────────────────────────────────────────

    fun setRecordingSpeed(sessionId: String, speed: Double, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "setDuetRecordingSpeed", reply) ?: return
        if (session.state == VGDuetSessionState.STOPPED) {
            reply(null, invalidState("setDuetRecordingSpeed", "stopped")); return
        }
        if (!isValidSpeed(speed)) {
            reply(null, errorMsg("source_invalid",
                "setDuetRecordingSpeed: speed $speed is not one of $VALID_SPEEDS.")); return
        }
        session.speedMultiplier = speed
        session.previewClock.setSpeed(speed)
        reply(null, null)
    }

    // ── setAudioMixGains ──────────────────────────────────────────────────────

    fun setAudioMixGains(sessionId: String, sourceGain: Double, micGain: Double, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "setDuetAudioMixGains", reply) ?: return
        if (session.state == VGDuetSessionState.STOPPED) {
            reply(null, invalidState("setDuetAudioMixGains", "stopped")); return
        }
        if (sourceGain < 0.0 || sourceGain > 1.0) {
            reply(null, errorMsg("source_invalid", "setDuetAudioMixGains: sourceGain must be in [0.0, 1.0].")); return
        }
        if (micGain < 0.0 || micGain > 1.0) {
            reply(null, errorMsg("source_invalid", "setDuetAudioMixGains: micGain must be in [0.0, 1.0].")); return
        }
        session.sourceGain = sourceGain
        session.micGain    = micGain
        reply(null, null)
    }

    // ── startRecording ────────────────────────────────────────────────────────

    fun startRecording(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "startDuetRecording", reply) ?: return
        if (session.state != VGDuetSessionState.INITIALIZED) {
            reply(null, invalidState("startDuetRecording", session.state.name, expected = "INITIALIZED")); return
        }
        session.state = VGDuetSessionState.RECORDING
        session.startSegment()
        reply(null, null)
    }

    // ── pauseRecording ────────────────────────────────────────────────────────

    fun pauseRecording(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "pauseDuetRecording", reply) ?: return
        if (session.state != VGDuetSessionState.RECORDING) {
            reply(null, invalidState("pauseDuetRecording", session.state.name, expected = "RECORDING")); return
        }
        session.commitSegment()
        session.state = if (session.previewClock.isAutoStopped) VGDuetSessionState.COMPLETED else VGDuetSessionState.PAUSED
        val targetPts = session.previewClock.currentSourcePtsMs().toLong()
        val dec = session.decoder
        if (dec != null) {
            decoderHandler.post { dec.stepFrame(targetPts) }
        }
        reply(null, null)
    }

    // ── resumeRecording ───────────────────────────────────────────────────────

    fun resumeRecording(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "resumeDuetRecording", reply) ?: return
        if (session.state != VGDuetSessionState.PAUSED) {
            reply(null, invalidState("resumeDuetRecording", session.state.name, expected = "PAUSED")); return
        }
        session.state = VGDuetSessionState.RECORDING
        session.startSegment()
        reply(null, null)
    }

    // ── deleteLastSegment ─────────────────────────────────────────────────────

    fun deleteLastSegment(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "deleteLastDuetSegment", reply) ?: return
        if (session.state == VGDuetSessionState.STOPPED) {
            reply(null, invalidState("deleteLastDuetSegment", "STOPPED")); return
        }
        session.deleteLastSegment()
        if (session.state == VGDuetSessionState.COMPLETED) {
            session.state = VGDuetSessionState.PAUSED
        }
        val targetPts = session.previewClock.currentSourcePtsMs().toLong()
        val dec = session.decoder
        if (dec != null) {
            decoderHandler.post { dec.seekTo(targetPts) }
        }
        reply(null, null)
    }

    // ── attachPreviewTexture (Slice 4A) ───────────────────────────────────────

    fun attachPreviewTexture(
        sessionId:       String,
        canvasSizeMap:   Map<String, Any?>,
        layoutConfigMap: Map<String, Any?>?,
        reply:           (Any?, String?) -> Unit,
    ) {
        val session = resolveSession(sessionId, "attachDuetPreviewTexture", reply) ?: return

        // Idempotent: return the ORIGINAL stored descriptor, not dims from the new request.
        val existing = session.previewProducer
        if (existing != null) {
            val storedWidth  = session.previewWidthPx
            val storedHeight = session.previewHeightPx
            if (storedWidth == null || storedHeight == null) {
                reply(null, errorMsg("composition_failed",
                    "attachDuetPreviewTexture: preview descriptor missing for existing texture."))
                return
            }
            reply(existing.toResultMap(storedWidth, storedHeight, session.previewLayoutRects), null)
            return
        }

        val registry = textureRegistry
        if (registry == null) {
            reply(null, errorMsg("composition_failed",
                "attachDuetPreviewTexture: textureRegistry not available."))
            return
        }

        val widthPx  = ((canvasSizeMap["width"]  as? Number)?.toDouble() ?: 1080.0).toInt()
        val heightPx = ((canvasSizeMap["height"] as? Number)?.toDouble() ?: 1920.0).toInt()

        // Finding #3: wrap producer construction; don't partially attach on failure.
        val producer = try {
            AndroidDuetPreviewSurfaceProducer(
                textureRegistry = registry,
                mainHandler     = mainHandler,
                widthPx         = widthPx,
                heightPx        = heightPx,
            )
        } catch (t: Throwable) {
            reply(null, errorMsg("composition_failed",
                "attachDuetPreviewTexture: failed to create SurfaceProducer: ${t.message}"))
            return
        }
        session.previewProducer = producer

        // Compute optional layout rects from the effective layoutConfig.
        val effectiveLayoutMap = layoutConfigMap ?: session.layoutConfigMap
        val layoutRects = buildLayoutRects(effectiveLayoutMap, widthPx.toDouble(), heightPx.toDouble())

        // Store original values so idempotent re-attach returns them verbatim.
        session.previewWidthPx    = widthPx
        session.previewHeightPx   = heightPx
        session.previewLayoutRects = layoutRects

        reply(producer.toResultMap(widthPx, heightPx, layoutRects), null)
    }

    // ── detachPreviewTexture (Slice 4A) ───────────────────────────────────────

    fun detachPreviewTexture(sessionId: String, reply: (Any?, String?) -> Unit) {
        // Unknown session → session_not_found per contract.
        val session = resolveSession(sessionId, "detachDuetPreviewTexture", reply) ?: return
        // Idempotent if no attachment exists; helper clears all stored fields.
        releasePreviewProducer(session)
        reply(null, null)
    }

    // ── Preview release helper ────────────────────────────────────────────────

    /**
     * Releases and nulls the session's preview producer if one is attached.
     *
     * Slice 4B-A two-phase seam: beginRelease() detaches callbacks and marks DETACHED;
     * a later compositor stop belongs between the two calls. No compositor exists yet,
     * so the phases run back to back.
     */
    private fun releasePreviewProducer(session: VGDuetAndroidSession) {
        val producer = session.previewProducer
        if (producer != null) {
            producer.beginRelease()
            producer.finishRelease()
        }
        session.previewProducer    = null
        session.previewWidthPx     = null
        session.previewHeightPx    = null
        session.previewLayoutRects = null
    }

    // ── Layout rect builder ───────────────────────────────────────────────────

    @Suppress("UNCHECKED_CAST")
    private fun buildLayoutRects(
        layoutConfigMap: Map<String, Any?>,
        canvasWidth:  Double,
        canvasHeight: Double,
    ): Map<String, Any>? {
        val mode = layoutConfigMap["mode"] as? String ?: "pip"
        return when (mode) {
            "splitLeftRight" -> {
                val swapped = layoutConfigMap["isSideSwapped"] as? Boolean ?: false
                val rects = AndroidDuetLayoutGeometry.splitLeftRight(canvasWidth, canvasHeight, swapped)
                mapOf("source" to rects.source.toMap(), "camera" to rects.camera.toMap())
            }
            "splitTopBottom" -> {
                val swapped = layoutConfigMap["isTopBottomSwapped"] as? Boolean ?: false
                val rects = AndroidDuetLayoutGeometry.splitTopBottom(canvasWidth, canvasHeight, swapped)
                mapOf("source" to rects.source.toMap(), "camera" to rects.camera.toMap())
            }
            "pip" -> {
                val sourceRect = AndroidDuetLayoutGeometry.pipSourceRect(canvasWidth, canvasHeight)
                var cameraRect = sourceRect
                val rectMap = layoutConfigMap["pipNormalizedRect"] as? Map<*, *>
                if (rectMap != null) {
                    val nl = (rectMap["left"]   as? Number)?.toDouble()
                    val nt = (rectMap["top"]    as? Number)?.toDouble()
                    val nw = (rectMap["width"]  as? Number)?.toDouble()
                    val nh = (rectMap["height"] as? Number)?.toDouble()
                    if (nl != null && nt != null && nw != null && nh != null) {
                        cameraRect = AndroidDuetLayoutGeometry.pipCameraRect(
                            canvasWidth, canvasHeight, nl, nt, nw, nh)
                    }
                }
                mapOf("source" to sourceRect.toMap(), "camera" to cameraRect.toMap())
            }
            "greenScreen" -> {
                val rects = AndroidDuetLayoutGeometry.greenScreen(canvasWidth, canvasHeight)
                mapOf("source" to rects.source.toMap(), "camera" to rects.camera.toMap())
            }
            else -> null
        }
    }

    // ── stopRecording ─────────────────────────────────────────────────────────

    fun stopRecording(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "stopDuetRecording", reply) ?: return
        when (session.state) {
            VGDuetSessionState.RECORDING -> session.commitSegment()
            VGDuetSessionState.PAUSED, VGDuetSessionState.COMPLETED -> { /* already committed */ }
            else -> {
                reply(null, invalidState("stopDuetRecording", session.state.name, expected = "RECORDING, PAUSED, or COMPLETED"))
                return
            }
        }
        session.state = VGDuetSessionState.STOPPED
        val dec = session.decoder
        session.decoder = null
        releasePreviewProducer(session)  // Slice 4A: detach before drop
        activeSession = null
        decoderHandler.post { dec?.release() }
        reply(session.buildStopResult(), null)
    }

    // ── disposeSession (idempotent) ────────────────────────────────────────────

    fun disposeSession(sessionId: String, reply: (Any?, String?) -> Unit) {
        if (pendingSessionId == sessionId) {
            canceledProbeIds += sessionId
            pendingSessionId = null
        }
        val current = activeSession
        if (current != null && current.sessionId == sessionId) {
            canceledProbeIds += sessionId
            val dec = current.decoder
            current.decoder = null
            releasePreviewProducer(current)  // Slice 4A: detach before drop
            activeSession = null
            decoderHandler.post { dec?.release() }
        }
        reply(null, null)
    }

    // ── disposeAll ────────────────────────────────────────────────────────────

    fun disposeAll() {
        val pending = pendingSessionId
        if (pending != null) {
            canceledProbeIds += pending
            pendingSessionId = null
        }
        val current = activeSession
        if (current != null) {
            canceledProbeIds += current.sessionId
            val dec = current.decoder
            current.decoder = null
            releasePreviewProducer(current)  // Slice 4A: detach before drop
            decoderHandler.post { dec?.release() }
        }
        activeSession = null
        try {
            probeThread.quitSafely()
        } catch (_: Exception) {}
        try {
            decoderThread.quitSafely()
        } catch (_: Exception) {}
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private fun resolveSession(
        sessionId: String,
        route: String,
        reply: (Any?, String?) -> Unit,
    ): VGDuetAndroidSession? {
        val session = activeSession
        if (session == null || session.sessionId != sessionId) {
            reply(null, errorMsg("session_not_found",
                "No active Duet session with id '$sessionId'."))
            return null
        }
        return session
    }

    private fun invalidState(route: String, current: String, expected: String? = null): String {
        val msg = if (expected != null)
            "$route: invalid state transition — current state is '$current', expected '$expected'."
        else
            "$route: operation not valid in state '$current'."
        return errorMsg("invalid_state", msg)
    }

    /** Encodes error as "code|message" for the handler to decode and surface as FlutterError. */
    private fun errorMsg(code: String, message: String): String = "$code|$message"
}
