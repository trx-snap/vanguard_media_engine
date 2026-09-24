package com.connects.vanguard_media_engine.greenscreen

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.util.Log
import android.view.Surface
import androidx.core.content.ContextCompat
import com.connects.vanguard_media_engine.camera.AndroidCameraSessionAdmission
import com.connects.vanguard_media_engine.camera.AndroidPreviewSurfaceProducer
import com.connects.vanguard_media_engine.camera.AndroidPreviewSurfaceState
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

// -----------------------------------------------------------------------------
// VG-LIVE-GREENSCREEN: generic live green-screen session (Android v1).
// -----------------------------------------------------------------------------
//
// Owns at most one live session that composites the engine-owned front camera,
// keyed by the production segmentation ladder, over a static solid-color or
// image background that fills the full canvas. Caller-agnostic: live
// meeting/calling, going live, camera, and any other surface start it through
// the four `*LiveGreenScreenSession` routes; nothing here is Duet-owned.
//
// Reuses the production GL preview stack as-is (no diagnostics Canvas code):
//   - AndroidPreviewSurfaceProducer      → Flutter texture / output Surface
//   - AndroidGreenScreenPreviewRenderLoop → independent single-camera render
//                                          thread + preview backend: no
//                                          decoderProvider, no source-video
//                                          clock, no Duet layout modes — the
//                                          camera redraw pump presents every
//                                          camera frame directly.
//     Backend selection (render loop factory seam): the GPU-resident backend
//     (AndroidGreenScreenGpuResidentPreviewBackend: self-contained TFLite
//     GpuDelegate segmentation + native ES 3.1 guided-filter composite, one
//     frame transaction per camera frame) is the default. If its first
//     attach fails (EGL/ES 3.1/model validation), the loop falls back to
//     AndroidGreenScreenPreviewCompositor BEFORE the camera starts; the
//     coordinator reads `usingFallbackBackend` inside cameraInputSurfaceReady
//     to configure the camera source to match.
//   - AndroidGreenScreenCamera2Source    → independent front-camera Camera2
//                                          source. With the GPU-resident
//                                          backend it runs preview-only
//                                          (analysisEnabled=false: no
//                                          ImageReader, no CPU segmentation
//                                          pipeline, no onMask). On fallback
//                                          it feeds the production
//                                          segmentation ladder (mediapipe_cpu
//                                          -> mlkit -> none) directly against
//                                          a Camera2 Image (see its class doc
//                                          for why it never uses CameraX/
//                                          ImageAnalysis or an ImageProxy).
//                                          The ladder walk itself is owned and
//                                          contained inside that source/its
//                                          segmentation pipeline; this
//                                          coordinator only sees `onMask`,
//                                          `onCameraFrameTransform`,
//                                          `onStarted`, and `onError`, so it
//                                          reports a coarse raw_tflite_gpu /
//                                          mediapipe_cpu / none backend rather
//                                          than the live rung.
//   - AndroidGreenScreenBackground   → static background spec (from the
//                                          very first frame; never VIDEO here).
//   - AndroidGreenScreenLayoutGeometry.greenScreen(canvas, transform) → source rect =
//     full canvas, camera rect = transformed keyed layer.
//
// Camera admission: the engine-wide AndroidCameraSessionAdmission lane is
// acquired after validation and before any resource is created, and released
// on every terminal path. A live start while Duet holds the lane fails with
// `live_busy`; Duet's own initialize fails with `session_conflict` while this
// coordinator holds it.
//
// Threading: every public method runs on the main thread (called by
// AndroidLiveGreenScreenMethodHandler). The camera source's callbacks
// (`onCameraFrameTransform`, `onMask`, `onStarted`, `onError`) are posted to
// the render thread or hopped to the main thread by the render loop itself
// before touching compositor/session state.
//
// Cleanup order on stop/dispose (matches the render loop's documented
// contract — prepareForCameraStop must precede the Camera2 stop so no
// drawFrame races the last OES write):
//   recording discard (detach encoder surface -> recorder.cancel, partial
//   deleted) -> producer.beginRelease -> renderLoop.prepareForCameraStop
//   -> camera.stop -> renderLoop.stopBlocking() -> producer.finishRelease
//   -> admission.release. No Surface.release on producer-owned surfaces.
//
// Recording (VG-LIVE-GREENSCREEN-RECORDING): at most one
// AndroidGreenScreenSegmentRecorder per session. start attaches the
// recorder's encoder surface to the preview backend through the render loop
// (async, render thread); the backend then draws the SAME full composite it
// presents on the texture into the encoder once per newly latched camera
// frame, so the file is exactly what the preview shows at 1.0x. stop detaches
// first (so no render-thread work can touch the encoder surface), then
// finalizes asynchronously and commits ".tmp" -> final only after non-empty
// validation. cancel / session stop / dispose / any encoder failure delete
// the partial and clear the recording state; the preview keeps running in
// every case except session stop. A backend without an encoder draw route
// (the GPU-resident backend today) rejects the attach and start fails closed
// with `recording_failed` -- never a black or raw-camera file.
//
// Still photo (VG-LIVE-GREENSCREEN-PHOTO): `takePhoto` asks the render loop
// for a one-shot read-back of the SAME composite the preview backend
// presents (background + keyed camera, current layout; both backends read it
// between their composite pass and the preview swap, the GPU-resident one
// through native). Only the pixel read runs on the render thread; row-flip,
// JPEG encode and the ".tmp" -> final commit run on a worker thread, and the
// reply lands on main only after the committed file is validated non-empty.
// Never the raw camera, never a Flutter texture screenshot, never an
// export-time recomposition; the preview and any active recording keep
// running, and a failure deletes the partial and leaves the session alive.

class AndroidLiveGreenScreenSessionCoordinator(
    private val mainHandler: Handler,
    private val textureRegistry: TextureRegistry?,
    private val context: Context?,
    private val cameraAdmission: AndroidCameraSessionAdmission,
    /**
     * Emits an `onLiveGreenScreenEvent` payload to Dart. Always invoked on the
     * main thread; the closure itself may post again before calling
     * `channel.invokeMethod`.
     */
    private val onLiveGreenScreenEvent: ((Map<String, Any?>) -> Unit)?,
) {

    companion object {
        private const val TAG = "LiveGreenScreenCoordinator"

        const val ADMISSION_OWNER = AndroidCameraSessionAdmission.OWNER_LIVE_GREEN_SCREEN

        // MethodChannel error codes (decoded from "code|message" by the handler).
        const val ERROR_LIVE_BUSY = "live_busy"
        const val ERROR_CAMERA_UNAVAILABLE = "cameraUnavailable"
        const val ERROR_COMPOSITION_FAILED = "composition_failed"
        const val ERROR_SESSION_NOT_FOUND = "session_not_found"
        const val ERROR_INVALID_ARG = "INVALID_ARG"
        const val ERROR_RECORDING_ACTIVE = "recording_active"
        const val ERROR_RECORDING_NOT_ACTIVE = "recording_not_active"
        const val ERROR_RECORDING_FAILED = "recording_failed"
        const val ERROR_DISK_FULL = "disk_full"

        /** Minimum free space on the recording volume before a recording may start. */
        private const val MIN_FREE_DISK_BYTES = 200L * 1024L * 1024L

        /** Cache subdirectory used when the caller supplies no outputPath. */
        private const val RECORDING_DIR_NAME = "vanguard_live_green_screen"

        // Event names on the `onLiveGreenScreenEvent` payload.
        const val EVENT_DEGRADED = "green_screen_degraded"
        const val EVENT_FALLBACK = "green_screen_fallback"
        const val EVENT_SUSPENDED = "suspended"
        const val EVENT_RESUMED = "resumed"
        const val EVENT_ERROR = "error"
    }

    /** Validated start arguments (built by the method handler). */
    class StartRequest(
        val widthPx: Int,
        val heightPx: Int,
        val background: AndroidGreenScreenBackground,
        val foregroundTransform: AndroidGreenScreenForegroundTransform?,
    )

    // ── Session ───────────────────────────────────────────────────────────────

    private class LiveSession(
        val sessionId: String,
        val widthPx: Int,
        val heightPx: Int,
        var background: AndroidGreenScreenBackground,
        var foregroundTransform: AndroidGreenScreenForegroundTransform?,
        var layoutRects: AndroidGreenScreenLayoutRects,
    ) {
        var producer: AndroidPreviewSurfaceProducer? = null
        var renderLoop: AndroidGreenScreenPreviewRenderLoop? = null
        var cameraSource: AndroidGreenScreenCamera2Source? = null
        /** True between an output-surface loss and its re-availability. */
        var suspended: Boolean = false
        /**
         * Coarse segmentation backend label reported in events/logs while the
         * camera source runs: raw_tflite_gpu for the GPU-resident backend,
         * mediapipe_cpu for the CPU compositor fallback. Set at camera start.
         */
        var segmentationBackend: String = AndroidGreenScreenSegmentationBackend.MEDIAPIPE_CPU

        /** Recorder whose encoder surface is attached to the preview backend (RECORDING). */
        var recorder: AndroidGreenScreenSegmentRecorder? = null

        /**
         * Recorder whose encoder-surface attach is still in flight on the render
         * thread; its start reply is parked in [pendingRecordingReply] until the
         * attach lands (or the session/recording is canceled underneath it).
         */
        var pendingRecorder: AndroidGreenScreenSegmentRecorder? = null
        var pendingRecordingReply: ((Any?, String?) -> Unit)? = null
    }

    // ── State ─────────────────────────────────────────────────────────────────

    @Volatile private var activeSession: LiveSession? = null
    private val disposed = AtomicBoolean(false)

    // ── start ─────────────────────────────────────────────────────────────────

    fun startSession(request: StartRequest, reply: (Any?, String?) -> Unit) {
        if (disposed.get()) {
            reply(null, errorMsg(ERROR_COMPOSITION_FAILED,
                "startLiveGreenScreenSession: coordinator has been disposed."))
            return
        }
        val existing = activeSession
        if (existing != null) {
            reply(null, errorMsg(ERROR_LIVE_BUSY,
                "startLiveGreenScreenSession: live session '${existing.sessionId}' is already active. Stop it first."))
            return
        }
        val ctx = context
        val registry = textureRegistry
        if (ctx == null || registry == null) {
            reply(null, errorMsg(ERROR_COMPOSITION_FAILED,
                "startLiveGreenScreenSession: engine context/textureRegistry not available."))
            return
        }
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            reply(null, errorMsg(ERROR_CAMERA_UNAVAILABLE,
                "startLiveGreenScreenSession: CAMERA permission not granted."))
            return
        }

        val sessionId = UUID.randomUUID().toString()
        if (!cameraAdmission.tryAcquire(ADMISSION_OWNER, sessionId)) {
            reply(null, errorMsg(ERROR_LIVE_BUSY,
                "startLiveGreenScreenSession: camera is held by another engine session " +
                    "(${cameraAdmission.debugString()}). Stop it first."))
            return
        }

        val widthPx = request.widthPx
        val heightPx = request.heightPx
        val session = LiveSession(
            sessionId = sessionId,
            widthPx = widthPx,
            heightPx = heightPx,
            background = request.background,
            foregroundTransform = request.foregroundTransform,
            layoutRects = AndroidGreenScreenLayoutGeometry.greenScreen(
                widthPx.toDouble(), heightPx.toDouble(), request.foregroundTransform,
            ),
        )

        val producer = try {
            AndroidPreviewSurfaceProducer(
                textureRegistry    = registry,
                mainHandler        = mainHandler,
                widthPx            = widthPx,
                heightPx           = heightPx,
                onSurfaceAvailable = { handleSurfaceAvailable(sessionId) },
                onSurfaceLost      = { handleSurfaceLost(sessionId) },
            )
        } catch (t: Throwable) {
            cameraAdmission.release(ADMISSION_OWNER, sessionId)
            reply(null, errorMsg(ERROR_COMPOSITION_FAILED,
                "startLiveGreenScreenSession: failed to create SurfaceProducer: ${t.message}"))
            return
        }

        val renderLoop = try {
            AndroidGreenScreenPreviewRenderLoop(
                mainHandler = mainHandler,
                cameraInputSurfaceReady = { camSurface ->
                    startCameraSourceIfNeeded(session, camSurface)
                },
                // Primary: GPU-resident self-contained segmentation backend.
                // Its EGL/ES 3.1/TFLite bootstrap runs inside its first attach
                // on the render thread; if that fails the loop swaps in the
                // proven CPU-mask compositor before any camera start.
                backendFactory = { AndroidGreenScreenGpuResidentPreviewBackend(ctx) },
                fallbackBackendFactory = { AndroidGreenScreenPreviewCompositor() },
            )
        } catch (t: Throwable) {
            producer.release()
            cameraAdmission.release(ADMISSION_OWNER, sessionId)
            reply(null, errorMsg(ERROR_COMPOSITION_FAILED,
                "startLiveGreenScreenSession: failed to create render loop: ${t.message}"))
            return
        }

        session.producer = producer
        session.renderLoop = renderLoop
        // Static background from the very first frame and keying enabled up
        // front: the compositor draws the background on every frame and the
        // masked camera as soon as both a camera frame and a mask exist.
        renderLoop.setGreenScreenBackground(session.background)
        renderLoop.setGreenScreenEnabled(true)
        activeSession = session

        // The producer's eager availability probe never fires the hook, so
        // bootstrap the output here when the surface already exists. Camera
        // start is driven exclusively by cameraInputSurfaceReady.
        if (producer.state == AndroidPreviewSurfaceState.SURFACE_AVAILABLE) {
            val surface = producer.acquireSurface()
            if (surface != null) {
                renderLoop.attachOutputSurface(
                    surface, widthPx, heightPx,
                    session.layoutRects.source, session.layoutRects.camera,
                )
            }
        }

        Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_SESSION_STARTED session=$sessionId " +
            "canvas=${widthPx}x$heightPx background=${session.background.type.name.lowercase()} " +
            "textureId=${producer.textureId}")
        reply(producer.toResultMap(widthPx, heightPx) + ("sessionId" to sessionId), null)
    }

    // ── updateBackground ──────────────────────────────────────────────────────

    fun updateBackground(
        sessionId: String,
        background: AndroidGreenScreenBackground,
        reply: (Any?, String?) -> Unit,
    ) {
        val session = resolveSession(sessionId, "updateLiveGreenScreenBackground", reply) ?: return
        session.background = background
        session.renderLoop?.setGreenScreenBackground(background)
        reply(null, null)
    }

    // ── updateTransform ───────────────────────────────────────────────────────

    fun updateTransform(
        sessionId: String,
        transform: AndroidGreenScreenForegroundTransform?,
        reply: (Any?, String?) -> Unit,
    ) {
        val session = resolveSession(sessionId, "updateLiveGreenScreenTransform", reply) ?: return
        session.foregroundTransform = transform
        val rects = AndroidGreenScreenLayoutGeometry.greenScreen(
            session.widthPx.toDouble(), session.heightPx.toDouble(), transform,
        )
        session.layoutRects = rects
        session.renderLoop?.updateLayout(rects.source, rects.camera)
        reply(null, null)
    }

    // ── stop (idempotent) ─────────────────────────────────────────────────────

    fun stopSession(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = activeSession
        if (session == null || session.sessionId != sessionId) {
            // Unknown or already stopped: success, nothing to do.
            reply(null, null)
            return
        }
        activeSession = null
        releaseSession(session, "stop")
        reply(null, null)
    }

    // ── recording: start ──────────────────────────────────────────────────────

    /**
     * Starts recording the composited output of [sessionId] to [outputPath]
     * (absolute local path; null → a fresh file in the app cache). Replies
     * only once the encoder surface is attached to the preview backend, so a
     * success reply means frames are being encoded. Fails closed (nothing
     * left recording, no file left behind) with `recording_active`,
     * `disk_full`, `INVALID_ARG` (bad/existing outputPath) or
     * `recording_failed`; the preview is untouched by any failure.
     */
    fun startRecording(sessionId: String, outputPath: String?, reply: (Any?, String?) -> Unit) {
        val route = "startLiveGreenScreenRecording"
        val session = resolveSession(sessionId, route, reply) ?: return
        if (session.recorder != null || session.pendingRecorder != null) {
            reply(null, errorMsg(ERROR_RECORDING_ACTIVE,
                "$route: a recording is already active on session '$sessionId'."))
            return
        }
        val ctx = context
        if (ctx == null) {
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: application context unavailable; cannot persist the recording."))
            return
        }
        val loop = session.renderLoop
        if (loop == null || session.producer == null) {
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: the preview is not attached, so composited frames are unavailable."))
            return
        }
        val file: File
        if (outputPath != null) {
            val candidate = File(outputPath)
            if (!candidate.isAbsolute) {
                reply(null, errorMsg(ERROR_INVALID_ARG,
                    "$route: 'outputPath' must be an absolute local path (got '$outputPath')."))
                return
            }
            if (candidate.exists()) {
                reply(null, errorMsg(ERROR_INVALID_ARG,
                    "$route: 'outputPath' already exists: $outputPath"))
                return
            }
            file = candidate
        } else {
            file = File(
                File(ctx.cacheDir, RECORDING_DIR_NAME),
                "live_gs_${sessionId.take(8)}_${System.currentTimeMillis()}.mp4",
            )
        }
        val dir = file.parentFile
        if (dir == null || (!dir.exists() && !dir.mkdirs() && !dir.exists())) {
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: cannot create the recording directory ${dir?.absolutePath ?: "<none>"}."))
            return
        }
        val freeBytes = try { dir.usableSpace } catch (_: Throwable) { Long.MAX_VALUE }
        if (freeBytes in 0 until MIN_FREE_DISK_BYTES) {
            reply(null, errorMsg(ERROR_DISK_FULL,
                "$route: insufficient free space (${freeBytes / (1024L * 1024L)} MB free; " +
                    "${MIN_FREE_DISK_BYTES / (1024L * 1024L)} MB required)."))
            return
        }

        val recorder = AndroidGreenScreenSegmentRecorder(
            context = ctx,
            outputFile = file,
            widthPx = session.widthPx,
            heightPx = session.heightPx,
        )
        if (!recorder.start()) {
            recorder.cancel()
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: the recording encoder/muxer could not be started."))
            return
        }
        session.pendingRecorder = recorder
        session.pendingRecordingReply = reply
        loop.attachSegmentRecorder(recorder) { attached ->
            if (activeSession !== session || session.pendingRecorder !== recorder) {
                // Canceled underneath (session released / recording canceled while
                // attaching): cancelPendingRecording already failed the parked reply.
                recorder.cancel()
                return@attachSegmentRecorder
            }
            session.pendingRecorder = null
            session.pendingRecordingReply = null
            if (!attached) {
                recorder.cancel()
                val backend = if (loop.usingFallbackBackend) "gles_compositor" else "gpu_resident"
                Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDING_ATTACH_FAILED session=${session.sessionId} " +
                    "backend=$backend file=${file.name}")
                reply(null, errorMsg(ERROR_RECORDING_FAILED,
                    "$route: the preview backend ($backend) could not accept the recording encoder surface."))
                return@attachSegmentRecorder
            }
            session.recorder = recorder
            Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDING_STARTED session=${session.sessionId} " +
                "file=${file.absolutePath} size=${session.widthPx}x${session.heightPx} " +
                "audio=${recorder.audioEnabled}")
            reply(null, null)
        }
    }

    // ── recording: stop (commit) ──────────────────────────────────────────────

    /**
     * Detaches the active recorder's encoder surface from the preview backend,
     * finalizes it asynchronously and replies with the committed file
     * (`{filePath, durationMs, fileSizeBytes, width, height, hasAudio}`), or
     * `recording_failed` with the recorder's reason when the file could not
     * be committed (the partial is deleted). `recording_not_active` when no
     * recording is running. The preview keeps running in every case.
     */
    fun stopRecording(sessionId: String, reply: (Any?, String?) -> Unit) {
        val route = "stopLiveGreenScreenRecording"
        val session = resolveSession(sessionId, route, reply) ?: return
        if (session.pendingRecorder != null) {
            // The start was still attaching: it never began encoding, so there is
            // nothing to commit. Discard it and report no active recording.
            cancelPendingRecording(session, "stop_during_attach")
            reply(null, errorMsg(ERROR_RECORDING_NOT_ACTIVE,
                "$route: the recording was still starting and has been discarded."))
            return
        }
        val recorder = session.recorder
        if (recorder == null) {
            reply(null, errorMsg(ERROR_RECORDING_NOT_ACTIVE,
                "$route: no recording is active on session '$sessionId'."))
            return
        }
        session.recorder = null
        val proceed = {
            recorder.finishAsync { result ->
                mainHandler.post { onRecordingFinished(session, route, result, reply) }
            }
        }
        val loop = session.renderLoop
        if (loop != null) loop.detachSegmentRecorder { proceed() } else proceed()
    }

    /** Main-thread landing of a recording's finalize result. */
    private fun onRecordingFinished(
        session: LiveSession,
        route: String,
        result: Result<AndroidGreenScreenSegmentRecorder.Outcome>,
        reply: (Any?, String?) -> Unit,
    ) {
        val outcome = result.getOrNull()
        if (outcome == null) {
            val reason = result.exceptionOrNull()?.message ?: "unknown"
            Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDING_FAILED session=${session.sessionId} reason=$reason")
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: the recording could not be committed ($reason); the partial file was deleted."))
            return
        }
        Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDING_COMMITTED session=${session.sessionId} " +
            "file=${outcome.file.absolutePath} bytes=${outcome.fileSizeBytes} durationMs=${outcome.durationMs} " +
            "audio=${outcome.hasAudio}")
        reply(
            mapOf(
                "filePath" to outcome.file.absolutePath,
                "durationMs" to outcome.durationMs,
                "fileSizeBytes" to outcome.fileSizeBytes,
                "width" to session.widthPx,
                "height" to session.heightPx,
                "hasAudio" to outcome.hasAudio,
            ),
            null,
        )
    }

    // ── recording: cancel (idempotent) ────────────────────────────────────────

    /**
     * Discards the active (or still-attaching) recording, deleting its partial
     * file. Completes normally when no recording is running. The preview
     * keeps running.
     */
    fun cancelRecording(sessionId: String, reply: (Any?, String?) -> Unit) {
        val session = resolveSession(sessionId, "cancelLiveGreenScreenRecording", reply) ?: return
        cancelPendingRecording(session, "cancel")
        discardActiveRecording(session, "cancel")
        reply(null, null)
    }

    /**
     * Fails a start whose encoder-surface attach is still in flight: the
     * parked reply gets `recording_failed`, the recorder is canceled (its
     * partial deleted), and the attach callback later sees a foreign
     * [LiveSession.pendingRecorder] and cancels again (idempotent).
     */
    private fun cancelPendingRecording(session: LiveSession, reason: String) {
        val pending = session.pendingRecorder ?: return
        val parked = session.pendingRecordingReply
        session.pendingRecorder = null
        session.pendingRecordingReply = null
        pending.cancel()
        Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDING_DISCARDED session=${session.sessionId} reason=$reason stage=attaching")
        parked?.invoke(null, errorMsg(ERROR_RECORDING_FAILED,
            "startLiveGreenScreenRecording: the recording was canceled while starting ($reason)."))
    }

    /** Detaches the encoder surface first, then discards the recorder (partial deleted). */
    private fun discardActiveRecording(session: LiveSession, reason: String) {
        val recorder = session.recorder ?: return
        session.recorder = null
        Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_RECORDING_DISCARDED session=${session.sessionId} reason=$reason stage=recording")
        val loop = session.renderLoop
        if (loop != null) loop.detachSegmentRecorder { recorder.cancel() } else recorder.cancel()
    }

    // ── still photo (VG-LIVE-GREENSCREEN-PHOTO) ───────────────────────────────

    /**
     * Captures the composited output of [sessionId] as one JPEG at
     * [outputPath] (absolute local path that must not exist yet) and replies
     * with `{filePath, width, height, fileSizeBytes}` once the file is
     * committed and validated non-empty. The frame is the composite the
     * preview backend presents right now (see the class doc); the preview and
     * any active recording are untouched. Fails closed with `INVALID_ARG`
     * (relative / existing path) or `recording_failed` (preview not attached
     * or suspended, unwritable directory, no camera frame yet, read-back /
     * encode / commit failure); no file is left at [outputPath] on failure and
     * the session stays alive for a retry.
     */
    fun takePhoto(sessionId: String, outputPath: String, reply: (Any?, String?) -> Unit) {
        val route = "takeLiveGreenScreenPhoto"
        val session = resolveSession(sessionId, route, reply) ?: return
        val file = File(outputPath)
        if (!file.isAbsolute) {
            reply(null, errorMsg(ERROR_INVALID_ARG,
                "$route: 'outputPath' must be an absolute local path (got '$outputPath')."))
            return
        }
        if (file.exists()) {
            reply(null, errorMsg(ERROR_INVALID_ARG,
                "$route: 'outputPath' already exists: $outputPath"))
            return
        }
        val loop = session.renderLoop
        if (loop == null || session.producer == null) {
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: the preview is not attached, so no composited frame is available."))
            return
        }
        if (session.suspended) {
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: the preview output is suspended, so no composited frame is being presented."))
            return
        }
        val dir = file.parentFile
        if (dir == null || (!dir.exists() && !dir.mkdirs() && !dir.exists())) {
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: cannot create the photo directory ${dir?.absolutePath ?: "<none>"}."))
            return
        }
        val backend = if (loop.usingFallbackBackend) "gles_compositor" else "gpu_resident"
        // The loop delivers on the main thread exactly once.
        loop.captureCompositePhoto(file) { result ->
            onPhotoFinished(session, route, backend, file, result, reply)
        }
    }

    /** Main-thread landing of a still photo's capture/encode/commit result. */
    private fun onPhotoFinished(
        session: LiveSession,
        route: String,
        backend: String,
        file: File,
        result: Result<AndroidGreenScreenPreviewRenderLoop.CompositePhotoOutcome>,
        reply: (Any?, String?) -> Unit,
    ) {
        val outcome = result.getOrNull()
        if (outcome == null) {
            val reason = result.exceptionOrNull()?.message ?: "unknown"
            // Never leave a partial at the final path (the loop already
            // deleted its own temp; this is the belt to that suspender).
            try { if (file.exists()) file.delete() } catch (_: Throwable) {}
            Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_PHOTO_FAILED session=${session.sessionId} " +
                "backend=$backend reason=$reason")
            reply(null, errorMsg(ERROR_RECORDING_FAILED,
                "$route: the composited photo could not be captured ($reason)."))
            return
        }
        Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_PHOTO_COMMITTED session=${session.sessionId} " +
            "backend=$backend file=${outcome.file.absolutePath} size=${outcome.widthPx}x${outcome.heightPx} " +
            "bytes=${outcome.fileSizeBytes}")
        reply(
            mapOf(
                "filePath" to outcome.file.absolutePath,
                "width" to outcome.widthPx,
                "height" to outcome.heightPx,
                "fileSizeBytes" to outcome.fileSizeBytes,
            ),
            null,
        )
    }

    // ── disposeAll ────────────────────────────────────────────────────────────

    fun disposeAll() {
        if (!disposed.compareAndSet(false, true)) return
        val session = activeSession
        activeSession = null
        if (session != null) releaseSession(session, "dispose")
    }

    // ── Output surface lifecycle (platform thread, synchronous) ───────────────

    private fun handleSurfaceAvailable(sessionId: String) {
        val session = activeSession ?: return
        if (session.sessionId != sessionId) return
        val producer = session.producer ?: return
        val renderLoop = session.renderLoop ?: return
        val surface = producer.acquireSurface() ?: return
        renderLoop.attachOutputSurface(
            surface, session.widthPx, session.heightPx,
            session.layoutRects.source, session.layoutRects.camera,
        )
        if (session.suspended) {
            session.suspended = false
            val backend = reportedBackend(session)
            emit(session, EVENT_RESUMED, backend, backend, "output_surface_available",
                "Live green-screen output resumed.")
        }
    }

    private fun handleSurfaceLost(sessionId: String) {
        val session = activeSession ?: return
        if (session.sessionId != sessionId) return
        // Must not block: the loop gates submissions immediately and detaches
        // its EGL surface asynchronously. The camera keeps running so a
        // re-available surface resumes without a camera restart.
        session.renderLoop?.handleOutputSurfaceLost()
        if (!session.suspended) {
            session.suspended = true
            val backend = reportedBackend(session)
            emit(session, EVENT_SUSPENDED, backend, backend, "output_surface_lost",
                "Live green-screen output suspended until the surface returns.")
        }
    }

    // ── Camera start (main thread, from cameraInputSurfaceReady) ──────────────

    /**
     * Idempotent camera start. No-ops when the session was torn down between
     * the render-thread post and this main-thread run, when the compositor
     * surface is already dead, or when the camera is already running (it
     * survives output loss).
     *
     * Backend-matched camera configuration: the render loop has already
     * settled its backend (primary GPU-resident, or CPU fallback) before this
     * callback was posted. With the GPU-resident backend the camera source
     * runs preview-only (`analysisEnabled = false`): segmentation happens
     * inside the backend's own frame transaction, so no ImageReader, no CPU
     * segmentation pipeline and no `onMask` ever exist. On fallback,
     * [AndroidGreenScreenCamera2Source] owns its own segmentation ladder
     * (mediapipe_cpu -> mlkit -> none) internally exactly as before and
     * forwards `onMask` to the render loop. In both cases it calls back with
     * `onCameraFrameTransform` (forwarded to the render loop), `onStarted`,
     * and `onError`. On failure the source is stopped and nulled so a later
     * re-attach can retry, and an `error` event is emitted; the session stays
     * alive for the caller to stop.
     */
    private fun startCameraSourceIfNeeded(session: LiveSession, surface: Surface) {
        if (activeSession !== session) return
        val renderLoop = session.renderLoop ?: return
        if (session.producer == null) return
        if (!surface.isValid) return
        val ctx = context ?: return
        if (session.cameraSource != null) return

        val gpuResident = !renderLoop.usingFallbackBackend
        session.segmentationBackend = if (gpuResident) {
            AndroidGreenScreenSegmentationBackend.RAW_TFLITE_GPU
        } else {
            AndroidGreenScreenSegmentationBackend.MEDIAPIPE_CPU
        }
        val backendLabel = session.segmentationBackend

        val camSource = AndroidGreenScreenCamera2Source(ctx, analysisEnabled = !gpuResident)
        session.cameraSource = camSource

        camSource.start(
            targetSurface = surface,
            onCameraFrameTransform = { rotationDegrees, mirrorHorizontal ->
                session.renderLoop?.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
            },
            onMask = { frame -> session.renderLoop?.updateGreenScreenMask(frame) },
            onStarted = {
                Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_CAMERA_STARTED session=${session.sessionId} " +
                    "source=${if (gpuResident) "camera2_preview_only" else "camera2_clean_segmentation"} " +
                    "backend=$backendLabel gpuResident=$gpuResident")
            },
            onError = { e ->
                Log.w(TAG, "Camera source failed for live session ${session.sessionId}: ${e.message}")
                camSource.stop()
                if (activeSession === session && session.cameraSource === camSource) {
                    session.cameraSource = null
                    emit(session, EVENT_ERROR, backendLabel, AndroidGreenScreenSegmentationBackend.NONE,
                        "camera_start_failed",
                        "The camera could not be started: ${e.message ?: e.javaClass.simpleName}")
                }
            },
        )
    }

    /**
     * Coarse backend label for `suspended`/`resumed`/`error` events: the
     * independent Camera2 source's internal ladder (mediapipe_cpu -> mlkit ->
     * none) is not observable from here, so this reports the session's
     * settled backend (`raw_tflite_gpu` for the GPU-resident backend,
     * `mediapipe_cpu` on fallback) while the camera source is running and
     * `none` once it is gone.
     */
    private fun reportedBackend(session: LiveSession): String =
        if (session.cameraSource != null) session.segmentationBackend else AndroidGreenScreenSegmentationBackend.NONE

    // ── Release ───────────────────────────────────────────────────────────────

    private fun releaseSession(session: LiveSession, why: String) {
        val producer = session.producer
        val renderLoop = session.renderLoop
        val camSource = session.cameraSource
        // Phase 0: discard any recording (partial deleted). The detach is posted
        // to the render thread ahead of stopBlocking's release below, so no
        // render-thread work touches the encoder surface after this point.
        cancelPendingRecording(session, why)
        discardActiveRecording(session, why)
        // Phase 1: stop new producer submissions (no hook fires).
        producer?.beginRelease()
        // Phase 2: halt render-thread pumps and block swap acceptance BEFORE
        // the Camera2 source is stopped, so no drawFrame races the last OES
        // write.
        renderLoop?.prepareForCameraStop()
        // Phase 3: stop the camera source (also closes its segmentation
        // pipeline and every backend it opened).
        camSource?.stop()
        // Phase 4: release the compositor (releases cameraInputSurface).
        renderLoop?.stopBlocking()
        // Phase 5: drop the Flutter SurfaceProducer.
        producer?.finishRelease()
        session.cameraSource = null
        session.producer = null
        session.renderLoop = null
        // Phase 6: free the engine-wide camera lane.
        cameraAdmission.release(ADMISSION_OWNER, session.sessionId)
        Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_SESSION_RELEASED session=${session.sessionId} reason=$why")
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun emit(
        session: LiveSession,
        event: String,
        previousBackend: String,
        currentBackend: String,
        reason: String,
        userMessage: String,
    ) {
        onLiveGreenScreenEvent?.invoke(
            mapOf(
                "event" to event,
                "sessionId" to session.sessionId,
                "previousBackend" to previousBackend,
                "currentBackend" to currentBackend,
                "reason" to reason,
                "userMessage" to userMessage,
            )
        )
    }

    private fun resolveSession(
        sessionId: String,
        route: String,
        reply: (Any?, String?) -> Unit,
    ): LiveSession? {
        val session = activeSession
        if (session == null || session.sessionId != sessionId) {
            reply(null, errorMsg(ERROR_SESSION_NOT_FOUND,
                "$route: no active live green-screen session with id '$sessionId'."))
            return null
        }
        return session
    }

    /** Encodes error as "code|message" for the handler to decode and surface as FlutterError. */
    private fun errorMsg(code: String, message: String): String = "$code|$message"
}
