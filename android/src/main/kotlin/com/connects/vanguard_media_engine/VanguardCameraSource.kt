package com.connects.vanguard_media_engine

// ── VanguardCameraSource (Phase B2 — Android Camera Foundation) ───────────────
//
// Android equivalent of iOS VanguardCameraMediaSource.
//
// Pipeline:
//   CameraX (Camera2 backend)
//   → Preview use-case frames
//   → custom SurfaceProvider
//   → Flutter TextureRegistry.SurfaceTextureEntry
//   → Flutter Texture widget (textureId)
//
// Key design decisions:
//
//   1. NO PreviewView, NO SurfaceView — frames route directly into the
//      Flutter SurfaceTexture, mirroring the iOS Metal Texture path.
//
//   2. Fake LifecycleOwner — CameraX bindToLifecycle() requires a
//      LifecycleOwner. Since the plugin lives outside an Activity, we manage
//      a LifecycleRegistry manually: CREATED → STARTED → RESUMED on start(),
//      DESTROYED on stop(). CameraX treats this as a mini Activity lifecycle.
//
//   3. SurfaceOrientedMeteringPointFactory — used for focus/metering without
//      a PreviewView. Requires the preview resolution (1080×1920 portrait).
//
//   4. All public methods are called from the MethodChannel handler (main
//      thread). CameraX internally dispatches to its own thread pool —
//      we never create custom threads here.
//
//   5. I-2 invariant: exactly one camera surface is active at a time.
//      isRunning() guard prevents double-start. stop() calls unbindAll()
//      which is idempotent.

import android.content.Context
import android.graphics.SurfaceTexture
import android.net.Uri
import android.util.Log
import android.view.Surface
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.SurfaceRequest
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

/**
 * VanguardCameraSource — CameraX-backed camera session for Android.
 *
 * Created by [VanguardMediaEnginePlugin] on `startCamera`. One instance
 * per active camera session. Destroyed on `stopCamera` or `switchCamera`.
 *
 * @param context Application context. Used for [ProcessCameraProvider] and
 *   [ContextCompat.getMainExecutor].
 * @param textureEntry The Flutter surface texture entry whose [SurfaceTexture]
 *   will receive camera preview frames.
 * @param lensFacing Initial lens — [CameraSelector.LENS_FACING_BACK] or FRONT.
 * @param frameRate Target frame rate for the camera session (default 30).
 */
class VanguardCameraSource(
    private val context: Context,
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private var lensFacing: Int = CameraSelector.LENS_FACING_BACK,
    private val frameRate: Int = 30,
) {

    companion object {
        private const val TAG = "VanguardCameraSource"

        // Portrait 1080p — matches iOS VanguardCameraMediaSource 1080×1920 preset.
        private const val PREVIEW_WIDTH  = 1080
        private const val PREVIEW_HEIGHT = 1920
    }

    // ── Fake lifecycle owner ─────────────────────────────────────────────────
    // CameraX bindToLifecycle() requires a LifecycleOwner. We create a minimal
    // one backed by LifecycleRegistry and drive it ourselves.
    //
    // Fix: LifecycleRegistry constructor cannot reference `lifecycleRegistry`
    // recursively. Split into a named owner so the initializer order is unambiguous.
    private val lifecycleOwner: LifecycleOwner = object : LifecycleOwner {
        override val lifecycle: Lifecycle get() = lifecycleRegistry
    }
    private val lifecycleRegistry = LifecycleRegistry(lifecycleOwner)

    // ── CameraX use-case objects ─────────────────────────────────────────────
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null

    // ── Active recording (null when not recording) ───────────────────────────
    private var activeRecording: Recording? = null

    // ── Pending stopRecording callback ───────────────────────────────────────
    // CameraX delivers VideoRecordEvent.Finalize to the listener registered in
    // startRecording(), not to the caller of stopRecording(). We store the
    // onFinalized callback here so the Finalize handler can invoke it when the
    // MP4 is fully written and closed.
    private var pendingFinalizeCallback: ((filePath: String, droppedFrames: Int, totalFrames: Int) -> Unit)? = null
    private var pendingFinalizeError: ((Exception) -> Unit)? = null
    private var activeRecordingPath: String = ""

    // ── State guard (I-2: exactly one camera session at a time) ──────────────────
    private var isRunning = false

    // ── Async-start cancellation flag ──────────────────────────────────────
    // stop() sets this to true even when isRunning=false (i.e. during the
    // ProcessCameraProvider.getInstance() async gap). The providerFuture
    // listener checks it before calling bindUseCases()/onStarted(), so a
    // stop() that fires while the provider is resolving cleanly aborts the
    // session without touching the already-released SurfaceTexture.
    // Reset to false at the start of each new start() call.
    @Volatile private var stopRequested = false

    // ── Main-thread executor (callbacks from CameraX → plugin) ───────────────
    private val mainExecutor: Executor = ContextCompat.getMainExecutor(context)

    // ─────────────────────────────────────────────────────────────────────────
    // start()
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Opens the camera and begins delivering preview frames to the
     * Flutter [textureEntry].
     *
     * Idempotent: if already running, logs a warning and returns immediately.
     * Does NOT block the calling thread — CameraX internally dispatches
     * [ProcessCameraProvider.getInstance] on its own thread.
     *
     * @param onStarted Called on the main thread when the preview is live and
     *   [textureEntry.id()] is valid for Flutter's `Texture` widget.
     * @param onError Called on the main thread if the camera cannot be opened.
     */
    fun start(
        onStarted: () -> Unit = {},
        onError: (Exception) -> Unit = {},
    ) {
        // I-2 guard: prevent double-start
        if (isRunning) {
            Log.w(TAG, "start() called on already-running camera — ignored")
            return
        }

        Log.d(TAG, "start() — requesting ProcessCameraProvider")

        // Reset cancellation flag for this fresh start attempt.
        stopRequested = false

        // Advance fake lifecycle to RESUMED so CameraX considers the session active.
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)

        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            try {
                val provider = providerFuture.get()

                // Check if stop() was called while the provider was resolving.
                // If so, the plugin has already released the SurfaceTexture —
                // calling bindUseCases()/provideSurface() on a released texture
                // crashes. Abort cleanly without touching any hardware resource.
                if (stopRequested) {
                    Log.w(TAG, "start() listener: stop was requested during async gap — aborting bind")
                    provider.unbindAll()
                    return@addListener
                }

                cameraProvider = provider

                // Build and bind all use-cases in one call.
                bindUseCases(provider)

                isRunning = true
                Log.d(TAG, "start() — camera session live, textureId=${textureEntry.id()}")
                onStarted()
            } catch (e: Exception) {
                Log.e(TAG, "start() — ProcessCameraProvider failed: $e")
                onError(e)
            }
        }, mainExecutor)
    }

    // ── Use-case construction + binding ──────────────────────────────────────

    private fun bindUseCases(provider: ProcessCameraProvider) {
        // Tear down any previously bound use-cases first.
        provider.unbindAll()

        // ── Camera selector ───────────────────────────────────────────────────
        val selector = CameraSelector.Builder()
            .requireLensFacing(lensFacing)
            .build()

        // ── Preview use-case ─────────────────────────────────────────────────
        // Frames route into the Flutter SurfaceTexture via a custom SurfaceProvider.
        // NO PreviewView is involved — this is identical in concept to iOS where
        // AVCaptureVideoDataOutput delivers CVPixelBuffer to VanguardMetalRenderer.
        val previewUseCase = Preview.Builder()
            .build()
            .also { preview = it }

        previewUseCase.setSurfaceProvider { request ->
            provideSurface(request)
        }

        // ── ImageCapture use-case ─────────────────────────────────────────────
        val imageCaptureUseCase = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
            .also { imageCapture = it }

        // ── VideoCapture use-case (Recorder) ──────────────────────────────────
        // QualitySelector prefers 1080p — falls back to highest available if the
        // device doesn't support it (matches iOS AVCaptureSessionPreset1920x1080
        // fallback to 1280x720).
        val recorder = Recorder.Builder()
            .setQualitySelector(
                QualitySelector.from(
                    Quality.FHD,                   // 1080p preferred
                    FallbackStrategy.higherQualityOrLowerThan(Quality.HD)
                )
            )
            .build()
        val videoCaptureUseCase = VideoCapture.withOutput(recorder)
            .also { videoCapture = it }

        // ── Bind to fake LifecycleOwner ───────────────────────────────────────
        // CameraX manages the camera session lifecycle internally.
        // All three use-cases are bound in one call to avoid USB-headset-rotation
        // race conditions that can occur when use-cases are added incrementally.
        camera = provider.bindToLifecycle(
            lifecycleOwner,
            selector,
            previewUseCase,
            imageCaptureUseCase,
            videoCaptureUseCase,
        )

        Log.d(TAG, "bindUseCases() — bound Preview + ImageCapture + VideoCapture")
    }

    // ── SurfaceProvider — bridges CameraX Preview → Flutter SurfaceTexture ───

    private fun provideSurface(request: SurfaceRequest) {
        // Prepare the Flutter SurfaceTexture to receive camera frames at the
        // negotiated resolution. CameraX fills in the exact size after binding;
        // we set 1080×1920 as a hint and let the request size override if needed.
        val surfaceTexture: SurfaceTexture = textureEntry.surfaceTexture()
        val size = request.resolution
        surfaceTexture.setDefaultBufferSize(size.width, size.height)

        val surface = Surface(surfaceTexture)

        // Provide the surface to CameraX. The release callback fires when
        // CameraX no longer needs the surface (e.g. on unbindAll or rotation).
        request.provideSurface(surface, mainExecutor) { result ->
            // Surface is no longer used by CameraX. We own it — release it.
            // DO NOT release the SurfaceTexture itself here: Flutter holds
            // the SurfaceTextureEntry and disposes it on textureEntry.release().
            Log.d(TAG, "provideSurface: CameraX released surface (result=${result.resultCode})")
            surface.release()
        }

        Log.d(TAG, "provideSurface: ${size.width}×${size.height} → Flutter textureId=${textureEntry.id()}")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // stop()
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Stops the camera session and releases CameraX use-cases.
     * Safe to call multiple times (idempotent).
     *
     * If a recording is in progress it is finalized before the session closes.
     * Callers that need the finalized file path should call [stopRecording]
     * first, then [stop]. (The plugin's teardown path follows this pattern.)
     */
    fun stop() {
        // Always set stopRequested — this cancels any in-flight start() that is
        // still waiting for ProcessCameraProvider.getInstance() to complete.
        // Without this, the async listener fires after stop() returns, tries to
        // bind use-cases against an already-released SurfaceTexture, and crashes.
        stopRequested = true

        if (!isRunning) {
            Log.d(TAG, "stop() called on already-stopped camera — state cleared, no-op for CameraX")
            return
        }
        Log.d(TAG, "stop() — unbinding all use-cases")

        // If recording is active, stop it synchronously before unbinding.
        // This matches iOS teardownCameraAsync which calls stopRecording first.
        activeRecording?.stop()
        activeRecording = null

        // Move fake lifecycle to DESTROYED — CameraX interprets this as the
        // "Activity finished" event and cleans up all hardware resources.
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)

        cameraProvider?.unbindAll()

        camera        = null
        preview       = null
        imageCapture  = null
        videoCapture  = null
        cameraProvider = null
        isRunning     = false

        Log.d(TAG, "stop() — complete")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // switchCamera()
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Flips the lens facing and restarts the camera session.
     * Must NOT be called while recording is active — the plugin's `switchCamera`
     * handler guards this with [isRecording].
     *
     * @param onStarted Forwarded to the new [start] call — called when the
     *   new camera session is live.
     */
    fun switchCamera(
        onStarted: () -> Unit = {},
        onError: (Exception) -> Unit = {},
    ) {
        Log.d(TAG, "switchCamera() — flipping lens")
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK)
            CameraSelector.LENS_FACING_FRONT
        else
            CameraSelector.LENS_FACING_BACK

        // Re-bind use-cases with the new selector.
        // We do NOT call stop()/start() because that would destroy and recreate
        // the LifecycleRegistry (causing a brief black frame). Instead we
        // call bindUseCases() directly with the existing provider so the
        // transition is as fast as possible.
        val provider = cameraProvider
        if (provider == null) {
            // No provider: full restart needed.
            start(onStarted, onError)
            return
        }

        try {
            bindUseCases(provider)
            onStarted()
            Log.d(TAG, "switchCamera() — complete; lensNow=${if (lensFacing == CameraSelector.LENS_FACING_FRONT) "FRONT" else "BACK"}")
        } catch (e: Exception) {
            Log.e(TAG, "switchCamera() — bindUseCases failed: $e")
            onError(e)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // takePhoto(outputPath, onResult, onError)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Captures a single JPEG photo and saves it to [outputPath].
     *
     * @param outputPath Absolute path for the JPEG output file.
     *   Parent directories must already exist (the plugin creates them before
     *   calling this method).
     * @param onResult Called on the main thread with the saved file path.
     * @param onError Called on the main thread with the underlying exception.
     */
    fun takePhoto(
        outputPath: String,
        onResult: (String) -> Unit,
        onError: (Exception) -> Unit,
    ) {
        val capture = imageCapture
        if (capture == null) {
            onError(IllegalStateException("ImageCapture use-case not bound — call start() first"))
            return
        }

        val outputFile = File(outputPath)
        val outputOptions = ImageCapture.OutputFileOptions.Builder(outputFile).build()

        capture.takePicture(
            outputOptions,
            mainExecutor,
            object : ImageCapture.OnImageSavedCallback {

                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    val savedUri: Uri? = output.savedUri
                    val path = savedUri?.path ?: outputPath
                    Log.d(TAG, "takePhoto: saved → $path")
                    onResult(path)
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e(TAG, "takePhoto: ImageCaptureException ${exception.imageCaptureError} — ${exception.message}")
                    onError(exception)
                }
            }
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // startRecording / stopRecording
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Returns true if a video recording is currently in progress.
     * Used by the plugin to reject `switchCamera` calls during recording
     * (mirrors iOS cameraSource?.isRecording guard).
     */
    val isRecording: Boolean get() = activeRecording != null

    /**
     * Begins recording video to [outputPath].
     *
     * @param outputPath Absolute path for the MP4 output file.
     * @param onStarted Called when recording has actually begun (first frame encoded).
     * @param onError Called if recording cannot start or if a fatal error occurs
     *   during recording.
     */
    fun startRecording(
        outputPath: String,
        onStarted: () -> Unit = {},
        onError: (Exception) -> Unit = {},
    ) {
        if (isRecording) {
            onError(IllegalStateException("Already recording — call stopRecording() first"))
            return
        }

        val vc = videoCapture
        if (vc == null) {
            onError(IllegalStateException("VideoCapture use-case not bound — call start() first"))
            return
        }

        val outputFile = File(outputPath)
        val outputOptions = FileOutputOptions.Builder(outputFile).build()

        // Prepare the recording. withAudioEnabled() matches iOS AVCaptureAudioDataOutput
        // (audio input is captured and muxed into the MP4 automatically).
        // Permission for RECORD_AUDIO must be granted by the host app before this call.
        val pendingRecording = vc.output
            .prepareRecording(context, outputOptions)
            .withAudioEnabled()

        val recording = pendingRecording.start(mainExecutor) { event ->
            when (event) {
                is VideoRecordEvent.Start -> {
                    Log.d(TAG, "startRecording: recording started → $outputPath")
                    onStarted()
                }
                is VideoRecordEvent.Finalize -> {
                    activeRecording = null
                    val callback = pendingFinalizeCallback
                    val errCb    = pendingFinalizeError
                    pendingFinalizeCallback = null
                    pendingFinalizeError    = null

                    if (event.hasError()) {
                        Log.e(TAG, "Finalize error ${event.error} — ${event.cause?.message}")
                        // Deliver to the stopRecording error callback if registered,
                        // otherwise log only (recording was stopped by system/app-background).
                        errCb?.invoke(
                            RuntimeException("Recording finalized with error ${event.error}: ${event.cause?.message}")
                        )
                    } else {
                        // Resolve output path from the finalize Uri (most reliable source).
                        val uri   = event.outputResults.outputUri
                        val path  = uri.path ?: activeRecordingPath

                        // CameraX does not expose dropped/total frame counts directly.
                        // Report 0/0 to match the contract shape; the plugin layer
                        // sends these to Dart which only uses filePath in practice.
                        Log.d(TAG, "Finalize OK → $path")
                        callback?.invoke(path, 0, 0)
                    }
                }
                is VideoRecordEvent.Status -> { /* per-frame stats — no action */ }
                else -> { /* ignore future subtypes */ }
            }
        }

        activeRecordingPath = outputPath
        activeRecording = recording
        Log.d(TAG, "startRecording: recording pending → $outputPath")
    }

    /**
     * Stops the active recording and calls [onFinalized] with the output file path.
     *
     * @param onFinalized Called on the main thread when the MP4 is fully written
     *   and closed. Passes (filePath, droppedFrames, totalFrames). Mirrors iOS
     *   stopRecording(completion:) contract.
     * @param onError Called if no recording is active or if finalization fails.
     */
    fun stopRecording(
        onFinalized: (filePath: String, droppedFrames: Int, totalFrames: Int) -> Unit,
        onError: (Exception) -> Unit = {},
    ) {
        val rec = activeRecording
        if (rec == null) {
            onError(IllegalStateException("No active recording — call startRecording() first"))
            return
        }

        // Store callbacks so the Finalize event handler (in startRecording's listener)
        // can invoke them when the MP4 is fully written.
        pendingFinalizeCallback = onFinalized
        pendingFinalizeError    = onError

        Log.d(TAG, "stopRecording: signalling stop → $activeRecordingPath")
        rec.stop()
        // VideoRecordEvent.Finalize will fire asynchronously on the mainExecutor
        // and invoke pendingFinalizeCallback with the final file path.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Device controls
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Sets the zoom ratio. [ratio] is a linear multiplier (1.0 = no zoom).
     * CameraX clamps to [Camera.CameraInfo.zoomState] min/max automatically.
     *
     * Mirrors iOS `cameraSource?.setZoom(CGFloat(factor))`.
     */
    fun setZoom(ratio: Float) {
        val cam = camera
        if (cam == null) { Log.w(TAG, "setZoom: camera not started"); return }
        cam.cameraControl.setZoomRatio(ratio)
        Log.d(TAG, "setZoom: $ratio")
    }

    /**
     * Enables or disables the torch (flash).
     * No-op on front camera (torch not available — caller guards this).
     *
     * Mirrors iOS `cameraSource?.setTorchMode(mode)`.
     */
    fun setTorchMode(enabled: Boolean) {
        val cam = camera
        if (cam == null) { Log.w(TAG, "setTorchMode: camera not started"); return }
        cam.cameraControl.enableTorch(enabled)
        Log.d(TAG, "setTorchMode: $enabled")
    }

    /**
     * Sets the focus and metering point.
     *
     * [x] and [y] are normalised coordinates in [0, 1] × [0, 1] relative to
     * the preview surface (top-left origin). This matches the iOS contract:
     * `setFocusPoint(x.clamp(0, 1), y.clamp(0, 1))`.
     *
     * Uses [SurfaceOrientedMeteringPointFactory] since we don't have a
     * PreviewView. The factory maps normalised coordinates onto the camera's
     * physical coordinate system via the preview resolution.
     *
     * Mirrors iOS `cameraSource?.setFocus(x:y:)`.
     */
    fun setFocusPoint(x: Float, y: Float) {
        val cam = camera
        if (cam == null) { Log.w(TAG, "setFocusPoint: camera not started"); return }

        // SurfaceOrientedMeteringPointFactory(width, height) accepts normalised or
        // pixel coords — passing 1f×1f makes it treat x/y directly as normalised.
        val factory = SurfaceOrientedMeteringPointFactory(1f, 1f)
        val point = factory.createPoint(x, y)

        val action = FocusMeteringAction.Builder(point)
            .setAutoCancelDuration(3, TimeUnit.SECONDS)
            .build()

        cam.cameraControl.startFocusAndMetering(action)
        Log.d(TAG, "setFocusPoint: ($x, $y)")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Accessors for plugin (Step 2 wiring)
    // ─────────────────────────────────────────────────────────────────────────

    /** The Flutter texture ID for this camera session. */
    val textureId: Long get() = textureEntry.id()

    /** Current lens facing — for plugin queries. */
    val currentLensFacing: Int get() = lensFacing

    /** True when camera session is active. */
    val running: Boolean get() = isRunning
}
