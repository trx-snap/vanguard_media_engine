package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.connects.vanguard_media_engine.camera.AndroidCameraSessionAdmission
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
    // Foreground (live camera + green-screen keying) source — started on
    // attach, stopped with renderLoop. Phase 6B seam: owns camera/adapter
    // lifecycle, backend ladder latch, and first-mask readiness internally;
    // see AndroidDuetForegroundProvider.
    var foregroundProvider: AndroidDuetForegroundProvider? = null
    // Original dimensions and layout rects stored on first attach;
    // returned verbatim on repeated (idempotent) attach calls.
    var previewWidthPx:    Int? = null
    var previewHeightPx:   Int? = null
    var previewLayoutRects: Map<String, Any>? = null
    // Typed twin of previewLayoutRects, fed to the render loop on (re)attach.
    // Recomputed by updateLayout while a preview is attached.
    var previewTypedLayoutRects: VGDuetLayoutRects? = null
    // Duet-only preview rotation metadata paired with previewTypedLayoutRects,
    // fed to the render loop alongside it on (re)attach and updateLayout.
    // Identity outside greenScreen mode; never sent over the MethodChannel.
    var previewForegroundRotation: VGDuetForegroundRotation = VGDuetForegroundRotation.IDENTITY
    // startDuetRecording reply parked behind the barrier. Non-null only while
    // state == INITIALIZED and a start is pending; cleared by completion/cancel.
    var pendingStartReply: ((Any?, String?) -> Unit)? = null
    // Bounded fallback that starts anyway if the first mask never arrives.
    var pendingStartTimeoutRunnable: Runnable? = null

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
    /**
     * Emits a Duet degradation/fallback event (`onDuetEvent`) to Dart. Invoked
     * synchronously from [handleGreenScreenFallback] after the safe-PiP layout
     * has been applied; the closure itself is responsible for hopping to the
     * main thread before calling `channel.invokeMethod`.
     */
    private val onDuetEvent: ((Map<String, Any?>) -> Unit)? = null,
    /**
     * Engine-wide single live camera owner guard shared with the generic live
     * green-screen session. Acquired in [initializeSession] after validation
     * and sessionId creation (before pendingSessionId) and released on every
     * failure/cancel path after acquisition and on stop/dispose/disposeAll.
     * Null keeps the standalone behavior (no cross-feature admission).
     */
    private val cameraAdmission: AndroidCameraSessionAdmission? = null,
) {

    companion object {
        private val VALID_SPEEDS = setOf(0.3, 0.5, 1.0, 2.0, 3.0)
        private const val SPEED_EPSILON = 0.001

        /**
         * Upper bound the green-screen start barrier waits for the first mask
         * before starting the clock/source anyway, so startDuetRecording can
         * never hang if segmentation stalls.
         */
        private const val GREEN_SCREEN_FIRST_MASK_START_TIMEOUT_MS = 4000L

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
        // Engine-wide camera admission: a generic live green-screen session that
        // holds the camera blocks Duet with the existing session_conflict code.
        val admission = cameraAdmission
        if (admission != null &&
            !admission.tryAcquire(AndroidCameraSessionAdmission.OWNER_DUET, sessionId)
        ) {
            reply(null, errorMsg("session_conflict",
                "The camera is held by another engine session (${admission.debugString()}). " +
                    "Stop it before initializing a Duet session."))
            return
        }
        pendingSessionId = sessionId

        probeHandler.post {
            val probeResult = probeSource(filePath)

            val probVal = probeResult.getOrNull()
            if (probVal == null) {
                mainHandler.post {
                    if (pendingSessionId == sessionId) {
                        pendingSessionId = null
                    }
                    releaseCameraAdmission(sessionId)
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
                    releaseCameraAdmission(sessionId)
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
                        releaseCameraAdmission(sessionId)
                        return@post
                    }

                    if (prepErr != null) {
                        decoderHandler.post { decoder.release() }
                        releaseCameraAdmission(sessionId)
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
        // Debug-only (RND diagnostic): forward the raw mask visualization
        // opt-in on every updateLayout call. Invalid/absent values disable
        // the visualization via the compositor's own allowlist — no event,
        // no session-level persistence beyond the layoutConfigMap already
        // stored above.
        session.previewRenderLoop?.setGreenScreenDebugView(
            layoutConfigMap["debugGreenScreenView"] as? String
        )
        session.previewRenderLoop?.setGreenScreenBackgroundMode(
            layoutConfigMap["debugGreenScreenBackgroundMode"] as? String
        )
        session.previewRenderLoop?.setGreenScreenBackground(
            AndroidDuetGreenScreenBackground.parse(layoutConfigMap["greenScreenBackground"] as? Map<*, *>)
        )
        val newMode = layoutConfigMap["mode"] as? String ?: "pip"
        // Slice green-screen: handle mode switch without restarting the whole session.
        val widthPx  = session.previewWidthPx
        val heightPx = session.previewHeightPx
        if (widthPx != null && heightPx != null) {
            val typedRects = buildTypedLayoutRects(layoutConfigMap, widthPx.toDouble(), heightPx.toDouble())
            val foregroundRotation = buildForegroundRotation(layoutConfigMap)
            session.previewTypedLayoutRects = typedRects
            session.previewForegroundRotation = foregroundRotation
            session.previewLayoutRects = typedRects?.let {
                mapOf("source" to it.source.toMap(), "camera" to it.camera.toMap())
            }
            if (typedRects != null) {
                session.previewRenderLoop?.updateLayout(
                    typedRects.source,
                    typedRects.camera,
                    session.previewClock.currentSourcePtsMs().toLong(),
                    foregroundRotation,
                )
            }
            // Enable/disable green-screen compositing based on the new mode.
            if (newMode == "greenScreen") {
                // Switching into greenScreen: the provider builds/rebinds its
                // adapter as needed. If it cannot enable keying, fall back to
                // safe PiP immediately. When no provider exists yet (camera not
                // started), that mirrors a bind failure (no camera to bind to),
                // since the render loop guaranteed by this branch means adapter
                // construction itself would not have failed.
                val provider = session.foregroundProvider
                val enabled = provider?.setGreenScreenEnabled(true, layoutConfigMap) ?: false
                if (!enabled) {
                    val reason = provider?.lastEnableFailureReason() ?: "bind_failed"
                    Log.w("DuetCoordinator",
                        "foregroundProvider.setGreenScreenEnabled(true) failed ($reason) — PiP fallback")
                    handleGreenScreenFallback(session,
                        provider?.reportedBackendId() ?: DuetSegmentationBackend.NONE,
                        reason)
                    reply(null, null)
                    return
                }
            } else {
                // Switching away from greenScreen: provider removes the analysis
                // use-case, stops its adapter, disables compositor. Camera Preview
                // continues.
                session.foregroundProvider?.setGreenScreenEnabled(false, layoutConfigMap)
                // Leaving greenScreen while a start is parked behind the first-mask
                // barrier: no mask will ever arrive, so begin immediately.
                completePendingStart(session, "layout_left_green_screen")
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
        if (session.pendingStartReply != null) {
            // A start is already parked behind the green-screen first-mask barrier:
            // never start twice and never overwrite the parked reply.
            reply(null, invalidState("startDuetRecording", "INITIALIZED (start pending)", expected = "INITIALIZED")); return
        }
        val immediateReason = immediateStartReason(session)
        if (immediateReason != null) {
            beginRecordingNow(session, reply, immediateReason)
            return
        }
        // Green-screen visual barrier: hold the Duet clock and source playback until
        // the current adapter delivers its first real mask, so the composited camera
        // does not trail the source by the segmentation warm-up. Bounded by a
        // fallback timeout so the route can never hang.
        session.pendingStartReply = reply
        val timeout = object : Runnable {
            override fun run() {
                if (activeSession !== session) return
                if (session.pendingStartTimeoutRunnable !== this) return
                if (session.pendingStartReply == null) return
                Log.w("DuetCoordinator",
                    "ANDROID_DUET_GREENSCREEN_START_FIRST_MASK_TIMEOUT session=${session.sessionId} " +
                        "timeoutMs=$GREEN_SCREEN_FIRST_MASK_START_TIMEOUT_MS " +
                        "backend=${session.foregroundProvider?.reportedBackendId() ?: "none"}")
                completePendingStart(session, "first_mask_timeout")
            }
        }
        session.pendingStartTimeoutRunnable = timeout
        Log.i("DuetCoordinator",
            "ANDROID_DUET_GREENSCREEN_START_WAITING_FOR_FIRST_MASK session=${session.sessionId} " +
                "timeoutMs=$GREEN_SCREEN_FIRST_MASK_START_TIMEOUT_MS " +
                "adapterPresent=${session.foregroundProvider != null} " +
                "backend=${session.foregroundProvider?.reportedBackendId() ?: "none"}")
        mainHandler.postDelayed(timeout, GREEN_SCREEN_FIRST_MASK_START_TIMEOUT_MS)
    }

    /**
     * Performs the actual INITIALIZED -> RECORDING transition: state, segment
     * open, active render-loop playback, success reply. Main thread only — the
     * preview clock, the loop's PTS provider, and the (possibly parked)
     * MethodChannel reply all live there.
     */
    private fun beginRecordingNow(
        session: VGDuetAndroidSession,
        reply: (Any?, String?) -> Unit,
        reason: String,
    ) {
        session.state = VGDuetSessionState.RECORDING
        session.startSegment()
        // Slice 4B-C: active playback. The provider runs on the main thread only,
        // so reading the preview clock here is safe.
        session.previewRenderLoop?.startActive {
            session.previewClock.currentSourcePtsMs().toLong()
        }
        Log.i("DuetCoordinator",
            "ANDROID_DUET_RECORDING_BEGIN session=${session.sessionId} reason=$reason")
        reply(null, null)
    }

    /**
     * Returns null when startDuetRecording must wait for the first green-screen
     * mask, otherwise the reason the start may proceed immediately. Waiting only
     * makes sense when something can actually deliver a mask through the
     * adapter's callbacks: greenScreen mode with a live preview/render loop.
     */
    private fun immediateStartReason(session: VGDuetAndroidSession): String? {
        val mode = session.layoutConfigMap["mode"] as? String ?: "pip"
        if (mode != "greenScreen") return "non_green_screen"
        if (session.foregroundProvider?.firstMaskReady == true) return "first_mask_ready"
        if (session.previewRenderLoop == null) return "no_preview_attached"
        return null
    }

    /** Drops the parked reply and its timeout without invoking either. Main thread only. */
    private fun clearPendingStartBarrier(session: VGDuetAndroidSession) {
        session.pendingStartTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        session.pendingStartTimeoutRunnable = null
        session.pendingStartReply = null
    }

    /**
     * Completes a parked start (first mask arrived, timeout fired, or green
     * screen was disabled so no mask can ever arrive). No-op when nothing is
     * pending. Main thread only.
     */
    private fun completePendingStart(session: VGDuetAndroidSession, reason: String) {
        val reply = session.pendingStartReply ?: return
        clearPendingStartBarrier(session)
        if (session.state != VGDuetSessionState.INITIALIZED) {
            // Defensive: no route moves a session out of INITIALIZED while a start
            // is parked, but never double-start if that invariant is ever broken.
            reply(null, invalidState("startDuetRecording", session.state.name, expected = "INITIALIZED"))
            return
        }
        beginRecordingNow(session, reply, reason)
    }

    /**
     * Fails a parked start that can no longer be satisfied (preview released by
     * detach/stop/dispose). The session stays INITIALIZED so the caller may retry.
     * No-op when nothing is pending. Main thread only.
     */
    private fun cancelPendingStart(session: VGDuetAndroidSession, reason: String) {
        val reply = session.pendingStartReply ?: return
        clearPendingStartBarrier(session)
        Log.w("DuetCoordinator",
            "ANDROID_DUET_GREENSCREEN_START_CANCELED session=${session.sessionId} reason=$reason")
        reply(null, errorMsg("invalid_state",
            "startDuetRecording: start canceled before the first green-screen mask arrived ($reason)."))
    }

    /**
     * Main-thread landing for [AndroidDuetForegroundProvider]'s first-mask
     * event. Releases a parked start only when [provider] is still the
     * session's live foreground provider — an event from a stale (torn down)
     * provider proves nothing about what the compositor is drawing now.
     * Adapter-level staleness (rebuilt/replaced adapter within the same
     * provider) is already filtered by the provider itself.
     */
    private fun handleGreenScreenFirstMask(
        session: VGDuetAndroidSession,
        provider: AndroidDuetForegroundProvider,
    ) {
        if (activeSession !== session) return
        if (session.foregroundProvider !== provider) return
        Log.i("DuetCoordinator",
            "ANDROID_DUET_GREENSCREEN_FIRST_MASK_READY session=${session.sessionId} " +
                "backend=${provider.reportedBackendId()} startPending=${session.pendingStartReply != null}")
        completePendingStart(session, "first_mask_ready")
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

        // Compute the effective layoutConfig up front (before the render loop is
        // constructed) so it can both select the diagnostic preview backend and
        // drive the layout-rect computation below without a second declaration.
        val effectiveLayoutMap = layoutConfigMap ?: session.layoutConfigMap
        val backendSelection = AndroidDuetPreviewBackendFactory.selectForLayoutConfig(effectiveLayoutMap)

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
                backendSelection = backendSelection,
            )
        } catch (t: Throwable) {
            producer.release()
            reply(null, errorMsg("composition_failed",
                "attachDuetPreviewTexture: failed to create render loop: ${t.message}"))
            return
        }

        session.previewProducer   = producer
        session.previewRenderLoop = renderLoop
        // Debug-only (RND diagnostic): forward the raw mask visualization
        // opt-in at attach time too, so a physical smoke can request it from
        // the very first attach without waiting for a later updateLayout.
        renderLoop.setGreenScreenDebugView(effectiveLayoutMap["debugGreenScreenView"] as? String)
        renderLoop.setGreenScreenBackgroundMode(effectiveLayoutMap["debugGreenScreenBackgroundMode"] as? String)
        renderLoop.setGreenScreenBackground(
            AndroidDuetGreenScreenBackground.parse(effectiveLayoutMap["greenScreenBackground"] as? Map<*, *>)
        )

        // Persist the caller-supplied layout so startCameraSourceIfNeeded sees the
        // correct mode (e.g. "greenScreen") when its cameraInputSurfaceReady callback
        // fires.  We only overwrite when a layoutConfigMap was explicitly passed in;
        // if the caller omitted it we fall back to the existing session value and
        // leave it unchanged (preserves idempotent re-attach behaviour).
        if (layoutConfigMap != null) {
            session.layoutConfigMap = layoutConfigMap
        }
        val typedRects = buildTypedLayoutRects(effectiveLayoutMap, widthPx.toDouble(), heightPx.toDouble())
        val foregroundRotation = buildForegroundRotation(effectiveLayoutMap)
        val layoutRects = typedRects?.let {
            mapOf("source" to it.source.toMap(), "camera" to it.camera.toMap())
        }

        // Store original values so idempotent re-attach returns them verbatim.
        session.previewWidthPx    = widthPx
        session.previewHeightPx   = heightPx
        session.previewLayoutRects = layoutRects
        session.previewTypedLayoutRects = typedRects
        session.previewForegroundRotation = foregroundRotation

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
                    foregroundRotation,
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
     * is idempotent — the foreground provider no-ops when its camera source is
     * already running — so this is safe for normal re-attaches after output loss.
     * It also enables retry: if a prior transient CameraX failure nulled the
     * provider's camera source, the re-fired callback gives the coordinator a
     * chance to start the camera again.
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
            session.previewForegroundRotation,
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
     * Centralized, idempotent foreground-provider start helper called from the
     * render loop's [cameraInputSurfaceReady] callback (main thread).
     *
     * Session-level idempotent guards (all checked before delegating to the
     * provider):
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
     *
     * [AndroidDuetForegroundProvider.start] itself guards context-availability
     * and camera-already-started idempotency.
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
        val renderLoop = session.previewRenderLoop ?: return
        if (session.previewProducer == null) return
        if (!surface.isValid) return

        val mode = session.layoutConfigMap["mode"] as? String ?: "pip"
        val provider = session.foregroundProvider
            ?: AndroidDuetLegacyForegroundProvider(context, mainHandler).also { session.foregroundProvider = it }

        provider.start(
            surface         = surface,
            renderLoop      = renderLoop,
            layoutConfigMap = session.layoutConfigMap,
            callbacks       = object : AndroidDuetForegroundProviderCallbacks {
                override fun onStarted() {
                    Log.d("DuetCoordinator", "Camera source started for session $sessionId")
                }

                override fun onError(e: Exception) {
                    Log.w("DuetCoordinator", "Camera source failed for $sessionId: ${e.message}")
                    // If this was a greenScreen bind attempt, apply safe PiP fallback
                    // so the session is in a clean state (no greenScreen enabled, no
                    // dangling adapter). Avoids infinite retry via re-attach surface.
                    if (mode == "greenScreen" && activeSession === session && session.foregroundProvider === provider) {
                        Log.w("DuetCoordinator",
                            "greenScreen initial camera bind failed — applying PiP fallback layout")
                        handleGreenScreenFallback(session, provider.reportedBackendId(),
                            "initial_camera_bind_failed")
                    }
                }

                override fun onFirstMaskReady() {
                    handleGreenScreenFirstMask(session, provider)
                }

                override fun onDegraded(previousBackend: String, currentBackend: String, reason: String, userMessage: String) {
                    handleGreenScreenDegraded(session, provider, previousBackend, currentBackend, reason, userMessage)
                }

                override fun onFallback(previousBackend: String, reason: String, userMessage: String) {
                    // Provider-origin callback: only act while this provider is
                    // still the session's live foreground provider (not torn
                    // down/replaced between the async fallback and this landing).
                    if (session.foregroundProvider !== provider) return
                    handleGreenScreenFallback(session, previousBackend, reason)
                }
            },
        )
    }

    // Adapter/camera building, debug backend policy, the segmentation ladder,
    // and the ladder latch now live in AndroidDuetForegroundProvider — see
    // AndroidDuetLegacyForegroundProvider.buildGreenScreenAdapter.

    /**
     * Handles a NON-terminal backend degradation (MediaPipe -> ML Kit): green
     * screen stays live, the layout is untouched, and the reached rung is
     * latched inside [provider] so no later adapter climbs back up. Emits
     * `green_screen_degraded` via [onDuetEvent] only when [provider] is still
     * the session's live foreground provider (the provider itself has already
     * filtered stale/replaced adapters before invoking this callback).
     *
     * Called on the main thread from the provider's onDegraded callback.
     */
    private fun handleGreenScreenDegraded(
        session: VGDuetAndroidSession,
        provider: AndroidDuetForegroundProvider,
        previousBackend: String,
        currentBackend: String,
        reason: String,
        userMessage: String,
    ) {
        if (activeSession !== session) return
        if (session.foregroundProvider !== provider) return
        Log.w("DuetCoordinator",
            "Green screen degraded $previousBackend -> $currentBackend ($reason); staying live on $currentBackend")
        onDuetEvent?.invoke(
            mapOf(
                "event" to "green_screen_degraded",
                "sessionId" to session.sessionId,
                "previousBackend" to previousBackend,
                "currentBackend" to currentBackend,
                "reason" to reason,
                "userMessage" to userMessage,
            )
        )
    }

    /**
     * Handles the TERMINAL segmentation fallback (ladder exhausted — ML Kit
     * failed, or green screen could not be bound at all): switches the session
     * to a safe PiP layout, stops the foreground provider's keying, disables
     * green-screen in the render loop, and updates layout rects. Session is
     * preserved; no restart. Non-terminal MediaPipe -> ML Kit degradation never
     * reaches here (see [handleGreenScreenDegraded]).
     *
     * Called on the main thread, either from the provider's onFallback and
     * onError callbacks (both identity-check their captured provider against
     * [VGDuetAndroidSession.foregroundProvider] at the call site before
     * reaching here, since those callbacks may land after an async gap) or
     * directly from updateLayout, which calls in synchronously within the
     * same stack frame that read `session.foregroundProvider`, so no separate
     * identity check is needed there. This function itself only re-checks
     * [activeSession].
     *
     * Safe PiP rect per spec: left=0.58, top=0.05, width=0.36, height=0.24.
     */
    private fun handleGreenScreenFallback(
        session: VGDuetAndroidSession,
        previousBackend: String,
        reason: String,
    ) {
        if (activeSession !== session) return
        Log.w("DuetCoordinator",
            "Falling back from $previousBackend to none ($reason) — switching to PiP")

        // Remove the analysis use-case and stop keying immediately.
        session.foregroundProvider?.setGreenScreenEnabled(false, session.layoutConfigMap)

        // Build and apply the safe fallback PiP layout.
        val fallbackPipRect = mapOf(
            "left" to 0.58, "top" to 0.05, "width" to 0.36, "height" to 0.24,
        )
        val fallbackLayout: Map<String, Any?> = mapOf(
            "mode"            to "pip",
            "pipNormalizedRect" to fallbackPipRect,
        )
        session.layoutConfigMap = fallbackLayout

        val widthPx  = session.previewWidthPx
        val heightPx = session.previewHeightPx
        if (widthPx != null && heightPx != null) {
            val typedRects = buildTypedLayoutRects(fallbackLayout, widthPx.toDouble(), heightPx.toDouble())
            session.previewTypedLayoutRects = typedRects
            // PiP fallback leaves greenScreen mode: rotation is Duet-only
            // metadata scoped to the green-screen camera layer, so it resets
            // to identity here rather than carrying over a stale angle.
            session.previewForegroundRotation = VGDuetForegroundRotation.IDENTITY
            session.previewLayoutRects = typedRects?.let {
                mapOf("source" to it.source.toMap(), "camera" to it.camera.toMap())
            }
            if (typedRects != null) {
                session.previewRenderLoop?.updateLayout(
                    typedRects.source,
                    typedRects.camera,
                    session.previewClock.currentSourcePtsMs().toLong(),
                    VGDuetForegroundRotation.IDENTITY,
                )
            }
        }
        Log.d("DuetCoordinator", "Green-screen fallback → PiP applied for session ${session.sessionId}")

        // Emit onDuetEvent only after the PiP fallback layout above has been
        // applied — currentBackend in the event payload is always "pip" (the
        // resulting preview backend), distinct from the internal segmentation
        // backend value ("none").
        onDuetEvent?.invoke(
            mapOf(
                "event" to "green_screen_fallback",
                "sessionId" to session.sessionId,
                "previousBackend" to previousBackend,
                "currentBackend" to "pip",
                "reason" to reason,
                "userMessage" to "Green screen unavailable. Switched to Picture-in-Picture",
            )
        )
        // A start parked behind the first-mask barrier can no longer be satisfied
        // (adapter stopped, PiP layout): begin it now instead of waiting out the timeout.
        completePendingStart(session, "green_screen_fallback")
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
     * Releases and nulls the session's preview producer, foreground provider,
     * and render loop.
     *
     * Opus P1 stop ordering (prevents CameraX writing into a concurrently
     * releasing SurfaceTexture or a live drawFrame consuming an OES frame mid-stop):
     *   1. producer.beginRelease()            — detaches producer callbacks
     *   2. renderLoop.prepareForCameraStop()  — stops active ticking, stops camera
     *      idle redraw, sets canSubmit=false and bumps surfaceGeneration so no
     *      pending swaps continue while CameraX is draining its last OES frame
     *   3. provider.stopKeying(); provider.stop() — stops keying, then stops
     *      CameraX writes into cameraInputSurface
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
        val provider = session.foregroundProvider
        // Phase 0: a start parked behind the green-screen barrier can never be
        // satisfied once the preview (and its keying) is gone — fail it now so
        // neither the MethodChannel reply nor the timeout runnable leaks.
        cancelPendingStart(session, "preview_released")
        // Phase 1: stop new producer submissions.
        producer?.beginRelease()
        // Phase 2: halt render-thread ticking and camera-idle redraw, and block
        // swap acceptance BEFORE CameraX is stopped. This prevents a drawFrame
        // updateTexImage racing the last CameraX OES write during drain.
        renderLoop?.prepareForCameraStop()
        // Phase 2b: stop keying so ML Kit is not dispatching new frames into
        // the (soon-to-be-released) render loop.
        provider?.stopKeying()
        // Phase 3: stop camera — render loop is already quiet, safe to drain.
        provider?.stop()
        // Phase 4: unwind decoder and release compositor (releases cameraInputSurface).
        renderLoop?.stopBlocking(session.previewClock.currentSourcePtsMs().toLong())
        // Phase 5: drop the Flutter SurfaceProducer.
        producer?.finishRelease()
        session.foregroundProvider = null
        session.previewProducer    = null
        session.previewRenderLoop  = null
        session.previewWidthPx     = null
        session.previewHeightPx    = null
        session.previewLayoutRects = null
        session.previewTypedLayoutRects = null
        session.previewForegroundRotation = VGDuetForegroundRotation.IDENTITY
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
            "greenScreen" -> {
                val fgTransform = parseForegroundTransform(layoutConfigMap)
                AndroidDuetLayoutGeometry.greenScreen(canvasWidth, canvasHeight, fgTransform)
            }
            else -> null
        }
    }

    /**
     * Duet-only preview rotation metadata paired with [buildTypedLayoutRects]:
     * identity for every mode except greenScreen, where it mirrors the same
     * parsed foreground transform used for the camera rect.
     */
    private fun buildForegroundRotation(layoutConfigMap: Map<String, Any?>): VGDuetForegroundRotation {
        val mode = layoutConfigMap["mode"] as? String ?: "pip"
        if (mode != "greenScreen") return VGDuetForegroundRotation.IDENTITY
        return AndroidDuetLayoutGeometry.foregroundRotation(parseForegroundTransform(layoutConfigMap))
    }

    /**
     * Parses a [NativeForegroundTransform] from a layout config map.
     *
     * Reads the nested `foregroundTransform` map with keys:
     *   `scale` (Double), `offset.x`, `offset.y`, `anchor.x`, `anchor.y`,
     *   `rotationDegrees`.
     *
     * Missing or wrong-type `scale` defaults to `1.0` (matching the Dart
     * `VGDuetForegroundTransform.fromMap` contract); the resulting scale must
     * still be finite and positive, or null is returned (full-canvas identity).
     * Offset/anchor components default per-field (offset -> 0.0, anchor -> 0.5)
     * on missing, wrong-type, or non-finite values. `rotationDegrees` defaults
     * to `0.0` on missing, wrong-type, or non-finite values; it is carried on
     * the returned transform but does not affect the rect returned by
     * [AndroidGreenScreenLayoutGeometry.greenScreen].
     */
    private fun parseForegroundTransform(layoutConfigMap: Map<String, Any?>): NativeForegroundTransform? {
        @Suppress("UNCHECKED_CAST")
        val fgMap = layoutConfigMap["foregroundTransform"] as? Map<*, *> ?: return null
        val scale = (fgMap["scale"] as? Number)?.toDouble() ?: 1.0
        if (!scale.isFinite() || scale <= 0.0) return null
        @Suppress("UNCHECKED_CAST")
        val offsetMap = fgMap["offset"] as? Map<*, *>
        @Suppress("UNCHECKED_CAST")
        val anchorMap = fgMap["anchor"] as? Map<*, *>
        val rawOffsetX = (offsetMap?.get("x") as? Number)?.toDouble() ?: Double.NaN
        val rawOffsetY = (offsetMap?.get("y") as? Number)?.toDouble() ?: Double.NaN
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
        releaseCameraAdmission(session.sessionId)
        reply(session.buildStopResult(), null)
    }

    // ── disposeSession (idempotent) ────────────────────────────────────────────

    fun disposeSession(sessionId: String, reply: (Any?, String?) -> Unit) {
        if (pendingSessionId == sessionId) {
            canceledProbeIds += sessionId
            pendingSessionId = null
            // Free the camera lane now so a new session may start before the
            // canceled probe lands (its own late release is then a no-op).
            releaseCameraAdmission(sessionId)
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
            releaseCameraAdmission(sessionId)
        }
        reply(null, null)
    }

    // ── disposeAll ────────────────────────────────────────────────────────────

    fun disposeAll() {
        val pending = pendingSessionId
        if (pending != null) {
            canceledProbeIds += pending
            pendingSessionId = null
            releaseCameraAdmission(pending)
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
            releaseCameraAdmission(current.sessionId)
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

    /**
     * Frees the engine-wide camera lane held for [sessionId]. No-op when no
     * admission guard is wired or the lane is not held by Duet/[sessionId].
     */
    private fun releaseCameraAdmission(sessionId: String) {
        cameraAdmission?.release(AndroidCameraSessionAdmission.OWNER_DUET, sessionId)
    }

    /** Encodes error as "code|message" for the handler to decode and surface as FlutterError. */
    private fun errorMsg(code: String, message: String): String = "$code|$message"
}
