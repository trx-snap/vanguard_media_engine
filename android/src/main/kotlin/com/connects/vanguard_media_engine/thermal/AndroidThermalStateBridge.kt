package com.connects.vanguard_media_engine.thermal

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Phase 3-Unit T: Android OS thermal listener lifecycle bridge.
 *
 * Owns [PowerManager] access, the registered [PowerManager.OnThermalStatusChangedListener],
 * and its registration flag. Maps Android's PowerManager thermal statuses onto the
 * existing four-state Dart raw contract (VGThermalState: 0=nominal, 1=fair, 2=serious,
 * 3=critical) and forwards transitions to Dart via the existing `onThermalStateChanged`
 * MethodChannel callback — the same callback name/shape the plugin already used before
 * this bridge existed.
 *
 * `simulateThermalState` never touches PowerManager or mutates OS thermal state — it
 * only re-invokes `onThermalStateChanged` with a caller-supplied raw value, so the Dart
 * listener path can be exercised without reaching real thermal load.
 */
class AndroidThermalStateBridge(
    private val context: Context,
    private val channel: MethodChannel,
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "AndroidThermalStateBridge"

        fun ownsMethod(method: String): Boolean =
            method == "getThermalState" || method == "simulateThermalState"

        /** Maps a raw Android PowerManager thermal status to the Dart raw contract (0-3). */
        fun mapAndroidStatusToRaw(status: Int?): Int {
            if (status == null) return 0
            return when (status) {
                PowerManager.THERMAL_STATUS_NONE -> 0
                PowerManager.THERMAL_STATUS_LIGHT -> 1
                PowerManager.THERMAL_STATUS_MODERATE,
                PowerManager.THERMAL_STATUS_SEVERE -> 2
                PowerManager.THERMAL_STATUS_CRITICAL,
                PowerManager.THERMAL_STATUS_EMERGENCY,
                PowerManager.THERMAL_STATUS_SHUTDOWN -> 3
                else -> 0
            }
        }
    }

    private val powerManager: PowerManager? =
        context.getSystemService(Context.POWER_SERVICE) as? PowerManager

    private var listener: PowerManager.OnThermalStatusChangedListener? = null
    @Volatile private var registered = false

    /** Registers the OS thermal status listener. Safe to call once per plugin attach. */
    fun start() {
        if (registered) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val pm = powerManager ?: return
        val newListener = PowerManager.OnThermalStatusChangedListener { status ->
            val raw = mapAndroidStatusToRaw(status)
            Log.i(TAG, "onThermalStatusChanged: androidStatus=$status raw=$raw")
            mainHandler.post { channel.invokeMethod("onThermalStateChanged", raw) }
        }
        try {
            pm.addThermalStatusListener(newListener)
            listener = newListener
            registered = true
        } catch (t: Throwable) {
            Log.w(TAG, "addThermalStatusListener failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /** Unregisters the OS thermal status listener. Safe to call even if never started. */
    fun shutdown() {
        val pm = powerManager
        val activeListener = listener
        if (pm != null && activeListener != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                pm.removeThermalStatusListener(activeListener)
            } catch (t: Throwable) {
                Log.w(TAG, "removeThermalStatusListener failed: ${t.javaClass.simpleName}: ${t.message}")
            }
        }
        listener = null
        registered = false
    }

    /** Routes `getThermalState`/`simulateThermalState`. Returns false for any other method. */
    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "getThermalState" -> result.success(mapAndroidStatusToRaw(currentAndroidStatus()))
            "simulateThermalState" -> {
                val rawValue = (args?.get("rawValue") as? Number)?.toInt()
                if (rawValue == null || rawValue < 0 || rawValue > 3) {
                    result.error("INVALID_ARG", "simulateThermalState: rawValue (0-3) required", null)
                    return true
                }
                channel.invokeMethod("onThermalStateChanged", rawValue)
                result.success(null)
            }
            else -> return false
        }
        return true
    }

    private fun currentAndroidStatus(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            powerManager?.currentThermalStatus
        } catch (t: Throwable) {
            Log.w(TAG, "currentThermalStatus failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    private fun androidStatusName(status: Int?): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || status == null) return "unavailable"
        return when (status) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown_$status"
        }
    }

    /**
     * Diagnostic snapshot for the Phase 3-Unit T smoke harness — read-only, no side
     * effects, no camera/renderer/UI access.
     */
    fun diagnosticState(): Map<String, Any?> {
        val status = currentAndroidStatus()
        return mapOf(
            "apiLevel" to Build.VERSION.SDK_INT,
            "listenerApiSupported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
            "listenerRegistered" to registered,
            "androidThermalStatus" to status,
            "androidThermalStatusName" to androidStatusName(status),
            "mappedRawValue" to mapAndroidStatusToRaw(status),
        )
    }
}
