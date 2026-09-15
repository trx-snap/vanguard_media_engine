package com.connects.vanguard_media_engine.greenscreen

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import androidx.camera.core.ImageAnalysis
import androidx.core.content.ContextCompat
import com.connects.vanguard_media_engine.camera.AndroidCameraSessionAdmission
import com.connects.vanguard_media_engine.duet.AndroidDuetCameraSource
import com.connects.vanguard_media_engine.duet.AndroidDuetGreenScreenAdapter
import com.connects.vanguard_media_engine.duet.AndroidDuetGreenScreenBackground
import com.connects.vanguard_media_engine.duet.AndroidDuetLayoutGeometry
import com.connects.vanguard_media_engine.duet.AndroidDuetPreviewRenderLoop
import com.connects.vanguard_media_engine.duet.AndroidDuetPreviewSurfaceProducer
import com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationBackendSelector
import com.connects.vanguard_media_engine.duet.AndroidDuetSegmentationFrame
import com.connects.vanguard_media_engine.duet.DuetSegmentationBackend
import com.connects.vanguard_media_engine.duet.DuetSegmentationMaskFormat
import com.connects.vanguard_media_engine.duet.DuetSurfaceState
import com.connects.vanguard_media_engine.duet.NativeForegroundTransform
import com.connects.vanguard_media_engine.duet.VGDuetLayoutRects
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
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
//   - AndroidDuetPreviewSurfaceProducer  → Flutter texture / output Surface
//   - AndroidDuetPreviewRenderLoop       → render thread + GLES compositor,
//                                          constructed with decoderProvider =
//                                          { null }: no source video exists,
//                                          so no decoder is ever bound and the
//                                          camera-idle redraw pump presents
//                                          every camera frame.
//   - AndroidDuetCameraSource            → CameraX front Preview + optional
//                                          ImageAnalysis.
//   - AndroidDuetGreenScreenAdapter      → segmentation ladder
//                                          (mediapipe_cpu -> mlkit -> none).
//   - AndroidDuetGreenScreenBackground   → static background spec (from the
//                                          very first frame; never VIDEO here).
//   - AndroidDuetLayoutGeometry.greenScreen(canvas, transform) → source rect =
//     full canvas, camera rect = transformed keyed layer.
//
// Fallback semantics (differ from Duet on purpose):
//   - degraded : the adapter moved to a lower rung, keying continues; the rung
//                is latched so a rebuilt adapter never climbs back up; emits
//                `green_screen_degraded`.
//   - fallback : the ladder is exhausted. The analysis use-case is unbound and
//                the adapter stopped, but green-screen compositing stays
//                ENABLED with a constant fully-opaque mask, so the compositor
//                keeps drawing the same static background with the unkeyed
//                live camera on top. No PiP, no layout rewrite, no Duet
//                event; emits `green_screen_fallback` with currentBackend
//                `none`. (Disabling green screen in the compositor would
//                drop the static background entirely, which is why the
//                opaque-mask path is used instead.)
//
// Camera admission: the engine-wide AndroidCameraSessionAdmission lane is
// acquired after validation and before any resource is created, and released
// on every terminal path. A live start while Duet holds the lane fails with
// `live_busy`; Duet's own initialize fails with `session_conflict` while this
// coordinator holds it.
//
// Threading: every public method runs on the main thread (called by
// AndroidLiveGreenScreenMethodHandler). Adapter callbacks hop to the main
// thread before touching session state; the render loop confines compositor
// work to its own render thread; a private decoder-lane HandlerThread exists
// only because the render loop requires one (no decoder op ever does work).
//
// Cleanup order on stop/dispose (matches the render loop's documented
// contract — prepareForCameraStop must precede the CameraX stop so no
// drawFrame races the last OES write):
//   producer.beginRelease -> renderLoop.prepareForCameraStop -> adapter.stop
//   -> camera.stop -> renderLoop.stopBlocking(0) -> producer.finishRelease
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

        private const val FALLBACK_USER_MESSAGE =
            "Green screen is unavailable on this device. Showing the live camera over the background."

        /** Side length of the constant fully-opaque mask uploaded on terminal fallback. */
        private const val OPAQUE_MASK_DIMENSION = 4
    }

    /** Validated start arguments (built by the method handler). */
    class StartRequest(
        val widthPx: Int,
        val heightPx: Int,
        val background: AndroidDuetGreenScreenBackground,
        val foregroundTransform: NativeForegroundTransform?,
    )

    // ── Session ───────────────────────────────────────────────────────────────

    private class LiveSession(
        val sessionId: String,
        val widthPx: Int,
        val heightPx: Int,
        var background: AndroidDuetGreenScreenBackground,
        var foregroundTransform: NativeForegroundTransform?,
        var layoutRects: VGDuetLayoutRects,
    ) {
        var producer: AndroidDuetPreviewSurfaceProducer? = null
        var renderLoop: AndroidDuetPreviewRenderLoop? = null
        var cameraSource: AndroidDuetCameraSource? = null
        var adapter: AndroidDuetGreenScreenAdapter? = null
        /** One-way ladder latch: rung reached after a degrade; a rebuilt adapter starts here. */
        var latchedBackendId: String? = null
        /** Set once the terminal fallback (unkeyed camera over background) has been applied. */
        var fallbackApplied: Boolean = false
        /** True between an output-surface loss and its re-availability. */
        var suspended: Boolean = false
    }

    // ── State ─────────────────────────────────────────────────────────────────

    @Volatile private var activeSession: LiveSession? = null
    private val disposed = AtomicBoolean(false)

    // The render loop requires a decoder-lane Handler even though this
    // coordinator never has a decoder: every decoder op it posts resolves
    // decoderProvider() == null and completes immediately.
    private val decoderThread = HandlerThread("vg.livegs.decoder").also { it.start() }
    private val decoderHandler = Handler(decoderThread.looper)

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
            layoutRects = AndroidDuetLayoutGeometry.greenScreen(
                widthPx.toDouble(), heightPx.toDouble(), request.foregroundTransform,
            ),
        )

        val producer = try {
            AndroidDuetPreviewSurfaceProducer(
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
            AndroidDuetPreviewRenderLoop(
                mainHandler     = mainHandler,
                decoderHandler  = decoderHandler,
                decoderProvider = { null },
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
        if (producer.state == DuetSurfaceState.SURFACE_AVAILABLE) {
            val surface = producer.acquireSurface()
            if (surface != null) {
                renderLoop.attachOutputSurface(
                    surface, widthPx, heightPx,
                    session.layoutRects.source, session.layoutRects.camera,
                    0L,
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
        background: AndroidDuetGreenScreenBackground,
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
        transform: NativeForegroundTransform?,
        reply: (Any?, String?) -> Unit,
    ) {
        val session = resolveSession(sessionId, "updateLiveGreenScreenTransform", reply) ?: return
        session.foregroundTransform = transform
        val rects = AndroidDuetLayoutGeometry.greenScreen(
            session.widthPx.toDouble(), session.heightPx.toDouble(), transform,
        )
        session.layoutRects = rects
        session.renderLoop?.updateLayout(rects.source, rects.camera, 0L)
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
        try { decoderThread.quitSafely() } catch (_: Throwable) {}
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
            0L,
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
     * survives output loss). On CameraX failure the source is stopped and
     * nulled so a later re-attach can retry, and an `error` event is emitted;
     * the session stays alive for the caller to stop.
     */
    private fun startCameraSourceIfNeeded(session: LiveSession, surface: Surface) {
        if (activeSession !== session) return
        if (session.renderLoop == null || session.producer == null) return
        if (!surface.isValid) return
        val ctx = context ?: return
        if (session.cameraSource != null) return

        val camSource = AndroidDuetCameraSource(ctx)
        session.cameraSource = camSource

        // Bind the analyzer as part of the first use-case set. After a terminal
        // fallback no analyzer is ever rebuilt for this session.
        val analyzer: ImageAnalysis.Analyzer? = if (session.fallbackApplied) {
            null
        } else {
            val adapter = buildGreenScreenAdapter(session)
            if (adapter == null) {
                applyFallback(session, reportedBackend(session), "adapter_creation_failed")
            }
            adapter
        }

        camSource.start(
            targetSurface = surface,
            analyzer      = analyzer,
            onStarted = {
                Log.i(TAG, "ANDROID_LIVE_GREENSCREEN_CAMERA_STARTED session=${session.sessionId} " +
                    "keyed=${analyzer != null} backend=${reportedBackend(session)}")
            },
            onError = { e ->
                Log.w(TAG, "Camera source failed for live session ${session.sessionId}: ${e.message}")
                camSource.stop()
                if (activeSession === session && session.cameraSource === camSource) {
                    session.cameraSource = null
                    stopGreenScreenAdapter(session)
                    emit(session, EVENT_ERROR, reportedBackend(session), DuetSegmentationBackend.NONE,
                        "camera_start_failed",
                        "The camera could not be started: ${e.message ?: e.javaClass.simpleName}")
                }
            },
        )
    }

    // ── Segmentation adapter ──────────────────────────────────────────────────

    /**
     * Creates, stores and arms the session's [AndroidDuetGreenScreenAdapter]
     * on the production ladder (or the session-latched rung after a prior
     * degrade). Returns null when construction/start throws; the partial
     * adapter is stopped and cleared so the caller can fall back.
     */
    private fun buildGreenScreenAdapter(session: LiveSession): AndroidDuetGreenScreenAdapter? {
        session.adapter?.let { return it }
        val renderLoop = session.renderLoop ?: return null
        return try {
            val selector = AndroidDuetSegmentationBackendSelector(context)
            val initialBackendId = session.latchedBackendId ?: selector.primaryBackendId()
            var adapterRef: AndroidDuetGreenScreenAdapter? = null
            val adapter = AndroidDuetGreenScreenAdapter(
                selector = selector,
                initialBackendId = initialBackendId,
                onMask = { frame -> renderLoop.updateGreenScreenMask(frame) },
                onGpuMask = { hardwareBuffer, widthPx, heightPx, timestampUs ->
                    renderLoop.updateGreenScreenMaskHardwareBuffer(hardwareBuffer, widthPx, heightPx, timestampUs)
                },
                onDegraded = { prev, next, reason, userMessage ->
                    Log.w(TAG, "[LiveGreenScreen degraded] $prev->$next ($reason): $userMessage")
                    mainHandler.post {
                        handleGreenScreenDegraded(session, adapterRef, prev, next, reason, userMessage)
                    }
                },
                onFallback = { prev, next, reason, userMessage ->
                    Log.w(TAG, "[LiveGreenScreen fallback] $prev->$next ($reason): $userMessage")
                    mainHandler.post {
                        handleGreenScreenFallback(session, adapterRef, prev, reason)
                    }
                },
            )
            adapterRef = adapter
            session.adapter = adapter
            adapter.start()
            Log.d(TAG, "Live green-screen adapter started for session ${session.sessionId} " +
                "(initial backend=$initialBackendId, latched=${session.latchedBackendId})")
            adapter
        } catch (t: Throwable) {
            Log.w(TAG, "[LiveGreenScreen fallback] ${reportedBackend(session)}->none " +
                "(adapter_start_failed): ${t.message}")
            try { session.adapter?.stop() } catch (_: Throwable) {}
            session.adapter = null
            null
        }
    }

    /** Stops and clears the adapter (idempotent); its stop() closes every opened backend. */
    private fun stopGreenScreenAdapter(session: LiveSession) {
        val adapter = session.adapter ?: return
        try { adapter.stop() } catch (_: Throwable) {}
        session.adapter = null
    }

    /**
     * Non-terminal degrade: keying continues on [currentBackend]. The rung is
     * latched regardless of adapter staleness; the event is emitted only for
     * the session's live adapter.
     */
    private fun handleGreenScreenDegraded(
        session: LiveSession,
        adapter: AndroidDuetGreenScreenAdapter?,
        previousBackend: String,
        currentBackend: String,
        reason: String,
        userMessage: String,
    ) {
        if (activeSession !== session) return
        session.latchedBackendId = currentBackend
        if (adapter == null || session.adapter !== adapter) {
            Log.d(TAG, "Live green-screen degrade from a stale adapter latched ($currentBackend) without event")
            return
        }
        Log.w(TAG, "Live green screen degraded $previousBackend -> $currentBackend ($reason); " +
            "staying keyed on $currentBackend")
        emit(session, EVENT_DEGRADED, previousBackend, currentBackend, reason, userMessage)
    }

    /**
     * Terminal ladder exhaustion for the session's live adapter. Never touches
     * Duet's PiP path: see [applyFallback].
     */
    private fun handleGreenScreenFallback(
        session: LiveSession,
        adapter: AndroidDuetGreenScreenAdapter?,
        previousBackend: String,
        reason: String,
    ) {
        if (activeSession !== session) return
        if (adapter == null || session.adapter !== adapter) {
            Log.d(TAG, "Live green-screen fallback from a stale adapter ignored")
            return
        }
        applyFallback(session, previousBackend, reason)
    }

    /**
     * Unkeyed live camera over the SAME static background, applied once:
     *   1. unbind the analysis use-case so no new frames reach the adapter,
     *   2. stop/clear the adapter (closes every backend),
     *   3. keep green-screen compositing enabled and upload a constant
     *      fully-opaque mask, so the compositor still draws the static
     *      background and now draws the whole camera rect opaque,
     *   4. emit `green_screen_fallback` with currentBackend `none`.
     * The layout rects are untouched (no PiP); the camera keeps running.
     */
    private fun applyFallback(session: LiveSession, previousBackend: String, reason: String) {
        if (session.fallbackApplied) return
        session.fallbackApplied = true
        session.cameraSource?.setAnalysisAnalyzer(null)
        stopGreenScreenAdapter(session)
        session.renderLoop?.updateGreenScreenMask(opaqueMaskFrame())
        Log.w(TAG, "ANDROID_LIVE_GREENSCREEN_FALLBACK session=${session.sessionId} " +
            "previous=$previousBackend reason=$reason -> unkeyed camera over static background")
        emit(session, EVENT_FALLBACK, previousBackend, DuetSegmentationBackend.NONE, reason,
            FALLBACK_USER_MESSAGE)
    }

    /**
     * Constant 255 (fully foreground) uint8 mask. Through the compositor's
     * erosion + smoothstep this yields alpha 1.0 everywhere, i.e. the camera
     * is drawn unkeyed inside its rect while the background draw is unchanged.
     */
    private fun opaqueMaskFrame(): AndroidDuetSegmentationFrame {
        val n = OPAQUE_MASK_DIMENSION
        val bytes = ByteBuffer.allocateDirect(n * n)
        for (i in 0 until n * n) bytes.put(0xFF.toByte())
        bytes.rewind()
        return AndroidDuetSegmentationFrame.adoptOwned(
            ownedBytes = bytes,
            width = n,
            height = n,
            timestampMs = SystemClock.elapsedRealtime(),
            backend = DuetSegmentationBackend.NONE,
            format = DuetSegmentationMaskFormat.UINT8_ALPHA,
        )
    }

    /** Backend to report: live adapter rung, else the latch, else `none` after fallback, else the primary. */
    private fun reportedBackend(session: LiveSession): String =
        session.adapter?.currentBackendId
            ?: session.latchedBackendId
            ?: if (session.fallbackApplied) DuetSegmentationBackend.NONE
            else AndroidDuetSegmentationBackendSelector(context).primaryBackendId()

    // ── Release ───────────────────────────────────────────────────────────────

    private fun releaseSession(session: LiveSession, why: String) {
        val producer = session.producer
        val renderLoop = session.renderLoop
        val camSource = session.cameraSource
        // Phase 1: stop new producer submissions (no hook fires).
        producer?.beginRelease()
        // Phase 2: halt render-thread pumps and block swap acceptance BEFORE
        // CameraX is stopped, so no drawFrame races the last OES write.
        renderLoop?.prepareForCameraStop()
        // Phase 3: stop segmentation so nothing dispatches into the dying loop.
        stopGreenScreenAdapter(session)
        // Phase 4: stop CameraX (also clears its analyzer/executor).
        camSource?.stop()
        // Phase 5: release the compositor (releases cameraInputSurface).
        renderLoop?.stopBlocking(0L)
        // Phase 6: drop the Flutter SurfaceProducer.
        producer?.finishRelease()
        session.cameraSource = null
        session.producer = null
        session.renderLoop = null
        // Phase 7: free the engine-wide camera lane.
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
