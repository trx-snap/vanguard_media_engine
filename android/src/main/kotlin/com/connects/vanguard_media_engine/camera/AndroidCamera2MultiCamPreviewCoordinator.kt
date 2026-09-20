package com.connects.vanguard_media_engine.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.StatFs
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.diagnostics.BackendCapabilityReport
import com.connects.vanguard_media_engine.diagnostics.VanguardDiagnostics
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * P3-CAM-CONCURRENT-STARTMULTICAM-FAIL-CLOSED-ANDROID-HANDLER /
 * P3-CAM-CONCURRENT-MULTICAM-ACTIONS-FAIL-CLOSED-ANDROID-HANDLER: owns the
 * public Dart VGCameraSession MultiCam preview/action routes as explicit
 * fail-closed guard routes.
 *
 * Non-claims (read before touching this file):
 *  - This slice does NOT implement real Android concurrent camera capture,
 *    rendering, photo capture, or recording. No camera is opened, no
 *    TextureRegistry/SurfaceTexture is allocated, no capture session is
 *    created, and no file is written by any route owned here.
 *  - Hardware/device-id combinations that Camera2's read-only
 *    [AndroidCamera2CapabilityProbe] reports as concurrent-capable still fail
 *    closed with CONCURRENT_PREVIEW_NOT_READY, because this package has no
 *    production Android concurrent-preview lifecycle owner yet. A fake
 *    texture/session is never returned.
 *  - stopMultiCamPreview and stopMultiCamRenderDiagnostic are idempotent
 *    no-op successes: there is no Android multicam preview/diagnostic
 *    session in this slice, so neither touches the single-camera
 *    [hasActiveSingleCamera] state.
 *  - updateMultiCamPreviewConfig and takeMultiCamPhoto are real
 *    implementations that operate on the live [dualCamCompositor] (layout
 *    updates and PixelCopy-based composited-frame snapshots respectively);
 *    both still reject with NOT_RUNNING when no MultiCam preview is active.
 *    startMultiCamRecording/stopMultiCamRecording are real implementations
 *    backed by [AndroidMultiCamVideoRecorder], which encodes the compositor's
 *    rendered frames (delivered via [AndroidDualCameraCompositor.onFrameRendered])
 *    into a composited H.264/AAC MP4; both still reject with NOT_RUNNING when
 *    no MultiCam preview is active.
 *  - measureMultiCamHardwareCost/runMultiCamStreamingDiagnostic/
 *    runMultiCamSyncDiagnostic/runMultiCamSourceLifecycleDiagnostic
 *    (P3-CAM-CONCURRENT-DIAGNOSTIC-FAIL-CLOSED-ANDROID-HANDLER) are explicit
 *    fail-closed guard routes with the same validation/capability-gated
 *    shape as [startMultiCamPreviewLikeGuard]: hardware without a matching
 *    concurrent combo rejects with CONCURRENT_NOT_SUPPORTED, and a matching
 *    combo still rejects with CONCURRENT_DIAGNOSTIC_NOT_READY because this
 *    package has no production Android concurrent-diagnostic lifecycle
 *    owner yet. No camera is opened, no frames are streamed, no
 *    hardware-cost measurement is performed, and no fake cost/report map is
 *    ever returned by any of the four routes.
 *
 * Capability lookups go through [AndroidCamera2CapabilityProbe.probe], which
 * only calls CameraManager.getCameraIdList / getCameraCharacteristics /
 * concurrentCameraIds -- it never opens a camera.
 */
class AndroidCamera2MultiCamPreviewCoordinator(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val hasActiveSingleCamera: () -> Boolean,
) {

    // ── Dual-camera session state ──────────────────────────────────────────
    // Non-null only while a concurrent preview is running.
    // Coordinator owns the lifecycle of both texture entries.
    private var dualCameraSource: IVanguardDualCameraSource? = null
    private var frontTexture: TextureRegistry.SurfaceTextureEntry? = null
    private var backTexture: TextureRegistry.SurfaceTextureEntry? = null
    private var dualCamCompositor: AndroidDualCameraCompositor? = null
    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
    private var activeRecorder: AndroidMultiCamVideoRecorder? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cameraManager by lazy { context.getSystemService(Context.CAMERA_SERVICE) as CameraManager }
    companion object {
        private const val TAG = "AndroidCamera2MultiCamPreviewCoordinator"

        private val OWNED_METHODS = setOf(
            "startMultiCamPreview",
            "stopMultiCamPreview",
            "discoverDualCameraPairs",
            "probeDualCameraPair",
            "runMultiCamRenderDiagnostic",
            "startMultiCamRenderDiagnostic",
            "stopMultiCamRenderDiagnostic",
            "updateMultiCamPreviewConfig",
            "takeMultiCamPhoto",
            "startMultiCamRecording",
            "stopMultiCamRecording",
            "measureMultiCamHardwareCost",
            "runMultiCamStreamingDiagnostic",
            "runMultiCamSyncDiagnostic",
            "runMultiCamSourceLifecycleDiagnostic",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun handle(method: String, args: Map<String, Any?>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "startMultiCamPreview" -> startMultiCamPreviewReal(args, result)
            "stopMultiCamPreview" -> stopMultiCamPreviewReal(result)
            "discoverDualCameraPairs" -> discoverDualCameraPairs(result)
            "probeDualCameraPair" -> probeDualCameraPair(args, result)
            "runMultiCamRenderDiagnostic" -> startMultiCamPreviewLikeGuard(args, result)
            "startMultiCamRenderDiagnostic" -> startMultiCamPreviewLikeGuard(args, result)
            "stopMultiCamRenderDiagnostic" -> stopIdempotent(result)
            "updateMultiCamPreviewConfig" -> updateMultiCamPreviewConfig(args, result)
            "takeMultiCamPhoto" -> takeMultiCamPhoto(args, result)
            "startMultiCamRecording" -> startMultiCamRecording(args, result)
            "stopMultiCamRecording" -> stopMultiCamRecording(result)
            "measureMultiCamHardwareCost" -> multiCamDiagnosticFailClosedGuard(args, result)
            "runMultiCamStreamingDiagnostic" -> multiCamDiagnosticFailClosedGuard(args, result)
            "runMultiCamSyncDiagnostic" -> multiCamDiagnosticFailClosedGuard(args, result)
            "runMultiCamSourceLifecycleDiagnostic" -> multiCamDiagnosticFailClosedGuard(args, result)
            else -> return false
        }
        return true
    }

    // -- startMultiCamPreview / runMultiCamRenderDiagnostic /
    // -- startMultiCamRenderDiagnostic -----------------------------------------
    //
    // All three routes share the same validation/capability-gated fail-closed
    // start path: no cameras or textures are allocated by any of them.

    private fun startMultiCamPreviewLikeGuard(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val frontDeviceId = (args?.get("frontDeviceId") as? String)?.trim()
        val backDeviceId = (args?.get("backDeviceId") as? String)?.trim()
        if (frontDeviceId.isNullOrEmpty() || backDeviceId.isNullOrEmpty()) {
            result.error(
                "INVALID_ARG",
                "This route requires non-blank frontDeviceId and backDeviceId",
                null,
            )
            return
        }

        if (hasActiveSingleCamera()) {
            result.error(
                "CAMERA_ACTIVE",
                "A single-camera session is active; stop it before starting a multi-cam preview",
                null,
            )
            return
        }

        val probeResult = try {
            AndroidCamera2CapabilityProbe(context).probe()
        } catch (t: Throwable) {
            Log.w(TAG, "startMultiCamPreviewLikeGuard: probe failed: ${t.javaClass.simpleName}: ${t.message}")
            result.error(
                "CONCURRENT_NOT_SUPPORTED",
                "Unable to determine concurrent camera capability: ${t.message}",
                null,
            )
            return
        }

        val supportsConcurrentCamera = probeResult["supportsConcurrentCamera"] as? Boolean ?: false
        @Suppress("UNCHECKED_CAST")
        val concurrentCameraIdSets =
            probeResult["concurrentCameraIdSets"] as? List<List<String>> ?: emptyList()

        val matchingSet = concurrentCameraIdSets.firstOrNull { idSet ->
            idSet.contains(frontDeviceId) && idSet.contains(backDeviceId)
        }

        if (!supportsConcurrentCamera || matchingSet == null) {
            result.error(
                "CONCURRENT_NOT_SUPPORTED",
                "No concurrent camera combination supports frontDeviceId=$frontDeviceId " +
                    "and backDeviceId=$backDeviceId on this device",
                mapOf(
                    "supportsConcurrentCamera" to supportsConcurrentCamera,
                    "concurrentCameraIdSets" to concurrentCameraIdSets,
                ),
            )
            return
        }

        // A matching hardware combination exists, but this package has no
        // production Android concurrent-preview lifecycle owner in this
        // slice. Fail closed instead of opening cameras / allocating a
        // texture / creating a capture session for a session nothing drives.
        result.error(
            "CONCURRENT_PREVIEW_NOT_READY",
            "Android production concurrent preview lifecycle is not implemented",
            mapOf(
                "supportsConcurrentCamera" to supportsConcurrentCamera,
                "matchingConcurrentCameraIdSet" to matchingSet,
            ),
        )
    }

    // -- startMultiCamPreview (real implementation) ----------------------------

    private fun startMultiCamPreviewReal(args: Map<String, Any?>?, result: MethodChannel.Result) {
        // Validate args — same guard shape as startMultiCamPreviewLikeGuard.
        val frontDeviceId = (args?.get("frontDeviceId") as? String)?.trim()
        val backDeviceId  = (args?.get("backDeviceId")  as? String)?.trim()
        val targetWidth   = (args?.get("width") as? Number)?.toInt() ?: 1080
        val targetHeight  = (args?.get("height") as? Number)?.toInt() ?: 1920
        val initialConfig = args?.get("config") as? Map<*, *>

        if (frontDeviceId.isNullOrEmpty() || backDeviceId.isNullOrEmpty()) {
            result.error(
                "INVALID_ARG",
                "This route requires non-blank frontDeviceId and backDeviceId",
                null,
            )
            return
        }

        // Guard: reject if single-camera session is active.
        if (hasActiveSingleCamera()) {
            result.error(
                "CAMERA_ACTIVE",
                "A single-camera session is active; stop it before starting a multi-cam preview",
                null,
            )
            return
        }

        // Guard: reject if dual-camera preview is already running.
        if (dualCameraSource != null) {
            result.error(
                "ALREADY_RUNNING",
                "A MultiCam preview is already running — call stopMultiCamPreview first",
                null,
            )
            return
        }

        // Probe GPU backend capability for the compositor (Vulkan preferred, GLES fallback).
        // Uses a throwaway VanguardNativeBridge purely to call probeCapabilities() —
        // this coordinator does not own a bridge instance otherwise.
        val diagnostics = VanguardDiagnostics()
        val probeBridge = VanguardNativeBridge(VanguardLifecycleObserver(diagnostics), diagnostics, null)
        val capabilityReport: BackendCapabilityReport = try {
            probeBridge.probeCapabilities()
        } catch (t: Throwable) {
            Log.e(TAG, "startMultiCamPreview: probeCapabilities failed: ${t.javaClass.simpleName}: ${t.message}")
            result.error("CAMERA_ERROR", "Unable to probe backend capabilities: ${t.message}", null)
            return
        }

        // Allocate a single Flutter SurfaceProducer for the composited output —
        // architectural parity with iOS (one texture, backTextureId=null).
        val producer = textureRegistry.createSurfaceProducer()
        producer.setSize(targetWidth, targetHeight)
        val outputSurface = producer.getSurface()
        if (outputSurface == null) {
            Log.e(TAG, "startMultiCamPreview: SurfaceProducer.getSurface() returned null")
            try { producer.release() } catch (t: Throwable) { /* ignore */ }
            result.error("CAMERA_ERROR", "SurfaceProducer.getSurface() returned null", null)
            return
        }

        // Create and start the compositor — it owns the camera input surfaces,
        // the GPU render loop, and renders composited frames into outputSurface.
        val compositor = AndroidDualCameraCompositor(
            outputSurface = outputSurface,
            backendCapability = capabilityReport,
            canvasWidth = targetWidth,
            canvasHeight = targetHeight,
        )
        try {
            compositor.start()
        } catch (t: Throwable) {
            Log.e(TAG, "startMultiCamPreview: compositor.start() failed: ${t.javaClass.simpleName}: ${t.message}")
            try { producer.release() } catch (e: Throwable) { /* ignore */ }
            result.error("CAMERA_ERROR", "Failed to start dual-camera compositor: ${t.message}", null)
            return
        }

        // Apply initial layout config if provided by the caller.
        if (initialConfig != null) {
            val initialParams = AndroidDualCameraCompositor.parseConfigMap(initialConfig)
            compositor.updateLayout(initialParams)
            Log.d(TAG, "startMultiCamPreview: applied initial layout layoutMode=${initialParams.layoutMode} anchor=${initialParams.anchor}")
        }

        val compositorFrontSurface = compositor.frontInputSurface
        val compositorBackSurface = compositor.backInputSurface

        fun onCompositorPipelineStarted(source: IVanguardDualCameraSource) {
            dualCameraSource = source
            dualCamCompositor = compositor
            surfaceProducer = producer
            frontTexture = null
            backTexture = null
            Log.i(
                TAG,
                "startMultiCamPreview: compositor pipeline live — textureId=${producer.id()} " +
                    "backend=${if (compositor.isVulkanBackend) "Vulkan" else "GLES"}",
            )
            result.success(
                mapOf(
                    "textureId" to producer.id(),
                    "backTextureId" to null,
                    "outputWidth" to targetWidth,
                    "outputHeight" to targetHeight,
                    "frontDeviceId" to frontDeviceId,
                    "backDeviceId" to backDeviceId,
                    "backend" to if (compositor.isVulkanBackend) "Vulkan" else "GLES",
                )
            )
        }

        fun onCompositorPipelineError(e: Exception) {
            Log.e(TAG, "startMultiCamPreview: camera source failed: ${e.javaClass.simpleName}: ${e.message}")
            try { compositor.stop() } catch (t: Throwable) { /* ignore */ }
            try { producer.release() } catch (t: Throwable) { /* ignore */ }
            dualCameraSource = null
            dualCamCompositor = null
            surfaceProducer = null
            frontTexture = null
            backTexture = null
            result.error("CAMERA_ERROR", e.message, null)
        }

        // Check whether HAL advertises concurrent camera IDs for CameraX
        val probeResult = try {
            AndroidCamera2CapabilityProbe(context).probe()
        } catch (t: Throwable) {
            null
        }
        val supportsConcurrent = probeResult?.get("supportsConcurrentCamera") as? Boolean ?: false
        @Suppress("UNCHECKED_CAST")
        val concurrentCameraIdSets =
            probeResult?.get("concurrentCameraIdSets") as? List<List<String>> ?: emptyList()
        val hasMatchingConcurrentSet = concurrentCameraIdSets.any {
            it.contains(frontDeviceId) && it.contains(backDeviceId)
        }

        if (supportsConcurrent && hasMatchingConcurrentSet) {
            // Attempt CameraX ConcurrentCamera path first, streaming into the
            // compositor's input surfaces instead of Flutter SurfaceTextures.
            val source = VanguardDualCameraSource(
                context = context,
                frontTextureEntry = null,
                backTextureEntry = null,
                externalFrontSurface = compositorFrontSurface,
                externalBackSurface = compositorBackSurface,
            )
            source.start(
                onStarted = { _ -> onCompositorPipelineStarted(source) },
                onError = { e ->
                    Log.w(TAG, "startMultiCamPreview: CameraX compositor path failed (${e.message}) — falling back to generic Camera2")
                    val genericSource = VanguardGenericDualCamera2Source(
                        context = context,
                        frontTextureEntry = null,
                        backTextureEntry = null,
                        frontCameraId = frontDeviceId,
                        backCameraId = backDeviceId,
                        targetWidth = targetWidth,
                        targetHeight = targetHeight,
                        externalFrontSurface = compositorFrontSurface,
                        externalBackSurface = compositorBackSurface,
                    )
                    genericSource.start(
                        onStarted = { _ -> onCompositorPipelineStarted(genericSource) },
                        onError = { e2 -> onCompositorPipelineError(e2) },
                    )
                },
            )
        } else {
            // Direct generic raw Camera2 path (bypasses missing HAL concurrentCameraIds
            // table), streaming into the compositor's input surfaces.
            val source = VanguardGenericDualCamera2Source(
                context = context,
                frontTextureEntry = null,
                backTextureEntry = null,
                frontCameraId = frontDeviceId,
                backCameraId = backDeviceId,
                targetWidth = targetWidth,
                targetHeight = targetHeight,
                externalFrontSurface = compositorFrontSurface,
                externalBackSurface = compositorBackSurface,
            )
            source.start(
                onStarted = { _ -> onCompositorPipelineStarted(source) },
                onError = { e -> onCompositorPipelineError(e) },
            )
        }
    }

    // -- discoverDualCameraPairs (hardware enumeration) ------------------------

    private fun discoverDualCameraPairs(result: MethodChannel.Result) {
        Thread {
            try {
                val allCameraIds = cameraManager.cameraIdList.toList()
                val frontCameras = mutableListOf<Map<String, Any>>()
                val backCameras  = mutableListOf<Map<String, Any>>()

                for (id in allCameraIds) {
                    val chars = try {
                        cameraManager.getCameraCharacteristics(id)
                    } catch (t: Throwable) {
                        Log.w(TAG, "discover: getCameraCharacteristics($id) error: ${t.message}")
                        continue
                    }

                    val facing = chars.get(CameraCharacteristics.LENS_FACING)
                    val orientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
                    val hwLevel = chars.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL) ?: -1

                    val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                    val previewSizes = map?.getOutputSizes(SurfaceTexture::class.java)?.map {
                        mapOf("width" to it.width, "height" to it.height)
                    } ?: emptyList()

                    val infoMap = mapOf(
                        "cameraId" to id,
                        "facing" to if (facing == CameraCharacteristics.LENS_FACING_FRONT) "FRONT" else "BACK",
                        "orientation" to orientation,
                        "hardwareLevel" to hwLevel,
                        "previewSizes" to previewSizes.take(5),
                    )

                    if (facing == CameraCharacteristics.LENS_FACING_FRONT) {
                        frontCameras.add(infoMap)
                    } else if (facing == CameraCharacteristics.LENS_FACING_BACK) {
                        backCameras.add(infoMap)
                    }
                }

                val candidatePairs = mutableListOf<Map<String, String>>()
                for (f in frontCameras) {
                    val fId = f["cameraId"] as String
                    for (b in backCameras) {
                        val bId = b["cameraId"] as String
                        candidatePairs.add(mapOf("frontId" to fId, "backId" to bId))
                    }
                }

                val payload = mapOf(
                    "allCameraIds" to allCameraIds,
                    "frontCameras" to frontCameras,
                    "backCameras" to backCameras,
                    "candidatePairs" to candidatePairs,
                    "recommendedFrontId" to (frontCameras.firstOrNull()?.get("cameraId") ?: "1"),
                    "recommendedBackId" to (backCameras.firstOrNull()?.get("cameraId") ?: "0"),
                )

                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                Log.e(TAG, "discoverDualCameraPairs failed", t)
                mainHandler.post { result.error("DISCOVERY_FAILED", t.message, null) }
            }
        }.start()
    }

    // -- probeDualCameraPair (non-destructive rapid hardware test) -------------

    @SuppressLint("MissingPermission")
    private fun probeDualCameraPair(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val frontId = (args?.get("frontDeviceId") as? String)?.trim() ?: "1"
        val backId  = (args?.get("backDeviceId")  as? String)?.trim() ?: "0"

        val probeThread = HandlerThread("DualCamProbeThread").apply { start() }
        val probeHandler = Handler(probeThread.looper)

        Thread {
            val frontLatch = CountDownLatch(1)
            val backLatch  = CountDownLatch(1)
            val failed = AtomicBoolean(false)
            var failureMessage: String? = null
            var frontDev: CameraDevice? = null
            var backDev: CameraDevice? = null

            try {
                cameraManager.openCamera(frontId, object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        frontDev = camera
                        frontLatch.countDown()
                    }
                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        failed.set(true)
                        failureMessage = "Front camera $frontId disconnected"
                        frontLatch.countDown()
                    }
                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        failed.set(true)
                        failureMessage = "Front camera $frontId error code=$error"
                        frontLatch.countDown()
                    }
                }, probeHandler)

                cameraManager.openCamera(backId, object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        backDev = camera
                        backLatch.countDown()
                    }
                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        failed.set(true)
                        failureMessage = "Back camera $backId disconnected"
                        backLatch.countDown()
                    }
                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        failed.set(true)
                        failureMessage = "Back camera $backId error code=$error"
                        backLatch.countDown()
                    }
                }, probeHandler)

                val frontOk = frontLatch.await(3, TimeUnit.SECONDS)
                val backOk  = backLatch.await(3, TimeUnit.SECONDS)
                val supported = frontOk && backOk && !failed.get() && frontDev != null && backDev != null

                Log.i(TAG, "probeDualCameraPair F:$frontId + B:$backId -> supported=$supported (err=$failureMessage)")

                try { frontDev?.close() } catch (t: Throwable) {}
                try { backDev?.close()  } catch (t: Throwable) {}
                probeThread.quitSafely()

                mainHandler.post {
                    result.success(
                        mapOf(
                            "frontDeviceId" to frontId,
                            "backDeviceId" to backId,
                            "supported" to supported,
                            "error" to failureMessage,
                        )
                    )
                }
            } catch (t: Throwable) {
                Log.e(TAG, "probeDualCameraPair exception F:$frontId + B:$backId", t)
                try { frontDev?.close() } catch (e: Throwable) {}
                try { backDev?.close()  } catch (e: Throwable) {}
                probeThread.quitSafely()
                mainHandler.post {
                    result.success(
                        mapOf(
                            "frontDeviceId" to frontId,
                            "backDeviceId" to backId,
                            "supported" to false,
                            "error" to t.message,
                        )
                    )
                }
            }
        }.start()
    }

    // -- stopMultiCamPreview (real implementation) ------------------------------

    private fun stopMultiCamPreviewReal(result: MethodChannel.Result) {
        val source = dualCameraSource
        if (source == null) {
            // Idempotent: no active session — succeed silently.
            Log.d(TAG, "stopMultiCamPreview: no active session — idempotent no-op")
            result.success(null)
            return
        }

        Log.i(TAG, "stopMultiCamPreview: stopping dual camera session")

        // 0. Finalize any active recording before tearing down the compositor,
        //    so a valid MP4 remains at the requested path when possible. Bounded
        //    and never throws; on finalize failure the recorder aborts and
        //    cleans up its own .tmp file.
        val recorder = activeRecorder
        if (recorder != null) {
            dualCamCompositor?.onFrameRendered = null
            activeRecorder = null
            val stats = try {
                recorder.stop()
            } catch (t: Throwable) {
                Log.e(TAG, "stopMultiCamPreview: recorder.stop() threw during preview teardown: ${t.javaClass.simpleName}: ${t.message}", t)
                null
            }
            if (stats == null) {
                Log.w(TAG, "stopMultiCamPreview: recording finalize failed during preview teardown — aborting it")
                try { recorder.abort() } catch (t: Throwable) { /* ignore */ }
            }
        }

        // 1. Stop camera source first (it streams into compositor surfaces)
        source.stop()

        // 2. Stop compositor (owns input surfaces, render loop, GPU resources)
        try { dualCamCompositor?.stop() } catch (t: Throwable) {
            Log.w(TAG, "dualCamCompositor.stop failed: ${t.message}")
        }

        // 3. Release SurfaceProducer (Flutter texture)
        try { surfaceProducer?.release() } catch (t: Throwable) {
            Log.w(TAG, "surfaceProducer.release failed: ${t.message}")
        }

        // 4. Release legacy texture entries if they exist (backward compat safety)
        try { frontTexture?.release() } catch (t: Throwable) { Log.w(TAG, "frontTexture.release failed: ${t.message}") }
        try { backTexture?.release()  } catch (t: Throwable) { Log.w(TAG, "backTexture.release failed: ${t.message}")  }

        // 5. Clear all state
        dualCameraSource = null
        dualCamCompositor = null
        surfaceProducer  = null
        frontTexture     = null
        backTexture      = null

        Log.i(TAG, "stopMultiCamPreview: complete")
        result.success(null)
    }

    // -- stopMultiCamRenderDiagnostic (fail-closed, no-op success) ---------------

    private fun stopIdempotent(result: MethodChannel.Result) {
        // Idempotent no-op for diagnostic routes that have no Android
        // session to tear down. Must never touch dualCameraSource or the
        // single-camera cameraSource/cameraTexture state owned by the plugin.
        result.success(null)
    }

    // -- updateMultiCamPreviewConfig -------------------------------------------

    private fun updateMultiCamPreviewConfig(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val config = args?.get("config") as? Map<*, *>
        if (config == null) {
            result.error(
                "INVALID_ARG",
                "updateMultiCamPreviewConfig requires a config map",
                null,
            )
            return
        }

        val compositor = dualCamCompositor
        if (compositor == null || dualCameraSource == null) {
            result.error(
                "NOT_RUNNING",
                "Android MultiCam preview is not running",
                null,
            )
            return
        }

        val params = AndroidDualCameraCompositor.parseConfigMap(config)
        compositor.updateLayout(params)
        Log.d(TAG, "updateMultiCamPreviewConfig: applied layoutMode=${params.layoutMode} anchor=${params.anchor} splitDir=${params.splitDirection}")
        result.success(null)
    }

    // -- takeMultiCamPhoto ------------------------------------------------------

    private fun takeMultiCamPhoto(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val path = (args?.get("path") as? String)?.trim()
        if (path.isNullOrEmpty()) {
            result.error(
                "INVALID_ARG",
                "takeMultiCamPhoto requires a non-blank path",
                null,
            )
            return
        }

        val compositor = dualCamCompositor
        if (compositor == null || dualCameraSource == null) {
            result.error(
                "NOT_RUNNING",
                "Android MultiCam preview is not running",
                null,
            )
            return
        }

        // Retain a caller-owned snapshot under the compositor's lock (nanosecond
        // hold — see AndroidDualCameraCompositor.captureSnapshot). JPEG encoding
        // and disk I/O run outside that lock, on a background thread.
        val bitmap = compositor.captureSnapshot()
        if (bitmap == null) {
            result.error(
                "NO_FRAME",
                "No composited frame available yet",
                null,
            )
            return
        }

        Thread {
            val out = try {
                FileOutputStream(path)
            } catch (t: Throwable) {
                Log.e(TAG, "takeMultiCamPhoto: failed to open output file: ${t.javaClass.simpleName}: ${t.message}")
                bitmap.recycle()
                mainHandler.post { result.error("WRITE_FAIL", t.message, null) }
                return@Thread
            }

            val encoded = try {
                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
            } catch (t: Throwable) {
                Log.e(TAG, "takeMultiCamPhoto: JPEG compress threw: ${t.javaClass.simpleName}: ${t.message}")
                false
            } finally {
                try { out.close() } catch (t: Throwable) { /* ignore */ }
            }

            if (!encoded) {
                bitmap.recycle()
                mainHandler.post { result.error("ENCODE_FAIL", "JPEG encoding failed", null) }
                return@Thread
            }

            val width = bitmap.width
            val height = bitmap.height
            bitmap.recycle()

            val sizeBytes = try { File(path).length() } catch (t: Throwable) { 0L }

            Log.i(TAG, "takeMultiCamPhoto: wrote ${sizeBytes}b to $path (${width}x$height)")
            mainHandler.post {
                result.success(
                    mapOf(
                        "filePath" to path,
                        "width" to width,
                        "height" to height,
                        "sizeBytes" to sizeBytes,
                        "format" to "jpeg",
                    )
                )
            }
        }.start()
    }

    // -- startMultiCamRecording ---------------------------------------------------

    private fun startMultiCamRecording(args: Map<String, Any?>?, result: MethodChannel.Result) {
        val path = (args?.get("path") as? String)?.trim()
        if (path.isNullOrEmpty() || !path.endsWith(".mp4")) {
            result.error(
                "INVALID_ARG",
                "startMultiCamRecording requires a non-blank path ending in .mp4",
                null,
            )
            return
        }

        val compositor = dualCamCompositor
        if (compositor == null || dualCameraSource == null) {
            result.error(
                "NOT_RUNNING",
                "Android MultiCam preview is not running",
                null,
            )
            return
        }

        if (!compositor.hasRenderedFrame) {
            result.error(
                "NOT_RENDERING",
                "No frames rendered yet — start preview first",
                null,
            )
            return
        }

        if (activeRecorder != null) {
            result.error(
                "ALREADY_RECORDING",
                "A recording is already active",
                null,
            )
            return
        }

        val parent = File(path).absoluteFile.parentFile
        if (parent == null) {
            result.error("INVALID_ARG", "startMultiCamRecording path has no parent directory: $path", null)
            return
        }
        try {
            if (!parent.exists() && !parent.mkdirs()) {
                result.error("INVALID_ARG", "Unable to create output directory: ${parent.absolutePath}", null)
                return
            }
        } catch (t: Throwable) {
            result.error("INVALID_ARG", "Unable to create output directory: ${t.message}", null)
            return
        }

        val availableBytes = try {
            StatFs(parent.absolutePath).availableBytes
        } catch (t: Throwable) {
            Log.w(TAG, "startMultiCamRecording: StatFs failed: ${t.javaClass.simpleName}: ${t.message}")
            Long.MAX_VALUE
        }
        if (availableBytes < 200L * 1024 * 1024) {
            result.error(
                "DISK_SPACE",
                "Insufficient disk space (< 200 MB)",
                null,
            )
            return
        }

        val recorder = AndroidMultiCamVideoRecorder(
            context = context,
            outputPath = path,
            width = compositor.outputWidth,
            height = compositor.outputHeight,
        )

        val started = try {
            recorder.start()
        } catch (t: Throwable) {
            Log.e(TAG, "startMultiCamRecording: recorder.start() threw: ${t.javaClass.simpleName}: ${t.message}", t)
            false
        }

        if (!started) {
            try { recorder.abort() } catch (t: Throwable) { /* ignore */ }
            result.error(
                "WRITER_INIT_FAIL",
                "Failed to initialize the video recorder",
                null,
            )
            return
        }

        activeRecorder = recorder
        compositor.onFrameRendered = { bitmap -> recorder.submitFrame(bitmap) }

        Log.i(TAG, "startMultiCamRecording: recording started -> $path")
        result.success(true)
    }

    // -- stopMultiCamRecording ------------------------------------------------

    private fun stopMultiCamRecording(result: MethodChannel.Result) {
        val compositor = dualCamCompositor
        if (compositor == null) {
            result.error(
                "NOT_RUNNING",
                "Android MultiCam preview is not running",
                null,
            )
            return
        }

        val recorder = activeRecorder
        if (recorder == null) {
            result.error(
                "NOT_RECORDING",
                "No recording is currently active",
                null,
            )
            return
        }

        compositor.onFrameRendered = null
        activeRecorder = null

        Thread {
            val stats = try {
                recorder.stop()
            } catch (t: Throwable) {
                Log.e(TAG, "stopMultiCamRecording: recorder.stop() threw: ${t.javaClass.simpleName}: ${t.message}", t)
                null
            }

            mainHandler.post {
                if (stats == null) {
                    result.error(
                        "WRITER_FINISH_FAIL",
                        "Failed to finalize the recording",
                        null,
                    )
                } else {
                    Log.i(TAG, "stopMultiCamRecording: finalized ${stats["filePath"]}")
                    result.success(stats)
                }
            }
        }.start()
    }

    // -- measureMultiCamHardwareCost / runMultiCamStreamingDiagnostic /
    // -- runMultiCamSyncDiagnostic / runMultiCamSourceLifecycleDiagnostic ------
    //
    // All four legacy diagnostic routes share the same validation/
    // capability-gated fail-closed path as [startMultiCamPreviewLikeGuard]:
    // no camera is opened, no session/surface/TextureRegistry/ImageReader is
    // allocated, and no file is written by any of them.

    private fun multiCamDiagnosticFailClosedGuard(
        args: Map<String, Any?>?,
        result: MethodChannel.Result,
    ) {
        val frontDeviceId = (args?.get("frontDeviceId") as? String)?.trim()
        val backDeviceId = (args?.get("backDeviceId") as? String)?.trim()
        if (frontDeviceId.isNullOrEmpty() || backDeviceId.isNullOrEmpty()) {
            result.error(
                "INVALID_ARG",
                "This route requires non-blank frontDeviceId and backDeviceId",
                null,
            )
            return
        }

        if (hasActiveSingleCamera()) {
            result.error(
                "CAMERA_ACTIVE",
                "A single-camera session is active; stop it before running a multi-cam diagnostic",
                null,
            )
            return
        }

        val probeResult = try {
            AndroidCamera2CapabilityProbe(context).probe()
        } catch (t: Throwable) {
            Log.w(TAG, "multiCamDiagnosticFailClosedGuard: probe failed: ${t.javaClass.simpleName}: ${t.message}")
            result.error(
                "CONCURRENT_NOT_SUPPORTED",
                "Unable to determine concurrent camera capability: ${t.message}",
                null,
            )
            return
        }

        val supportsConcurrentCamera = probeResult["supportsConcurrentCamera"] as? Boolean ?: false
        @Suppress("UNCHECKED_CAST")
        val concurrentCameraIdSets =
            probeResult["concurrentCameraIdSets"] as? List<List<String>> ?: emptyList()

        val matchingSet = concurrentCameraIdSets.firstOrNull { idSet ->
            idSet.contains(frontDeviceId) && idSet.contains(backDeviceId)
        }

        if (!supportsConcurrentCamera || matchingSet == null) {
            result.error(
                "CONCURRENT_NOT_SUPPORTED",
                "No concurrent camera combination supports frontDeviceId=$frontDeviceId " +
                    "and backDeviceId=$backDeviceId on this device",
                mapOf(
                    "supportsConcurrentCamera" to supportsConcurrentCamera,
                    "concurrentCameraIdSets" to concurrentCameraIdSets,
                ),
            )
            return
        }

        // A matching hardware combination exists, but this package has no
        // production Android concurrent camera diagnostic lifecycle owner in
        // this slice. Fail closed instead of streaming frames / measuring
        // hardware cost / creating a source lifecycle for a diagnostic
        // nothing drives.
        result.error(
            "CONCURRENT_DIAGNOSTIC_NOT_READY",
            "Android production concurrent camera diagnostic lifecycle is not implemented",
            mapOf(
                "supportsConcurrentCamera" to supportsConcurrentCamera,
                "matchingConcurrentCameraIdSet" to matchingSet,
            ),
        )
    }

    // ── Public accessors for plugin-level routing ──────────────────────────

    /** True when a dual-camera preview session is live and streaming. */
    val isMultiCamRunning: Boolean get() = dualCameraSource != null

    /**
     * Forwards a tap-to-focus request to the active dual-camera source's back
     * camera. No-op when the active source is not a [VanguardDualCameraSource]
     * (the generic Camera2 path manages its own repeating AF mode).
     */
    fun setFocusPoint(x: Float, y: Float) {
        (dualCameraSource as? VanguardDualCameraSource)?.setFocusPoint(x, y)
    }
}
