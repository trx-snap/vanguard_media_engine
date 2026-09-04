package com.connects.vanguard_media_engine.camera

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.Executor
import java.util.concurrent.TimeoutException
import kotlin.math.abs

/**
 * P3-CAM-THERMAL-ACT-CAMERAX-FPS-BRIDGE: production Android CameraX repeating
 * request AE target FPS actuator.
 *
 * Owns Camera2 interop selection/application of a reduced
 * [CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE] against the already-bound
 * CameraX [Camera] session behind `VanguardCameraSource`. FPS-only -- never
 * mutates resolution, never rebinds/reconfigures the CameraX session, never
 * touches [android.hardware.camera2.CameraCaptureSession] directly, and never
 * touches the OS thermal listener registry.
 *
 * One instance is bound to exactly one CameraX bind generation. The owning
 * `VanguardCameraSource` recreates this actuator after every `bindUseCases()`
 * call and discards the previous instance -- this class does not itself track
 * bind generation.
 */
@OptIn(ExperimentalCamera2Interop::class)
class AndroidCameraXThermalFpsActuator(
    camera: Camera,
    private val mainExecutor: Executor,
) {
    companion object {
        private const val TAG = "AndroidCameraXThermalFpsActuator"
        private const val APPLY_TIMEOUT_MS = 4000L
    }

    private val camera2CameraInfo = Camera2CameraInfo.from(camera.cameraInfo)
    private val camera2CameraControl = Camera2CameraControl.from(camera.cameraControl)
    private val timeoutHandler = Handler(Looper.getMainLooper())

    // Both the timeout Runnable (posted via Handler(Looper.getMainLooper()))
    // and the ListenableFuture listener (posted via mainExecutor) run on the
    // main thread, so this field never races -- whichever callback observes
    // itself as the still-current pending attempt "wins" and clears it before
    // invoking a caller callback. Doubles as the in-flight guard for
    // [applySelectedRange]: non-null means a caller is already waiting on a
    // callback, so a second [applySelectedRange] must not touch it.
    private var pendingFuture: ListenableFuture<Void>? = null

    /** Result of a successful [selectTargetFpsRange] call. */
    data class SelectionResult(
        val requestedTargetFps: Int,
        val observedCurrentLower: Int,
        val observedCurrentUpper: Int,
        val selectedLower: Int,
        val selectedUpper: Int,
        val availableRanges: List<Range<Int>>,
    )

    /** Outcome of [selectTargetFpsRange] -- either a selected range or a typed rejection. */
    sealed class SelectionOutcome {
        data class Selected(val result: SelectionResult) : SelectionOutcome()
        data class Rejected(
            val reason: String,
            val message: String,
            val availableRanges: List<Range<Int>> = emptyList(),
        ) : SelectionOutcome()
    }

    /**
     * Selects a reduced [CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE] candidate.
     *
     * Candidates are drawn from
     * [CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES] filtered to
     * ranges with strictly positive `lower`/`upper` and `upper < observedCurrentUpper`;
     * the candidate minimising `abs(upper - targetFps)` is selected, ties broken
     * by the higher upper bound. Rejects (without touching hardware) when
     * [targetFps] is not positive, the observed current range is unavailable,
     * no ranges are reported, or no candidate range strictly reduces the upper
     * bound below the observed current upper bound.
     */
    fun selectTargetFpsRange(
        targetFps: Int,
        observedCurrentLower: Int?,
        observedCurrentUpper: Int?,
    ): SelectionOutcome {
        if (targetFps <= 0) {
            return SelectionOutcome.Rejected(
                "INVALID_TARGET_FPS",
                "selectTargetFpsRange: targetFps must be > 0, got $targetFps",
            )
        }
        if (observedCurrentLower == null || observedCurrentUpper == null) {
            return SelectionOutcome.Rejected(
                "MISSING_OBSERVED_RANGE",
                "selectTargetFpsRange: no observed current AE target FPS range yet",
            )
        }

        val ranges: Array<Range<Int>>? = camera2CameraInfo.getCameraCharacteristic(
            CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES,
        )
        if (ranges == null || ranges.isEmpty()) {
            return SelectionOutcome.Rejected(
                "NO_AVAILABLE_RANGES",
                "selectTargetFpsRange: no CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES reported",
            )
        }
        val allRanges = ranges.toList()

        val candidates = allRanges.filter {
            it.lower > 0 && it.upper > 0 && it.upper < observedCurrentUpper
        }
        val selected = candidates.minWithOrNull(
            compareBy<Range<Int>> { abs(it.upper - targetFps) }.thenByDescending { it.upper },
        )

        if (selected == null) {
            return SelectionOutcome.Rejected(
                "NO_REDUCTION",
                "selectTargetFpsRange: no candidate range strictly below observed current upper $observedCurrentUpper",
                availableRanges = allRanges,
            )
        }

        return SelectionOutcome.Selected(
            SelectionResult(
                requestedTargetFps = targetFps,
                observedCurrentLower = observedCurrentLower,
                observedCurrentUpper = observedCurrentUpper,
                selectedLower = selected.lower,
                selectedUpper = selected.upper,
                availableRanges = allRanges,
            ),
        )
    }

    /**
     * Applies [selected] to the live CameraX repeating request via
     * [Camera2CameraControl.setCaptureRequestOptions] -- never mutates
     * [android.hardware.camera2.CameraCaptureSession] directly and never
     * triggers a CameraX rebind/reconfigure.
     *
     * Returns `false` without touching hardware or either callback when an
     * earlier [applySelectedRange] call is still in flight -- the caller
     * owns a not-yet-answered MethodChannel result for that earlier attempt,
     * and it must be left completely alone (its future/timeout keep running
     * and will eventually invoke its own [onApplied]/[onError] exactly once).
     * Returns `true` when this call started a new in-flight attempt.
     *
     * When started, [onApplied] / [onError] are invoked exactly once, on
     * [mainExecutor]. A bounded [APPLY_TIMEOUT_MS] timeout guards against a
     * future that never completes -- this fires even after the owning
     * `VanguardCameraSource` has stopped or rebound, so callers must map a
     * post-teardown/stale completion themselves rather than relying on this
     * class to suppress it.
     */
    fun applySelectedRange(
        selected: SelectionResult,
        onApplied: () -> Unit,
        onError: (Exception) -> Unit,
    ): Boolean {
        if (pendingFuture != null) {
            return false
        }

        val range = Range(selected.selectedLower, selected.selectedUpper)
        val options = CaptureRequestOptions.Builder()
            .setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, range)
            .build()

        val future = camera2CameraControl.setCaptureRequestOptions(options)
        pendingFuture = future

        val timeoutRunnable = Runnable {
            if (pendingFuture === future) {
                pendingFuture = null
                future.cancel(false)
                Log.w(TAG, "applySelectedRange: timed out after ${APPLY_TIMEOUT_MS}ms")
                onError(TimeoutException("applySelectedRange: setCaptureRequestOptions timed out after ${APPLY_TIMEOUT_MS}ms"))
            }
        }
        timeoutHandler.postDelayed(timeoutRunnable, APPLY_TIMEOUT_MS)

        future.addListener({
            if (pendingFuture !== future) return@addListener
            pendingFuture = null
            timeoutHandler.removeCallbacks(timeoutRunnable)
            try {
                future.get()
                onApplied()
            } catch (e: Exception) {
                onError(e)
            }
        }, mainExecutor)

        return true
    }
}
