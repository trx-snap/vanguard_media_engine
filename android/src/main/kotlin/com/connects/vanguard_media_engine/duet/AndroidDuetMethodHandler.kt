package com.connects.vanguard_media_engine.duet

import android.os.Handler
import io.flutter.plugin.common.MethodChannel

// ─────────────────────────────────────────────────────────────────────────────
// VG-DUET-SLICE-2: Android thin dispatch handler for Duet MethodChannel routes.
// ─────────────────────────────────────────────────────────────────────────────
//
// Owns the 10 Duet route names. Plugin is a thin router only —
// all session logic lives in AndroidDuetSessionCoordinator.
// All public methods are called on the main thread.

/**
 * Thin dispatch handler for all Duet MethodChannel routes.
 * Plugin owns one instance and calls [handleMethodCall] for routes [ownsMethod] returns true for.
 */
class AndroidDuetMethodHandler(mainHandler: Handler) {

    // ── Owned routes ──────────────────────────────────────────────────────────

    companion object {
        private val OWNED_METHODS = setOf(
            "initializeDuetSession",
            "updateDuetLayout",
            "setDuetRecordingSpeed",
            "setDuetAudioMixGains",
            "startDuetRecording",
            "pauseDuetRecording",
            "resumeDuetRecording",
            "deleteLastDuetSegment",
            "stopDuetRecording",
            "disposeDuetSession",
        )

        @JvmStatic
        fun ownsMethod(method: String): Boolean = OWNED_METHODS.contains(method)
    }

    // ── Coordinator ───────────────────────────────────────────────────────────

    private val coordinator = AndroidDuetSessionCoordinator(mainHandler)

    // ── Dispatch ──────────────────────────────────────────────────────────────

    @Suppress("UNCHECKED_CAST")
    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        val safeArgs = args as? Map<String, Any?> ?: emptyMap()

        when (method) {

            "initializeDuetSession" -> handleInitialize(safeArgs, result)

            "updateDuetLayout" -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                val layoutMap = safeArgs["layoutConfig"] as? Map<String, Any?> ?: emptyMap()
                coordinator.updateLayout(sid, layoutMap) { _, errStr ->
                    replyFromCoordinator(result, null, errStr)
                }
            }

            "setDuetRecordingSpeed" -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                val speed = (safeArgs["speed"] as? Number)?.toDouble() ?: 1.0
                coordinator.setRecordingSpeed(sid, speed) { _, errStr ->
                    replyFromCoordinator(result, null, errStr)
                }
            }

            "setDuetAudioMixGains" -> {
                val sid        = requireSessionId(safeArgs, method, result) ?: return
                val sourceGain = (safeArgs["sourceGain"] as? Number)?.toDouble() ?: 1.0
                val micGain    = (safeArgs["micGain"]    as? Number)?.toDouble() ?: 1.0
                coordinator.setAudioMixGains(sid, sourceGain, micGain) { _, errStr ->
                    replyFromCoordinator(result, null, errStr)
                }
            }

            "startDuetRecording" -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                coordinator.startRecording(sid) { _, errStr ->
                    replyFromCoordinator(result, null, errStr)
                }
            }

            "pauseDuetRecording" -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                coordinator.pauseRecording(sid) { _, errStr ->
                    replyFromCoordinator(result, null, errStr)
                }
            }

            "resumeDuetRecording" -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                coordinator.resumeRecording(sid) { _, errStr ->
                    replyFromCoordinator(result, null, errStr)
                }
            }

            "deleteLastDuetSegment" -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                coordinator.deleteLastSegment(sid) { _, errStr ->
                    replyFromCoordinator(result, null, errStr)
                }
            }

            "stopDuetRecording" -> {
                val sid = requireSessionId(safeArgs, method, result) ?: return
                coordinator.stopRecording(sid) { value, errStr ->
                    replyFromCoordinator(result, value, errStr)
                }
            }

            "disposeDuetSession" -> {
                // dispose is idempotent — accept empty/unknown sessionId gracefully
                val sid = safeArgs["sessionId"] as? String ?: ""
                coordinator.disposeSession(sid) { _, errStr ->
                    replyFromCoordinator(result, null, errStr)
                }
            }

            else -> result.notImplemented()
        }
    }

    // ── Teardown ──────────────────────────────────────────────────────────────

    fun disposeAll() {
        coordinator.disposeAll()
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    @Suppress("UNCHECKED_CAST")
    private fun handleInitialize(args: Map<String, Any?>, result: MethodChannel.Result) {
        val sourceRaw = args["source"] as? Map<String, Any?>
        val trimRaw   = args["trimWindow"] as? Map<String, Any?>
        if (sourceRaw == null || trimRaw == null) {
            result.error("source_invalid",
                "initializeDuetSession: missing required arguments 'source' and/or 'trimWindow'.",
                null)
            return
        }
        val layoutMap  = args["layoutConfig"] as? Map<String, Any?> ?: mapOf("mode" to "pip")
        val speed      = (args["speed"]       as? Number)?.toDouble() ?: 1.0
        val sourceGain = (args["sourceGain"]  as? Number)?.toDouble() ?: 1.0
        val micGain    = (args["micGain"]     as? Number)?.toDouble() ?: 1.0

        coordinator.initializeSession(
            sourceMap        = sourceRaw,
            trimWindowMap    = trimRaw,
            layoutConfigMap  = layoutMap,
            speed            = speed,
            sourceGain       = sourceGain,
            micGain          = micGain,
        ) { sessionId, errStr ->
            if (errStr != null) {
                val (code, message) = splitError(errStr)
                result.error(code, message, null)
            } else {
                result.success(sessionId)
            }
        }
    }

    private fun requireSessionId(
        args: Map<String, Any?>,
        method: String,
        result: MethodChannel.Result,
    ): String? {
        val sid = args["sessionId"] as? String
        if (sid.isNullOrEmpty()) {
            result.error("source_invalid",
                "$method: missing required argument 'sessionId'.", null)
            return null
        }
        return sid
    }

    /**
     * Routes coordinator reply to the Flutter result.
     * [errStr] is encoded as "code|message" by the coordinator when non-null.
     */
    private fun replyFromCoordinator(
        result: MethodChannel.Result,
        value: Any?,
        errStr: String?,
    ) {
        if (errStr != null) {
            val (code, message) = splitError(errStr)
            result.error(code, message, null)
        } else {
            result.success(value)
        }
    }

    /** Splits "code|message" encoding used by AndroidDuetSessionCoordinator. */
    private fun splitError(errStr: String): Pair<String, String> {
        val idx = errStr.indexOf('|')
        return if (idx < 0) Pair("unknown", errStr)
        else Pair(errStr.substring(0, idx), errStr.substring(idx + 1))
    }
}
