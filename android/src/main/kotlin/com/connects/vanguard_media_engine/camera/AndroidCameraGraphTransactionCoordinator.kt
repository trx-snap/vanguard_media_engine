package com.connects.vanguard_media_engine.camera

import io.flutter.plugin.common.MethodChannel

/**
 * Phase 6C.2A/6C.2B Android: owns the public Dart VGCameraSession route
 * (applyGraphTransaction).
 *
 * LIVE-CAMERA-BEAUTY-PARITY: this coordinator now routes recognized "beauty"
 * filter presets to the live camera beauty SurfaceProcessor pipeline via
 * [setBeautyIntensity], replacing the previous GRAPH_MODE_DISABLED fail-close
 * guard for the beauty filter type. LUT and segmentation filters remain
 * unsupported and still fail closed with GRAPH_MODE_DISABLED.
 *
 * Supported beauty intensity mapping (matches iOS preset levels):
 *   - "none" / enabled=false / intensity=0.0 -> 0.0 (passthrough)
 *   - "soft"  / intensity=0.5                -> 0.5
 *   - "strong" / intensity=0.75              -> 0.75
 *   - "max"   / intensity=1.0                -> 1.0
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
 *  - any enabled LUT or segmentation filter               -> GRAPH_MODE_DISABLED
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
    private val setBeautyIntensity: (Float) -> Unit = {},
    private val setColorFilter: (CameraColorFilterState?) -> Unit = {},
    private val updateColorFilterIntensity: ((Float) -> Unit)? = null,
) {
    companion object {
        private val KNOWN_FILTER_TYPES = setOf("lut", "beauty", "colormatrix", "colorMatrix", "segmentation")

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
                val isKnown = KNOWN_FILTER_TYPES.any { it.equals(type, ignoreCase = true) }
                if (!isKnown) {
                    result.error("UNKNOWN_FILTER", "applyGraphTransaction: unrecognized filter type: $type", null)
                    return
                }
            }

            // Empty filter list -- "no filters are applied" is trivially satisfied.
            // Also reset beauty and color filters to passthrough.
            if (rawFilterStack.isEmpty()) {
                setBeautyIntensity(0f)
                setColorFilter(null)
                result.success(null)
                return
            }

            @Suppress("UNCHECKED_CAST")
            val filterStack = rawFilterStack as List<Map<*, *>>
            val anyEnabled = filterStack.any { (it["enabled"] as? Boolean) ?: true }
            if (!anyEnabled) {
                // All filters disabled — reset to passthrough.
                setBeautyIntensity(0f)
                setColorFilter(null)
                result.success(null)
                return
            }

            // CAM-01 / LIVE-CAMERA-BEAUTY-PARITY: route beauty and color/LUT filters to
            // the live camera beauty SurfaceProcessor pipeline.
            var beautyHandled = false
            var colorFilterHandled = false
            var hasUnsupportedEnabled = false

            for (filter in filterStack) {
                val type = filter["type"] as? String ?: continue
                val enabled = (filter["enabled"] as? Boolean) ?: true
                if (!enabled) continue

                when (type.lowercase()) {
                    "beauty" -> {
                        val intensityValue = extractBeautyIntensity(filter)
                        setBeautyIntensity(intensityValue)
                        beautyHandled = true
                    }
                    "lut", "colormatrix" -> {
                        val filterState = CameraColorFilterState.fromFilterMap(filter, defaultType = type)
                        setColorFilter(filterState)
                        colorFilterHandled = true
                    }
                    else -> {
                        // Segmentation — not yet available on Android live camera.
                        hasUnsupportedEnabled = true
                    }
                }
            }

            // In a rebuild transaction, any unmentioned effect is reset.
            if (!beautyHandled) {
                setBeautyIntensity(0f)
            }
            if (!colorFilterHandled) {
                setColorFilter(null)
            }

            if (hasUnsupportedEnabled && !beautyHandled && !colorFilterHandled) {
                // Only unsupported (e.g. segmentation) filters present — fail closed.
                result.error(
                    "GRAPH_MODE_DISABLED",
                    "applyGraphTransaction: Android camera graph/filter execution is not available for non-beauty/non-LUT filters.",
                    null,
                )
                return
            }

            // At least one valid filter handled (or best-effort parity with unsupported filters).
            result.success(null)
            return
        }

        // ── B. No-op success (requiresRebuild == false, parameterUpdates empty) ──
        if (parameterUpdatesEmpty) {
            result.success(null)
            return
        }

        // ── C. Hot parameter path — route beauty & LUT parameter updates ────────────
        @Suppress("UNCHECKED_CAST")
        val parameterUpdates = rawParameterUpdates as? Map<String, Any?>
        var handledAny = false

        if (parameterUpdates != null) {
            // Check for beauty intensity in parameter updates.
            val beautyParams = parameterUpdates["beauty"] as? Map<*, *>
            if (beautyParams != null) {
                val intensityValue = (beautyParams["intensity"] as? Number)?.toFloat()
                if (intensityValue != null) {
                    setBeautyIntensity(intensityValue.coerceIn(0f, 1f))
                    handledAny = true
                }
            }

            // Check for lut / colorMatrix in parameter updates.
            val lutParams = (parameterUpdates["lut"] ?: parameterUpdates["colorMatrix"] ?: parameterUpdates["colormatrix"]) as? Map<*, *>
            if (lutParams != null) {
                val intensityValue = (lutParams["intensity"] as? Number)?.toFloat()
                val hasPresetOrMatrix = lutParams.containsKey("preset") || lutParams.containsKey("matrix")
                if (intensityValue != null && !hasPresetOrMatrix && updateColorFilterIntensity != null) {
                    updateColorFilterIntensity.invoke(intensityValue.coerceIn(0f, 1f))
                    handledAny = true
                } else {
                    val filterState = CameraColorFilterState.fromFilterMap(lutParams, defaultType = "lut")
                    setColorFilter(filterState)
                    handledAny = true
                }
            }
        }

        if (handledAny) {
            result.success(null)
            return
        }

        // Non-supported hot parameter updates — fail closed.
        result.error(
            "GRAPH_MODE_DISABLED",
            "applyGraphTransaction: Android camera graph/filter execution is not available for non-beauty/non-LUT parameter updates.",
            null,
        )
    }

    // ── Beauty intensity extraction ─────────────────────────────────────────────

    /**
     * Extracts the beauty intensity from a filter descriptor map.
     * Supports:
     *   - Direct "intensity" key (Float/Double)
     *   - "preset" string: "none"=0.0, "soft"=0.5, "strong"=0.75, "max"=1.0
     * Falls back to 0.75 (strong) if no intensity source is found.
     */
    private fun extractBeautyIntensity(filter: Map<*, *>): Float {
        // Direct intensity value.
        val directIntensity = (filter["intensity"] as? Number)?.toFloat()
        if (directIntensity != null) return directIntensity.coerceIn(0f, 1f)

        // Parameters sub-map.
        val params = filter["parameters"] as? Map<*, *>
        if (params != null) {
            val paramIntensity = (params["intensity"] as? Number)?.toFloat()
            if (paramIntensity != null) return paramIntensity.coerceIn(0f, 1f)

            val preset = params["preset"] as? String
            if (preset != null) return presetToIntensity(preset)
        }

        // Preset at top level.
        val preset = filter["preset"] as? String
        if (preset != null) return presetToIntensity(preset)

        // Default: strong.
        return 0.75f
    }

    private fun presetToIntensity(preset: String): Float = when (preset.lowercase()) {
        "none", "off", "disabled" -> 0f
        "soft", "light" -> 0.5f
        "strong", "medium" -> 0.75f
        "max", "maximum", "heavy" -> 1.0f
        else -> 0.75f
    }
}
