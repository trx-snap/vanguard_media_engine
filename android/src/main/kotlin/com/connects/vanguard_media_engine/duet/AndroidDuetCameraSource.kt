package com.connects.vanguard_media_engine.duet

// -----------------------------------------------------------------------------
// VG-DUET-LIVE-CAMERA: Front-camera live preview ingest for the Duet GLES
// compositor (Android).
// -----------------------------------------------------------------------------
//
// Responsibilities — strictly bounded:
//   - Owns one CameraX ProcessCameraProvider / fake LifecycleOwner / Preview
//     use-case. Nothing else (no ImageCapture, no VideoCapture, no Recorder,
//     no audio, no TextureRegistry, no thermal policy, no export, no app UI).
//   - start(targetSurface, onStarted, onError): wires a caller-owned Surface
//     (the compositor's cameraInputSurface) as the CameraX SurfaceProvider.
//     Compositor owns and releases the Surface; this class never releases it.
//   - stop(): idempotent. Sets stopRequested, drives lifecycle to DESTROYED,
//     unbinds the provider, clears state. If the provider resolves after stop,
//     the listener detects stopRequested and aborts.
//   - Permission check: uses ContextCompat.checkSelfPermission. If CAMERA is
//     not granted, calls onError(SecurityException) without throwing.
//
// Threading: start/stop called on main thread. CameraX internally dispatches
// on its own pool; all callbacks arrive on mainExecutor (main thread).
// The SurfaceProvider callback fires on the CameraX executor; it calls
// request.provideSurface() which is safe from any thread.

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import android.util.Range
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.util.concurrent.Executor

class AndroidDuetCameraSource(private val context: Context) {

    companion object {
        private const val TAG = "DuetCameraSource"
        private const val TARGET_FRAME_RATE = 30
    }

    // ── Fake LifecycleOwner (same pattern as VanguardCameraSource) ────────────

    private val lifecycleOwner: LifecycleOwner = object : LifecycleOwner {
        override val lifecycle: Lifecycle get() = lifecycleRegistry
    }
    private val lifecycleRegistry = LifecycleRegistry(lifecycleOwner)

    // ── CameraX state ─────────────────────────────────────────────────────────

    private var cameraProvider: ProcessCameraProvider? = null
    private var preview: Preview? = null

    // ── Run state ─────────────────────────────────────────────────────────────

    /** True only between a successful bind and the next stop(). */
    @Volatile private var _isRunning = false
    val isRunning: Boolean get() = _isRunning

    /**
     * Set by stop() before the provider resolves so the async listener can
     * detect the race and abort cleanly without touching a dead surface.
     */
    @Volatile private var stopRequested = false

    // ── Main-thread executor ──────────────────────────────────────────────────

    private val mainExecutor: Executor = ContextCompat.getMainExecutor(context)

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * Requests the front camera, binds a Preview use-case, and directs frames
     * into [targetSurface].
     *
     * [targetSurface] is compositor-owned: this class never releases it.
     * [onStarted] fires on the main thread when CameraX accepts the surface.
     * [onError] fires on the main thread on any failure (including missing
     * CAMERA permission, in which case a SecurityException is passed).
     *
     * Idempotent: if already running, logs and returns immediately.
     */
    fun start(
        targetSurface: Surface,
        onStarted: () -> Unit = {},
        onError: (Exception) -> Unit = {},
    ) {
        if (_isRunning) {
            Log.w(TAG, "start() called while already running — ignored")
            return
        }

        // Permission check: never throw, always delegate to onError on deny.
        val permResult = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
        if (permResult != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "start(): CAMERA permission not granted")
            onError(SecurityException("CAMERA permission not granted for Duet camera source"))
            return
        }

        stopRequested = false

        // Advance fake lifecycle so CameraX sees RESUMED.
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)

        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            try {
                val provider = providerFuture.get()

                if (stopRequested) {
                    Log.w(TAG, "start(): stop requested during async gap — aborting bind")
                    provider.unbindAll()
                    return@addListener
                }

                cameraProvider = provider
                bindPreview(provider, targetSurface, onStarted, onError)
            } catch (e: Exception) {
                Log.e(TAG, "start(): ProcessCameraProvider failed: $e")
                onError(e)
            }
        }, mainExecutor)
    }

    /**
     * Stops the camera session. Idempotent. The compositor-owned [targetSurface]
     * passed to [start] is NOT released here; the compositor owns it.
     */
    fun stop() {
        stopRequested = true

        if (!_isRunning) {
            // Drive lifecycle to DESTROYED anyway in case stop() races the async
            // provider listener.
            try {
                lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
                lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
                lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
            } catch (_: Throwable) {}
            Log.d(TAG, "stop() — camera not running, lifecycle driven to DESTROYED")
            return
        }

        Log.d(TAG, "stop() — unbinding all CameraX use-cases")

        try {
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        } catch (_: Throwable) {}

        cameraProvider?.unbindAll()

        cameraProvider = null
        preview = null
        _isRunning = false
    }

    // ── Private: bind Preview use-case ────────────────────────────────────────

    private fun bindPreview(
        provider: ProcessCameraProvider,
        targetSurface: Surface,
        onStarted: () -> Unit,
        onError: (Exception) -> Unit,
    ) {
        try {
            provider.unbindAll()

            // Front camera only — never MultiCam, never back camera.
            val selector = CameraSelector.Builder()
                .requireLensFacing(CameraSelector.LENS_FACING_FRONT)
                .build()

            // 16:9 resolution family — matches the compositor viewport aspect.
            val resolutionSelector = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                .build()

            val previewUseCase = Preview.Builder()
                .setResolutionSelector(resolutionSelector)
                .setTargetFrameRate(Range(TARGET_FRAME_RATE, TARGET_FRAME_RATE))
                .build()
                .also { preview = it }

            previewUseCase.setSurfaceProvider { request: SurfaceRequest ->
                if (stopRequested) {
                    // We are tearing down; decline the surface request cleanly.
                    request.willNotProvideSurface()
                    return@setSurfaceProvider
                }

                // Point CameraX at the compositor-owned Surface.
                // The compositor's cameraInputSurface (backed by cameraTexture's
                // SurfaceTexture) will receive camera frames via this binding.
                // The release callback is informational only; DO NOT release
                // targetSurface here — the compositor owns and releases it in
                // its terminal release().
                request.provideSurface(targetSurface, mainExecutor) { result ->
                    Log.d(TAG, "CameraX released compositor surface (resultCode=${result.resultCode})")
                }

                Log.d(TAG, "provideSurface → compositor cameraInputSurface " +
                    "(${request.resolution.width}×${request.resolution.height})")

                if (!stopRequested) {
                    _isRunning = true
                    onStarted()
                }
            }

            provider.bindToLifecycle(lifecycleOwner, selector, previewUseCase)

            Log.d(TAG, "bindPreview() — front camera Preview use-case bound")
        } catch (e: Exception) {
            Log.e(TAG, "bindPreview() threw: $e")
            onError(e)
        }
    }
}
