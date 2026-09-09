package com.connects.vanguard_media_engine.duet

import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import java.io.File
import java.util.UUID

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-SLICE-2: Android native session lifecycle and local source ingestion
// ─────────────────────────────────────────────────────────────────────────────
//
// Responsibilities:
//   - Validates local .mp4/.mov source via MediaMetadataRetriever / MediaExtractor.
//   - Manages the Duet session state machine (initialized → recording → paused → stopped).
//   - Enforces single active session invariant.
//   - Threading: probe runs on a HandlerThread; replies always on main thread.
//   - Generates wall-clock-based segment records (no real media).
//
// Out of scope: Camera2, GLES, Vulkan, real recording, GPU compositor.

// ─────────────────────────────────────────────────────────────────────────────
// State machine
// ─────────────────────────────────────────────────────────────────────────────

enum class VGDuetSessionState {
    INITIALIZED, RECORDING, PAUSED, STOPPED
}

// ─────────────────────────────────────────────────────────────────────────────
// Segment record (wall-clock, lifecycle only)
// ─────────────────────────────────────────────────────────────────────────────

data class VGDuetAndroidSegmentRecord(
    val index: Int,
    val durationMs: Int,
    val speedMultiplier: Double,
    val sourceStartMs: Int,
    val sourceEndMs: Int,
    val outputStartMs: Int,
    val outputEndMs: Int,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "segmentIndex"    to index,
        "durationMs"      to durationMs,
        "speedMultiplier" to speedMultiplier,
        "sourceStartMs"   to sourceStartMs,
        "sourceEndMs"     to sourceEndMs,
        "outputStartMs"   to outputStartMs,
        "outputEndMs"     to outputEndMs,
    )
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
) {
    var layoutConfigMap: Map<String, Any?> = layoutConfigMapInit
    var speedMultiplier: Double = speedInit
    var sourceGain: Double = sourceGainInit
    var micGain: Double = micGainInit
    var state: VGDuetSessionState = VGDuetSessionState.INITIALIZED
    var probeResult: VGDuetAndroidSourceProbeResult? = null

    private val segments = mutableListOf<VGDuetAndroidSegmentRecord>()
    private var segmentStartWallMs: Long = 0L
    private var outputCursorMs: Int = 0
    private var sourceCursorMs: Int = 0

    fun startSegment() {
        segmentStartWallMs = System.currentTimeMillis()
    }

    fun commitSegment() {
        val wallMs = maxOf(1, (System.currentTimeMillis() - segmentStartWallMs).toInt())
        val segStartOut = outputCursorMs
        val segEndOut   = outputCursorMs + wallMs
        val segStartSrc = sourceCursorMs
        val segEndSrc   = sourceCursorMs + wallMs
        segments += VGDuetAndroidSegmentRecord(
            index           = segments.size,
            durationMs      = wallMs,
            speedMultiplier = speedMultiplier,
            sourceStartMs   = segStartSrc,
            sourceEndMs     = segEndSrc,
            outputStartMs   = segStartOut,
            outputEndMs     = segEndOut,
        )
        outputCursorMs = segEndOut
        sourceCursorMs = segEndSrc
    }

    fun deleteLastSegment(): Boolean {
        if (segments.isEmpty()) return false
        val removed = segments.removeLast()
        outputCursorMs = removed.outputStartMs
        sourceCursorMs = removed.sourceStartMs
        return true
    }

    fun totalDurationMs(): Int = outputCursorMs
    fun segmentCount(): Int = segments.size

    fun buildStopResult(): Map<String, Any?> {
        val segmentMaps = segments.map { it.toMap() }
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
 * File probing runs on a dedicated HandlerThread and replies on the main thread.
 */
class AndroidDuetSessionCoordinator(private val mainHandler: Handler) {

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
    private val canceledProbeIds = mutableSetOf<String>()

    // HandlerThread for off-main probing
    private val probeThread = HandlerThread("vg.duet.probe").also { it.start() }
    private val probeHandler = Handler(probeThread.looper)

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
        // Must be called on main thread
        if (activeSession != null) {
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
        val session = VGDuetAndroidSession(
            sessionId        = sessionId,
            sourceMap        = sourceMap,
            trimWindowMap    = trimWindowMap,
            layoutConfigMapInit = layoutConfigMap,
            speedInit        = speed,
            sourceGainInit   = sourceGain,
            micGainInit      = micGain,
            trimStartMs      = trimStartMs,
            trimEndMs        = trimEndMs,
        )
        activeSession = session

        probeHandler.post {
            val probeResult = probeSource(filePath)

            mainHandler.post {
                // Check cancellation
                if (canceledProbeIds.contains(sessionId)) {
                    canceledProbeIds.remove(sessionId)
                    // Already replied via dispose — do not reply twice
                    return@post
                }

                val probVal = probeResult.getOrNull()
                if (probVal == null) {
                    activeSession = null
                    val msg = probeResult.exceptionOrNull()?.message
                        ?: "Source probe failed for '$filePath'."
                    reply(null, errorMsg("source_invalid", msg))
                    return@post
                }

                val trimErr = validateTrimWindow(trimStartMs, trimEndMs, probVal.durationMs)
                if (trimErr != null) {
                    activeSession = null
                    reply(null, errorMsg("source_invalid", trimErr))
                    return@post
                }

                session.probeResult = probVal
                reply(sessionId, null)
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
        session.state = VGDuetSessionState.PAUSED
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
        reply(null, null)
    }

    // ── stopRecording ─────────────────────────────────────────────────────────

    fun stopRecording(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "stopDuetRecording", reply) ?: return
        when (session.state) {
            VGDuetSessionState.RECORDING -> session.commitSegment()
            VGDuetSessionState.PAUSED    -> { /* already committed */ }
            else -> {
                reply(null, invalidState("stopDuetRecording", session.state.name, expected = "RECORDING or PAUSED"))
                return
            }
        }
        session.state = VGDuetSessionState.STOPPED
        activeSession = null
        reply(session.buildStopResult(), null)
    }

    // ── disposeSession (idempotent) ────────────────────────────────────────────

    fun disposeSession(sessionId: String, reply: (Any?, String?) -> Unit) {
        val current = activeSession
        if (current != null && current.sessionId == sessionId) {
            canceledProbeIds += sessionId
            activeSession = null
        }
        reply(null, null)
    }

    // ── disposeAll ────────────────────────────────────────────────────────────

    fun disposeAll() {
        activeSession?.let { canceledProbeIds += it.sessionId }
        activeSession = null
        try {
            probeThread.quitSafely()
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
