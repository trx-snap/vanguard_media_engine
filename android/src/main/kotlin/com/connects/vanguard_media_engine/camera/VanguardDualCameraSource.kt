package com.connects.vanguard_media_engine.camera

// ── VanguardDualCameraSource ──────────────────────────────────────────────────
//
// CameraX ConcurrentCamera-based dual-camera preview source.
//
// Opens a front-facing and a back-facing camera simultaneously using CameraX's
// ConcurrentCamera API and routes each stream to its own Flutter SurfaceTexture.
//
// Pipeline:
//   CameraX ConcurrentCamera (Camera2 backend)
//   → Front Preview use-case → frontTextureEntry (Flutter Texture widget)
//   → Back  Preview use-case → backTextureEntry  (Flutter Texture widget)
//
// Key design decisions (parallel to VanguardCameraSource for single camera):
//
//   1. NO PreviewView, NO SurfaceView — frames route directly into Flutter
//      SurfaceTexture, identical to the single-camera path.
//
//   2. Two independent fake LifecycleOwners — CameraX ConcurrentCamera
//      bindToLifecycle(List<SingleCameraConfig>) requires a separate
//      LifecycleOwner per SingleCameraConfig. Each is driven CREATED →
//      STARTED → RESUMED on start(), DESTROYED on stop().
//
//   3. Camera2Interop session capture callbacks — set cameraReadyFlag per
//      camera on the first completed capture, mirroring VanguardCameraSource's
//      cameraReadyFlag approach.
//
//   4. This class does NOT own recording, photo capture, or ImageCapture.
//      Preview-only in this slice.
//
//   5. This class does NOT release SurfaceTextureEntry. Callers own the
//      texture lifecycle; they must call release() on each entry after stop().
//
//   6. Mutual exclusion: callers must ensure no single-camera VanguardCameraSource
//      is active before calling start(). The coordinator enforces this guard.

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.util.Log
import android.view.Surface
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.ConcurrentCamera
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executor

/**
 * CameraX ConcurrentCamera dual-camera preview source.
 *
 * Delivers live preview frames from the front and back cameras simultaneously,
 * each into its own Flutter [TextureRegistry.SurfaceTextureEntry].
 *
 * Lifecycle:
 *   1. Construct with two pre-allocated texture entries.
 *   2. Call [start] — async; [onStarted] fires when both cameras are live.
 *   3. Call [stop] to tear down all camera resources.
 *   4. After [stop] returns, release both texture entries (caller's responsibility).
 *
 * @param context           Application context.
 * @param frontTextureEntry Flutter texture entry that will receive front camera frames.
 * @param backTextureEntry  Flutter texture entry that will receive back camera frames.
 */
class VanguardDualCameraSource(
    private val context: Context,
    private val frontTextureEntry: TextureRegistry.SurfaceTextureEntry,
    private val backTextureEntry: TextureRegistry.SurfaceTextureEntry,
) : IVanguardDualCameraSource {

    companion object {
        private const val TAG = "VanguardDualCameraSource"
    }

    // ── Per-camera fake lifecycle owners ──────────────────────────────────────
    // CameraX ConcurrentCamera requires a distinct LifecycleOwner per
    // SingleCameraConfig. We manage two independently.

    private val frontLifecycleOwner: LifecycleOwner = object : LifecycleOwner {
        override val lifecycle: Lifecycle get() = frontLifecycleRegistry
    }
    private val frontLifecycleRegistry = LifecycleRegistry(frontLifecycleOwner)

    private val backLifecycleOwner: LifecycleOwner = object : LifecycleOwner {
        override val lifecycle: Lifecycle get() = backLifecycleRegistry
    }
    private val backLifecycleRegistry = LifecycleRegistry(backLifecycleOwner)

    // ── CameraX objects ───────────────────────────────────────────────────────
    private var cameraProvider: ProcessCameraProvider? = null
    private var frontPreview: Preview? = null
    private var backPreview: Preview? = null

    // ── State ─────────────────────────────────────────────────────────────────
    private var isRunning = false

    // Fires off the Camera2 capture thread — volatile for main-thread reads.
    @Volatile private var frontCameraReadyFlag = false
    @Volatile private var backCameraReadyFlag  = false

    // Set by stop() even before isRunning=true, to abort an in-flight
    // ProcessCameraProvider.getInstance() async gap.
    @Volatile private var stopRequested = false

    // ── Main-thread executor ──────────────────────────────────────────────────
    private val mainExecutor: Executor = ContextCompat.getMainExecutor(context)

    // ─────────────────────────────────────────────────────────────────────────
    // start()
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Opens both cameras concurrently and begins delivering preview frames.
     *
     * Async: CameraX resolves [ProcessCameraProvider] internally.
     * [onStarted] fires on the main thread when both cameras are bound.
     * [onStarted] receives a map with:
     *   - "textureId"    → Long: front camera Flutter texture ID (primary display)
     *   - "backTextureId"→ Long: back camera Flutter texture ID
     *   - "outputWidth"  → Int: 0 (compositor not yet wired; width is negotiated per-frame)
     *   - "outputHeight" → Int: 0
     *
     * [onError] fires on the main thread if binding fails. After [onError],
     * the caller must still release the texture entries.
     *
     * Idempotent: if already running, logs a warning and returns.
     */
    override fun start(
        onStarted: (Map<String, Any>) -> Unit,
        onError: (Exception) -> Unit,
    ) {
        if (isRunning) {
            Log.w(TAG, "start() called on already-running dual camera — ignored")
            return
        }

        Log.d(TAG, "start() — requesting ProcessCameraProvider for concurrent cameras")

        // Reset all flags for this fresh start attempt.
        stopRequested       = false
        frontCameraReadyFlag = false
        backCameraReadyFlag  = false

        // Advance both fake lifecycles to RESUMED so CameraX considers them active.
        advanceLifecycleTo(frontLifecycleRegistry, Lifecycle.Event.ON_RESUME)
        advanceLifecycleTo(backLifecycleRegistry,  Lifecycle.Event.ON_RESUME)

        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            try {
                val provider = providerFuture.get()

                // Abort if stop() was called during the async provider resolution.
                // Mirrors VanguardCameraSource.kt:265-268.
                if (stopRequested) {
                    Log.w(TAG, "start() listener: stop was requested during async gap — aborting concurrent bind")
                    provider.unbindAll()
                    destroyLifecycles()
                    return@addListener
                }

                cameraProvider = provider
                bindConcurrentUseCases(provider, onStarted, onError)

            } catch (e: Exception) {
                Log.e(TAG, "start() — ProcessCameraProvider failed: ${e.javaClass.simpleName}: ${e.message}")
                destroyLifecycles()
                onError(e)
            }
        }, mainExecutor)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // bindConcurrentUseCases()
    // ─────────────────────────────────────────────────────────────────────────

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bindConcurrentUseCases(
        provider: ProcessCameraProvider,
        onStarted: (Map<String, Any>) -> Unit,
        onError: (Exception) -> Unit,
    ) {
        // Tear down any previously bound use-cases.
        provider.unbindAll()

        // ── Shared resolution selector ─────────────────────────────────────
        // 16:9 fallback auto strategy — matches VanguardCameraSource.kt:325-327.
        val resolutionSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .build()

        // ── Front camera Preview use-case ──────────────────────────────────
        val frontPreviewBuilder = Preview.Builder()
            .setResolutionSelector(resolutionSelector)

        Camera2Interop.Extender<Preview>(frontPreviewBuilder)
            .setSessionCaptureCallback(object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    // Signal readiness once the first real frame arrives from the sensor.
                    // Fires off the main thread — volatile write is safe.
                    frontCameraReadyFlag = true
                }
            })

        val frontPreviewUseCase = frontPreviewBuilder.build().also { frontPreview = it }
        frontPreviewUseCase.setSurfaceProvider { request ->
            provideSurface(request, frontTextureEntry, "front")
        }

        // ── Back camera Preview use-case ───────────────────────────────────
        val backPreviewBuilder = Preview.Builder()
            .setResolutionSelector(resolutionSelector)

        Camera2Interop.Extender<Preview>(backPreviewBuilder)
            .setSessionCaptureCallback(object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    backCameraReadyFlag = true
                }
            })

        val backPreviewUseCase = backPreviewBuilder.build().also { backPreview = it }
        backPreviewUseCase.setSurfaceProvider { request ->
            provideSurface(request, backTextureEntry, "back")
        }

        // ── Build SingleCameraConfigs ──────────────────────────────────────
        val frontConfig = ConcurrentCamera.SingleCameraConfig(
            CameraSelector.DEFAULT_FRONT_CAMERA,
            UseCaseGroup.Builder()
                .addUseCase(frontPreviewUseCase)
                .build(),
            frontLifecycleOwner,
        )
        val backConfig = ConcurrentCamera.SingleCameraConfig(
            CameraSelector.DEFAULT_BACK_CAMERA,
            UseCaseGroup.Builder()
                .addUseCase(backPreviewUseCase)
                .build(),
            backLifecycleOwner,
        )

        // ── Bind concurrent cameras ────────────────────────────────────────
        try {
            provider.bindToLifecycle(listOf(frontConfig, backConfig))
        } catch (e: IllegalArgumentException) {
            // Thrown when the device does not support the requested concurrent
            // combination (CameraX validates this at bind time).
            Log.e(TAG, "bindConcurrentUseCases: concurrent binding rejected: ${e.message}")
            destroyLifecycles()
            onError(IllegalStateException("CONCURRENT_NOT_SUPPORTED: ${e.message}", e))
            return
        } catch (e: Exception) {
            Log.e(TAG, "bindConcurrentUseCases: binding failed: ${e.javaClass.simpleName}: ${e.message}")
            destroyLifecycles()
            onError(e)
            return
        }

        isRunning = true

        Log.d(
            TAG,
            "bindConcurrentUseCases: both cameras bound — " +
                "frontTextureId=${frontTextureEntry.id()} backTextureId=${backTextureEntry.id()}",
        )

        // Deliver the result map. textureId is the front camera (primary display
        // texture for VGMultiCamPreview). outputWidth/Height are 0 until a
        // compositor is wired (Phase 2). Dart VGMultiCamRenderTextureSession
        // handles outputWidth=0 gracefully (defaults to 9:16 aspect ratio).
        onStarted(
            mapOf(
                "textureId"     to frontTextureEntry.id(),
                "backTextureId" to backTextureEntry.id(),
                "outputWidth"   to 0,
                "outputHeight"  to 0,
            )
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // provideSurface()
    // ─────────────────────────────────────────────────────────────────────────

    // Bridges a CameraX Preview surface request → Flutter SurfaceTexture.
    // Mirrors VanguardCameraSource.kt:430-455 exactly.
    private fun provideSurface(
        request: SurfaceRequest,
        textureEntry: TextureRegistry.SurfaceTextureEntry,
        tag: String,
    ) {
        val surfaceTexture: SurfaceTexture = textureEntry.surfaceTexture()
        val size = request.resolution
        surfaceTexture.setDefaultBufferSize(size.width, size.height)

        val surface = Surface(surfaceTexture)
        request.provideSurface(surface, mainExecutor) { result ->
            // CameraX released the surface — we own it, so release it.
            // DO NOT release the SurfaceTexture itself; the caller-owned
            // SurfaceTextureEntry manages its lifetime.
            Log.d(TAG, "provideSurface[$tag]: CameraX released surface (result=${result.resultCode})")
            surface.release()
        }

        Log.d(TAG, "provideSurface[$tag]: ${size.width}×${size.height} → textureId=${textureEntry.id()}")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // stop()
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Stops both camera streams and releases CameraX use-cases.
     *
     * Safe to call multiple times (idempotent). Always sets [stopRequested]
     * so an in-flight async [start] will abort cleanly.
     *
     * Does NOT release the [TextureRegistry.SurfaceTextureEntry] instances —
     * the caller owns their lifecycle and must call release() after stop().
     */
    override fun stop() {
        // Always set stopRequested — aborts any in-flight start() async gap.
        stopRequested = true

        if (!isRunning) {
            Log.d(TAG, "stop() called on already-stopped dual camera — state cleared")
            destroyLifecycles()
            return
        }

        Log.d(TAG, "stop() — unbinding all CameraX use-cases")

        // Move both fake lifecycles to DESTROYED. CameraX interprets this as
        // the Activity finishing and cleans up all hardware resources.
        // Mirrors VanguardCameraSource.kt:490-492.
        destroyLifecycles()

        cameraProvider?.unbindAll()

        cameraProvider  = null
        frontPreview    = null
        backPreview     = null
        isRunning       = false
        frontCameraReadyFlag = false
        backCameraReadyFlag  = false

        Log.d(TAG, "stop() — complete")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lifecycle helpers
    // ─────────────────────────────────────────────────────────────────────────

    private fun advanceLifecycleTo(registry: LifecycleRegistry, targetEvent: Lifecycle.Event) {
        // Walk the lifecycle from INITIALIZED up to the target state safely.
        // LifecycleRegistry requires events to arrive in order.
        val currentState = registry.currentState
        if (currentState == Lifecycle.State.INITIALIZED || currentState == Lifecycle.State.CREATED) {
            registry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        }
        if (targetEvent == Lifecycle.Event.ON_START || targetEvent == Lifecycle.Event.ON_RESUME) {
            if (registry.currentState.isAtLeast(Lifecycle.State.CREATED)) {
                registry.handleLifecycleEvent(Lifecycle.Event.ON_START)
            }
        }
        if (targetEvent == Lifecycle.Event.ON_RESUME) {
            if (registry.currentState.isAtLeast(Lifecycle.State.STARTED)) {
                registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
            }
        }
    }

    private fun destroyLifecycles() {
        // Guard: only send destroy events if the lifecycle is not already destroyed.
        destroyLifecycle(frontLifecycleRegistry)
        destroyLifecycle(backLifecycleRegistry)
    }

    private fun destroyLifecycle(registry: LifecycleRegistry) {
        if (registry.currentState == Lifecycle.State.DESTROYED) return
        try {
            if (registry.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
                registry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
            }
            if (registry.currentState.isAtLeast(Lifecycle.State.STARTED)) {
                registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
            }
            if (registry.currentState.isAtLeast(Lifecycle.State.CREATED)) {
                registry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "destroyLifecycle: failed to advance lifecycle: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Accessors
    // ─────────────────────────────────────────────────────────────────────────

    /** True when both cameras are bound and streaming frames. */
    override val running: Boolean get() = isRunning

    /** True once the front camera has delivered at least one completed capture. */
    val isFrontCameraReady: Boolean get() = frontCameraReadyFlag

    /** True once the back camera has delivered at least one completed capture. */
    val isBackCameraReady: Boolean get() = backCameraReadyFlag

    /** Flutter texture ID for the front camera stream. */
    override val frontTextureId: Long get() = frontTextureEntry.id()

    /** Flutter texture ID for the back camera stream. */
    override val backTextureId: Long get() = backTextureEntry.id()
}
