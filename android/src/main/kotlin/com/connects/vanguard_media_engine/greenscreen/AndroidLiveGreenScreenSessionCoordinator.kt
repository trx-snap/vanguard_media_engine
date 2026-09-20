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
//                                          thread + GLES compositor: no
//                                          decoderProvider, no source-video
//                                          clock, no Duet layout modes — the
//                                          camera redraw pump presents every
//                                          camera frame directly.
//   - AndroidGreenScreenCamera2Source    → independent front-camera Camera2
//                                          source feeding the production
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
//                                          reports a coarse mediapipe_cpu/none
//                                          backend rather than the live rung.
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
//   producer.beginRelease -> renderLoop.prepareForCameraStop -> camera.stop
//   -> renderLoop.stopBlocking() -> producer.finishRelease
//   -> admission.release. No Surface.release on producer-owned surfaces.

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
     * survives output loss). [AndroidGreenScreenCamera2Source] owns its own
     * segmentation ladder (mediapipe_cpu -> mlkit -> none) internally and only
     * ever calls back here with `onCameraFrameTransform` (forwarded to the
     * render loop so the compositor corrects for sensor orientation/mirroring),
     * `onMask` (forwarded to the render loop), `onStarted`, and `onError`. On
     * failure the source is stopped and nulled so a later re-attach can retry,
     * and an `error` event is emitted; the session stays alive for the caller
     * to stop.
     */
    private fun startCameraSourceIfNeeded(session: LiveSession, surface: Surface) {
        if (activeSession !== session) return
        if (session.renderLoop == null || session.producer == null) return
        if (!surface.isValid) return
        val ctx = context ?: return
        if (session.cameraSource != null) return

        val camSource = AndroidGreenScreenCamera2Source(ctx)
        session.cameraSource = camSource

        camSource.start(
            targetSurface = surface,
            onCameraFrameTransform = { rotationDegrees, mirrorHorizontal ->
                session.renderLoop?.setCameraFrameTransform(rotationDegrees, mirrorHorizontal)
            },
            onMask = { frame -> session.renderLoop?.updateGreenScreenMask(frame) },
            onStarted = {
                Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_CAMERA_STARTED session=${session.sessionId} " +
                    "source=camera2_clean_segmentation backend=${AndroidGreenScreenSegmentationBackend.MEDIAPIPE_CPU}")
            },
            onError = { e ->
                Log.w(TAG, "Camera source failed for live session ${session.sessionId}: ${e.message}")
                camSource.stop()
                if (activeSession === session && session.cameraSource === camSource) {
                    session.cameraSource = null
                    emit(session, EVENT_ERROR, AndroidGreenScreenSegmentationBackend.MEDIAPIPE_CPU, AndroidGreenScreenSegmentationBackend.NONE,
                        "camera_start_failed",
                        "The camera could not be started: ${e.message ?: e.javaClass.simpleName}")
                }
            },
        )
    }

    /**
     * Coarse backend label for `suspended`/`resumed`/`error` events: the
     * independent Camera2 source's internal ladder (mediapipe_cpu -> mlkit ->
     * none) is not observable from here, so this reports `mediapipe_cpu`
     * while the camera source is running and `none` once it is gone.
     */
    private fun reportedBackend(session: LiveSession): String =
        if (session.cameraSource != null) AndroidGreenScreenSegmentationBackend.MEDIAPIPE_CPU else AndroidGreenScreenSegmentationBackend.NONE

    // ── Release ───────────────────────────────────────────────────────────────

    private fun releaseSession(session: LiveSession, why: String) {
        val producer = session.producer
        val renderLoop = session.renderLoop
        val camSource = session.cameraSource
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
