package com.connects.vanguard_media_engine

// ── AndroidVanguardLiveKitBridge ─────────────────────────────────────────────
//
// Slice C of the Android Vanguard → LiveKit bridge contract: the Android side
// of the MethodChannel "vanguard_livekit_bridge" (attachVanguardToLiveKitTrack /
// detachVanguard / getStats), mirroring the iOS VanguardRTCVideoCapturer
// channel contract that Dart already talks to on both platforms (Slice B).
//
// Data path once attached:
//   Vanguard processor → egress Surface (720x1280, Slice A)
//     → flutter_webrtc SurfaceTextureHelper (our VideoSink)
//     → LocalVideoTrack.onFrameCaptured(frame) → WebRTC encoder → LiveKit.
//
// Why the WebRTC side is reached by reflection: this module has no compile-time
// dependency on flutter_webrtc or the WebRTC SDK (android/build.gradle), and
// adding one is outside this slice. At runtime every Flutter plugin shares the
// app class loader, so the classes are present. The access points are exactly
// the ones named by the contract:
//   public   FlutterWebRTCPlugin.sharedSingleton, FlutterWebRTCPlugin.getLocalTrack(trackId)
//   public   GetUserMediaImpl.getCapturerInfo(trackId), VideoCapturerInfo.{capturer,width,height,fps}
//   public   SurfaceTextureHelper.{stopListening,setTextureSize,getSurfaceTexture,startListening}
//   public   LocalVideoTrack.onFrameCaptured(VideoFrame), VideoCapturer.{stopCapture,startCapture}
//   private  FlutterWebRTCPlugin.methodCallHandler, MethodCallHandlerImpl.getUserMediaImpl,
//            GetUserMediaImpl.mSurfaceTextureHelpers
// Every member is resolved and validated before any side effect, so a missing
// or renamed member fails closed without touching the stock capturer.
// GetUserMediaImpl.removeVideoCapturer is deliberately never called: it
// disposes the capturer and the SurfaceTextureHelper the track still needs.
//
// Threading: all bridge state is owned by the main thread (MethodChannel
// calls and the settle/retry handler both run there). The only cross-thread
// touch is the VideoSink proxy, which runs on the helper's thread and updates
// framesDelivered (volatile) and forwards frames to the track.
//
// Debug/POC only: no R8 keep rules exist for these names yet (contract Slice E).
//
// ── Virtual camera provider (Option C, local flutter_webrtc fork) ────────────
//
// When the app's flutter_webrtc exposes the external video source SPI
// (com.cloudwebrtc.webrtc.ExternalVideoSourceProvider +
// FlutterWebRTCPlugin.registerExternalVideoSourceProvider), this bridge
// registers itself for deviceId "vanguard_virtual_camera". A LiveKit
// createCameraTrack with that deviceId then never opens a stock camera:
// flutter_webrtc creates the track, its SurfaceTextureHelper and a Surface, and
// calls onStart(trackId, surface, framesDelivered); the bridge hands that
// Surface to the Vanguard egress seam (720x1280, rotation 0, unmirrored).
// Track dispose calls onStop, which detaches the egress; flutter_webrtc
// releases the Surface/helper after its grace delay. Only public SPI members
// are bound (Class.forName + getMethod, and a Proxy for the interface), so this
// module still builds and runs against a stock flutter_webrtc, where the
// provider is simply not registered and Dart falls back to the attach path
// above.

import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Field
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.concurrent.atomic.AtomicLong

/** What the bridge needs from the engine: the active camera's egress seam. */
internal interface VanguardEgressHost {
    val isCameraActive: Boolean
    fun attachEgressSurface(surface: Surface, width: Int, height: Int, mirror: Boolean): Boolean
    fun detachEgressSurface()
}

internal class AndroidVanguardLiveKitBridge(
    messenger: BinaryMessenger,
    private val host: VanguardEgressHost,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "vanguard_livekit_bridge"
        private const val TAG = "VGLiveKitBridge"

        const val EGRESS_WIDTH = 720
        const val EGRESS_HEIGHT = 1280

        // Slice C policy: remote egress is never mirrored, and front-camera
        // mirroring is deliberately not inferred here.
        const val EGRESS_MIRROR = false

        // stopCapture() only posts the stock session's stop onto the camera
        // thread; that stop calls SurfaceTextureHelper.stopListening() itself,
        // which would silently clear a sink registered too early. Steps 4-8 of
        // the attach therefore run after this settle delay, retried a bounded
        // number of times if the helper still reports a listener.
        private const val STOP_SETTLE_MS = 400L
        private const val MAX_LISTENER_ATTEMPTS = 3

        // Give the GPU thread time to destroy its EGL surface (Slice A posts
        // that on detach) before the wrapper Surface is released.
        private const val SURFACE_RELEASE_DELAY_MS = 200L

        /** deviceId the livestream passes to LiveKit's createCameraTrack. */
        const val VIRTUAL_CAMERA_DEVICE_ID = "vanguard_virtual_camera"
        const val VIRTUAL_CAMERA_FPS = 30

        private const val SPI_PROVIDER_CLASS = "com.cloudwebrtc.webrtc.ExternalVideoSourceProvider"
        private const val SPI_PLUGIN_CLASS = "com.cloudwebrtc.webrtc.FlutterWebRTCPlugin"
    }

    private val channel: MethodChannel = MethodChannel(messenger, CHANNEL_NAME).also {
        it.setMethodCallHandler(this)
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Virtual camera provider state (main thread) ──────────────────────────
    private var virtualTrackId: String? = null
    private var virtualFramesDelivered: AtomicLong? = null
    private var providerRegistration: ProviderRegistration? = null  // set in init, after all state

    // ── Bridge-owned attached state (main thread) ────────────────────────────
    private var attachedTrackId: String? = null
    private var attachedHelper: Any? = null      // org.webrtc.SurfaceTextureHelper
    private var attachedSurface: Surface? = null // wrapper we created around the helper's SurfaceTexture
    private var attachedSink: Any? = null        // our org.webrtc.VideoSink proxy
    private var reflection: WebRtcReflection? = null

    @Volatile private var framesDelivered: Long = 0L
    @Volatile private var sinkErrorLogged: Boolean = false

    // ── In-flight attach (between stopCapture() and the sink registration) ───
    private class PendingAttach(
        val trackId: String,
        val refs: WebRtcReflection,
        val localTrack: Any,
        val capturerInfo: Any,
        val capturer: Any,
        val helper: Any,
        val result: MethodChannel.Result,
        var attemptsLeft: Int,
    )

    private var pendingAttach: PendingAttach? = null
    private val continueAttachRunnable = Runnable { continueAttach() }

    init {
        // Last: every property above is initialized before flutter_webrtc can
        // call the provider.
        providerRegistration = registerVirtualCameraProvider()
    }

    // ── MethodChannel ────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "attachVanguardToLiveKitTrack" -> attach(call, result)
            "detachVanguard" -> {
                stopVirtualEgress(reason = "detachVanguard")
                detachInternal(reason = "detachVanguard")
                result.success(mapOf("status" to "detached"))
            }
            "getStats" -> result.success(stats())
            else -> result.notImplemented()
        }
    }

    /** Engine teardown: detach bridge-owned state, then drop the channel. */
    fun dispose() {
        providerRegistration?.unregister()
        providerRegistration = null
        stopVirtualEgress(reason = "engine detached")
        detachInternal(reason = "engine detached", releaseSurfaceImmediately = true)
        channel.setMethodCallHandler(null)
    }

    private fun stats(): Map<String, Any?> {
        val virtualId = virtualTrackId
        if (virtualId != null) {
            return mapOf(
                "isStreaming" to true,
                "framesDelivered" to (virtualFramesDelivered?.get() ?: 0L),
                "trackId" to virtualId,
                "mode" to "virtual",
            )
        }
        return mapOf(
            "isStreaming" to (attachedTrackId != null),
            "framesDelivered" to framesDelivered,
            "trackId" to attachedTrackId,
            "mode" to if (attachedTrackId != null) "attached" else "idle",
        )
    }

    // ── Virtual camera provider (flutter_webrtc external video source SPI) ────

    /** The public SPI binding: the Proxy we registered and how to unregister it. */
    private class ProviderRegistration(
        private val unregisterMethod: Method,
        private val proxy: Any,
    ) {
        fun unregister() {
            try {
                unregisterMethod.invoke(null, VIRTUAL_CAMERA_DEVICE_ID, proxy)
                Log.i(TAG, "virtual camera provider unregistered")
            } catch (e: Exception) {
                Log.w(TAG, "virtual camera provider unregister failed: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    // Binds only public SPI members; returns null (legacy attach path only)
    // when this app's flutter_webrtc does not provide the SPI.
    private fun registerVirtualCameraProvider(): ProviderRegistration? {
        val loader = javaClass.classLoader
        val providerInterface: Class<*>
        val registerMethod: Method
        val unregisterMethod: Method
        try {
            providerInterface = Class.forName(SPI_PROVIDER_CLASS, true, loader)
            val pluginClass = Class.forName(SPI_PLUGIN_CLASS, true, loader)
            registerMethod = pluginClass.getMethod(
                "registerExternalVideoSourceProvider", String::class.java, providerInterface,
            )
            unregisterMethod = pluginClass.getMethod(
                "unregisterExternalVideoSourceProvider", String::class.java, providerInterface,
            )
        } catch (e: ReflectiveOperationException) {
            Log.i(TAG, "flutter_webrtc external video source SPI not present; virtual camera unavailable (${e.javaClass.simpleName})")
            return null
        }
        val proxy = Proxy.newProxyInstance(providerInterface.classLoader, arrayOf(providerInterface)) { proxy, method, args ->
            when (method.name) {
                "getOutputFormat" -> intArrayOf(EGRESS_WIDTH, EGRESS_HEIGHT, VIRTUAL_CAMERA_FPS)
                "onStart" -> startVirtualEgress(
                    trackId = args?.getOrNull(0) as? String,
                    surface = args?.getOrNull(1) as? Surface,
                    counter = args?.getOrNull(2) as? AtomicLong,
                )
                "onStop" -> {
                    (args?.getOrNull(0) as? String)?.let { onVirtualTrackStopped(it) }
                    null
                }
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "VanguardVirtualCameraProvider"
                else -> null
            }
        }
        return try {
            registerMethod.invoke(null, VIRTUAL_CAMERA_DEVICE_ID, proxy)
            Log.i(TAG, "virtual camera provider registered for deviceId $VIRTUAL_CAMERA_DEVICE_ID")
            ProviderRegistration(unregisterMethod, proxy)
        } catch (e: Exception) {
            Log.e(TAG, "virtual camera provider registration failed: ${describe(e)}")
            null
        }
    }

    // Main thread (flutter_webrtc getUserMedia). Returns false to refuse the
    // track; flutter_webrtc then fails getUserMedia without opening a camera.
    private fun startVirtualEgress(trackId: String?, surface: Surface?, counter: AtomicLong?): Boolean {
        if (trackId.isNullOrBlank() || surface == null || counter == null) {
            Log.e(TAG, "virtual camera onStart rejected: invalid arguments")
            return false
        }
        if (Looper.myLooper() != Looper.getMainLooper()) {
            Log.e(TAG, "virtual camera onStart rejected: not on the main thread")
            return false
        }
        if (!host.isCameraActive) {
            Log.e(TAG, "virtual camera onStart rejected for $trackId: Vanguard camera is not running")
            return false
        }
        // One egress at a time: a legacy attach or an earlier virtual track
        // (e.g. a LiveKit restartTrack) gives way to the new track.
        stopVirtualEgress(reason = "virtual track $trackId starting")
        detachInternal(reason = "virtual track $trackId starting")
        if (!host.attachEgressSurface(surface, EGRESS_WIDTH, EGRESS_HEIGHT, EGRESS_MIRROR)) {
            Log.e(TAG, "virtual camera onStart rejected for $trackId: Vanguard egress attach was rejected")
            return false
        }
        virtualTrackId = trackId
        virtualFramesDelivered = counter
        Log.i(TAG, "virtual camera started for track $trackId: egress ${EGRESS_WIDTH}x${EGRESS_HEIGHT} mirror=$EGRESS_MIRROR (no stock capturer)")
        return true
    }

    // Main thread (flutter_webrtc track/stream dispose). flutter_webrtc owns and
    // releases the Surface after this returns (with a grace delay).
    private fun onVirtualTrackStopped(trackId: String) {
        if (trackId != virtualTrackId) {
            Log.i(TAG, "virtual camera onStop for $trackId ignored (active: $virtualTrackId)")
            return
        }
        stopVirtualEgress(reason = "track $trackId disposed")
    }

    // Main thread. Idempotent. Detaches the Vanguard egress from the virtual
    // track's Surface; the Surface itself belongs to flutter_webrtc.
    private fun stopVirtualEgress(reason: String) {
        val trackId = virtualTrackId ?: return
        try {
            host.detachEgressSurface()
        } catch (e: Exception) {
            Log.w(TAG, "virtual camera: detachEgressSurface failed: ${describe(e)}")
        }
        Log.i(TAG, "virtual camera stopped for track $trackId ($reason) after ${virtualFramesDelivered?.get() ?: 0L} frames")
        virtualTrackId = null
        virtualFramesDelivered = null
    }

    // ── Attach ───────────────────────────────────────────────────────────────

    private fun attach(call: MethodCall, result: MethodChannel.Result) {
        val trackId = call.argument<String>("trackId")?.takeIf { it.isNotBlank() }

        // Step 1: an active Vanguard camera source must exist.
        if (!host.isCameraActive) {
            result.error("NO_ACTIVE_CAMERA", "Vanguard camera is not running", null)
            return
        }
        if (trackId == null) {
            result.error("INVALID_TRACK_ID", "trackId is required", null)
            return
        }
        if (attachedTrackId == trackId) {
            // Idempotent: already attached to this track.
            result.success(mapOf("status" to "attached", "trackId" to trackId, "framesDelivered" to framesDelivered))
            return
        }
        if (virtualTrackId == trackId) {
            // Already fed through the virtual camera provider; there is no
            // stock capturer to take over.
            result.success(
                mapOf(
                    "status" to "attached",
                    "trackId" to trackId,
                    "framesDelivered" to (virtualFramesDelivered?.get() ?: 0L),
                    "mode" to "virtual",
                ),
            )
            return
        }
        // A legacy attach replaces any virtual egress (one egress at a time).
        stopVirtualEgress(reason = "legacy attach to $trackId")
        if (pendingAttach != null) {
            result.error("ATTACH_IN_PROGRESS", "An attach is already in progress", null)
            return
        }
        if (attachedTrackId != null) {
            // A different track: tear the previous attach down first.
            detachInternal(reason = "re-attach to $trackId")
        }

        // Step 2: resolve and validate everything before any side effect.
        val refs = reflection ?: try {
            WebRtcReflection.resolve(javaClass.classLoader).also { reflection = it }
        } catch (e: Exception) {
            Log.e(TAG, "flutter_webrtc internals unavailable: ${describe(e)}")
            result.error("WEBRTC_INTERNALS_UNAVAILABLE", describe(e), null)
            return
        }
        val localTrack: Any
        val capturerInfo: Any
        val capturer: Any
        val helper: Any
        try {
            val plugin = refs.sharedSingletonField.get(null)
                ?: throw IllegalStateException("FlutterWebRTCPlugin.sharedSingleton is null")
            localTrack = refs.getLocalTrackMethod.invoke(plugin, trackId)
                ?: throw IllegalStateException("Track $trackId not found in flutter_webrtc local tracks")
            if (!refs.localVideoTrackClass.isInstance(localTrack)) {
                throw IllegalStateException("Track $trackId is not a LocalVideoTrack")
            }
            val handler = refs.methodCallHandlerField.get(plugin)
                ?: throw IllegalStateException("FlutterWebRTCPlugin.methodCallHandler is null")
            val getUserMedia = refs.getUserMediaImplField.get(handler)
                ?: throw IllegalStateException("MethodCallHandlerImpl.getUserMediaImpl is null")
            capturerInfo = refs.getCapturerInfoMethod.invoke(getUserMedia, trackId)
                ?: throw IllegalStateException("No VideoCapturerInfo for track $trackId")
            capturer = refs.capturerField.get(capturerInfo)
                ?: throw IllegalStateException("VideoCapturerInfo.capturer is null for track $trackId")
            val helpers = refs.surfaceTextureHelpersField.get(getUserMedia) as? Map<*, *>
                ?: throw IllegalStateException("GetUserMediaImpl.mSurfaceTextureHelpers is unavailable")
            helper = helpers[trackId]
                ?: throw IllegalStateException("No SurfaceTextureHelper for track $trackId")
        } catch (e: Exception) {
            val message = describe(e)
            Log.e(TAG, "attach validation failed for $trackId: $message")
            result.error("ATTACH_VALIDATION_FAILED", message, null)
            return
        }

        // Step 3: stop the stock capturer — the first side effect.
        try {
            refs.stopCaptureMethod.invoke(capturer)
        } catch (e: Exception) {
            // stopCapture() threw; the session may or may not be stopping. Treat
            // as post-stop and roll back so the stock path is restored.
            Log.e(TAG, "stopCapture() failed for $trackId: ${describe(e)}")
            rollbackAfterStop(refs, helper, null, capturerInfo, capturer)
            result.error("STOCK_CAPTURER_STOP_FAILED", describe(e), null)
            return
        }
        Log.i(TAG, "stock capturer stop requested for track $trackId; settling ${STOP_SETTLE_MS}ms")

        // Steps 4-8 run after the stock session's own stop has had time to run.
        pendingAttach = PendingAttach(
            trackId = trackId,
            refs = refs,
            localTrack = localTrack,
            capturerInfo = capturerInfo,
            capturer = capturer,
            helper = helper,
            result = result,
            attemptsLeft = MAX_LISTENER_ATTEMPTS,
        )
        mainHandler.postDelayed(continueAttachRunnable, STOP_SETTLE_MS)
    }

    // Main thread. Steps 4-8; replies to the pending attach result.
    private fun continueAttach() {
        val pending = pendingAttach ?: return
        val refs = pending.refs
        var surface: Surface? = null
        try {
            if (!host.isCameraActive) {
                throw IllegalStateException("Vanguard camera stopped while attaching")
            }

            // Step 4: defensive — also clears a stock session listener that
            // is still set if its stop has not run yet.
            refs.stopListeningMethod.invoke(pending.helper)

            // Step 5: the helper's SurfaceTexture takes 720x1280 buffers.
            refs.setTextureSizeMethod.invoke(pending.helper, EGRESS_WIDTH, EGRESS_HEIGHT)

            // Step 6: wrap the helper's SurfaceTexture in a Surface we own.
            val surfaceTexture = refs.getSurfaceTextureMethod.invoke(pending.helper) as? SurfaceTexture
                ?: throw IllegalStateException("SurfaceTextureHelper returned no SurfaceTexture")
            surface = Surface(surfaceTexture)

            // Step 7: our VideoSink forwards every helper frame into the track.
            val sink = createVideoSink(refs, pending.localTrack)
            try {
                refs.startListeningMethod.invoke(pending.helper, sink)
            } catch (e: InvocationTargetException) {
                val cause = e.targetException
                if (cause is IllegalStateException && pending.attemptsLeft > 0) {
                    // "listener has already been set": the stock session's stop
                    // has not reached the helper yet. Wait and try again.
                    pending.attemptsLeft--
                    surface.release()
                    Log.w(TAG, "helper still has a listener; retrying (${pending.attemptsLeft} left)")
                    mainHandler.postDelayed(continueAttachRunnable, STOP_SETTLE_MS)
                    return
                }
                throw e
            }

            // Step 8: hand the surface to the Vanguard processor (binds on the GPU thread).
            if (!host.attachEgressSurface(surface, EGRESS_WIDTH, EGRESS_HEIGHT, EGRESS_MIRROR)) {
                throw IllegalStateException("Vanguard egress attach was rejected")
            }

            attachedTrackId = pending.trackId
            attachedHelper = pending.helper
            attachedSurface = surface
            attachedSink = sink
            framesDelivered = 0L
            sinkErrorLogged = false
            pendingAttach = null
            Log.i(TAG, "attached track ${pending.trackId}: egress ${EGRESS_WIDTH}x${EGRESS_HEIGHT} mirror=$EGRESS_MIRROR")
            pending.result.success(
                mapOf("status" to "attached", "trackId" to pending.trackId, "framesDelivered" to 0L),
            )
        } catch (e: Exception) {
            pendingAttach = null
            val message = describe(e)
            Log.e(TAG, "attach failed after stock capturer stop for ${pending.trackId}: $message")
            rollbackAfterStop(refs, pending.helper, surface, pending.capturerInfo, pending.capturer)
            pending.result.error(
                "ATTACH_FAILED",
                "Attach failed after stopping the stock capturer; rolled back: $message",
                null,
            )
        }
    }

    private fun createVideoSink(refs: WebRtcReflection, localTrack: Any): Any {
        val onFrameCaptured = refs.onFrameCapturedMethod
        return Proxy.newProxyInstance(
            refs.videoSinkClass.classLoader,
            arrayOf(refs.videoSinkClass),
        ) { proxy, method, args ->
            when (method.name) {
                "onFrame" -> {
                    val frame = args?.getOrNull(0)
                    if (frame != null) {
                        try {
                            onFrameCaptured.invoke(localTrack, frame)
                            framesDelivered++
                        } catch (e: Exception) {
                            if (!sinkErrorLogged) {
                                sinkErrorLogged = true
                                Log.e(TAG, "onFrameCaptured failed (logged once): ${describe(e)}")
                            }
                        }
                    }
                    null
                }
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "VanguardEgressVideoSink"
                else -> null
            }
        }
    }

    // ── Rollback / detach ────────────────────────────────────────────────────

    // Main thread. Undoes everything done after stopCapture(), then best-effort
    // restarts the stock capturer so the LiveKit track keeps publishing.
    private fun rollbackAfterStop(
        refs: WebRtcReflection,
        helper: Any,
        surface: Surface?,
        capturerInfo: Any,
        capturer: Any,
    ) {
        try {
            host.detachEgressSurface()
        } catch (e: Exception) {
            Log.w(TAG, "rollback: detachEgressSurface failed: ${describe(e)}")
        }
        try {
            refs.stopListeningMethod.invoke(helper)
        } catch (e: Exception) {
            Log.w(TAG, "rollback: stopListening failed: ${describe(e)}")
        }
        try {
            surface?.release()
        } catch (e: Exception) {
            Log.w(TAG, "rollback: surface release failed: ${describe(e)}")
        }
        try {
            val width = refs.widthField.getInt(capturerInfo)
            val height = refs.heightField.getInt(capturerInfo)
            val fps = refs.fpsField.getInt(capturerInfo)
            refs.startCaptureMethod.invoke(capturer, width, height, fps)
            Log.w(TAG, "rollback: stock capturer restarted ${width}x${height}@$fps")
        } catch (e: Exception) {
            Log.e(TAG, "rollback: stock capturer restart failed: ${describe(e)}")
        }
    }

    // Main thread. Idempotent; releases only bridge-owned listener/Surface state.
    // The stock capturer is never restarted here: the caller is tearing the
    // stream (and its track) down.
    private fun detachInternal(reason: String, releaseSurfaceImmediately: Boolean = false) {
        val pending = pendingAttach
        if (pending != null) {
            pendingAttach = null
            mainHandler.removeCallbacks(continueAttachRunnable)
            try {
                pending.refs.stopListeningMethod.invoke(pending.helper)
            } catch (e: Exception) {
                Log.w(TAG, "detach: stopListening on pending helper failed: ${describe(e)}")
            }
            pending.result.error("ATTACH_CANCELLED", "Detached before the attach completed ($reason)", null)
        }

        val helper = attachedHelper
        val surface = attachedSurface
        val trackId = attachedTrackId
        if (helper == null && surface == null && trackId == null) return

        try {
            host.detachEgressSurface()
        } catch (e: Exception) {
            Log.w(TAG, "detach: detachEgressSurface failed: ${describe(e)}")
        }
        val refs = reflection
        if (helper != null && refs != null) {
            try {
                refs.stopListeningMethod.invoke(helper)
            } catch (e: Exception) {
                Log.w(TAG, "detach: stopListening failed: ${describe(e)}")
            }
        }
        if (surface != null) {
            if (releaseSurfaceImmediately) {
                surface.release()
            } else {
                mainHandler.postDelayed({ surface.release() }, SURFACE_RELEASE_DELAY_MS)
            }
        }
        Log.i(TAG, "detached track $trackId ($reason) after $framesDelivered frames")
        attachedTrackId = null
        attachedHelper = null
        attachedSurface = null
        attachedSink = null
    }

    private fun describe(e: Throwable): String {
        val cause = if (e is InvocationTargetException) e.targetException ?: e else e
        return "${cause.javaClass.simpleName}: ${cause.message}"
    }

    // ── Reflection surface (resolved once, before any side effect) ───────────

    private class WebRtcReflection private constructor(
        val sharedSingletonField: Field,
        val getLocalTrackMethod: Method,
        val methodCallHandlerField: Field,
        val getUserMediaImplField: Field,
        val getCapturerInfoMethod: Method,
        val surfaceTextureHelpersField: Field,
        val localVideoTrackClass: Class<*>,
        val onFrameCapturedMethod: Method,
        val videoSinkClass: Class<*>,
        val capturerField: Field,
        val widthField: Field,
        val heightField: Field,
        val fpsField: Field,
        val stopCaptureMethod: Method,
        val startCaptureMethod: Method,
        val stopListeningMethod: Method,
        val setTextureSizeMethod: Method,
        val getSurfaceTextureMethod: Method,
        val startListeningMethod: Method,
    ) {
        companion object {
            /** Throws (ReflectiveOperationException/SecurityException) if any member is missing. */
            fun resolve(loader: ClassLoader?): WebRtcReflection {
                fun load(name: String): Class<*> = Class.forName(name, true, loader)

                val pluginClass = load("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin")
                val handlerClass = load("com.cloudwebrtc.webrtc.MethodCallHandlerImpl")
                val getUserMediaClass = load("com.cloudwebrtc.webrtc.GetUserMediaImpl")
                val capturerInfoClass = load("com.cloudwebrtc.webrtc.video.VideoCapturerInfo")
                val localVideoTrackClass = load("com.cloudwebrtc.webrtc.video.LocalVideoTrack")
                val videoCapturerClass = load("org.webrtc.VideoCapturer")
                val helperClass = load("org.webrtc.SurfaceTextureHelper")
                val videoSinkClass = load("org.webrtc.VideoSink")
                val videoFrameClass = load("org.webrtc.VideoFrame")
                val int = Int::class.javaPrimitiveType!!

                return WebRtcReflection(
                    sharedSingletonField = pluginClass.getField("sharedSingleton"),
                    getLocalTrackMethod = pluginClass.getMethod("getLocalTrack", String::class.java),
                    methodCallHandlerField = pluginClass.getDeclaredField("methodCallHandler").also { it.isAccessible = true },
                    getUserMediaImplField = handlerClass.getDeclaredField("getUserMediaImpl").also { it.isAccessible = true },
                    getCapturerInfoMethod = getUserMediaClass.getMethod("getCapturerInfo", String::class.java),
                    surfaceTextureHelpersField = getUserMediaClass.getDeclaredField("mSurfaceTextureHelpers").also { it.isAccessible = true },
                    localVideoTrackClass = localVideoTrackClass,
                    onFrameCapturedMethod = localVideoTrackClass.getMethod("onFrameCaptured", videoFrameClass),
                    videoSinkClass = videoSinkClass,
                    capturerField = capturerInfoClass.getField("capturer"),
                    widthField = capturerInfoClass.getField("width"),
                    heightField = capturerInfoClass.getField("height"),
                    fpsField = capturerInfoClass.getField("fps"),
                    stopCaptureMethod = videoCapturerClass.getMethod("stopCapture"),
                    startCaptureMethod = videoCapturerClass.getMethod("startCapture", int, int, int),
                    stopListeningMethod = helperClass.getMethod("stopListening"),
                    setTextureSizeMethod = helperClass.getMethod("setTextureSize", int, int),
                    getSurfaceTextureMethod = helperClass.getMethod("getSurfaceTexture"),
                    startListeningMethod = helperClass.getMethod("startListening", videoSinkClass),
                )
            }
        }
    }
}
