package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C5G: Streaming Preflight Advisory Smoke Harness.
 *
 * Joins manifest policy validation (Phase 4C5D), codec compatibility decision (Phase 4C5E),
 * and network profile policy (Phase 4C5B) into host-facing preflight advisory verification.
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
 * Verification Invariants:
 * - Evaluates preflight advisory reports across canonical public streams or host-supplied specs.
 * - Smoke pass requires: advisory pass true, totalReports=3, failedReports=0,
 *   recommendedNetworkProfile="CONSTRAINED", recommendedNetworkPolicy.profile="CONSTRAINED",
 *   advisoryOnly=true, playbackMutation=false.
 * - Pure diagnostic smoke: no media decoders, renderers, or playback sessions instantiated.
 */
object AdaptiveStreamingPreflightAdvisorySmokeHarness {

    const val PHASE = AdaptiveStreamingPreflightAdvisory.PHASE
    const val SERVER_LADDER_POLICY = AdaptiveStreamingPreflightAdvisory.SERVER_LADDER_POLICY
    const val IOS_MIRROR_NOTE = AdaptiveStreamingPreflightAdvisory.IOS_MIRROR_NOTE

    /**
     * Runs preflight advisory smoke across the canonical public test streams (HLS, DASH, LL-HLS)
     * using CONSTRAINED network profile.
     */
    fun runDefaultPublicPreflightAdvisorySmoke(): Map<String, Any?> {
        val defaultSpecs = AdaptiveStreamingManifestPolicySmokeHarness.defaultPublicStreamSpecs()
        return runHostPreflightAdvisory(
            specs = defaultSpecs,
            requestedNetworkProfileRaw = "CONSTRAINED",
            preferLowLatency = false,
            allowLowLatencyOnConstrained = false,
        )
    }

    /**
     * Runs preflight advisory smoke across host-supplied manifest specs and network configuration.
     */
    fun runHostPreflightAdvisory(
        specs: List<Map<*, *>>,
        requestedNetworkProfileRaw: String = "CONSTRAINED",
        preferLowLatency: Boolean = false,
        allowLowLatencyOnConstrained: Boolean = false,
    ): Map<String, Any?> {
        if (specs.isEmpty()) {
            return mapOf(
                "phase" to PHASE,
                "pass" to false,
                "compatibilityDecision" to emptyMap<String, Any?>(),
                "compatibilityReports" to emptyList<Map<String, Any?>>(),
                "totalReports" to 0,
                "passedReports" to 0,
                "failedReports" to 0,
                "deviceWarnings" to emptyList<String>(),
                "warnings" to listOf("no_manifest_specs"),
                "advisoryDecision" to AdaptiveStreamingPreflightAdvisory.DECISION_BLOCKED_NO_MANIFEST_SPECS,
                "requestedNetworkProfile" to requestedNetworkProfileRaw,
                "recommendedNetworkProfile" to AdaptiveStreamingNetworkProfile.CONSTRAINED.name,
                "recommendedNetworkPolicy" to AdaptiveStreamingNetworkPolicy.forProfile(AdaptiveStreamingNetworkProfile.CONSTRAINED).toDiagnosticMap(),
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

        return try {
            AdaptiveStreamingPreflightAdvisory.buildAdvisory(
                specs = specs,
                requestedNetworkProfileRaw = requestedNetworkProfileRaw,
                preferLowLatency = preferLowLatency,
                allowLowLatencyOnConstrained = allowLowLatencyOnConstrained,
            )
        } catch (t: Throwable) {
            mapOf(
                "phase" to PHASE,
                "pass" to false,
                "compatibilityDecision" to emptyMap<String, Any?>(),
                "compatibilityReports" to emptyList<Map<String, Any?>>(),
                "totalReports" to specs.size,
                "passedReports" to 0,
                "failedReports" to specs.size,
                "deviceWarnings" to emptyList<String>(),
                "warnings" to listOf("unexpected_error:${t.javaClass.simpleName}"),
                "advisoryDecision" to AdaptiveStreamingPreflightAdvisory.DECISION_BLOCKED_COMPATIBILITY_FAILED,
                "requestedNetworkProfile" to requestedNetworkProfileRaw,
                "recommendedNetworkProfile" to AdaptiveStreamingNetworkProfile.CONSTRAINED.name,
                "recommendedNetworkPolicy" to AdaptiveStreamingNetworkPolicy.forProfile(AdaptiveStreamingNetworkProfile.CONSTRAINED).toDiagnosticMap(),
                "preferLowLatency" to preferLowLatency,
                "allowLowLatencyOnConstrained" to allowLowLatencyOnConstrained,
                "llHlsAvailable" to false,
                "advisoryOnly" to true,
                "playbackMutation" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "raw" to "status=UNEXPECTED_ERROR;reason=${t.javaClass.simpleName}:${t.message}",
            )
        }
    }
}
