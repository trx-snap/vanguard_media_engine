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
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.util.concurrent.Executor
import java.util.concurrent.Executors

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

    // ── ImageAnalysis state (green-screen slice) ───────────────────────────────

    /** Dedicated single-thread executor for the ImageAnalysis use-case. */
    private var analyzerExecutor: java.util.concurrent.ExecutorService? = null

    /** Currently bound ImageAnalysis use-case, null when not in use. */
    private var imageAnalysis: ImageAnalysis? = null

    /**
     * The compositor-owned Surface supplied to [start]; stored so [setAnalysisAnalyzer]
     * can rebind use-cases without the caller needing to re-supply it.
     * Never released by this class.
     */
    private var heldSurface: Surface? = null


    /**
     * Hot-rebinds the analysis use-case (or removes it) without stopping CameraX.
     *
     * When [analyzer] is non-null: tears down any existing analysis use-case/executor,
     * creates a fresh one and binds Preview + ImageAnalysis to the same lifecycle.
     * When [analyzer] is null: unbinds the analysis use-case only and shuts down
     * the prior executor; Preview continues undisturbed.
     *
     * Returns true on successful bind, false if camera is not running, provider/
     * surface are null, or [bindPreview] throws. Safe to call on the main thread.
     */
    fun setAnalysisAnalyzer(analyzer: ImageAnalysis.Analyzer?): Boolean {
        if (!_isRunning) {
            Log.d(TAG, "setAnalysisAnalyzer(): camera not running — ignored")
            return false
        }
        val provider = cameraProvider ?: return false
        val surface = heldSurface ?: return false

        // Tear down previous analysis use-case and executor.
        try { imageAnalysis?.clearAnalyzer() } catch (_: Throwable) {}
        imageAnalysis = null
        try { analyzerExecutor?.shutdownNow() } catch (_: Throwable) {}
        analyzerExecutor = null

        Log.d(TAG, "setAnalysisAnalyzer(): rebinding use-cases (analyzer=${analyzer != null})")
        var bindOk = false
        bindPreview(
            provider      = provider,
            targetSurface = surface,
            onStarted     = {},  // already running; no callback needed
            onError       = { e ->
                Log.w(TAG, "setAnalysisAnalyzer rebind error: ${e.message}")
            },
            analyzer      = analyzer,
            onBindResult  = { ok -> bindOk = ok },
        )
        return bindOk
    }

    /**
     * Requests the front camera, binds a Preview use-case (and optionally an
     * ImageAnalysis use-case) and directs frames into [targetSurface].
     *
     * [targetSurface] is compositor-owned: this class never releases it.
     * [analyzer] is optional. When non-null, an ImageAnalysis use-case is bound
     *   alongside Preview using STRATEGY_KEEP_ONLY_LATEST and a capped resolution
     *   of 256 px on the shortest side. Preview never waits for analysis.
     * [onStarted] fires on the main thread when CameraX accepts the surface.
     * [onError] fires on the main thread on any failure (including missing
     *   CAMERA permission, in which case a SecurityException is passed).
     *
     * Idempotent: if already running, logs and returns immediately.
     */
    fun start(
        targetSurface: Surface,
        onStarted: () -> Unit = {},
        onError: (Exception) -> Unit = {},
        analyzer: ImageAnalysis.Analyzer? = null,
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
                bindPreview(provider, targetSurface, onStarted, onError, analyzer)
            } catch (e: Exception) {
                Log.e(TAG, "start(): ProcessCameraProvider failed: $e")
                onError(e)
            }
        }, mainExecutor)
    }


    /**
     * Stops the camera session. Idempotent. The compositor-owned [targetSurface]
     * passed to [start] is NOT released here; the compositor owns it.
     *
     * Stop ordering (green-screen slice):
     *   1. stopRequested = true
     *   2. clear analyzer reference (analyzer.clearAnalyzer() / null)
     *   3. shut down analyzerExecutor (shutdownNow)
     *   4. lifecycle pause/stop/destroy
     *   5. provider.unbindAll()
     *   6. null all state
     */
    fun stop() {
        stopRequested = true

        // Step 2: clear the analyzer reference so no new frames are dispatched
        // while CameraX is draining its last frame.
        try { imageAnalysis?.clearAnalyzer() } catch (_: Throwable) {}
        imageAnalysis = null

        // Step 3: shut down the analysis executor immediately.
        try { analyzerExecutor?.shutdownNow() } catch (_: Throwable) {}
        analyzerExecutor = null

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

        // Step 4: lifecycle teardown.
        try {
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        } catch (_: Throwable) {}

        // Step 5: unbind all CameraX use-cases.
        cameraProvider?.unbindAll()

        // Step 6: null all state.
        cameraProvider = null
        preview = null
        heldSurface = null
        _isRunning = false
    }


    // ── Private: bind Preview use-case ────────────────────────────────────────

    private fun bindPreview(
        provider: ProcessCameraProvider,
        targetSurface: Surface,
        onStarted: () -> Unit,
        onError: (Exception) -> Unit,
        analyzer: ImageAnalysis.Analyzer? = null,
        /** Called synchronously with true after successful bindToLifecycle, false on catch. */
        onBindResult: (Boolean) -> Unit = {},
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
                    request.willNotProvideSurface()
                    return@setSurfaceProvider
                }
                request.provideSurface(targetSurface, mainExecutor) { result ->
                    Log.d(TAG, "CameraX released compositor surface (resultCode=${result.resultCode})")
                }
                Log.d(TAG, "provideSurface → compositor cameraInputSurface " +
                    "(${request.resolution.width}×${request.resolution.height})")
                if (!stopRequested) {
                    _isRunning = true
                    heldSurface = targetSurface
                    onStarted()
                }
            }

            val useCases = if (analyzer != null) {
                val analysisResolutionSelector = ResolutionSelector.Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            Size(256, 256),
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                        )
                    )
                    .build()
                val analysisUseCase = ImageAnalysis.Builder()
                    .setResolutionSelector(analysisResolutionSelector)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                    .build()
                    .also { imageAnalysis = it }
                val executor = Executors.newSingleThreadExecutor { r ->
                    Thread(r, "vg.duet.analysis").apply { isDaemon = true }
                }
                analyzerExecutor = executor
                analysisUseCase.setAnalyzer(executor, analyzer)
                Log.d(TAG, "bindPreview() — ImageAnalysis use-case bound (256px cap, KEEP_ONLY_LATEST)")
                arrayOf(previewUseCase, analysisUseCase)
            } else {
                arrayOf(previewUseCase)
            }

            provider.bindToLifecycle(lifecycleOwner, selector, *useCases)
            Log.d(TAG, "bindPreview() — front camera Preview use-case bound")
            onBindResult(true)
        } catch (e: Exception) {
            Log.e(TAG, "bindPreview() threw: $e")
            onBindResult(false)
            onError(e)
        }
    }
}
