package com.connects.vanguard_media_engine.camera

import io.flutter.plugin.common.MethodChannel

/**
 * Phase 6C.2A/6C.2B Android: owns the public Dart VGCameraSession route
 * (applyGraphTransaction) as an honest guard route only.
 *
 * Non-claims (read before touching this file):
 *  - This slice does NOT implement camera graph filter execution on Android.
 *    No filters are applied to camera pixels, and no GL/filter-node/shader
 *    code is added by this route.
 *  - A no-op success (empty transaction, or a rebuild preset whose
 *    filterStack is empty/all-disabled) proves only route reachability,
 *    guard ordering, and a satisfiable no-filter postcondition. It is not
 *    evidence of filter application.
 *  - Any recognized, enabled filter in a rebuild preset -- or any non-empty
 *    hot parameterUpdates transaction -- fails closed with
 *    GRAPH_MODE_DISABLED. No visual parity with iOS is claimed or implied by
 *    this route.
 *
 * Error codes/messages mirror the iOS route policy in
 * VanguardMediaEnginePlugin.swift's "applyGraphTransaction" case so Dart sees
 * a [PlatformException], never a MissingPluginException:
 *  - args == null                                        -> BAD_ARGS
 *  - no active camera graph session                      -> NO_CAMERA_GRAPH
 *  - requiresRebuild + non-empty parameterUpdates (mixed) -> UNSUPPORTED_TRANSACTION_POLICY
 *  - requiresRebuild without a usable preset/filterStack  -> UNSUPPORTED_TRANSACTION_POLICY
 *  - malformed filterStack entry                          -> BAD_ARGS
 *  - unrecognized filter type                             -> UNKNOWN_FILTER
 *  - any enabled known filter / any non-empty hot update  -> GRAPH_MODE_DISABLED
 *
 * The known filter type set `{ "lut", "beauty", "segmentation" }` mirrors the
 * native runtime authority used by AndroidTimelineLiveControlCoordinator and
 * ios/Classes/VanguardGraphRuntime.m:1305.
 *
 * Stateless: holds no native resources, runs no async work, and does no I/O.
 * Calls arrive on the platform main thread and this route replies
 * synchronously exactly once per call.
 */
class AndroidCameraGraphTransactionCoordinator(
    private val hasActiveCameraProvider: () -> Boolean,
) {
    companion object {
        private val KNOWN_FILTER_TYPES = setOf("lut", "beauty", "segmentation")

        private val OWNED_METHODS = setOf(
            "applyGraphTransaction",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        when (method) {
            "applyGraphTransaction" -> applyGraphTransaction(args, result)
            else -> return false
        }
        return true
    }

    // ── applyGraphTransaction ───────────────────────────────────────────────────

    private fun applyGraphTransaction(args: Map<*, *>?, result: MethodChannel.Result) {
        if (args == null) {
            result.error("BAD_ARGS", "applyGraphTransaction expects a payload dictionary.", null)
            return
        }

        if (!hasActiveCameraProvider()) {
            result.error("NO_CAMERA_GRAPH", "Camera graph session is not running.", null)
            return
        }

        val requiresRebuild = args["requiresRebuild"] as? Boolean ?: false
        val rawParameterUpdates = args["parameterUpdates"]
        val parameterUpdatesEmpty = (rawParameterUpdates as? Map<*, *>)?.isEmpty() ?: true

        // ── A. Rebuild path (6C.2A) ─────────────────────────────────────────────
        if (requiresRebuild) {
            // Reject mixed preset + parameterUpdates: the preset establishes the
            // full filter-chain state; hot overlays in the same rebuild
            // transaction are unsupported and produce ambiguous results.
            if (!parameterUpdatesEmpty) {
                result.error(
                    "UNSUPPORTED_TRANSACTION_POLICY",
                    "Mixed rebuild+parameterUpdates transactions are not " +
                        "supported. Use a preset-only rebuild transaction.",
                    null,
                )
                return
            }

            val presetDict = args["preset"] as? Map<*, *>
            val rawFilterStack = presetDict?.get("filterStack") as? List<*>
            if (presetDict == null || rawFilterStack == null) {
                result.error(
                    "UNSUPPORTED_TRANSACTION_POLICY",
                    "Rebuild transactions without a preset are not " +
                        "supported in Phase 6C.2A.",
                    null,
                )
                return
            }

            for (rawFilter in rawFilterStack) {
                val filter = rawFilter as? Map<*, *>
                val type = filter?.get("type")
                if (filter == null || type !is String || type.isEmpty()) {
                    result.error(
                        "BAD_ARGS",
                        "applyGraphTransaction: preset filterStack entries must be maps with a non-empty \"type\".",
                        null,
                    )
                    return
                }
                if (type !in KNOWN_FILTER_TYPES) {
                    result.error("UNKNOWN_FILTER", "applyGraphTransaction: unrecognized filter type: $type", null)
                    return
                }
            }

            // Empty filter list -- "no filters are applied" is trivially satisfied.
            if (rawFilterStack.isEmpty()) {
                result.success(null)
                return
            }

            @Suppress("UNCHECKED_CAST")
            val filterStack = rawFilterStack as List<Map<*, *>>
            val anyEnabled = filterStack.any { (it["enabled"] as? Boolean) ?: true }
            if (!anyEnabled) {
                result.success(null)
                return
            }

            result.error(
                "GRAPH_MODE_DISABLED",
                "applyGraphTransaction: Android camera graph/filter execution is not available in this slice.",
                null,
            )
            return
        }

        // ── B. No-op success (requiresRebuild == false, parameterUpdates empty) ──
        if (parameterUpdatesEmpty) {
            result.success(null)
            return
        }

        // ── C. Hot parameter path -- fails closed (6C.2B not available on Android) ──
        result.error(
            "GRAPH_MODE_DISABLED",
            "applyGraphTransaction: Android camera graph/filter execution is not available in this slice.",
            null,
        )
    }
}
