package com.connects.vanguard_media_engine.duet

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.HandlerThread
import android.os.StatFs
import android.util.Log
import com.connects.vanguard_media_engine.camera.AndroidCameraSessionAdmission
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.TreeMap
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
//   - Slice 1A (live take persistence): every RECORDING span is one
//     AndroidDuetSegmentRecorder take written to
//     <cacheDir>/vanguard_duet_segments/<sessionId>/take_<n>.mp4 from the
//     compositor's already-latched camera frame (encoder surface attached
//     through the render loop), and the source clip's own audio is previewed
//     through AndroidDuetPreviewAudioPlayer at the clock's cursor/speed.
//     pause/stop reply only after the take file is durable; stop returns the
//     real per-segment asset paths (index-aligned with the clock's segments).

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

    // ── Slice 1A: live take persistence + source-audio preview ────────────────
    // Per-session temp directory holding one MP4 per take; created lazily on
    // the first take, deleted on dispose (never on stop: the returned assets
    // belong to the caller from then on).
    var segmentDir: File? = null
    // Monotonic file-name counter so a rolled-back take never reuses the name
    // of a file whose async deletion may still be pending.
    var takeFileCounter: Int = 0
    // Recorder of the RECORDING take and the clock segment index it commits as.
    var currentRecorder: AndroidDuetSegmentRecorder? = null
    var currentTakeIndex: Int = -1
    // A take whose encoder-surface attach is still in flight on the render
    // thread (state is still INITIALIZED/PAUSED). Guards double starts; the
    // parked reply is failed with [pendingTakeFailureCode] if the preview goes away.
    var pendingTakeRecorder: AndroidDuetSegmentRecorder? = null
    var pendingTakeReply: ((Any?, String?) -> Unit)? = null
    var pendingTakeFailureCode: String = "recording_start_failed"
    // Durable take files keyed by clock segment index (ordered).
    val segmentAssetPathsByIndex: TreeMap<Int, String> = TreeMap()
    // Takes whose recorder is still finalizing, keyed by segment index.
    val finalizingRecorders: MutableMap<Int, AndroidDuetSegmentRecorder> = mutableMapOf()
    // Segment indices rolled back (deleteLastSegment) while their take was still finalizing.
    val discardedTakeIndices: MutableSet<Int> = mutableSetOf()
    // Continuation parked by stopRecording until every finalizing take has landed.
    var onAllTakesFinalized: (() -> Unit)? = null
    // Source-clip audio preview; null when the source has no audio track.
    var previewAudioPlayer: AndroidDuetPreviewAudioPlayer? = null

    fun startSegment() {
        previewClock.startSegment()
    }

    /** Commits the active clock segment; null when the clock was not recording. */
    fun commitSegment(): VGDuetAndroidSegmentRecord? {
        return previewClock.commitSegment()
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
        // Slice 1A: real per-take files, ordered by clock segment index. A take
        // that failed to finalize has already rolled its clock segment back, so
        // this list stays index-aligned with `segments`.
        return mapOf(
            "compositionDescriptor" to descriptor,
            "totalDurationMs"       to maxOf(1, totalDurationMs()),
            "segmentCount"          to maxOf(1, segmentCount()),
            "segmentAssets"         to segmentAssetPathsByIndex.values.toList(),
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

        /** Slice 1A: free storage required in the cache volume before a take may start. */
        private const val MIN_FREE_DISK_BYTES = 200L * 1024L * 1024L
        private const val SEGMENT_DIR_ROOT = "vanguard_duet_segments"

        fun isValidSpeed(speed: Double): Boolean =
            VALID_SPEEDS.any { Math.abs(it - speed) < SPEED_EPSILON }

        /** Plain filesystem path for a `file://` URI or path (same rule as [probeSource]). */
        fun resolveSourcePath(filePath: String): String {
            if (!filePath.startsWith("file://")) return filePath
            return try {
                java.net.URI(filePath).path ?: filePath
            } catch (_: Exception) {
                filePath
            }
        }

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
                    // Slice 1A: source-audio preview only when the clip has an
                    // audio track; prepared asynchronously and primed at trimStart
                    // so the first take's play() is immediate. Failure to prepare
                    // is logged inside the player and never blocks the session.
                    if (probVal.hasAudioTrack) {
                        val player = AndroidDuetPreviewAudioPlayer(resolveSourcePath(filePath), mainHandler)
                        player.prepare(trimStartMs)
                        session.previewAudioPlayer = player
                    } else {
                        Log.i("DuetCoordinator",
                            "ANDROID_DUET_PREVIEW_AUDIO_SKIPPED session=$sessionId reason=source_has_no_audio_track")
                    }
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
        // Slice 1A: the clock applies a speed change at the NEXT segment start
        // (activeSpeedMultiplier is captured by startSegment), so the audio
        // preview and the take's PTS policy pick it up at the next take too;
        // changing the live player mid-take would desync it from the source
        // video preview, which follows the clock.
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
        // Slice 1A: source gain drives the live audio preview immediately.
        // micGain stays descriptor metadata (applied at export); the take
        // recorder captures unity-gain mic audio so it is never baked in twice.
        session.previewAudioPlayer?.setVolume(sourceGain)
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
        if (session.pendingTakeRecorder != null) {
            // Slice 1A: a take's encoder-surface attach is in flight; never start twice.
            reply(null, invalidState("startDuetRecording", "INITIALIZED (take start pending)", expected = "INITIALIZED")); return
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
     * Performs the actual INITIALIZED -> RECORDING transition through the
     * Slice 1A take pipeline ([beginTake]): recorder + encoder-surface attach
     * first, then state, segment open, source-audio preview, active
     * render-loop playback and the success reply. Main thread only — the
     * preview clock, the loop's PTS provider, and the (possibly parked)
     * MethodChannel reply all live there.
     */
    private fun beginRecordingNow(
        session: VGDuetAndroidSession,
        reply: (Any?, String?) -> Unit,
        reason: String,
    ) {
        beginTake(session, reply, isResume = false, reason = reason)
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
        val committed = session.commitSegment()
        session.state = if (session.previewClock.isAutoStopped) VGDuetSessionState.COMPLETED else VGDuetSessionState.PAUSED
        // Slice 1A: silence the source preview before the held frame lands.
        session.previewAudioPlayer?.pause()
        val targetPts = session.previewClock.currentSourcePtsMs().toLong()
        session.previewRenderLoop?.pauseAndHold(targetPts)
        if (committed == null) {
            // Pre-existing quirk preserved: deleteLastSegment during RECORDING
            // stops the clock (and, since Slice 1A, discards the active take)
            // without leaving RECORDING; a following pause then has no segment
            // to commit, so any stray recorder has nothing to pair with.
            discardActiveTake(session, "pause_without_committed_segment")
            reply(null, null)
            return
        }
        // Slice 1A: the reply completes only once the take file is durable (or
        // the take has been rolled back), so callers can trust segmentAssets.
        finalizeActiveTake(session, committed.index) { err ->
            reply(null, err)
        }
    }

    // ── resumeRecording ───────────────────────────────────────────────────────

    fun resumeRecording(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "resumeDuetRecording", reply) ?: return
        if (session.state != VGDuetSessionState.PAUSED) {
            reply(null, invalidState("resumeDuetRecording", session.state.name, expected = "PAUSED")); return
        }
        if (session.pendingTakeRecorder != null) {
            reply(null, invalidState("resumeDuetRecording", "PAUSED (take start pending)", expected = "PAUSED")); return
        }
        if (session.finalizingRecorders.isNotEmpty()) {
            // Slice 1A: the previous take's file is not durable yet (its pause
            // reply is still pending). Starting a new clock segment now would
            // let a failed finalize orphan a non-last segment; keep the
            // segment/asset lists index-aligned by refusing until it lands.
            reply(null, invalidState("resumeDuetRecording", "PAUSED (previous take still finalizing)", expected = "PAUSED")); return
        }
        beginTake(session, reply, isResume = true, reason = "resume")
    }

    // ── deleteLastSegment ─────────────────────────────────────────────────────

    fun deleteLastSegment(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "deleteLastDuetSegment", reply) ?: return
        if (session.state == VGDuetSessionState.STOPPED) {
            reply(null, invalidState("deleteLastDuetSegment", "STOPPED")); return
        }
        // Slice 1A: the clock discards its active segment when deleting while
        // RECORDING, so the active take (if any) is discarded with it; the
        // last committed segment's take file goes with that segment.
        if (session.state == VGDuetSessionState.RECORDING) {
            discardActiveTake(session, "delete_last_segment_while_recording")
            session.previewAudioPlayer?.pause()
        }
        val removedIndex = session.previewClock.segments.lastOrNull()?.index
        val removed = session.deleteLastSegment()
        if (removed && removedIndex != null) {
            discardTakeFile(session, removedIndex)
        }
        if (session.state == VGDuetSessionState.COMPLETED) {
            session.state = VGDuetSessionState.PAUSED
        }
        val targetPts = session.previewClock.currentSourcePtsMs().toLong()
        session.previewRenderLoop?.seekAndHold(targetPts)
        session.previewAudioPlayer?.seekTo(targetPts.toInt())
        reply(null, null)
    }

    // ── Slice 1A: live take lifecycle ─────────────────────────────────────────

    /**
     * Opens one take: preconditions (context, preview/render loop, segment
     * directory, free storage), recorder start (bounded inline codec/muxer
     * setup), then the asynchronous encoder-surface attach on the render
     * thread. Only when the attach succeeds does the session transition to
     * RECORDING (state, clock segment, source-audio preview, active render
     * loop) and reply success; every failure leaves the session in its
     * previous retryable state with the recorder canceled and no file behind.
     * Main thread only.
     */
    private fun beginTake(
        session: VGDuetAndroidSession,
        reply: (Any?, String?) -> Unit,
        isResume: Boolean,
        reason: String,
    ) {
        val code = if (isResume) "recording_resume_failed" else "recording_start_failed"
        val route = if (isResume) "resumeDuetRecording" else "startDuetRecording"
        val ctx = context
        if (ctx == null) {
            reply(null, errorMsg(code, "$route: application context unavailable; cannot persist the take."))
            return
        }
        val loop = session.previewRenderLoop
        if (loop == null) {
            reply(null, errorMsg(code, "$route: no preview is attached, so live camera frames are unavailable for the take."))
            return
        }
        val dir = ensureSegmentDir(session, ctx)
        if (dir == null) {
            reply(null, errorMsg(code, "$route: cannot create the take directory in the app cache."))
            return
        }
        val diskErr = freeDiskError(dir)
        if (diskErr != null) {
            reply(null, errorMsg("disk_full", "$route: $diskErr"))
            return
        }
        val file = File(dir, "take_${session.takeFileCounter++}.mp4")
        val recorder = AndroidDuetSegmentRecorder(
            context = ctx,
            outputFile = file,
            speedMultiplier = session.previewClock.speedMultiplier,
            micGain = session.micGain,
        )
        if (!recorder.start()) {
            recorder.cancel()
            reply(null, errorMsg(code, "$route: the take encoder/muxer could not be started."))
            return
        }
        session.pendingTakeRecorder = recorder
        session.pendingTakeReply = reply
        session.pendingTakeFailureCode = code
        loop.attachSegmentRecorder(recorder) { attached ->
            if (activeSession !== session || session.pendingTakeRecorder !== recorder) {
                // Canceled underneath (preview released / disposed / stopped):
                // cancelPendingTake already failed the parked reply.
                recorder.cancel()
                return@attachSegmentRecorder
            }
            session.pendingTakeRecorder = null
            session.pendingTakeReply = null
            if (!attached) {
                recorder.cancel()
                Log.w("DuetCoordinator",
                    "ANDROID_DUET_TAKE_ATTACH_FAILED session=${session.sessionId} route=$route file=${file.name}")
                reply(null, errorMsg(code, "$route: could not attach the take encoder surface to the preview compositor."))
                return@attachSegmentRecorder
            }
            val activeLoop = session.previewRenderLoop ?: loop
            session.state = VGDuetSessionState.RECORDING
            session.currentRecorder = recorder
            session.currentTakeIndex = session.previewClock.segmentCount()
            // The clock captures its speed at startSegment; the recorder's PTS
            // policy must use exactly that value (a setRecordingSpeed may have
            // landed during the async attach gap).
            recorder.setSpeedMultiplier(session.previewClock.speedMultiplier)
            session.startSegment()
            session.previewAudioPlayer?.play(
                session.previewClock.sourceCursorMs,
                session.previewClock.speedMultiplier,
                session.sourceGain,
            )
            // Slice 4B-C: active playback. The provider runs on the main thread only,
            // so reading the preview clock here is safe.
            activeLoop.startActive {
                session.previewClock.currentSourcePtsMs().toLong()
            }
            Log.i("DuetCoordinator",
                "ANDROID_DUET_RECORDING_BEGIN session=${session.sessionId} reason=$reason " +
                    "takeIndex=${session.currentTakeIndex} file=${file.name} " +
                    "speed=${session.previewClock.speedMultiplier} sourceGain=${session.sourceGain} " +
                    "audioPreview=${session.previewAudioPlayer != null}")
            reply(null, null)
        }
    }

    /**
     * Detaches the RECORDING take's encoder surface from the render loop (so
     * no render-thread work can touch it), then finalizes the recorder
     * asynchronously. [onDone] lands on the main thread with null on success
     * (file registered under [takeIndex]) or the error string to reply with.
     * A take that cannot be finalized rolls its clock segment back so the
     * segment/asset lists stay aligned (see [onTakeFinalized]).
     */
    private fun finalizeActiveTake(
        session: VGDuetAndroidSession,
        takeIndex: Int,
        onDone: (String?) -> Unit,
    ) {
        val recorder = session.currentRecorder
        session.currentRecorder = null
        session.currentTakeIndex = -1
        if (recorder == null) {
            // The clock committed a segment but no recorder ever ran for it
            // (should not happen: RECORDING is only entered with a recorder).
            rollbackFailedTake(session, takeIndex, "no_recorder")
            onDone(errorMsg("stop_recording_failed",
                "The take could not be persisted (no recorder was active); the segment was rolled back."))
            return
        }
        session.finalizingRecorders[takeIndex] = recorder
        val proceed = {
            recorder.finishAsync { result ->
                mainHandler.post { onTakeFinalized(session, takeIndex, result, onDone) }
            }
        }
        val loop = session.previewRenderLoop
        if (loop != null) loop.detachSegmentRecorder { proceed() } else proceed()
    }

    /** Main-thread landing of a take's finalize result. */
    private fun onTakeFinalized(
        session: VGDuetAndroidSession,
        takeIndex: Int,
        result: Result<File>,
        onDone: (String?) -> Unit,
    ) {
        session.finalizingRecorders.remove(takeIndex)
        val discarded = session.discardedTakeIndices.remove(takeIndex)
        val sessionLive = activeSession === session
        val file = result.getOrNull()
        val durable = file != null && file.exists() && file.length() > 0L
        var err: String? = null
        if (durable) {
            if (discarded || !sessionLive) {
                deleteFileAsync(file!!)
                if (!sessionLive) {
                    err = errorMsg("invalid_state",
                        "The session was disposed while its take was finalizing; the take was discarded.")
                }
            } else {
                session.segmentAssetPathsByIndex[takeIndex] = file!!.absolutePath
                Log.i("DuetCoordinator",
                    "ANDROID_DUET_TAKE_PERSISTED session=${session.sessionId} takeIndex=$takeIndex " +
                        "path=${file.absolutePath} bytes=${file.length()}")
            }
        } else {
            val reason = result.exceptionOrNull()?.message ?: "unknown"
            if (!sessionLive) {
                err = errorMsg("invalid_state",
                    "The session was disposed while its take was finalizing ($reason).")
            } else if (!discarded) {
                rollbackFailedTake(session, takeIndex, reason)
                err = errorMsg("stop_recording_failed",
                    "The take could not be persisted ($reason); the segment was rolled back.")
            }
        }
        onDone(err)
        val continuation = session.onAllTakesFinalized
        if (continuation != null && session.finalizingRecorders.isEmpty()) {
            session.onAllTakesFinalized = null
            continuation()
        }
    }

    /**
     * Rolls the clock segment [takeIndex] back after its take failed, but only
     * while it is still the last segment (it always is: resume refuses to open
     * a new segment while a take is finalizing). Re-holds preview and audio at
     * the rolled-back cursor and leaves the session PAUSED and retryable.
     */
    private fun rollbackFailedTake(session: VGDuetAndroidSession, takeIndex: Int, reason: String) {
        val last = session.previewClock.segments.lastOrNull()
        if (last == null || last.index != takeIndex) {
            Log.w("DuetCoordinator",
                "ANDROID_DUET_TAKE_FAILED session=${session.sessionId} takeIndex=$takeIndex reason=$reason " +
                    "rollback=skipped lastSegmentIndex=${last?.index}")
            return
        }
        session.previewClock.deleteLastSegment()
        session.segmentAssetPathsByIndex.remove(takeIndex)
        if (session.state == VGDuetSessionState.COMPLETED) {
            session.state = VGDuetSessionState.PAUSED
        }
        val targetPts = session.previewClock.currentSourcePtsMs().toLong()
        if (session.state != VGDuetSessionState.STOPPED) {
            session.previewRenderLoop?.seekAndHold(targetPts)
            session.previewAudioPlayer?.seekTo(targetPts.toInt())
        }
        Log.w("DuetCoordinator",
            "ANDROID_DUET_TAKE_FAILED session=${session.sessionId} takeIndex=$takeIndex reason=$reason " +
                "rollback=applied state=${session.state.name} cursorMs=$targetPts")
    }

    /** Discards the RECORDING take without keeping any file (detach first, then cancel). */
    private fun discardActiveTake(session: VGDuetAndroidSession, reason: String) {
        val recorder = session.currentRecorder ?: return
        session.currentRecorder = null
        session.currentTakeIndex = -1
        Log.i("DuetCoordinator", "ANDROID_DUET_TAKE_DISCARDED session=${session.sessionId} reason=$reason")
        val loop = session.previewRenderLoop
        if (loop != null) loop.detachSegmentRecorder { recorder.cancel() } else recorder.cancel()
    }

    /** Drops the durable file (or marks a still-finalizing take) for clock segment [index]. */
    private fun discardTakeFile(session: VGDuetAndroidSession, index: Int) {
        val path = session.segmentAssetPathsByIndex.remove(index)
        if (path != null) deleteFileAsync(File(path))
        if (session.finalizingRecorders.containsKey(index)) {
            session.discardedTakeIndices.add(index)
        }
    }

    /** Fails a take whose encoder-surface attach is still in flight (preview released / stop / dispose). */
    private fun cancelPendingTake(session: VGDuetAndroidSession, reason: String) {
        val recorder = session.pendingTakeRecorder ?: return
        val reply = session.pendingTakeReply
        val code = session.pendingTakeFailureCode
        session.pendingTakeRecorder = null
        session.pendingTakeReply = null
        recorder.cancel()
        Log.w("DuetCoordinator", "ANDROID_DUET_TAKE_START_CANCELED session=${session.sessionId} reason=$reason")
        reply?.invoke(null, errorMsg(code, "The take could not be started ($reason)."))
    }

    /** Cancels every recorder the session still owns (active, pending, finalizing). Idempotent. */
    private fun cancelAllTakes(session: VGDuetAndroidSession, reason: String) {
        cancelPendingTake(session, reason)
        discardActiveTake(session, reason)
        for (recorder in session.finalizingRecorders.values.toList()) {
            recorder.cancel()
        }
        // Their completions still land in onTakeFinalized (sessionLive == false there).
    }

    /** Runs [action] now, or once every finalizing take has landed. */
    private fun whenAllTakesFinalized(session: VGDuetAndroidSession, action: () -> Unit) {
        if (session.finalizingRecorders.isEmpty()) {
            action()
        } else {
            session.onAllTakesFinalized = action
        }
    }

    private fun ensureSegmentDir(session: VGDuetAndroidSession, ctx: Context): File? {
        val existing = session.segmentDir
        if (existing != null && (existing.isDirectory || existing.mkdirs())) return existing
        val dir = File(File(ctx.cacheDir, SEGMENT_DIR_ROOT), session.sessionId)
        val ok = try { dir.isDirectory || dir.mkdirs() || dir.isDirectory } catch (_: Throwable) { false }
        if (!ok) return null
        session.segmentDir = dir
        return dir
    }

    /** Null when at least [MIN_FREE_DISK_BYTES] are free on [dir]'s volume (or the check itself fails). */
    private fun freeDiskError(dir: File): String? {
        val available = try {
            StatFs(dir.absolutePath).availableBytes
        } catch (t: Throwable) {
            Log.w("DuetCoordinator", "StatFs failed for ${dir.absolutePath}: ${t.message}")
            return null
        }
        if (available >= MIN_FREE_DISK_BYTES) return null
        return "Insufficient free storage for a Duet take (${available / (1024L * 1024L)} MB available, " +
            "${MIN_FREE_DISK_BYTES / (1024L * 1024L)} MB required)."
    }

    private fun deleteFileAsync(file: File) {
        val posted = probeHandler.post {
            try { if (file.exists()) file.delete() } catch (_: Throwable) {}
        }
        if (!posted) {
            try { if (file.exists()) file.delete() } catch (_: Throwable) {}
        }
    }

    /** Deletes the session's take directory (best effort, off the main thread when possible). */
    private fun deleteSegmentDirAsync(session: VGDuetAndroidSession) {
        val dir = session.segmentDir ?: return
        session.segmentDir = null
        session.segmentAssetPathsByIndex.clear()
        val task = Runnable {
            try { dir.deleteRecursively() } catch (_: Throwable) {}
        }
        if (!probeHandler.post(task)) task.run()
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
                // Defect 1 fix: receive notification on the main thread once the
                // render-thread EGL bootstrap completes, then call the centralized
                // startCameraSourceIfNeeded — no synchronous post-attach read of
                // cameraInputSurface. The callback carries no Surface argument:
                // the coordinator reads cameraInputSurface through the render loop's
                // AndroidDuetForegroundSink interface (backend-owned consumer endpoint).
                cameraInputSurfaceReady = {
                    startCameraSourceIfNeeded(session, sessionId)
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
        // Slice 1A: a take that is still RECORDING across a detach/re-attach
        // keeps recording from the new compositor (best effort; frames are
        // simply absent while no preview existed).
        val liveRecorder = session.currentRecorder
        if (liveRecorder != null) {
            renderLoop.attachSegmentRecorder(liveRecorder) { ok ->
                Log.i("DuetCoordinator",
                    "ANDROID_DUET_TAKE_REATTACHED session=$sessionId ok=$ok")
            }
        }
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
     * The coordinator owns CameraX and segmentation lifecycle only; the backend
     * compositor owns the graphics consumer endpoint (SurfaceTexture for GLES,
     * ImageReader/HardwareBuffer for Vulkan). The camera input surface is read
     * through [renderLoop] (which implements [AndroidDuetForegroundSink]) rather
     * than being passed as a callback argument, keeping the raw Surface off the
     * callback payload.
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
     *   - [renderLoop.cameraInputSurface] is null or invalid → no-op (compositor's
     *     cameraInputSurface was already released during teardown before the posted
     *     callback ran; provider.start will report the error internally).
     *
     * [AndroidDuetForegroundProvider.start] itself guards context-availability
     * and camera-already-started idempotency.
     */
    private fun startCameraSourceIfNeeded(
        session: VGDuetAndroidSession,
        sessionId: String,
    ) {
        // Hard lifecycle guards — any of these failing means the session was torn
        // down between when cameraInputSurfaceReady was posted and when it ran.
        if (activeSession !== session) return
        if (session.sessionId != sessionId) return
        val renderLoop = session.previewRenderLoop ?: return
        if (session.previewProducer == null) return
        // Read the backend-owned surface through the sink interface.
        // The compositor (backend) owns the BufferQueue consumer; we only
        // check validity here as a fast-path guard — provider.start will
        // perform the definitive null/isValid check and report onError if needed.
        val surface = renderLoop.cameraInputSurface
        if (surface == null || !surface.isValid) return

        val mode = session.layoutConfigMap["mode"] as? String ?: "pip"
        val provider = session.foregroundProvider
            ?: AndroidDuetCameraForegroundProvider(context, mainHandler).also { session.foregroundProvider = it }

        provider.start(
            sink            = renderLoop,
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

    // Filter-node/camera building, debug backend policy, the segmentation
    // ladder, and the ladder latch now live in AndroidDuetForegroundProvider —
    // see AndroidDuetCameraForegroundProvider.buildGreenScreenFilterNode.

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
        // Phase 0b (Slice 1A): a take whose encoder surface is still being
        // attached to this compositor can never receive frames — fail it too.
        // A take already RECORDING keeps its recorder: the compositor's
        // release() (phase 4) drops only the EGL wrapper of its surface.
        cancelPendingTake(session, "preview_released")
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
        var committed: VGDuetAndroidSegmentRecord? = null
        val wasRecording: Boolean
        when (session.state) {
            VGDuetSessionState.RECORDING -> {
                committed = session.commitSegment()
                wasRecording = true
            }
            VGDuetSessionState.PAUSED, VGDuetSessionState.COMPLETED -> wasRecording = false
            else -> {
                reply(null, invalidState("stopDuetRecording", session.state.name, expected = "RECORDING, PAUSED, or COMPLETED"))
                return
            }
        }
        session.state = VGDuetSessionState.STOPPED
        // Slice 1A: a resume whose encoder attach is still in flight can no
        // longer start; the source preview stops now. Then the active take (if
        // any) is committed + finalized, and the reply waits for every take
        // file to be durable before the session is torn down.
        cancelPendingTake(session, "stop")
        session.previewAudioPlayer?.pause()
        // Fail-closed: a last take that cannot be persisted (its segment is
        // rolled back by onTakeFinalized) must fail the stop itself after the
        // full teardown, never surface as a success with a shorter asset list.
        var stopTakeError: String? = null
        val afterTakes = { completeStop(session, stopTakeError, reply) }
        if (wasRecording && committed != null) {
            finalizeActiveTake(session, committed.index) { err ->
                if (err != null) {
                    Log.w("DuetCoordinator",
                        "ANDROID_DUET_STOP_LAST_TAKE_FAILED session=${session.sessionId} error=$err")
                    stopTakeError = err
                }
                whenAllTakesFinalized(session, afterTakes)
            }
        } else {
            // No committed segment to pair a recorder with (see pauseRecording's
            // preserved quirk): discard rather than persist an orphan take.
            discardActiveTake(session, "stop_without_committed_segment")
            whenAllTakesFinalized(session, afterTakes)
        }
    }

    /**
     * Second half of [stopRecording], run once every take file is durable:
     * tears the preview/decoder/admission down (unless a dispose already did)
     * and replies with the stop result carrying the real segment assets.
     * Fails closed, after that teardown, with [stopTakeError] (the last take's
     * finalize error; its segment was already rolled back) or with
     * `stop_recording_failed` when no take file was persisted at all, so a
     * success reply always carries at least one real asset.
     */
    private fun completeStop(
        session: VGDuetAndroidSession,
        stopTakeError: String?,
        reply: (Any?, String?) -> Unit,
    ) {
        if (activeSession === session) {
            // Slice 4B-C: stop the render loop while the decoder is still reachable,
            // so its final unbind lands on a live decoder before release is queued.
            releasePreviewProducer(session)
            val dec = session.decoder
            session.decoder = null
            activeSession = null
            decoderHandler.post { dec?.release() }
            releaseCameraAdmission(session.sessionId)
        }
        session.previewAudioPlayer?.release()
        session.previewAudioPlayer = null
        val segmentCount = session.previewClock.segmentCount()
        val assetCount = session.segmentAssetPathsByIndex.size
        Log.i("DuetCoordinator",
            "ANDROID_DUET_STOP_RESULT session=${session.sessionId} segments=$segmentCount assets=$assetCount " +
                "totalDurationMs=${session.totalDurationMs()}")
        if (stopTakeError != null || assetCount == 0) {
            Log.w("DuetCoordinator",
                "ANDROID_DUET_STOP_FAILED_CLOSED session=${session.sessionId} segments=$segmentCount " +
                    "assets=$assetCount lastTakeFailed=${stopTakeError != null}")
            reply(null, stopTakeError ?: errorMsg("stop_recording_failed",
                "stopDuetRecording: no take could be persisted for the recorded segments."))
            return
        }
        if (assetCount != segmentCount) {
            Log.w("DuetCoordinator",
                "ANDROID_DUET_STOP_ASSET_MISMATCH session=${session.sessionId} segments=$segmentCount assets=$assetCount")
        }
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
            // Slice 1A: discard every take (active / pending / finalizing) and
            // the source-audio preview before the preview stack goes away; the
            // take directory is deleted last (a disposed session's takes never
            // reach a caller).
            cancelAllTakes(current, "dispose")
            current.previewAudioPlayer?.release()
            current.previewAudioPlayer = null
            // Slice 4B-C: render loop stops while decoder is still non-null.
            releasePreviewProducer(current)
            val dec = current.decoder
            current.decoder = null
            activeSession = null
            decoderHandler.post { dec?.release() }
            releaseCameraAdmission(sessionId)
            deleteSegmentDirAsync(current)
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
            // Slice 1A: see disposeSession. The directory delete is posted to
            // probeHandler before quitSafely below, so it still runs.
            cancelAllTakes(current, "dispose_all")
            current.previewAudioPlayer?.release()
            current.previewAudioPlayer = null
            // Slice 4B-C: stopBlocking inside completes the render-loop unbind
            // (decoder still non-null) before the decoder thread is quit below.
            releasePreviewProducer(current)
            val dec = current.decoder
            current.decoder = null
            decoderHandler.post { dec?.release() }
            releaseCameraAdmission(current.sessionId)
            deleteSegmentDirAsync(current)
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
