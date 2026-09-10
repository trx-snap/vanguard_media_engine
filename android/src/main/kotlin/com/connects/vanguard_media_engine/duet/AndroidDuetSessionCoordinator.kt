package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import androidx.camera.core.ImageAnalysis
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
//   - Slice 4B-C: wires AndroidDuetPreviewRenderLoop behind the preview texture
//     lifecycle (attach / surface available / surface lost / detach) and the
//     recording transport (start/pause/resume/deleteLastSegment/updateLayout).

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
    // Slice 4B-C: render loop pumping decoder frames into the producer's Surface.
    // Created alongside previewProducer, stopped and cleared with it.
    var previewRenderLoop: AndroidDuetPreviewRenderLoop? = null
    // Live camera source for duet preview — started on attach, stopped with renderLoop.
    var cameraSource: AndroidDuetCameraSource? = null
    // Green-screen segmentation adapter — started when layout mode is greenScreen,
    // stopped on fallback or layout mode switch.
    var greenScreenAdapter: AndroidDuetGreenScreenAdapter? = null
    // Original dimensions and layout rects stored on first attach;
    // returned verbatim on repeated (idempotent) attach calls.
    var previewWidthPx:    Int? = null
    var previewHeightPx:   Int? = null
    var previewLayoutRects: Map<String, Any>? = null
    // Typed twin of previewLayoutRects, fed to the render loop on (re)attach.
    // Recomputed by updateLayout while a preview is attached.
    var previewTypedLayoutRects: VGDuetLayoutRects? = null

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
    private val context: Context? = null,
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
                    // Headless sink until a preview attaches; the render loop then
                    // rebinds the compositor-owned Surface via rebindOutputSurface.
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
        val newMode = layoutConfigMap["mode"] as? String ?: "pip"
        // Slice green-screen: handle mode switch without restarting the whole session.
        val widthPx  = session.previewWidthPx
        val heightPx = session.previewHeightPx
        if (widthPx != null && heightPx != null) {
            val typedRects = buildTypedLayoutRects(layoutConfigMap, widthPx.toDouble(), heightPx.toDouble())
            session.previewTypedLayoutRects = typedRects
            session.previewLayoutRects = typedRects?.let {
                mapOf("source" to it.source.toMap(), "camera" to it.camera.toMap())
            }
            if (typedRects != null) {
                session.previewRenderLoop?.updateLayout(
                    typedRects.source,
                    typedRects.camera,
                    session.previewClock.currentSourcePtsMs().toLong(),
                )
            }
            // Enable/disable green-screen compositing based on the new mode.
            if (newMode == "greenScreen") {
                // Switching into greenScreen: build adapter if not already running,
                // then hot-rebind the analysis use-case via setAnalysisAnalyzer.
                if (session.greenScreenAdapter == null) {
                    val adapter = buildGreenScreenAdapter(session)
                    if (adapter != null) {
                        // Hot-rebind: camera is already running, add ImageAnalysis.
                        // If the rebind fails, fall back to safe PiP immediately.
                        val bound = session.cameraSource?.setAnalysisAnalyzer(adapter) ?: false
                        if (!bound) {
                            Log.w("DuetCoordinator",
                                "setAnalysisAnalyzer failed during greenScreen switch — PiP fallback")
                            handleGreenScreenFallback(session, DuetSegmentationBackend.MLKIT,
                                DuetSegmentationBackend.NONE, "bind_failed")
                            reply(null, null)
                            return
                        }
                    } else {
                        // Adapter creation failed — fall back immediately.
                        Log.w("DuetCoordinator",
                            "buildGreenScreenAdapter returned null — PiP fallback")
                        handleGreenScreenFallback(session, DuetSegmentationBackend.MLKIT,
                            DuetSegmentationBackend.NONE, "adapter_creation_failed")
                        reply(null, null)
                        return
                    }
                }
                session.previewRenderLoop?.setGreenScreenEnabled(true)
            } else {
                // Switching away from greenScreen: remove analysis use-case,
                // stop adapter, disable compositor. Camera Preview continues.
                session.cameraSource?.setAnalysisAnalyzer(null)
                stopGreenScreenAdapter(session)
                session.previewRenderLoop?.setGreenScreenEnabled(false)
            }
        }
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
        // Slice 4B-C: active playback. The provider runs on the main thread only,
        // so reading the preview clock here is safe.
        session.previewRenderLoop?.startActive {
            session.previewClock.currentSourcePtsMs().toLong()
        }
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
        session.previewRenderLoop?.pauseAndHold(targetPts)
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
        session.previewRenderLoop?.startActive {
            session.previewClock.currentSourcePtsMs().toLong()
        }
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
        session.previewRenderLoop?.seekAndHold(targetPts)
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
        // Slice 4B-C: hooks capture the sessionId only; everything else is
        // resolved through activeSession when the callback fires.
        val producer = try {
            AndroidDuetPreviewSurfaceProducer(
                textureRegistry    = registry,
                mainHandler        = mainHandler,
                widthPx            = widthPx,
                heightPx           = heightPx,
                onSurfaceAvailable = { handlePreviewSurfaceAvailable(sessionId) },
                onSurfaceLost      = { handlePreviewSurfaceLost(sessionId) },
            )
        } catch (t: Throwable) {
            reply(null, errorMsg("composition_failed",
                "attachDuetPreviewTexture: failed to create SurfaceProducer: ${t.message}"))
            return
        }

        val renderLoop = try {
            AndroidDuetPreviewRenderLoop(
                mainHandler     = mainHandler,
                decoderHandler  = decoderHandler,
                decoderProvider = { session.decoder },
                // Defect 1 fix: receive the compositor's cameraInputSurface on the
                // main thread once the render-thread EGL bootstrap completes, then
                // call the centralized startCameraSourceIfNeeded — no synchronous
                // post-attach read of cameraInputSurface.
                cameraInputSurfaceReady = { camSurface ->
                    startCameraSourceIfNeeded(session, sessionId, camSurface)
                },
            )
        } catch (t: Throwable) {
            producer.release()
            reply(null, errorMsg("composition_failed",
                "attachDuetPreviewTexture: failed to create render loop: ${t.message}"))
            return
        }

        session.previewProducer   = producer
        session.previewRenderLoop = renderLoop

        // Compute optional layout rects from the effective layoutConfig.
        val effectiveLayoutMap = layoutConfigMap ?: session.layoutConfigMap
        // Persist the caller-supplied layout so startCameraSourceIfNeeded sees the
        // correct mode (e.g. "greenScreen") when its cameraInputSurfaceReady callback
        // fires.  We only overwrite when a layoutConfigMap was explicitly passed in;
        // if the caller omitted it we fall back to the existing session value and
        // leave it unchanged (preserves idempotent re-attach behaviour).
        if (layoutConfigMap != null) {
            session.layoutConfigMap = layoutConfigMap
        }
        val typedRects = buildTypedLayoutRects(effectiveLayoutMap, widthPx.toDouble(), heightPx.toDouble())
        val layoutRects = typedRects?.let {
            mapOf("source" to it.source.toMap(), "camera" to it.camera.toMap())
        }

        // Store original values so idempotent re-attach returns them verbatim.
        session.previewWidthPx    = widthPx
        session.previewHeightPx   = heightPx
        session.previewLayoutRects = layoutRects
        session.previewTypedLayoutRects = typedRects

        // The eager probe in the producer's init never fires the availability
        // hook, so bootstrap the render loop here when the surface already exists.
        // Camera start is handled exclusively via the cameraInputSurfaceReady
        // callback wired above — no synchronous read of cameraInputSurface here.
        if (producer.state == DuetSurfaceState.SURFACE_AVAILABLE && typedRects != null) {
            val surface = producer.acquireSurface()
            if (surface != null) {
                renderLoop.attachOutputSurface(
                    surface, widthPx, heightPx,
                    typedRects.source, typedRects.camera,
                    session.previewClock.currentSourcePtsMs().toLong(),
                )
            }
        }

        reply(producer.toResultMap(widthPx, heightPx, layoutRects), null)
    }

    // ── Preview surface lifecycle hooks (Slice 4B-C) ──────────────────────────

    /**
     * Fires synchronously inside the producer's platform-thread callback when the
     * Flutter surface (re)appears. Re-attaches the render loop's output using the
     * stored attach-time dimensions/layout and the current hold PTS.
     *
     * Camera management: [attachOutputSurface] inside the render loop re-fires the
     * [cameraInputSurfaceReady] callback on the main thread. [startCameraSourceIfNeeded]
     * is idempotent — it no-ops when cameraSource is already running — so this is
     * safe for normal re-attaches after output loss. It also enables retry: if a
     * prior transient CameraX failure nulled cameraSource, the re-fired callback
     * gives the coordinator a chance to start the camera again.
     */
    private fun handlePreviewSurfaceAvailable(sessionId: String) {
        val session = activeSession ?: return
        if (session.sessionId != sessionId) return
        val producer   = session.previewProducer   ?: return
        val renderLoop = session.previewRenderLoop ?: return
        val widthPx    = session.previewWidthPx    ?: return
        val heightPx   = session.previewHeightPx   ?: return
        val typedRects = session.previewTypedLayoutRects ?: return
        val surface = producer.acquireSurface() ?: return
        renderLoop.attachOutputSurface(
            surface, widthPx, heightPx,
            typedRects.source, typedRects.camera,
            session.previewClock.currentSourcePtsMs().toLong(),
        )
    }

    /**
     * Fires synchronously inside the producer's platform-thread cleanup callback.
     * Must not block: the loop gates further submissions immediately and detaches
     * its EGL surface asynchronously on the render thread.
     */
    private fun handlePreviewSurfaceLost(sessionId: String) {
        val session = activeSession ?: return
        if (session.sessionId != sessionId) return
        session.previewRenderLoop?.handleOutputSurfaceLost()
    }

    /**
     * Centralized, idempotent camera-start helper called from the render loop's
     * [cameraInputSurfaceReady] callback (main thread).
     *
     * Idempotent guards (all checked before starting CameraX):
     *   - [activeSession] is not this exact session object → no-op (session was
     *     detached/stopped/disposed/disposeAll between when the callback was posted
     *     on the render thread and when it ran on the main thread).
     *   - [session.sessionId] != [sessionId] → no-op (same identity check via the
     *     captured closure argument, belt-and-suspenders).
     *   - [session.previewRenderLoop] is null → no-op (render loop was released
     *     before this callback ran; camera must not start against a dead loop).
     *   - [session.previewProducer] is null → no-op (producer was released; the
     *     output surface is gone and starting camera would be pointless).
     *   - [surface.isValid] is false → no-op (compositor's cameraInputSurface was
     *     already released during teardown before the posted callback ran).
     *   - [context] is null → no-op (no Context available, cannot create CameraSource).
     *   - [session.cameraSource] is non-null → no-op (camera already started; camera
     *     source survives output loss — the compositor Surface lives across re-attaches).
     *
     * On start error: stops/nulls the source so a later re-attach or re-callback can retry.
     */
    private fun startCameraSourceIfNeeded(
        session: VGDuetAndroidSession,
        sessionId: String,
        surface: android.view.Surface,
    ) {
        // Hard lifecycle guards — any of these failing means the session was torn
        // down between when cameraInputSurfaceReady was posted and when it ran.
        if (activeSession !== session) return
        if (session.sessionId != sessionId) return
        if (session.previewRenderLoop == null) return
        if (session.previewProducer == null) return
        if (!surface.isValid) return
        val ctx = context ?: return
        // Already started: camera source and its surface survive output loss, so
        // a repeat callback when cameraSource is non-null correctly does nothing.
        if (session.cameraSource != null) return

        val camSource = AndroidDuetCameraSource(ctx)
        session.cameraSource = camSource

        // When the initial/effective layout mode is greenScreen, create and start
        // the adapter NOW — before the camera bind — so ImageAnalysis is part of
        // the first use-case set. This is the only path that puts the analyzer
        // into the CameraX bind.
        val mode = session.layoutConfigMap["mode"] as? String ?: "pip"
        val analyzerForBind: ImageAnalysis.Analyzer? = if (mode == "greenScreen") {
            buildGreenScreenAdapter(session)
        } else null

        camSource.start(
            targetSurface = surface,
            analyzer      = analyzerForBind,
            onStarted = {
                Log.d("DuetCoordinator", "Camera source started for session $sessionId")
                if (mode == "greenScreen" && session.greenScreenAdapter != null) {
                    session.previewRenderLoop?.setGreenScreenEnabled(true)
                }
            },
            onError = { e ->
                Log.w("DuetCoordinator", "Camera source failed for $sessionId: ${e.message}")
                // Stop any partial CameraX state and null the source so a later
                // re-attach callback can retry cleanly.
                camSource.stop()
                if (session.cameraSource === camSource) {
                    session.cameraSource = null
                    // Fix C: always stop the adapter properly before clearing the ref,
                    // to avoid leaking the ML Kit Segmenter.
                    stopGreenScreenAdapter(session)
                    // If this was a greenScreen bind attempt, apply safe PiP fallback
                    // so the session is in a clean state (no greenScreen enabled, no
                    // dangling adapter). Avoids infinite retry via re-attach surface.
                    if (mode == "greenScreen" && activeSession === session) {
                        Log.w("DuetCoordinator",
                            "greenScreen initial camera bind failed — applying PiP fallback layout")
                        val fallbackLayout: Map<String, Any?> = mapOf(
                            "mode" to "pip",
                            "pipNormalizedRect" to mapOf(
                                "left" to 0.58, "top" to 0.05,
                                "width" to 0.36, "height" to 0.24,
                            ),
                        )
                        session.layoutConfigMap = fallbackLayout
                        val wPx = session.previewWidthPx?.toDouble()
                        val hPx = session.previewHeightPx?.toDouble()
                        if (wPx != null && hPx != null) {
                            val typedRects = buildTypedLayoutRects(fallbackLayout, wPx, hPx)
                            session.previewTypedLayoutRects = typedRects
                            session.previewLayoutRects = typedRects?.let {
                                mapOf("source" to it.source.toMap(), "camera" to it.camera.toMap())
                            }
                            if (typedRects != null) {
                                session.previewRenderLoop?.updateLayout(
                                    typedRects.source, typedRects.camera,
                                    session.previewClock.currentSourcePtsMs().toLong(),
                                )
                            }
                        }
                        session.previewRenderLoop?.setGreenScreenEnabled(false)
                    }
                }
            },
        )
    }

    /**
     * Creates, stores, and starts a new [AndroidDuetGreenScreenAdapter] for [session].
     * Returns the adapter (which also implements [ImageAnalysis.Analyzer]) so it can
     * be passed directly to [AndroidDuetCameraSource.start]. No-ops and returns null
     * if an adapter is already running or if construction/start throws.
     *
     * On any exception: cleans up the partially stored adapter, logs structured
     * fallback metadata, and returns null so callers can apply PiP fallback.
     */
    private fun buildGreenScreenAdapter(session: VGDuetAndroidSession): AndroidDuetGreenScreenAdapter? {
        if (session.greenScreenAdapter != null) return session.greenScreenAdapter
        val renderLoop = session.previewRenderLoop ?: return null
        return try {
            val adapter = AndroidDuetGreenScreenAdapter(
                onMask = { frame ->
                    renderLoop.updateGreenScreenMask(frame)
                },
                onFallback = { prev, next, reason, userMessage ->
                    Log.w("DuetCoordinator",
                        "[GreenScreen fallback] $prev->$next ($reason): $userMessage")
                    mainHandler.post {
                        handleGreenScreenFallback(session, prev, next, reason)
                    }
                },
            )
            session.greenScreenAdapter = adapter
            adapter.start()
            Log.d("DuetCoordinator", "Green-screen adapter built and started for session ${session.sessionId}")
            adapter
        } catch (t: Throwable) {
            Log.w("DuetCoordinator",
                "[GreenScreen fallback] mlkit->none (adapter_start_failed): ${t.message}")
            // Ensure no partial adapter reference is left in the session.
            try { session.greenScreenAdapter?.stop() } catch (_: Throwable) {}
            session.greenScreenAdapter = null
            null
        }
    }

    /**
     * Stops and nulls the session's green-screen adapter (idempotent).
     */
    private fun stopGreenScreenAdapter(session: VGDuetAndroidSession) {
        val adapter = session.greenScreenAdapter ?: return
        try { adapter.stop() } catch (_: Throwable) {}
        session.greenScreenAdapter = null
        Log.d("DuetCoordinator", "Green-screen adapter stopped for session ${session.sessionId}")
    }

    /**
     * Handles an ML Kit failure fallback: switches the session to a safe PiP
     * layout, stops the adapter, disables green-screen in the render loop, and
     * updates layout rects. Session is preserved; no restart.
     *
     * Called on the main thread from the onFallback callback.
     *
     * Safe PiP rect per spec: left=0.58, top=0.05, width=0.36, height=0.24.
     */
    private fun handleGreenScreenFallback(
        session: VGDuetAndroidSession,
        previousBackend: String,
        currentBackend: String,
        reason: String,
    ) {
        if (activeSession !== session) return
        Log.w("DuetCoordinator",
            "Falling back from $previousBackend to $currentBackend ($reason) — switching to PiP")

        // Remove the analysis use-case from CameraX before stopping the adapter,
        // so no new frames arrive during teardown.
        session.cameraSource?.setAnalysisAnalyzer(null)

        // Stop the adapter immediately.
        stopGreenScreenAdapter(session)

        // Disable green-screen in the render loop.
        session.previewRenderLoop?.setGreenScreenEnabled(false)

        // Build and apply the safe fallback PiP layout.
        val fallbackPipRect = mapOf(
            "left" to 0.58, "top" to 0.05, "width" to 0.36, "height" to 0.24,
        )
        val fallbackLayout: Map<String, Any?> = mapOf(
            "mode"            to "pip",
            "pipNormalizedRect" to fallbackPipRect,
        )
        session.layoutConfigMap = fallbackLayout

        val widthPx  = session.previewWidthPx ?: return
        val heightPx = session.previewHeightPx ?: return
        val typedRects = buildTypedLayoutRects(fallbackLayout, widthPx.toDouble(), heightPx.toDouble())
        session.previewTypedLayoutRects = typedRects
        session.previewLayoutRects = typedRects?.let {
            mapOf("source" to it.source.toMap(), "camera" to it.camera.toMap())
        }
        if (typedRects != null) {
            session.previewRenderLoop?.updateLayout(
                typedRects.source,
                typedRects.camera,
                session.previewClock.currentSourcePtsMs().toLong(),
            )
        }
        Log.d("DuetCoordinator", "Green-screen fallback → PiP applied for session ${session.sessionId}")
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
     * Releases and nulls the session's preview producer, camera source, and
     * render loop.
     *
     * Opus P1 stop ordering (prevents CameraX writing into a concurrently
     * releasing SurfaceTexture or a live drawFrame consuming an OES frame mid-stop):
     *   1. producer.beginRelease()            — detaches producer callbacks
     *   2. renderLoop.prepareForCameraStop()  — stops active ticking, stops camera
     *      idle redraw, sets canSubmit=false and bumps surfaceGeneration so no
     *      pending swaps continue while CameraX is draining its last OES frame
     *   3. cameraSource.stop()               — stops CameraX writes into cameraInputSurface
     *   4. renderLoop.stopBlocking(...)      — unbinds decoder, releases compositor
     *      (which releases cameraInputSurface in its terminal release())
     *   5. producer.finishRelease()          — drops the Flutter SurfaceProducer
     *
     * Must be called while session.decoder is still non-null: stopBlocking's
     * unbind reaches the decoder through the loop's decoderProvider.
     */
    private fun releasePreviewProducer(session: VGDuetAndroidSession) {
        val producer = session.previewProducer
        val renderLoop = session.previewRenderLoop
        val camSource = session.cameraSource
        val gsAdapter = session.greenScreenAdapter
        // Phase 1: stop new producer submissions.
        producer?.beginRelease()
        // Phase 2: halt render-thread ticking and camera-idle redraw, and block
        // swap acceptance BEFORE CameraX is stopped. This prevents a drawFrame
        // updateTexImage racing the last CameraX OES write during drain.
        renderLoop?.prepareForCameraStop()
        // Phase 2b: stop the green-screen adapter so ML Kit is not dispatching
        // new frames into the (soon-to-be-released) render loop.
        try { gsAdapter?.stop() } catch (_: Throwable) {}
        session.greenScreenAdapter = null
        // Phase 3: stop camera — render loop is already quiet, safe to drain.
        camSource?.stop()
        // Phase 4: unwind decoder and release compositor (releases cameraInputSurface).
        renderLoop?.stopBlocking(session.previewClock.currentSourcePtsMs().toLong())
        // Phase 5: drop the Flutter SurfaceProducer.
        producer?.finishRelease()
        session.cameraSource       = null
        session.previewProducer    = null
        session.previewRenderLoop  = null
        session.previewWidthPx     = null
        session.previewHeightPx    = null
        session.previewLayoutRects = null
        session.previewTypedLayoutRects = null
    }

    // ── Layout rect builder ───────────────────────────────────────────────────

    /** Typed geometry shared by the MethodChannel reply map and the render loop. */
    private fun buildTypedLayoutRects(
        layoutConfigMap: Map<String, Any?>,
        canvasWidth:  Double,
        canvasHeight: Double,
    ): VGDuetLayoutRects? {
        val mode = layoutConfigMap["mode"] as? String ?: "pip"
        return when (mode) {
            "splitLeftRight" -> {
                val swapped = layoutConfigMap["isSideSwapped"] as? Boolean ?: false
                AndroidDuetLayoutGeometry.splitLeftRight(canvasWidth, canvasHeight, swapped)
            }
            "splitTopBottom" -> {
                val swapped = layoutConfigMap["isTopBottomSwapped"] as? Boolean ?: false
                AndroidDuetLayoutGeometry.splitTopBottom(canvasWidth, canvasHeight, swapped)
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
                VGDuetLayoutRects(source = sourceRect, camera = cameraRect)
            }
            "greenScreen" -> AndroidDuetLayoutGeometry.greenScreen(canvasWidth, canvasHeight)
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
        // Slice 4B-C: stop the render loop while the decoder is still reachable,
        // so its final unbind lands on a live decoder before release is queued.
        releasePreviewProducer(session)
        val dec = session.decoder
        session.decoder = null
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
            // Slice 4B-C: render loop stops while decoder is still non-null.
            releasePreviewProducer(current)
            val dec = current.decoder
            current.decoder = null
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
            // Slice 4B-C: stopBlocking inside completes the render-loop unbind
            // (decoder still non-null) before the decoder thread is quit below.
            releasePreviewProducer(current)
            val dec = current.decoder
            current.decoder = null
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
