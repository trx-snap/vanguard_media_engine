package com.connects.vanguard_media_engine.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Phase 3-Unit H: diagnostic-only Android Camera2 single-camera open/close
 * lifecycle smoke harness.
 *
 * Opens exactly one Camera2 device via [CameraManager.openCamera] on a
 * private [HandlerThread] and closes it immediately once opened, proving a
 * deterministic open/close lifecycle when CAMERA is already granted. Never
 * creates a CameraCaptureSession, SessionConfiguration, Surface,
 * SurfaceTexture, ImageReader, MediaRecorder, CameraX, or permission UI.
 * Diagnostic/capability foundation only.
 */
class AndroidCamera2OpenCloseSmokeHarness(private val context: Context) {

    companion object {
        private const val TAG = "AndroidCamera2OpenCloseSmokeHarness"
        private const val DEFAULT_TIMEOUT_MS = 5000L
        private const val MIN_TIMEOUT_MS = 1000L
        private const val MAX_TIMEOUT_MS = 15000L
    }

    fun run(args: Map<*, *>?): Map<String, Any?> {
        val startElapsed = SystemClock.elapsedRealtime()
        val apiLevel = Build.VERSION.SDK_INT
        val hasCameraPermission = hasCameraPermission()
        val requestedCameraId = (args?.get("cameraId") as? String)?.trim()
        val timeoutMs = clampTimeout((args?.get("timeoutMs") as? Number)?.toLong())

        val events = mutableListOf<String>()
        val reasons = mutableListOf<String>()
        val diagnostics = mutableMapOf<String, Any?>()

        fun buildResult(
            decision: String,
            attemptedOpen: Boolean,
            opened: Boolean,
            closed: Boolean,
            cameraId: String?,
            selectedLensFacing: String,
        ): Map<String, Any?> {
            val durationMs = SystemClock.elapsedRealtime() - startElapsed
            val success = decision == "openedAndClosed" && opened && closed
            Log.i(
                TAG,
                "decision=$decision attemptedOpen=$attemptedOpen opened=$opened closed=$closed " +
                    "cameraId=$cameraId selectedLensFacing=$selectedLensFacing durationMs=$durationMs",
            )
            return mapOf(
                "success" to success,
                "apiLevel" to apiLevel,
                "hasCameraPermission" to hasCameraPermission,
                "attemptedOpen" to attemptedOpen,
                "opened" to opened,
                "closed" to closed,
                "cameraId" to cameraId,
                "selectedLensFacing" to selectedLensFacing,
                "decision" to decision,
                "reasons" to reasons.toList(),
                "events" to events.toList(),
                "diagnostics" to diagnostics.toMap(),
                "durationMs" to durationMs,
            )
        }

        // Guard 1: no CameraManager.
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (cameraManager == null) {
            reasons.add("camera_manager_unavailable")
            return buildResult("cameraManagerUnavailable", false, false, false, null, "unknown")
        }

        val cameraIds = try {
            cameraManager.cameraIdList.toList()
        } catch (t: Throwable) {
            Log.w(TAG, "getCameraIdList failed: ${t.javaClass.simpleName}: ${t.message}")
            diagnostics["cameraIdListError"] = "${t.javaClass.simpleName}: ${t.message}"
            emptyList()
        }

        // Guard 2: no cameras.
        if (cameraIds.isEmpty()) {
            reasons.add("no_camera_available")
            return buildResult("noCamera", false, false, false, null, "unknown")
        }

        val selectedCameraId = if (!requestedCameraId.isNullOrBlank()) {
            requestedCameraId
        } else {
            cameraIds.firstOrNull { lensFacingName(cameraManager, it) == "back" } ?: cameraIds.first()
        }
        val selectedLensFacing = lensFacingName(cameraManager, selectedCameraId)

        // Guard 3: permission absent.
        if (!hasCameraPermission) {
            reasons.add("camera_permission_absent")
            return buildResult(
                "permissionRequired", false, false, false, selectedCameraId, selectedLensFacing,
            )
        }

        // Guard 4: invalid requested camera id.
        if (!requestedCameraId.isNullOrBlank() && !cameraIds.contains(requestedCameraId)) {
            reasons.add("requested_camera_id_not_found")
            return buildResult(
                "cameraUnavailable", false, false, false, selectedCameraId, selectedLensFacing,
            )
        }

        val openLatch = CountDownLatch(1)
        val closeLatch = CountDownLatch(1)
        val deviceRef = AtomicReference<CameraDevice?>(null)
        val openedFlag = AtomicBoolean(false)
        val closedFlag = AtomicBoolean(false)
        val decision = AtomicReference("openFailed")

        val handlerThread = HandlerThread("VGCamera2OpenCloseSmoke")
        handlerThread.start()
        val bgHandler = Handler(handlerThread.looper)

        try {
            val stateCallback = object : CameraDevice.StateCallback() {
                private fun closeDeviceOnce(device: CameraDevice) {
                    try {
                        device.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "device.close() failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                }

                override fun onOpened(device: CameraDevice) {
                    events.add("onOpened")
                    openedFlag.set(true)
                    deviceRef.set(device)
                    decision.set("openedAndClosed")
                    closeDeviceOnce(device)
                    openLatch.countDown()
                }

                override fun onClosed(device: CameraDevice) {
                    events.add("onClosed")
                    closedFlag.set(true)
                    closeLatch.countDown()
                }

                override fun onDisconnected(device: CameraDevice) {
                    events.add("onDisconnected")
                    decision.set("openDisconnected")
                    reasons.add("camera_disconnected")
                    closeDeviceOnce(device)
                    openLatch.countDown()
                    closeLatch.countDown()
                }

                override fun onError(device: CameraDevice, error: Int) {
                    events.add("onError:$error")
                    decision.set("openError")
                    reasons.add("camera_open_error")
                    diagnostics["errorCode"] = error
                    closeDeviceOnce(device)
                    openLatch.countDown()
                    closeLatch.countDown()
                }
            }

            events.add("openCameraRequested")
            try {
                cameraManager.openCamera(selectedCameraId, stateCallback, bgHandler)
            } catch (e: SecurityException) {
                reasons.add("camera_permission_absent")
                diagnostics["openCameraError"] = "${e.javaClass.simpleName}: ${e.message}"
                return buildResult(
                    "permissionRequired", true, false, false, selectedCameraId, selectedLensFacing,
                )
            } catch (t: Throwable) {
                reasons.add("camera_open_failed")
                diagnostics["openCameraError"] = "${t.javaClass.simpleName}: ${t.message}"
                return buildResult(
                    "openFailed", true, false, false, selectedCameraId, selectedLensFacing,
                )
            }

            val openedInTime = openLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
            if (!openedInTime) {
                events.add("openTimeout")
                decision.set("openTimeout")
                reasons.add("camera_open_timeout")
                deviceRef.get()?.let { device ->
                    try {
                        device.close()
                    } catch (t: Throwable) {
                        Log.w(TAG, "device.close() on timeout failed: ${t.javaClass.simpleName}: ${t.message}")
                    }
                }
            } else if (decision.get() == "openedAndClosed") {
                val closedInTime = closeLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
                if (!closedInTime) {
                    events.add("closeTimeout")
                    decision.set("openTimeout")
                    reasons.add("camera_close_timeout")
                }
            }

            return buildResult(
                decision.get(), true, openedFlag.get(), closedFlag.get(), selectedCameraId, selectedLensFacing,
            )
        } finally {
            handlerThread.quitSafely()
        }
    }

    private fun hasCameraPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun lensFacingName(cameraManager: CameraManager, cameraId: String): String {
        return try {
            when (cameraManager.getCameraCharacteristics(cameraId).get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                else -> "unknown"
            }
        } catch (t: Throwable) {
            Log.w(TAG, "getCameraCharacteristics($cameraId) failed: ${t.javaClass.simpleName}: ${t.message}")
            "unknown"
        }
    }

    private fun clampTimeout(raw: Long?): Long {
        val value = raw ?: DEFAULT_TIMEOUT_MS
        return value.coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
    }
}
