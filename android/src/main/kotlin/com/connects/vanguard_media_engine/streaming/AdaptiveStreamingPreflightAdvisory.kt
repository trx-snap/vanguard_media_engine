package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C5G: Streaming Preflight Advisory API.
 *
 * Official Android & Media3 Platform Facts:
 * - Media3 supports HLS, Apple LL-HLS, and DASH, but contained sample formats must be supported
 *   by the device.
 * - Media3/ExoPlayer adaptive track selection updates selected tracks using bandwidth and buffer state;
 *   the player remains responsible for ABR during playback.
 * - Media3 track-selection constraints can be specified before tracks are known, but this slice must
 *   only advise the host which existing Vanguard [AdaptiveStreamingNetworkProfile] to pass later.
 * - Media3 network stacks are DataSource-based; this slice must not change from the current
 *   [DefaultHttpDataSource] path or add HttpEngine/Cronet/OkHttp.
 *
 * Advisory Invariants:
 * - Pure diagnostic advisory: MUST NEVER instantiate ExoPlayer, MediaCodec, Surface, ImageReader,
 *   HardwareBuffer, Vulkan, GLES, DAG renderers, LiveKit, WebRTC, or audio room SDKs.
 * - Composes Phase 4C5E compatibility decision ([AdaptiveStreamingCompatibilityDecisionReport])
 *   with Phase 4C5B network profiles ([AdaptiveStreamingNetworkPolicy]).
 * - Advisory-only: does not instantiate playback, mutate Media3 player setup, force tracks,
 *   change ABR, change HLS/DASH/LL-HLS behavior, or touch RTC.
 */
object AdaptiveStreamingPreflightAdvisory {

    const val PHASE = "Phase4C5G"
    const val SERVER_LADDER_POLICY = AdaptiveStreamingCompatibilityDecisionReport.SERVER_LADDER_POLICY
    const val IOS_MIRROR_NOTE = AdaptiveStreamingCompatibilityDecisionReport.IOS_MIRROR_NOTE

    // Warning constants
    const val WARNING_INVALID_NETWORK_PROFILE = "invalid_network_profile"
    const val WARNING_LOW_LATENCY_DEFERRED_FOR_CONSTRAINED = "low_latency_deferred_for_constrained_network"
    const val WARNING_LOW_LATENCY_MANIFEST_ABSENT = "low_latency_manifest_absent"
    const val WARNING_NO_MANIFEST_SPECS = "no_manifest_specs"

    // Decision constants
    const val DECISION_BLOCKED_NO_MANIFEST_SPECS = "blocked_no_manifest_specs"
    const val DECISION_BLOCKED_COMPATIBILITY_FAILED = "blocked_compatibility_failed"
    const val DECISION_ADVISE_CONSTRAINED = "advise_constrained"
    const val DECISION_ADVISE_LOW_LATENCY = "advise_low_latency"
    const val DECISION_ADVISE_STABLE = "advise_stable"

    /**
     * Builds a preflight advisory report for the given manifest specs and requested network configuration.
     *
     * @param specs List of host-supplied manifest specs.
     * @param requestedNetworkProfileRaw String representation of requested [AdaptiveStreamingNetworkProfile] (default: "AUTO").
     * @param preferLowLatency Whether host hints preference for low latency playback (default: false).
     * @param allowLowLatencyOnConstrained Whether low latency can be advised even on constrained profiles (default: false).
     * @return Structured diagnostic advisory report map.
     */
    fun buildAdvisory(
        specs: List<Map<*, *>>,
        requestedNetworkProfileRaw: String = "AUTO",
        preferLowLatency: Boolean = false,
        allowLowLatencyOnConstrained: Boolean = false,
    ): Map<String, Any?> {
        val warnings = mutableListOf<String>()

        val parsedProfile: AdaptiveStreamingNetworkProfile = try {
            AdaptiveStreamingNetworkProfile.valueOf(requestedNetworkProfileRaw.trim().uppercase())
        } catch (_: Throwable) {
            warnings.add(WARNING_INVALID_NETWORK_PROFILE)
            AdaptiveStreamingNetworkProfile.AUTO
        }

        if (specs.isEmpty()) {
            warnings.add(WARNING_NO_MANIFEST_SPECS)
            val recommendedProfile = AdaptiveStreamingNetworkProfile.CONSTRAINED
            val recommendedPolicy = AdaptiveStreamingNetworkPolicy.forProfile(recommendedProfile).toDiagnosticMap()
            return mapOf(
                "phase" to PHASE,
                "pass" to false,
                "compatibilityDecision" to emptyMap<String, Any?>(),
                "compatibilityReports" to emptyList<Map<String, Any?>>(),
                "totalReports" to 0,
                "passedReports" to 0,
                "failedReports" to 0,
                "deviceWarnings" to emptyList<String>(),
                "warnings" to warnings,
                "advisoryDecision" to DECISION_BLOCKED_NO_MANIFEST_SPECS,
                "requestedNetworkProfile" to parsedProfile.name,
                "recommendedNetworkProfile" to recommendedProfile.name,
                "recommendedNetworkPolicy" to recommendedPolicy,
                "preferLowLatency" to preferLowLatency,
                "allowLowLatencyOnConstrained" to allowLowLatencyOnConstrained,
                "llHlsAvailable" to false,
                "advisoryOnly" to true,
                "playbackMutation" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "raw" to "status=FAIL;reason=no_manifest_specs",
            )
        }

        // 1. Probe compatibility once
        val compatibilityDecision = AdaptiveStreamingCompatibilityDecisionReport.buildReports(specs)
        @Suppress("UNCHECKED_CAST")
        val compatibilityReports = (compatibilityDecision["reports"] as? List<Map<String, Any?>>) ?: emptyList()
        val totalReports = (compatibilityDecision["totalReports"] as? Number)?.toInt() ?: compatibilityReports.size
        val passedReports = (compatibilityDecision["passedReports"] as? Number)?.toInt() ?: 0
        val failedReports = (compatibilityDecision["failedReports"] as? Number)?.toInt() ?: (totalReports - passedReports)
        val compatibilityPass = compatibilityDecision["pass"] == true
        @Suppress("UNCHECKED_CAST")
        val deviceWarnings = (compatibilityDecision["deviceWarnings"] as? List<String>) ?: emptyList()

        // 2. Detect LL-HLS availability across inspected manifests
        val llHlsAvailable = compatibilityReports.any { report ->
            val manifestValidation = report["manifestValidation"] as? Map<*, *>
            val inspection = manifestValidation?.get("inspection") as? Map<*, *>
            val llHlsIndicators = inspection?.get("llHlsIndicators") as? Map<*, *>
            llHlsIndicators?.get("isLlHls") == true
        }

        // 3. Compute recommendedNetworkProfile and advisoryDecision
        val pass: Boolean
        val recommendedProfile: AdaptiveStreamingNetworkProfile
        val advisoryDecision: String

        if (!compatibilityPass || failedReports > 0 || totalReports == 0) {
            pass = false
            recommendedProfile = AdaptiveStreamingNetworkProfile.CONSTRAINED
            advisoryDecision = DECISION_BLOCKED_COMPATIBILITY_FAILED
        } else {
            pass = true
            when {
                parsedProfile == AdaptiveStreamingNetworkProfile.CONSTRAINED -> {
                    recommendedProfile = AdaptiveStreamingNetworkProfile.CONSTRAINED
                    advisoryDecision = DECISION_ADVISE_CONSTRAINED
                    if (preferLowLatency && !allowLowLatencyOnConstrained) {
                        warnings.add(WARNING_LOW_LATENCY_DEFERRED_FOR_CONSTRAINED)
                    }
                }
                parsedProfile == AdaptiveStreamingNetworkProfile.LOW_LATENCY || preferLowLatency -> {
                    if (llHlsAvailable) {
                        recommendedProfile = AdaptiveStreamingNetworkProfile.LOW_LATENCY
                        advisoryDecision = DECISION_ADVISE_LOW_LATENCY
                    } else {
                        recommendedProfile = AdaptiveStreamingNetworkProfile.STABLE
                        advisoryDecision = DECISION_ADVISE_STABLE
                        warnings.add(WARNING_LOW_LATENCY_MANIFEST_ABSENT)
                    }
                }
                parsedProfile == AdaptiveStreamingNetworkProfile.STABLE -> {
                    recommendedProfile = AdaptiveStreamingNetworkProfile.STABLE
                    advisoryDecision = DECISION_ADVISE_STABLE
                }
                parsedProfile == AdaptiveStreamingNetworkProfile.AUTO -> {
                    recommendedProfile = AdaptiveStreamingNetworkProfile.STABLE
                    advisoryDecision = DECISION_ADVISE_STABLE
                }
                else -> {
                    recommendedProfile = AdaptiveStreamingNetworkProfile.STABLE
                    advisoryDecision = DECISION_ADVISE_STABLE
                }
            }
        }

        val recommendedPolicy = AdaptiveStreamingNetworkPolicy.forProfile(recommendedProfile).toDiagnosticMap()

        val rawStatus = if (pass) {
            "status=OK;decision=$advisoryDecision;recommended=${recommendedProfile.name};" +
                "requested=${parsedProfile.name};llHlsAvailable=$llHlsAvailable;totalReports=$totalReports;" +
                "passedReports=$passedReports;failedReports=0"
        } else {
            "status=PREFLIGHT_ADVISORY_FAILED;decision=$advisoryDecision;recommended=${recommendedProfile.name};" +
                "requested=${parsedProfile.name};warnings=${warnings.joinToString(",")};" +
                "compatibilityPass=$compatibilityPass;totalReports=$totalReports;failedReports=$failedReports"
        }

        return mapOf(
            "phase" to PHASE,
            "pass" to pass,
            "compatibilityDecision" to compatibilityDecision,
            "compatibilityReports" to compatibilityReports,
            "totalReports" to totalReports,
            "passedReports" to passedReports,
            "failedReports" to failedReports,
            "deviceWarnings" to deviceWarnings,
            "warnings" to warnings,
            "advisoryDecision" to advisoryDecision,
            "requestedNetworkProfile" to parsedProfile.name,
            "recommendedNetworkProfile" to recommendedProfile.name,
            "recommendedNetworkPolicy" to recommendedPolicy,
            "preferLowLatency" to preferLowLatency,
            "allowLowLatencyOnConstrained" to allowLowLatencyOnConstrained,
            "llHlsAvailable" to llHlsAvailable,
            "advisoryOnly" to true,
            "playbackMutation" to false,
            "serverLadderPolicy" to SERVER_LADDER_POLICY,
            "iosMirrorNote" to IOS_MIRROR_NOTE,
            "raw" to rawStatus,
        )
    }
}
