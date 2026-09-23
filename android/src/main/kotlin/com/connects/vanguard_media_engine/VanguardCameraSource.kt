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
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.net.Uri
import android.util.Log
import android.util.Range
import android.view.Surface
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraEffect
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.MirrorMode
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.SurfaceProcessor
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
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
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.camera.AndroidCameraBeautySurfaceProcessor
import com.connects.vanguard_media_engine.camera.AndroidCameraXThermalFpsActuator
import com.connects.vanguard_media_engine.camera.CameraColorFilterState
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
    private val nativeBridge: VanguardNativeBridge? = null,
) {

    companion object {
        private const val TAG = "VanguardCameraSource"

        // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: proof-boundary telemetry
        // constants shared by the thermal FPS apply-result and diagnostics maps.
        private const val THERMAL_FPS_PROOF_BOUNDARY =
            "camerax_repeating_request_ae_fps_mutation_synthetic_thermal_no_rebind_no_forced_heat_no_product"
        private val THERMAL_FPS_NON_CLAIMS: Map<String, Boolean> = mapOf(
            "midRecordingActuationProven" to false,
            "osThermalListenerWired" to false,
            "resolutionReconfigured" to false,
            "secondaryCameraTouched" to false,
            "realForcedOverheat" to false,
            "encoderTouched" to false,
            "rendererTouched" to false,
            "productUiWired" to false,
        )
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

    // ── Recording-active signal (Android parity with iOS isRecordingActive) ──
    // False until CameraX has actually signalled VideoRecordEvent.Start, and
    // set back to false as soon as teardown begins (Finalize, stopRecording,
    // or stop()) — mirrors iOS VanguardCameraMediaSource.isRecordingActive,
    // which is true only once the writer is actively writing.
    @Volatile private var recordingActiveFlag = false

    // ── State guard (I-2: exactly one camera session at a time) ──────────────────
    private var isRunning = false

    // ── Camera readiness signal (Android parity with iOS isCameraReady) ──────
    // False until the Camera2 capture session behind the CameraX Preview
    // use-case has actually delivered a completed capture — mirrors iOS
    // VanguardCameraMediaSource, which reports ready only after the first
    // native frame buffer exists. Reset false on every start() before binding
    // and on stop(); set true from the Camera2Interop session capture
    // callback below, which fires off the main thread.
    @Volatile private var cameraReadyFlag = false

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

    // -- P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: thermal FPS actuation seam ----
    // bindGeneration/bindCount increment on every bindUseCases() call (start()
    // and switchCamera()); the thermal FPS actuator is recreated per bind and
    // any pending actuation whose captured generation no longer matches is a
    // stale no-op. surfaceRequestCount increments on every provideSurface()
    // call -- it must stay unchanged across a thermal FPS apply, proving no
    // rebind occurred. completedCaptureCount / observed*/applied*/consecutive*
    // are updated from the Camera2Interop session capture callback below.
    @Volatile private var bindGeneration = 0
    @Volatile private var bindCount = 0
    @Volatile private var surfaceRequestCount = 0
    @Volatile private var completedCaptureCount = 0
    @Volatile private var observedAeTargetFpsLower: Int? = null
    @Volatile private var observedAeTargetFpsUpper: Int? = null
    @Volatile private var appliedAeTargetFpsLower: Int? = null
    @Volatile private var appliedAeTargetFpsUpper: Int? = null
    @Volatile private var consecutiveAppliedRangeCompletedCaptures = 0
    private var thermalFpsActuator: AndroidCameraXThermalFpsActuator? = null

    // ── LIVE-CAMERA-BEAUTY-PARITY: beauty filter state ────────────────────────
    private var beautyProcessor: AndroidCameraBeautySurfaceProcessor? = null
    @Volatile private var beautyIntensity: Float = 0f
    @Volatile private var activeColorFilter: CameraColorFilterState? = null

    // Telemetry from the most recent applyThermalTargetFps() attempt (any
    // outcome -- applied, rejected, or stale). Reset to null on every fresh
    // bind. Surfaced read-only via thermalFpsDiagnostics().
    private data class ThermalFpsApplyTelemetry(
        val outcome: String,
        val reasons: List<String>,
        val selectedLower: Int?,
        val selectedUpper: Int?,
        val observedBeforeLower: Int?,
        val observedBeforeUpper: Int?,
        val observedAfterLower: Int?,
        val observedAfterUpper: Int?,
        val availableRanges: List<Range<Int>>,
        val bindGeneration: Int,
        val recordingActiveAtApply: Boolean,
        val isRecordingAtApply: Boolean,
        val completedCaptureCountBefore: Int,
        val completedCaptureCountAfter: Int,
    )
    @Volatile private var lastThermalFpsApplyTelemetry: ThermalFpsApplyTelemetry? = null

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

        // Reset readiness — a new session has not delivered a capture yet.
        cameraReadyFlag = false

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

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bindUseCases(provider: ProcessCameraProvider) {
        // Tear down any previously bound use-cases first.
        provider.unbindAll()

        // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: a fresh bind invalidates any
        // previously-observed/applied AE FPS state and the actuator bound to
        // the prior Camera instance. bindGeneration/bindCount/surfaceRequestCount
        // are proof counters for callers -- they always advance, never reset.
        bindGeneration += 1
        bindCount += 1
        surfaceRequestCount = 0
        completedCaptureCount = 0
        observedAeTargetFpsLower = null
        observedAeTargetFpsUpper = null
        appliedAeTargetFpsLower = null
        appliedAeTargetFpsUpper = null
        consecutiveAppliedRangeCompletedCaptures = 0
        lastThermalFpsApplyTelemetry = null
        // Deliberately do NOT cancel a still-in-flight apply on the previous
        // actuator instance here -- that would suppress its caller's
        // MethodChannel result. Just drop this source's reference to it; the
        // orphaned instance's own future/timeout keeps running independently
        // and reaches applyThermalTargetFps()'s stale-generation branch below,
        // which still replies exactly once (STALE_APPLY).
        thermalFpsActuator = null

        // ── Camera selector ───────────────────────────────────────────────────
        val selector = CameraSelector.Builder()
            .requireLensFacing(lensFacing)
            .build()

        // ── Resolution selector ──────────────────────────────────────────────
        // Negotiates a 16:9 buffer family (falling back automatically if the
        // device has no exact 16:9 stream) so Preview and ImageCapture agree on
        // the same portrait-compatible aspect ratio as the iOS 1080×1920/16:9
        // preset — matching the app's fixed 9:16 FittedBox(BoxFit.cover) layout.
        val resolutionSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .build()

        // ── Preview use-case ─────────────────────────────────────────────────
        // Frames route into the Flutter SurfaceTexture via a custom SurfaceProvider.
        // NO PreviewView is involved — this is identical in concept to iOS where
        // AVCaptureVideoDataOutput delivers CVPixelBuffer to VanguardMetalRenderer.
        val previewBuilder = Preview.Builder()
            .setResolutionSelector(resolutionSelector)

        // Camera2 interop: observe real preview capture delivery so isCameraReady
        // reflects an actual frame from the sensor, not just "use-cases bound".
        // This does NOT touch the Flutter SurfaceTexture's frame-available listener
        // (that ownership stays with TextureRegistry/Flutter) — it only observes
        // the underlying Camera2 capture session CameraX drives internally.
        Camera2Interop.Extender<Preview>(previewBuilder)
            .setSessionCaptureCallback(object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    result: TotalCaptureResult,
                ) {
                    cameraReadyFlag = true

                    // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: observe the AE
                    // target FPS range actually in effect for this completed
                    // capture and track consecutive captures matching the
                    // most recently applied thermal FPS range. Fires off the
                    // main thread -- see cameraReadyFlag comment above.
                    completedCaptureCount += 1
                    val range = result.get(CaptureResult.CONTROL_AE_TARGET_FPS_RANGE)
                    if (range != null) {
                        observedAeTargetFpsLower = range.lower
                        observedAeTargetFpsUpper = range.upper
                        val appliedLower = appliedAeTargetFpsLower
                        val appliedUpper = appliedAeTargetFpsUpper
                        consecutiveAppliedRangeCompletedCaptures =
                            if (appliedLower != null && appliedUpper != null &&
                                range.lower == appliedLower && range.upper == appliedUpper
                            ) {
                                consecutiveAppliedRangeCompletedCaptures + 1
                            } else {
                                0
                            }
                    }
                }
            })

        val previewUseCase = previewBuilder
            .build()
            .also { preview = it }

        previewUseCase.setSurfaceProvider { request ->
            provideSurface(request)
        }

        // ── ImageCapture use-case ─────────────────────────────────────────────
        // Dedicated high-resolution still capture selector:
        // Negotiates the highest 16:9 resolution supported by the camera hardware
        // sensor (e.g. 9–12+ Megapixels), matching the 9:16 viewfinder framing with
        // full ISP sharpness, rather than defaulting to the 1080p preview stream.
        val photoResolutionSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
            .build()

        val imageCaptureUseCase = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .setResolutionSelector(photoResolutionSelector)
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
        // Front-camera WYSIWYG parity (matches iOS videoMirrored = front):
        // saved video is mirrored like the preview for FRONT only; BACK stays normal.
        val videoCaptureUseCase = VideoCapture.Builder(recorder)
            .setMirrorMode(MirrorMode.MIRROR_MODE_ON_FRONT_ONLY)
            .build()
            .also { videoCapture = it }

        // ── LIVE-CAMERA-BEAUTY-PARITY: CameraEffect with SurfaceProcessor ────
        // Create the beauty SurfaceProcessor that intercepts camera frames for
        // real-time bilateral blur. Targets both PREVIEW and VIDEO_CAPTURE so
        // recorded video also receives the beauty filter (WYSIWYG parity with iOS).
        beautyProcessor?.release()
        val bridge = nativeBridge ?: run {
            val diag = com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics()
            VanguardNativeBridge(
                com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver(diag),
                diag,
                null
            )
        }
        val processor = AndroidCameraBeautySurfaceProcessor(bridge).also {
            it.intensity = beautyIntensity
            it.setColorFilter(activeColorFilter)
            beautyProcessor = it
        }

        val useCaseGroup = androidx.camera.core.UseCaseGroup.Builder()
            .addUseCase(previewUseCase)
            .addUseCase(imageCaptureUseCase)
            .addUseCase(videoCaptureUseCase)
            .apply {
                if (processor != null) {
                    addEffect(
                        CameraBeautyEffect(
                            CameraEffect.PREVIEW or CameraEffect.VIDEO_CAPTURE,
                            mainExecutor,
                            processor,
                        )
                    )
                }
            }
            .build()

        // ── Bind to fake LifecycleOwner ───────────────────────────────────────
        // CameraX manages the camera session lifecycle internally.
        // All use-cases bound in one call via UseCaseGroup to include the
        // CameraEffect for the beauty SurfaceProcessor pipeline.
        val boundCamera = provider.bindToLifecycle(
            lifecycleOwner,
            selector,
            useCaseGroup,
        )
        camera = boundCamera

        // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: recreate the actuator against
        // the freshly-bound Camera instance for this bind generation.
        thermalFpsActuator = AndroidCameraXThermalFpsActuator(boundCamera, mainExecutor)

        Log.d(TAG, "bindUseCases() — bound Preview + ImageCapture + VideoCapture + BeautyEffect")
    }

    // ── SurfaceProvider — bridges CameraX Preview → Flutter SurfaceTexture ───

    private fun provideSurface(request: SurfaceRequest) {
        // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: proof counter -- must stay
        // unchanged across a thermal FPS apply (no-rebind proof).
        surfaceRequestCount += 1

        // Prepare the Flutter SurfaceTexture to receive camera frames at the
        // resolution CameraX actually negotiated (16:9-family, via the
        // ResolutionSelector set on Preview.Builder — see bindUseCases()).
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
        recordingActiveFlag = false

        // Move fake lifecycle to DESTROYED — CameraX interprets this as the
        // "Activity finished" event and cleans up all hardware resources.
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)

        cameraProvider?.unbindAll()

        // LIVE-CAMERA-BEAUTY-PARITY: release the GPU processor on stop.
        beautyProcessor?.release()
        beautyProcessor = null
        activeColorFilter = null

        camera        = null
        preview       = null
        imageCapture  = null
        videoCapture  = null
        cameraProvider = null
        isRunning     = false
        cameraReadyFlag = false

        // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: deliberately do NOT cancel a
        // still-in-flight thermal FPS actuation here -- that would suppress
        // its caller's MethodChannel result. Just drop this source's
        // reference; the orphaned actuator's own future/timeout keeps running
        // and reaches applyThermalTargetFps()'s stopped-check branch below,
        // which still replies exactly once (STOPPED).
        thermalFpsActuator = null

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
        captureMode: String? = null,
        onResult: (String) -> Unit,
        onError: (Exception) -> Unit,
    ) {
        val capture = imageCapture
        if (capture == null) {
            onError(IllegalStateException("ImageCapture use-case not bound — call start() first"))
            return
        }

        val outputFile = File(outputPath)
        // Front-camera WYSIWYG parity: saved still is mirrored like the preview
        // for FRONT only (matches iOS videoMirrored = front); BACK stays normal.
        val metadata = ImageCapture.Metadata().apply {
            isReversedHorizontal = lensFacing == CameraSelector.LENS_FACING_FRONT
        }
        val outputOptions = ImageCapture.OutputFileOptions.Builder(outputFile)
            .setMetadata(metadata)
            .build()

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
     * Returns true only once CameraX has signalled that recording has
     * actually started (VideoRecordEvent.Start) and false again as soon as
     * teardown begins. Mirrors iOS cameraSource.isRecordingActive, which the
     * plugin exposes to Dart's isRecordingActive() polling.
     */
    val isRecordingActive: Boolean get() = isRecording && recordingActiveFlag

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

        recordingActiveFlag = false

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
                    recordingActiveFlag = true
                    onStarted()
                }
                is VideoRecordEvent.Finalize -> {
                    recordingActiveFlag = false
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
        recordingActiveFlag = false
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
     * Returns zoom capability keys matching the Dart
     * `VGCameraZoomCapabilities.fromMap` parser, or `null` if no active
     * capture device is available yet (e.g. [ZoomState] hasn't been
     * populated by CameraX).
     *
     * Mirrors iOS `VanguardCameraMediaSource.zoomCapabilities`. CameraX
     * exposes no separate optical/lossless-crop threshold the way AVFoundation
     * does, so [technicalMaxZoomFactor] is reused as a conservative
     * `upscaleThresholdZoomFactor`. Virtual-device fields are left at their
     * "none" values ([] / false) — CameraX logical multi-camera switch-over
     * points aren't surfaced in this wide-angle-only phase.
     *
     * Recommended-max policy (no AVFoundation upscale threshold to build
     * from): front camera `min(2.0, technicalMax)`; back camera
     * `min(10.0, technicalMax)`.
     */
    fun zoomCapabilities(): Map<String, Any>? {
        val cam = camera ?: return null
        val zoomState = cam.cameraInfo.zoomState.value ?: return null

        val minZoom = zoomState.minZoomRatio
        val technicalMax = zoomState.maxZoomRatio
        val isFront = lensFacing == CameraSelector.LENS_FACING_FRONT

        var recommendedMax = if (isFront) {
            minOf(2.0f, technicalMax)
        } else {
            minOf(10.0f, technicalMax)
        }
        // Guard degenerate values so max is at least min.
        recommendedMax = maxOf(recommendedMax, minZoom)

        val defaultZoom = 1.0f.coerceIn(minZoom, recommendedMax)

        return mapOf(
            "minZoomFactor" to minZoom.toDouble(),
            "maxZoomFactor" to recommendedMax.toDouble(),
            "defaultZoomFactor" to defaultZoom.toDouble(),
            "technicalMaxZoomFactor" to technicalMax.toDouble(),
            "upscaleThresholdZoomFactor" to technicalMax.toDouble(),
            "cameraPosition" to if (isFront) "front" else "back",
            "displayZoomFactorMultiplier" to 1.0,
            "virtualDeviceSwitchOverZoomFactors" to emptyList<Double>(),
            "isVirtualDevice" to false
        )
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

    // ----------------------------------------------------------------------
    // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: thermal FPS actuation
    // ----------------------------------------------------------------------

    private fun thermalFpsRangeMap(lower: Int?, upper: Int?): Map<String, Int>? =
        if (lower == null || upper == null) null else mapOf("lower" to lower, "upper" to upper)

    private fun thermalFpsAvailableRangesMap(ranges: List<Range<Int>>): List<Map<String, Int>> =
        ranges.map { mapOf("lower" to it.lower, "upper" to it.upper) }

    /**
     * Records telemetry for an applyThermalTargetFps() attempt rejected before
     * a candidate range could be selected (no active session/device/actuator).
     * No observed/applied range changed as a result, so before == after.
     */
    private fun recordThermalFpsEarlyRejection(
        reason: String,
        generation: Int,
        recordingActiveAtApply: Boolean,
        isRecordingAtApply: Boolean,
        completedCaptureCountAtCall: Int,
    ) {
        lastThermalFpsApplyTelemetry = ThermalFpsApplyTelemetry(
            outcome = "REJECTED",
            reasons = listOf(reason),
            selectedLower = null,
            selectedUpper = null,
            observedBeforeLower = observedAeTargetFpsLower,
            observedBeforeUpper = observedAeTargetFpsUpper,
            observedAfterLower = observedAeTargetFpsLower,
            observedAfterUpper = observedAeTargetFpsUpper,
            availableRanges = emptyList(),
            bindGeneration = generation,
            recordingActiveAtApply = recordingActiveAtApply,
            isRecordingAtApply = isRecordingAtApply,
            completedCaptureCountBefore = completedCaptureCountAtCall,
            completedCaptureCountAfter = completedCaptureCountAtCall,
        )
    }

    /**
     * Applies a Dart-planner-derived [targetFps] as a reduced CameraX
     * repeating-request AE target FPS range, via
     * [AndroidCameraXThermalFpsActuator]. FPS-only -- never rebinds, never
     * reconfigures resolution, never touches recording/encoder/renderer state.
     *
     * Rejects with a typed `(code, message)` via [onError] when the session
     * is not running/stopping, no camera device is bound, no actuator is
     * available, the actuator itself rejects the requested [targetFps]
     * (see [AndroidCameraXThermalFpsActuator.selectTargetFpsRange]), or an
     * earlier apply is still in flight (`APPLY_IN_PROGRESS` -- the earlier
     * attempt's own future/timeout and callback are left untouched).
     *
     * [onResult] / [onError] are guarded against stale completions: if the
     * bind generation has advanced (a rebind/switchCamera happened mid-flight)
     * or the session has since stopped, [onError] is still called exactly once
     * with a typed `STOPPED` / `STALE_APPLY` code -- the callback is never
     * silently dropped, and hardware state is never mutated for a stale result.
     */
    fun applyThermalTargetFps(
        targetFps: Int,
        onResult: (Map<String, Any?>) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
        val callRecordingActive = isRecordingActive
        val callIsRecording = isRecording
        val callCompletedCaptureCount = completedCaptureCount
        val requestGeneration = bindGeneration

        if (!isRunning) {
            recordThermalFpsEarlyRejection(
                "NOT_RUNNING", requestGeneration, callRecordingActive, callIsRecording, callCompletedCaptureCount,
            )
            onError("NOT_RUNNING", "applyThermalTargetFps: camera session not running")
            return
        }
        if (stopRequested) {
            recordThermalFpsEarlyRejection(
                "STOPPED", requestGeneration, callRecordingActive, callIsRecording, callCompletedCaptureCount,
            )
            onError("STOPPED", "applyThermalTargetFps: camera session is stopping")
            return
        }
        if (camera == null) {
            recordThermalFpsEarlyRejection(
                "NO_CAMERA_DEVICE", requestGeneration, callRecordingActive, callIsRecording, callCompletedCaptureCount,
            )
            onError("NO_CAMERA_DEVICE", "applyThermalTargetFps: no bound camera device")
            return
        }
        val actuator = thermalFpsActuator
        if (actuator == null) {
            recordThermalFpsEarlyRejection(
                "NO_ACTUATOR", requestGeneration, callRecordingActive, callIsRecording, callCompletedCaptureCount,
            )
            onError("NO_ACTUATOR", "applyThermalTargetFps: thermal FPS actuator not available")
            return
        }

        val observedBeforeLower = observedAeTargetFpsLower
        val observedBeforeUpper = observedAeTargetFpsUpper

        when (val outcome = actuator.selectTargetFpsRange(
            targetFps,
            observedBeforeLower,
            observedBeforeUpper,
        )) {
            is AndroidCameraXThermalFpsActuator.SelectionOutcome.Rejected -> {
                lastThermalFpsApplyTelemetry = ThermalFpsApplyTelemetry(
                    outcome = "REJECTED",
                    reasons = listOf(outcome.reason),
                    selectedLower = null,
                    selectedUpper = null,
                    observedBeforeLower = observedBeforeLower,
                    observedBeforeUpper = observedBeforeUpper,
                    observedAfterLower = observedAeTargetFpsLower,
                    observedAfterUpper = observedAeTargetFpsUpper,
                    availableRanges = outcome.availableRanges,
                    bindGeneration = requestGeneration,
                    recordingActiveAtApply = callRecordingActive,
                    isRecordingAtApply = callIsRecording,
                    completedCaptureCountBefore = callCompletedCaptureCount,
                    completedCaptureCountAfter = completedCaptureCount,
                )
                onError(outcome.reason, outcome.message)
            }
            is AndroidCameraXThermalFpsActuator.SelectionOutcome.Selected -> {
                val selection = outcome.result
                val started = actuator.applySelectedRange(
                    selected = selection,
                    onApplied = {
                        val stopped = !isRunning || stopRequested
                        val staleGeneration = requestGeneration != bindGeneration
                        if (stopped || staleGeneration) {
                            // Do not mutate applied-range bookkeeping or claim
                            // hardware effect for a stale/post-stop completion --
                            // but still reply exactly once so the MethodChannel
                            // result never hangs.
                            val code = if (stopped) "STOPPED" else "STALE_APPLY"
                            val message = if (stopped) {
                                "applyThermalTargetFps: camera session stopped before apply completed"
                            } else {
                                "applyThermalTargetFps: bind generation advanced before apply completed"
                            }
                            Log.w(TAG, "applyThermalTargetFps: stale apply completion ($code) -- replying with typed error")
                            onError(code, message)
                        } else {
                            appliedAeTargetFpsLower = selection.selectedLower
                            appliedAeTargetFpsUpper = selection.selectedUpper
                            consecutiveAppliedRangeCompletedCaptures = 0
                            lastThermalFpsApplyTelemetry = ThermalFpsApplyTelemetry(
                                outcome = "APPLIED",
                                reasons = listOf("APPLIED"),
                                selectedLower = selection.selectedLower,
                                selectedUpper = selection.selectedUpper,
                                observedBeforeLower = observedBeforeLower,
                                observedBeforeUpper = observedBeforeUpper,
                                observedAfterLower = observedAeTargetFpsLower,
                                observedAfterUpper = observedAeTargetFpsUpper,
                                availableRanges = selection.availableRanges,
                                bindGeneration = requestGeneration,
                                recordingActiveAtApply = callRecordingActive,
                                isRecordingAtApply = callIsRecording,
                                completedCaptureCountBefore = callCompletedCaptureCount,
                                completedCaptureCountAfter = completedCaptureCount,
                            )
                            onResult(
                                mapOf(
                                    "requestedTargetFps" to selection.requestedTargetFps,
                                    "observedCurrentLower" to selection.observedCurrentLower,
                                    "observedCurrentUpper" to selection.observedCurrentUpper,
                                    "selectedLower" to selection.selectedLower,
                                    "selectedUpper" to selection.selectedUpper,
                                    "selectedRange" to thermalFpsRangeMap(selection.selectedLower, selection.selectedUpper),
                                    "observedRangeBefore" to thermalFpsRangeMap(observedBeforeLower, observedBeforeUpper),
                                    "observedRangeAfter" to thermalFpsRangeMap(observedAeTargetFpsLower, observedAeTargetFpsUpper),
                                    "availableRanges" to thermalFpsAvailableRangesMap(selection.availableRanges),
                                    "bindGeneration" to requestGeneration,
                                    "recordingActiveAtApply" to callRecordingActive,
                                    "isRecordingAtApply" to callIsRecording,
                                    "completedCaptureCountBefore" to callCompletedCaptureCount,
                                    "completedCaptureCountAfter" to completedCaptureCount,
                                    "outcome" to "APPLIED",
                                    "reasons" to listOf("APPLIED"),
                                    "proofBoundary" to THERMAL_FPS_PROOF_BOUNDARY,
                                    "nonClaims" to THERMAL_FPS_NON_CLAIMS,
                                ),
                            )
                        }
                    },
                    onError = { e ->
                        val stopped = !isRunning || stopRequested
                        val staleGeneration = requestGeneration != bindGeneration
                        if (stopped || staleGeneration) {
                            val code = if (stopped) "STOPPED" else "STALE_APPLY"
                            val message = if (stopped) {
                                "applyThermalTargetFps: camera session stopped before apply error resolved"
                            } else {
                                "applyThermalTargetFps: bind generation advanced before apply error resolved"
                            }
                            Log.w(TAG, "applyThermalTargetFps: stale apply error ($code) -- replying with typed error: ${e.message}")
                            onError(code, message)
                        } else {
                            lastThermalFpsApplyTelemetry = ThermalFpsApplyTelemetry(
                                outcome = "REJECTED",
                                reasons = listOf("APPLY_FAILED"),
                                selectedLower = null,
                                selectedUpper = null,
                                observedBeforeLower = observedBeforeLower,
                                observedBeforeUpper = observedBeforeUpper,
                                observedAfterLower = observedAeTargetFpsLower,
                                observedAfterUpper = observedAeTargetFpsUpper,
                                availableRanges = selection.availableRanges,
                                bindGeneration = requestGeneration,
                                recordingActiveAtApply = callRecordingActive,
                                isRecordingAtApply = callIsRecording,
                                completedCaptureCountBefore = callCompletedCaptureCount,
                                completedCaptureCountAfter = completedCaptureCount,
                            )
                            onError("APPLY_FAILED", e.message ?: "applyThermalTargetFps: setCaptureRequestOptions failed")
                        }
                    },
                )
                if (!started) {
                    // An earlier apply is still in flight on this actuator --
                    // its future/timeout and eventual callback are left
                    // completely untouched. Reject this second call
                    // immediately without any hardware bookkeeping.
                    lastThermalFpsApplyTelemetry = ThermalFpsApplyTelemetry(
                        outcome = "REJECTED",
                        reasons = listOf("APPLY_IN_PROGRESS"),
                        selectedLower = null,
                        selectedUpper = null,
                        observedBeforeLower = observedBeforeLower,
                        observedBeforeUpper = observedBeforeUpper,
                        observedAfterLower = observedAeTargetFpsLower,
                        observedAfterUpper = observedAeTargetFpsUpper,
                        availableRanges = selection.availableRanges,
                        bindGeneration = requestGeneration,
                        recordingActiveAtApply = callRecordingActive,
                        isRecordingAtApply = callIsRecording,
                        completedCaptureCountBefore = callCompletedCaptureCount,
                        completedCaptureCountAfter = completedCaptureCount,
                    )
                    onError("APPLY_IN_PROGRESS", "applyThermalTargetFps: another apply is already in flight")
                }
            }
        }
    }

    /**
     * Snapshot diagnostics for the thermal FPS actuation seam -- bind/surface
     * proof counters, observed and applied AE target FPS ranges, the
     * consecutive-completed-capture confirmation counter, and telemetry from
     * the most recent applyThermalTargetFps() attempt (if any). Read-only;
     * safe to call at any time, including before [start] or after [stop] --
     * on Android this always returns a populated map when a camera session
     * object exists; callers with no active session at all receive a native
     * `NO_CAMERA` error from the owning router, not this map.
     */
    fun thermalFpsDiagnostics(): Map<String, Any?> {
        val telemetry = lastThermalFpsApplyTelemetry
        return mapOf(
            "running" to isRunning,
            "textureId" to textureEntry.id(),
            "bindGeneration" to bindGeneration,
            "bindCount" to bindCount,
            "surfaceRequestCount" to surfaceRequestCount,
            "cameraProviderIdentity" to cameraProvider?.let { System.identityHashCode(it) },
            "completedCaptureCount" to completedCaptureCount,
            "observedAeTargetFpsLower" to observedAeTargetFpsLower,
            "observedAeTargetFpsUpper" to observedAeTargetFpsUpper,
            "appliedAeTargetFpsLower" to appliedAeTargetFpsLower,
            "appliedAeTargetFpsUpper" to appliedAeTargetFpsUpper,
            "appliedRange" to thermalFpsRangeMap(appliedAeTargetFpsLower, appliedAeTargetFpsUpper),
            "consecutiveAppliedRangeCompletedCaptures" to consecutiveAppliedRangeCompletedCaptures,
            "isRecording" to isRecording,
            "isRecordingActive" to isRecordingActive,
            "outcome" to (telemetry?.outcome ?: "NONE"),
            "reasons" to (telemetry?.reasons ?: emptyList<String>()),
            "observedRangeBefore" to thermalFpsRangeMap(telemetry?.observedBeforeLower, telemetry?.observedBeforeUpper),
            "observedRangeAfter" to thermalFpsRangeMap(telemetry?.observedAfterLower, telemetry?.observedAfterUpper),
            "availableRanges" to thermalFpsAvailableRangesMap(telemetry?.availableRanges ?: emptyList()),
            "recordingActiveAtApply" to (telemetry?.recordingActiveAtApply ?: false),
            "isRecordingAtApply" to (telemetry?.isRecordingAtApply ?: false),
            "completedCaptureCountBefore" to (telemetry?.completedCaptureCountBefore ?: 0),
            "completedCaptureCountAfter" to (telemetry?.completedCaptureCountAfter ?: 0),
            "proofBoundary" to THERMAL_FPS_PROOF_BOUNDARY,
            "nonClaims" to THERMAL_FPS_NON_CLAIMS,
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // LIVE-CAMERA-BEAUTY-PARITY: beauty filter control
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Sets the beauty filter intensity.
     * 0.0 = off (direct passthrough), 0.5 = soft, 0.75 = strong, 1.0 = max.
     * Thread-safe: updates are forwarded to the GPU processor's volatile field.
     */
    fun setBeautyIntensity(intensity: Float) {
        beautyIntensity = intensity.coerceIn(0f, 1f)
        beautyProcessor?.intensity = beautyIntensity
        Log.d(TAG, "setBeautyIntensity: $beautyIntensity")
    }

    /**
     * CAM-01: sets or clears the active camera color filter (ColorMatrix / 2D LUT).
     * Thread-safe: updates are forwarded to the GPU processor.
     */
    fun setColorFilter(filterState: CameraColorFilterState?) {
        activeColorFilter = filterState
        beautyProcessor?.setColorFilter(filterState)
        Log.d(TAG, "setColorFilter: ${filterState?.mode} intensity=${filterState?.intensity}")
    }

    /**
     * CAM-01: updates the intensity of the active color filter or applies a warm preset
     * with the specified intensity if none was active.
     */
    fun updateColorFilterIntensity(intensity: Float) {
        val current = activeColorFilter
        val updated = if (current != null) {
            current.copy(intensity = intensity.coerceIn(0f, 1f))
        } else {
            CameraColorFilterState.fromPreset("warm", intensity)
        }
        setColorFilter(updated)
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

    /**
     * True once the Camera2 capture session behind the Preview use-case has
     * delivered at least one completed capture for the current start()
     * session. Mirrors iOS `cameraSource?.isCameraReady`.
     */
    val isCameraReady: Boolean get() = cameraReadyFlag
}

// ── LIVE-CAMERA-BEAUTY-PARITY: concrete CameraEffect subclass ────────────────
// CameraEffect is abstract with a protected constructor; this minimal subclass
// only exposes the constructor so we can register our SurfaceProcessor with
// the CameraX UseCaseGroup builder.

private class CameraBeautyEffect(
    targets: Int,
    executor: java.util.concurrent.Executor,
    surfaceProcessor: SurfaceProcessor,
) : CameraEffect(targets, executor, surfaceProcessor, { })
