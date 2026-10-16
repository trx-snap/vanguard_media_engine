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
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
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
import androidx.camera.core.SurfaceOutput
import androidx.camera.core.DynamicRange
import androidx.camera.core.resolutionselector.ResolutionFilter
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
import com.connects.vanguard_media_engine.camera.CameraGreenScreenState
import com.connects.vanguard_media_engine.camera.CameraOverlayState
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

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
 * @param captureProfile Optional capture profile token from Dart. null keeps
 *   the existing default use-case selection unchanged;
 *   [CAPTURE_PROFILE_LIVESTREAM_720P] requires an exact 1280×720 effect input
 *   (see [bindUseCases]): the size CameraX negotiates is validated by the
 *   effect-input gate before start/switch/resume report success.
 */
class VanguardCameraSource(
    private val context: Context,
    private val textureEntry: TextureRegistry.SurfaceTextureEntry,
    private var lensFacing: Int = CameraSelector.LENS_FACING_BACK,
    private val frameRate: Int = 30,
    private val nativeBridge: VanguardNativeBridge? = null,
    private val captureProfile: String? = null,
) {

    companion object {
        private const val TAG = "VanguardCameraSource"

        /** Livestream single-camera profile: exactly 1280×720 capture, or nothing. */
        const val CAPTURE_PROFILE_LIVESTREAM_720P = "livestream720p"

        // livestream720p raster: exactly 1280×720 pixels. 720×1280 is the same
        // 16:9 raster transposed by the sensor orientation and is the only
        // other accepted form; 960×540 and every other size are rejected.
        private const val LIVESTREAM_WIDTH = 1280
        private const val LIVESTREAM_HEIGHT = 720

        // Upper bound on how long a livestream720p bind may wait for CameraX's
        // effect-input SurfaceRequest before the operation fails.
        private const val LIVESTREAM_INPUT_GATE_TIMEOUT_MS = 10_000L

        private fun isLivestreamExactRaster(width: Int, height: Int): Boolean =
            (width == LIVESTREAM_WIDTH && height == LIVESTREAM_HEIGHT) ||
                (width == LIVESTREAM_HEIGHT && height == LIVESTREAM_WIDTH)

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

    // ── I1 livestream media source: capture suspension ──────────────────────
    // True between suspendCapture() and resumeCapture(): the use cases are
    // unbound (CameraX closes the camera device once nothing is bound) and the
    // beauty processor is released, while isRunning, the lifecycle owner, the
    // provider, the Flutter texture and every beauty/color/green-screen/overlay
    // state stay put so resumeCapture() rebinds through the normal
    // bindUseCases() path. Main thread only.
    private var captureSuspended = false

    // One-shot first-completed-capture listener armed by resumeCapture() and
    // fired exactly once, on the main executor, from the Camera2Interop capture
    // callback below (which runs off the main thread).
    private val firstFrameListener = AtomicReference<(() -> Unit)?>(null)

    // ── livestream720p exact effect-input gate ───────────────────────────────
    // Non-null from a successful livestream720p bindToLifecycle() until CameraX
    // delivers the effect-input SurfaceRequest (accepted or rejected), the
    // 10 s timeout fires, or stop()/suspendCapture()/a rebind cancels it. The
    // start()/switchCamera()/resumeCapture() completion that armed it is
    // reported exactly once, through the gate. Main thread only.
    private var livestreamInputGate: LivestreamInputGate? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── start() attempt awaiting its ProcessCameraProvider lookup ────────────
    // Non-null from start() until the provider listener takes over (bind) or
    // stop() settles the attempt: teardown plus its onError, exactly once. The
    // listener ignores an attempt that is no longer current and never touches
    // the process-wide provider for it (a newer source may already be bound on
    // it). start()/switchCamera() treat a pending attempt as an owned session.
    // The attempt also owns the start's terminal callback: exactly one of
    // onStarted/onError is ever selected, and once selected, an exception the
    // consumer throws from it is the consumer's own — it never selects the
    // opposite callback, is never delivered twice, and never rolls the
    // reported outcome back. Main thread only.
    private class StartAttempt(
        private val onStarted: () -> Unit,
        private val onError: (Exception) -> Unit,
    ) {
        /** True once onStarted or onError has been selected (whether or not it threw). */
        var isSettled = false
            private set

        fun reportStarted() {
            if (isSettled) return
            isSettled = true
            onStarted()
        }

        fun reportError(error: Exception) {
            if (isSettled) {
                Log.w(TAG, "start() — terminal callback already selected; later error ignored: $error")
                return
            }
            isSettled = true
            onError(error)
        }
    }
    private var pendingStart: StartAttempt? = null

    // True once teardownSession() has run (stop(), a failed start()/switchCamera(),
    // or an invalidated session) until the next start(): the source owns no
    // camera, processor or lifecycle any more and its owner should drop it.
    @Volatile private var tornDown = false

    /**
     * Owner hook for a session that fails closed AFTER its start/switch already
     * reported success (CameraX re-issued the livestream720p effect input at a
     * size other than 1280×720/720×1280). Called once, on the main thread, after
     * the source tore itself down ([isTornDown]); no MethodChannel result is
     * pending for it, so the owner only drops the source.
     */
    var onSessionInvalidated: ((Exception) -> Unit)? = null

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
    // F2: green-screen state; held at the source level so restart/rebind can reapply it.
    // Not nulled on stop() — state is kept across rebinds per task requirement.
    @Volatile private var activeGreenScreenState: CameraGreenScreenState? = null
    // G1-B: livestream overlay state; same lifetime policy as the green screen so
    // a beauty-processor rebind (start/switchCamera) reapplies the active items.
    @Volatile private var activeOverlayState: CameraOverlayState? = null

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
     *   [textureEntry.id()] is valid for Flutter's `Texture` widget. For
     *   [CAPTURE_PROFILE_LIVESTREAM_720P] this is only after CameraX's effect
     *   input was validated as exactly 1280×720 (or 720×1280 transposed).
     * @param onError Called on the main thread if the camera cannot be opened,
     *   if [stop] cancels the start while the camera provider is still being
     *   looked up, or (livestream720p) if the effect input has another size,
     *   does not arrive within 10 s, or the session is stopped before
     *   validation. Exactly one of [onStarted]/[onError] is selected per
     *   accepted start(); an exception thrown by the selected callback is the
     *   caller's own and propagates without selecting the other one or
     *   rolling the session back.
     */
    fun start(
        onStarted: () -> Unit = {},
        onError: (Exception) -> Unit = {},
    ) {
        // I-2 guard: prevent double-start. A start whose provider lookup is
        // still in flight, or a livestream720p bind still awaiting its
        // exact-input validation, is an owned session and counts as running.
        if (isRunning || pendingStart != null || livestreamInputGate != null) {
            Log.w(TAG, "start() called on already-running camera — ignored")
            return
        }

        Log.d(TAG, "start() — requesting ProcessCameraProvider")

        // Reset cancellation flag for this fresh start attempt.
        stopRequested = false
        tornDown = false

        // Reset readiness — a new session has not delivered a capture yet.
        cameraReadyFlag = false

        // Advance fake lifecycle to RESUMED so CameraX considers the session active.
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)

        // This attempt owns the session until the provider resolves. stop()
        // settles it meanwhile (teardown + onError, once); the listener below
        // then finds it is no longer current and does nothing.
        val attempt = StartAttempt(onStarted, onError)
        pendingStart = attempt

        try {
            val providerFuture = ProcessCameraProvider.getInstance(context)
            providerFuture.addListener({
                if (pendingStart !== attempt) {
                    // stop() settled this attempt while the provider was resolving:
                    // its onError already ran and the plugin may have released the
                    // SurfaceTexture, so nothing may be bound. Nothing of this
                    // attempt is bound, and the provider is shared process-wide (a
                    // newer source may be bound on it), so it is left untouched.
                    Log.w(TAG, "start() listener: this start was cancelled during the provider lookup — ignored")
                    return@addListener
                }
                pendingStart = null
                try {
                    val provider = providerFuture.get()
                    cameraProvider = provider

                    // Build and bind all use-cases in one call. livestream720p
                    // completes through the exact effect-input gate (asynchronously,
                    // once CameraX reports the negotiated input size); every other
                    // profile completes synchronously inside bindUseCases().
                    bindUseCases(
                        provider,
                        operation = "start",
                        onBound = {
                            isRunning = true
                            Log.d(TAG, "start() — camera session live, textureId=${textureEntry.id()}")
                            attempt.reportStarted()
                        },
                        onFailed = { e, cleanUp ->
                            if (cleanUp) teardownSession()
                            Log.e(TAG, "start() — livestream720p exact-input gate failed: $e")
                            attempt.reportError(e)
                        },
                    )
                } catch (e: Exception) {
                    if (attempt.isSettled) {
                        // The terminal callback had already been selected and
                        // delivered when this was thrown (onStarted/onError ran
                        // synchronously inside bindUseCases): it is the
                        // consumer's own exception, not a startup failure. The
                        // reported outcome stands — no teardown, no opposite
                        // callback — and the exception propagates unchanged.
                        Log.e(TAG, "start() — consumer callback threw after the start outcome was reported; propagating: $e")
                        throw e
                    }
                    // Provider resolution or bind failed before any outcome was
                    // selected: nothing usable remains, so tear the session down
                    // before reporting, and the owner never keeps a half-started
                    // source with a live lifecycle or provider.
                    Log.e(TAG, "start() — ProcessCameraProvider/bind failed; session torn down: $e")
                    teardownSession()
                    attempt.reportError(e)
                }
            }, mainExecutor)
        } catch (e: Exception) {
            if (attempt.isSettled) {
                // Only reachable if the listener ran inline and its consumer
                // callback threw: the consumer's own exception, see above.
                Log.e(TAG, "start() — consumer callback threw after the start outcome was reported; propagating: $e")
                throw e
            }
            // getInstance()/addListener() threw synchronously: no listener will
            // ever run for this attempt. Settle it through the same identity
            // guard as the asynchronous path, exactly once, with its session
            // torn down. Nothing is bound and cameraProvider is still null, so
            // the shared provider is not touched.
            if (pendingStart !== attempt) {
                Log.w(TAG, "start() — provider setup failed after this start was already settled — ignored: $e")
                return
            }
            Log.e(TAG, "start() — ProcessCameraProvider setup failed synchronously; session torn down: $e")
            teardownSession()
            attempt.reportError(e)
        }
    }

    // ── Use-case construction + binding ──────────────────────────────────────

    /**
     * Builds and binds the use cases for the current [lensFacing]. [onBound]
     * runs once the bind is complete: synchronously for the default profile,
     * and for [CAPTURE_PROFILE_LIVESTREAM_720P] only after the exact
     * effect-input gate accepted CameraX's negotiated input. [onFailed] runs
     * once, instead, when that gate rejects the input, times out, or is
     * cancelled by stop()/suspendCapture()/a rebind; `cleanUp` is true when the
     * caller must still unbind/tear down the session (false when the canceller
     * already did). A synchronous bind failure throws instead, with nothing
     * bound and no processor left behind. Main thread only.
     */
    @OptIn(ExperimentalCamera2Interop::class)
    private fun bindUseCases(
        provider: ProcessCameraProvider,
        operation: String,
        onBound: () -> Unit,
        onFailed: (error: Exception, cleanUp: Boolean) -> Unit,
    ) {
        // A rebind supersedes a livestream720p bind still awaiting its
        // exact-input validation: cancel its timer and report that operation
        // once, as an error, so it can never succeed late against this bind.
        livestreamInputGate?.fail(
            IllegalStateException("livestream720p exact-input validation superseded by $operation rebind"),
            cleanUp = false,
        )

        // Tear down any previously bound use-cases first. From here on the
        // previous camera is gone: readiness is false until the new session
        // completes a capture, and every failure below leaves nothing bound.
        provider.unbindAll()
        cameraReadyFlag = false

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

        // ── Capture profile ──────────────────────────────────────────────────
        // livestream720p (livestream single camera only) requires an exactly
        // 1280×720 beauty/effect INPUT, not just a 720p preview. The effect
        // targets PREVIEW|VIDEO_CAPTURE, so CameraX feeds it one shared
        // (StreamSharing) camera stream whose size is merged from the Preview
        // and VideoCapture children's candidate size lists; any child candidate
        // of another size lets CameraX pick another parent (observed: 1920×1080
        // and 960×540 inputs). So for livestream720p:
        //   - Preview candidates are exactly 1280×720 (FALLBACK_RULE_NONE plus a
        //     ResolutionFilter that also admits the 720×1280 transposition),
        //   - VideoCapture is Quality.HD with no fallback, and HD must be a
        //     supported SDR quality before anything is bound,
        //   - ImageCapture is not bound (the livestream takes no stills),
        //   - the effect input CameraX actually negotiates is checked by the
        //     LivestreamEffectInputProbe gate: anything but 1280×720 (or its
        //     720×1280 transposition) is withheld and the bind fails.
        // Preview + VideoCapture stay bound on purpose: that StreamSharing
        // topology is what the beauty processor's output path is built for
        // (its effect output keeps the input orientation/size).
        // Any other profile keeps the default selection below byte-for-byte.
        val livestream720p = captureProfile == CAPTURE_PROFILE_LIVESTREAM_720P
        val profileLabel = captureProfile ?: "default"

        // ── Resolution selector ──────────────────────────────────────────────
        // Negotiates a 16:9 buffer family (falling back automatically if the
        // device has no exact 16:9 stream) so Preview and ImageCapture agree on
        // the same portrait-compatible aspect ratio as the iOS 1080×1920/16:9
        // preset — matching the app's fixed 9:16 FittedBox(BoxFit.cover) layout.
        // livestream720p: exact 1280×720 with FALLBACK_RULE_NONE, and the filter
        // keeps only that raster (or its 720×1280 transposition). An empty
        // candidate list makes bindToLifecycle() throw — no fallback size.
        var livestreamExactCandidates = -1 // set by the livestream720p filter; -1 = not consulted
        val resolutionSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .apply {
                if (livestream720p) {
                    setResolutionStrategy(
                        ResolutionStrategy(
                            Size(LIVESTREAM_WIDTH, LIVESTREAM_HEIGHT),
                            ResolutionStrategy.FALLBACK_RULE_NONE,
                        )
                    )
                    setResolutionFilter(ResolutionFilter { sizes, _ ->
                        val exact = sizes.filter { isLivestreamExactRaster(it.width, it.height) }
                        livestreamExactCandidates = exact.size
                        if (exact.isEmpty()) {
                            Log.e(TAG, "bindUseCases(profile=livestream720p): no exact 1280×720 (or 720×1280) preview candidate among [${sizes.joinToString { "${it.width}×${it.height}" }}] — bind fails, no fallback")
                        } else {
                            Log.i(TAG, "bindUseCases(profile=livestream720p): exact preview candidates [${exact.joinToString { "${it.width}×${it.height}" }}]")
                        }
                        exact
                    })
                }
            }
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
                    // I1: a resumeCapture() caller waits for this first real
                    // capture before handing the egress back to the camera.
                    firstFrameListener.getAndSet(null)?.let { listener -> mainExecutor.execute { listener() } }

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
        // livestream720p: not bound (the livestream takes no stills); takePhoto
        // then reports "ImageCapture use-case not bound" as for an unstarted source.
        val imageCaptureUseCase: ImageCapture? = if (livestream720p) {
            null
        } else {
            val photoResolutionSelector = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                .build()

            ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                .setResolutionSelector(photoResolutionSelector)
                .build()
        }
        imageCapture = imageCaptureUseCase

        // ── VideoCapture use-case (Recorder) ──────────────────────────────────
        // Default: QualitySelector prefers 1080p — falls back to highest
        // available if the device doesn't support it (matches iOS
        // AVCaptureSessionPreset1920x1080 fallback to 1280x720).
        // livestream720p: Quality.HD (1280×720) only. The camera must report HD
        // among its supported SDR qualities before anything is bound, and no
        // FallbackStrategy is attached, so VideoCapture cannot select another
        // quality and move the shared effect stream off 1280×720. Should CameraX
        // still negotiate another input size, the effect-input gate rejects it.
        val qualitySelector = if (livestream720p) {
            val hdSupported = try {
                Recorder.getVideoCapabilities(provider.getCameraInfo(selector))
                    .isQualitySupported(Quality.HD, DynamicRange.SDR)
            } catch (e: Exception) {
                throw IllegalStateException("livestream720p: video capability probe failed — ${e.message}", e)
            }
            if (!hdSupported) {
                throw IllegalStateException("livestream720p: camera reports no Quality.HD (1280×720) SDR video quality — refusing to bind")
            }
            QualitySelector.from(Quality.HD)
        } else {
            QualitySelector.from(
                Quality.FHD,                   // 1080p preferred
                FallbackStrategy.higherQualityOrLowerThan(Quality.HD)
            )
        }
        val recorder = Recorder.Builder()
            .setQualitySelector(qualitySelector)
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
        val processor = AndroidCameraBeautySurfaceProcessor(bridge, context).also {
            it.intensity = beautyIntensity
            it.setColorFilter(activeColorFilter)
            // F2: reapply green-screen state so restart/rebind preserves the GS configuration.
            it.setGreenScreen(activeGreenScreenState)
            // G1-B: reapply the overlay list the same way.
            it.setOverlay(activeOverlayState)
            beautyProcessor = it
        }

        // livestream720p: the effect sees the processor behind the exact-input
        // gate, which forwards CameraX's input surface only when it is exactly
        // 1280×720 (or 720×1280 transposed) and otherwise withholds it and
        // fails this bind. The gate is tied to this bind generation.
        val gate: LivestreamInputGate? = if (livestream720p) {
            LivestreamInputGate(bindGeneration, operation, onBound, onFailed)
        } else {
            null
        }
        val effectProcessor: SurfaceProcessor =
            if (gate != null) LivestreamEffectInputProbe(processor, gate) else processor

        val useCaseGroup = androidx.camera.core.UseCaseGroup.Builder()
            .addUseCase(previewUseCase)
            .apply { if (imageCaptureUseCase != null) addUseCase(imageCaptureUseCase) }
            .addUseCase(videoCaptureUseCase)
            .apply {
                if (processor != null) {
                    addEffect(
                        CameraBeautyEffect(
                            CameraEffect.PREVIEW or CameraEffect.VIDEO_CAPTURE,
                            mainExecutor,
                            effectProcessor,
                        )
                    )
                }
            }
            .build()

        // ── Bind to fake LifecycleOwner ───────────────────────────────────────
        // CameraX manages the camera session lifecycle internally.
        // All use-cases bound in one call via UseCaseGroup to include the
        // CameraEffect for the beauty SurfaceProcessor pipeline.
        val boundCamera = try {
            provider.bindToLifecycle(
                lifecycleOwner,
                selector,
                useCaseGroup,
            )
        } catch (e: Exception) {
            // Nothing is bound: release the processor created for this bind and
            // clear the use-case and camera state (the previous camera was
            // unbound above) so the caller's error leaves no leak or stale field.
            processor.release()
            beautyProcessor = null
            camera = null
            preview = null
            imageCapture = null
            videoCapture = null
            if (livestreamExactCandidates == 0) {
                throw IllegalStateException("livestream720p: camera offers no exact 1280×720 (or 720×1280) preview size — refusing to bind", e)
            }
            throw e
        }
        camera = boundCamera

        // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: recreate the actuator against
        // the freshly-bound Camera instance for this bind generation.
        thermalFpsActuator = AndroidCameraXThermalFpsActuator(boundCamera, mainExecutor)

        if (gate != null) {
            // Bound, not yet valid: success is reported by the gate once CameraX
            // delivers an exactly 1280×720 effect input, failure on any other
            // size or after LIVESTREAM_INPUT_GATE_TIMEOUT_MS without one.
            livestreamInputGate = gate
            gate.arm()
            Log.d(TAG, "bindUseCases(profile=$profileLabel) — bound Preview + VideoCapture + BeautyEffect (no ImageCapture); exact 1280×720 input required, awaiting effect-input validation (bind generation ${gate.generation}, timeout ${LIVESTREAM_INPUT_GATE_TIMEOUT_MS} ms)")
        } else {
            Log.d(TAG, "bindUseCases(profile=$profileLabel) — bound Preview + ImageCapture + VideoCapture + BeautyEffect")
            onBound()
        }
    }

    // Gate states of one livestream720p bind (see LivestreamInputGate).
    private enum class LivestreamGateState { PENDING, ACCEPTED, FAILED }

    // livestream720p exact effect-input gate. CameraX hands the shared effect
    // input (the Preview + VideoCapture StreamSharing parent) to this processor
    // on the effect executor (main thread). The input is forwarded to the beauty
    // processor only when it is exactly 1280×720, or 720×1280 when the sensor
    // orientation transposes the same 16:9 raster; any other size (960×540
    // included) is withheld with willNotProvideSurface() and fails the bind.
    // Requests for a superseded bind generation or a failed gate are withheld
    // the same way, and output surfaces are forwarded only once the input of
    // the current generation was accepted — otherwise they are closed here.
    private inner class LivestreamEffectInputProbe(
        private val delegate: SurfaceProcessor,
        private val gate: LivestreamInputGate,
    ) : SurfaceProcessor {
        override fun onInputSurface(request: SurfaceRequest) {
            val size = request.resolution
            val generation = gate.generation
            val exact = isLivestreamExactRaster(size.width, size.height)
            when {
                generation != bindGeneration || gate.state == LivestreamGateState.FAILED || delegate !== beautyProcessor -> {
                    Log.w(TAG, "livestream720p effect input ${size.width}×${size.height} for bind generation $generation is stale (current $bindGeneration, gate ${gate.state}, processor live=${delegate === beautyProcessor}) — surface withheld")
                    request.willNotProvideSurface()
                }
                gate.state == LivestreamGateState.ACCEPTED && exact -> {
                    // CameraX rebuilt its pipeline for this still-current bind:
                    // the same exact input keeps flowing to the processor.
                    Log.i(TAG, "livestream720p effect input ${size.width}×${size.height} re-issued for accepted bind generation $generation — forwarded")
                    delegate.onInputSurface(request)
                }
                gate.state == LivestreamGateState.ACCEPTED -> {
                    // The session already reported success: fail closed. The
                    // teardown (which releases this delegate) runs on the main
                    // thread after this SurfaceProcessor callback has returned.
                    Log.e(TAG, "livestream720p effect input ${size.width}×${size.height} re-issued after acceptance is not the exact 1280×720 raster (720×1280 transposed is the only other accepted size) — surface withheld, session invalidated (bind generation $generation)")
                    request.willNotProvideSurface()
                    val error = IllegalStateException("livestream720p effect input re-issued as ${size.width}×${size.height}, not exactly 1280×720 (or 720×1280 transposed)")
                    mainHandler.post { invalidateSession(generation, error) }
                }
                !exact -> {
                    // Pending gate, wrong size: withhold now; the operation fails
                    // (and tears down) once this callback has returned.
                    Log.e(TAG, "livestream720p effect input ${size.width}×${size.height} is not the exact 1280×720 raster (720×1280 transposed is the only other accepted size) — gate REJECTED, surface withheld (bind generation $generation)")
                    request.willNotProvideSurface()
                    val error = IllegalStateException("livestream720p effect input ${size.width}×${size.height} is not exactly 1280×720 (or 720×1280 transposed)")
                    mainHandler.post { gate.fail(error, cleanUp = true) }
                }
                else -> {
                    Log.i(TAG, "livestream720p effect input ${size.width}×${size.height} — exact 1280×720 raster, gate ACCEPTED (bind generation $generation)")
                    delegate.onInputSurface(request)
                    gate.accept()
                }
            }
        }

        override fun onOutputSurface(surfaceOutput: SurfaceOutput) {
            if (gate.generation == bindGeneration && gate.state == LivestreamGateState.ACCEPTED && delegate === beautyProcessor) {
                delegate.onOutputSurface(surfaceOutput)
            } else {
                val size = surfaceOutput.size
                Log.w(TAG, "livestream720p effect output ${size.width}×${size.height} for bind generation ${gate.generation} without an accepted input (gate ${gate.state}, current generation $bindGeneration) — closed")
                surfaceOutput.close()
            }
        }
    }

    // Exactly-once completion of one livestream720p bind: accepted by the probe
    // (exact input forwarded), or failed by the probe (another size), by the
    // 10 s timeout, or by stop()/suspendCapture()/a rebind cancelling it. The
    // timer is cancelled on every settle, and a settled gate ignores every
    // later accept/fail, so the operation that armed it hears back exactly
    // once. Main thread only.
    private inner class LivestreamInputGate(
        val generation: Int,
        private val operation: String,
        private val onAccepted: () -> Unit,
        private val onFailed: (error: Exception, cleanUp: Boolean) -> Unit,
    ) {
        var state = LivestreamGateState.PENDING
            private set

        private val timeout = Runnable {
            Log.e(TAG, "livestream720p effect input not delivered within ${LIVESTREAM_INPUT_GATE_TIMEOUT_MS} ms — $operation failed (bind generation $generation)")
            fail(
                IllegalStateException("livestream720p: no effect input within ${LIVESTREAM_INPUT_GATE_TIMEOUT_MS} ms ($operation, bind generation $generation)"),
                cleanUp = true,
            )
        }

        fun arm() {
            mainHandler.postDelayed(timeout, LIVESTREAM_INPUT_GATE_TIMEOUT_MS)
        }

        fun accept() {
            if (!settle(LivestreamGateState.ACCEPTED)) return
            onAccepted()
        }

        fun fail(error: Exception, cleanUp: Boolean) {
            if (!settle(LivestreamGateState.FAILED)) return
            onFailed(error, cleanUp)
        }

        private fun settle(next: LivestreamGateState): Boolean {
            if (state != LivestreamGateState.PENDING) return false
            state = next
            mainHandler.removeCallbacks(timeout)
            if (livestreamInputGate === this) livestreamInputGate = null
            return true
        }
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

        // Negotiated size (proof gate reads this; the profile only requests).
        Log.d(TAG, "provideSurface(profile=${captureProfile ?: "default"}): SurfaceRequest.resolution=${size.width}×${size.height} → Flutter textureId=${textureEntry.id()}")
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
     *
     * A start() still waiting for its camera provider, or a livestream720p bind
     * still awaiting its exact-input validation, is an owned session with
     * [isRunning] still false: it is torn down here all the same (lifecycle
     * destroyed, nothing bound), and the start/switch/resume behind it is
     * reported once, as an error. The provider listener of a cancelled start
     * then does nothing, so no bind ever follows against a released texture.
     */
    fun stop() {
        // Always set stopRequested — the session is stopping for every later
        // caller (thermal apply, suspend/resume) even when nothing was bound.
        stopRequested = true

        val pendingGate = livestreamInputGate
        val startAttempt = pendingStart
        if (!isRunning && pendingGate == null && startAttempt == null) {
            Log.d(TAG, "stop() called on already-stopped camera — state cleared, no-op for CameraX")
            return
        }
        if (startAttempt != null) {
            Log.w(TAG, "stop() — cancelling the start() whose camera provider lookup is still in flight")
        }
        if (pendingGate != null) {
            Log.w(TAG, "stop() — cancelling the pending livestream720p exact-input gate (bind generation ${pendingGate.generation})")
        }
        Log.d(TAG, "stop() — unbinding all use-cases")
        teardownSession()
        // Resolve the pending operation exactly once, after the teardown, so its
        // callback observes a stopped source. cleanUp=false: done just above.
        pendingGate?.fail(
            IllegalStateException("camera stopped before livestream720p exact-input validation completed"),
            cleanUp = false,
        )
        startAttempt?.reportError(IllegalStateException("camera stopped while the camera provider was starting"))

        Log.d(TAG, "stop() — complete")
    }

    // Full teardown shared by stop(), a failed start()/switchCamera() and
    // invalidateSession(): ends any recording, destroys the fake lifecycle,
    // unbinds everything, releases the processor and clears every
    // session/readiness/use-case field. Afterwards isTornDown is true and the
    // owner is expected to drop this source.
    private fun teardownSession() {
        tornDown = true
        pendingStart = null

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
        captureSuspended = false
        firstFrameListener.set(null)

        // P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: deliberately do NOT cancel a
        // still-in-flight thermal FPS actuation here -- that would suppress
        // its caller's MethodChannel result. Just drop this source's
        // reference; the orphaned actuator's own future/timeout keeps running
        // and reaches applyThermalTargetFps()'s stopped-check branch below,
        // which still replies exactly once (STOPPED).
        thermalFpsActuator = null
    }

    // Unbinds the current use cases and releases the processor while keeping
    // isRunning, the provider, the lifecycle owner, the Flutter texture and all
    // beauty/color/green-screen/overlay state: the suspended shape that
    // suspendCapture() establishes and that a rejected/timed-out
    // resumeCapture() bind falls back to (a failed switchCamera() tears the
    // whole source down instead). Main thread only.
    private fun unbindSession() {
        firstFrameListener.set(null)
        cameraProvider?.unbindAll()
        beautyProcessor?.release()
        beautyProcessor = null
        camera = null
        preview = null
        imageCapture = null
        videoCapture = null
        thermalFpsActuator = null
        cameraReadyFlag = false
    }

    // Fails an already-accepted livestream720p session closed: CameraX re-issued
    // its effect input at a size other than 1280×720/720×1280 after start or
    // switch reported success. Runs on the main thread after the
    // SurfaceProcessor callback that detected it has returned. Tears the source
    // down once — only while that bind generation is still the live, running
    // session — and tells the owner through onSessionInvalidated; no
    // MethodChannel result is pending for it any more.
    private fun invalidateSession(generation: Int, error: Exception) {
        if (tornDown || !isRunning || captureSuspended || generation != bindGeneration) {
            Log.w(TAG, "invalidateSession(bind generation $generation) ignored — stale (current $bindGeneration, running=$isRunning, suspended=$captureSuspended, tornDown=$tornDown): ${error.message}")
            return
        }
        Log.e(TAG, "invalidateSession(bind generation $generation) — tearing the session down: ${error.message}")
        teardownSession()
        onSessionInvalidated?.invoke(error)
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
     *   new camera session is live. For [CAPTURE_PROFILE_LIVESTREAM_720P] that
     *   is only after the rebound session's exact effect-input validation.
     * @param onError Called once if the bind throws or the exact-input gate
     *   rejects or times out — the previous camera is already unbound by then,
     *   so the source is fully torn down first ([isTornDown] is true) and the
     *   owner must drop it — or, with the source left untouched (lens not
     *   flipped, nothing scheduled), when the camera is still starting, another
     *   validation is still pending, or the source is already torn down.
     */
    fun switchCamera(
        onStarted: () -> Unit = {},
        onError: (Exception) -> Unit = {},
    ) {
        // One bind validation at a time: a livestream720p bind still awaiting
        // its exact-input gate is neither superseded nor flipped underneath.
        val pendingGate = livestreamInputGate
        if (pendingGate != null) {
            Log.w(TAG, "switchCamera() — rejected: livestream720p exact-input validation pending (bind generation ${pendingGate.generation})")
            onError(IllegalStateException("switchCamera: livestream720p exact-input validation still pending"))
            return
        }
        // A start whose provider lookup is still in flight owns the session:
        // flipping the lens or scheduling a second start would race its bind
        // (or its cancellation) and its single MethodChannel reply.
        if (pendingStart != null) {
            Log.w(TAG, "switchCamera() — rejected: camera is still starting (provider lookup in flight)")
            onError(IllegalStateException("switchCamera: camera is still starting"))
            return
        }
        if (tornDown) {
            Log.w(TAG, "switchCamera() — rejected: camera source is torn down")
            onError(IllegalStateException("switchCamera: camera source is torn down"))
            return
        }
        Log.d(TAG, "switchCamera() — flipping lens")
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK)
            CameraSelector.LENS_FACING_FRONT
        else
            CameraSelector.LENS_FACING_BACK

        // I1: while capture is suspended (livestream image mode) only the lens
        // choice changes; resumeCapture() binds with the new selector. Binding
        // here would silently bring the camera hardware back.
        if (captureSuspended) {
            Log.i(TAG, "switchCamera() — capture suspended; lens recorded, rebind deferred to resumeCapture()")
            onStarted()
            return
        }

        // Re-bind use-cases with the new selector.
        // We do NOT call stop()/start() because that would destroy and recreate
        // the LifecycleRegistry (causing a brief black frame). Instead we
        // call bindUseCases() directly with the existing provider so the
        // transition is as fast as possible.
        val provider = cameraProvider
        if (provider == null) {
            // Never started (a torn-down or starting source was refused above):
            // start now with the flipped lens.
            start(onStarted, onError)
            return
        }

        // From the first line of bindUseCases() the previous camera is unbound,
        // so every failure past this point leaves no usable session: tear the
        // source down fully (isTornDown) before the single error callback, so
        // the owner drops it instead of keeping a "running" shell with stale
        // camera/processor state.
        try {
            bindUseCases(
                provider,
                operation = "switchCamera",
                onBound = {
                    onStarted()
                    Log.d(TAG, "switchCamera() — complete; lensNow=${if (lensFacing == CameraSelector.LENS_FACING_FRONT) "FRONT" else "BACK"}")
                },
                onFailed = { e, cleanUp ->
                    if (cleanUp) teardownSession()
                    Log.e(TAG, "switchCamera() — livestream720p exact-input gate failed; session torn down: $e")
                    onError(e)
                },
            )
        } catch (e: Exception) {
            Log.e(TAG, "switchCamera() — bindUseCases failed; session torn down: $e")
            teardownSession()
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

    /**
     * F2: Sets or clears the active camera green-screen state.
     * Thread-safe: stored in [activeGreenScreenState] and forwarded to the GPU
     * processor's volatile field. State is kept across camera restarts/rebinds
     * so the green screen is reapplied automatically.
     */
    fun setGreenScreen(state: CameraGreenScreenState?) {
        activeGreenScreenState = state
        beautyProcessor?.setGreenScreen(state)
        Log.d(TAG, "setGreenScreen: enabled=${state?.enabled} type=${state?.backgroundType}")
    }

    /**
     * F2: Hot-update green-screen parameters. Returns false if no active state exists
     * or the update fails validation. Merges [params] into the active state.
     */
    fun updateGreenScreenParameters(params: Map<*, *>): Boolean {
        val current = activeGreenScreenState ?: return false
        return try {
            val updated = current.mergeUpdates(params)
            setGreenScreen(updated)
            true
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "updateGreenScreenParameters rejected: ${e.message}")
            false
        }
    }

    /**
     * G1-B: Sets or clears the active livestream overlay list (null or an
     * inactive state clears every overlay). Thread-safe: stored in
     * [activeOverlayState] and forwarded to the GPU processor's volatile field;
     * kept across camera restarts/rebinds so the overlays are reapplied.
     */
    fun setOverlay(state: CameraOverlayState?) {
        activeOverlayState = state
        beautyProcessor?.setOverlay(state)
        Log.d(TAG, "setOverlay: active=${state?.isActive == true} items=${state?.items?.size ?: 0}")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I1 livestream media source: capture suspension / resumption
    // ─────────────────────────────────────────────────────────────────────────

    /** True between [suspendCapture] and [resumeCapture]. Main thread. */
    val isCaptureSuspended: Boolean get() = captureSuspended

    /** The overlay list currently applied to this source (reapplied on every rebind). */
    val currentOverlayState: CameraOverlayState? get() = activeOverlayState

    /**
     * Suspends camera capture without ending the session: unbinds every use
     * case (CameraX closes the camera device) and releases the beauty
     * processor, keeping [isRunning], the provider, the lifecycle owner, the
     * Flutter texture and all beauty/color/green-screen/overlay state so
     * [resumeCapture] can rebind exactly as [switchCamera] does. Any egress
     * surface must already be detached by the caller (the processor is gone).
     *
     * Returns false (nothing changed) when the session is not running or is
     * stopping, has no provider, or a recording is active. Idempotent while
     * suspended. A switchCamera()/resumeCapture() bind still awaiting its
     * livestream720p exact-input validation is unbound here like a live
     * session and its operation is reported once, as an error. Main thread only.
     */
    fun suspendCapture(): Boolean {
        if (!isRunning || stopRequested) {
            Log.w(TAG, "suspendCapture rejected: session not running")
            return false
        }
        val pendingGate = livestreamInputGate
        if (captureSuspended && pendingGate == null) return true
        val provider = cameraProvider
        if (provider == null) {
            Log.w(TAG, "suspendCapture rejected: no camera provider")
            return false
        }
        if (isRecording) {
            Log.w(TAG, "suspendCapture rejected: recording active")
            return false
        }
        if (pendingGate != null) {
            Log.w(TAG, "suspendCapture — cancelling the pending livestream720p exact-input gate (bind generation ${pendingGate.generation})")
        }
        unbindSession()
        captureSuspended = true
        pendingGate?.fail(
            IllegalStateException("capture suspended before livestream720p exact-input validation completed"),
            cleanUp = false,
        )
        Log.i(TAG, "suspendCapture — use-cases unbound, processor released; beauty/GS/overlay state retained")
        return true
    }

    /**
     * Rebinds the use cases after [suspendCapture] through [bindUseCases]
     * (same path as [switchCamera]: fresh beauty processor with the retained
     * beauty/color/green-screen/overlay state). [onFirstFrame] runs once, on
     * the main thread, when the Camera2 session reports its first completed
     * capture — for [CAPTURE_PROFILE_LIVESTREAM_720P] only after the exact
     * effect-input validation has also passed. [onError] runs once when the
     * resume is refused or the bind throws (synchronously), or when the
     * exact-input gate rejects or times out (asynchronously); in every case
     * the source stays suspended and a later resume may retry. Main thread.
     */
    fun resumeCapture(
        onFirstFrame: () -> Unit,
        onError: (Exception) -> Unit,
    ) {
        if (!captureSuspended) {
            onError(IllegalStateException("resumeCapture: capture is not suspended"))
            return
        }
        if (!isRunning || stopRequested) {
            onError(IllegalStateException("resumeCapture: camera session not running"))
            return
        }
        if (livestreamInputGate != null) {
            onError(IllegalStateException("resumeCapture: livestream720p exact-input validation still pending"))
            return
        }
        val provider = cameraProvider
        if (provider == null) {
            onError(IllegalStateException("resumeCapture: no camera provider"))
            return
        }
        cameraReadyFlag = false
        try {
            bindUseCases(
                provider,
                operation = "resumeCapture",
                onBound = {
                    captureSuspended = false
                    // The first frame needs both the (now passed) input
                    // validation and a completed capture: arm the one-shot
                    // listener, and fire it here if a capture already completed.
                    firstFrameListener.set(onFirstFrame)
                    if (cameraReadyFlag) {
                        firstFrameListener.getAndSet(null)?.let { listener -> mainExecutor.execute { listener() } }
                    }
                    Log.i(TAG, "resumeCapture — use-cases rebound; waiting for the first completed capture")
                },
                onFailed = { e, cleanUp ->
                    firstFrameListener.set(null)
                    if (cleanUp) unbindSession()
                    Log.e(TAG, "resumeCapture — livestream720p exact-input gate failed; capture stays suspended: $e")
                    onError(e)
                },
            )
        } catch (e: Exception) {
            firstFrameListener.set(null)
            Log.e(TAG, "resumeCapture — bindUseCases failed: $e")
            onError(e)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Processed-frame egress delegation (LiveKit bridge Slice C → processor Slice A)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Forwards an egress [surface] to the live beauty processor, which renders
     * the already-processed frame into it at [width]x[height] (see
     * [AndroidCameraBeautySurfaceProcessor.attachEgressSurface]). Returns false
     * when no processor exists yet (camera not started) or the processor
     * rejects the request up-front; a later GPU-side failure drops the egress
     * without affecting the preview.
     */
    fun attachEgressSurface(surface: Surface, width: Int, height: Int, mirror: Boolean): Boolean {
        val processor = beautyProcessor
        if (processor == null) {
            Log.w(
                TAG,
                "attachEgressSurface: beautyProcessor is null " +
                    (if (captureSuspended) "(capture suspended)" else "(camera not started)"),
            )
            return false
        }
        return processor.attachEgressSurface(surface, width, height, mirror)
    }

    /** Detaches any egress surface from the live beauty processor. Safe when none is bound. */
    fun detachEgressSurface() {
        beautyProcessor?.detachEgressSurface()
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
     * True once this source has torn itself down (stop(), a failed start or
     * switch, or an invalidated session) and owns no camera, processor or
     * lifecycle any more. Owners drop such a source instead of reusing it.
     */
    val isTornDown: Boolean get() = tornDown

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
