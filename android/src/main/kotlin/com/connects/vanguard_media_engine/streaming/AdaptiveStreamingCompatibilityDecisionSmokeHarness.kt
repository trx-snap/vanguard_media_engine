package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C5E: Streaming Compatibility Decision Smoke Harness.
 *
 * Joins device codec capability diagnostics (Phase 4C5A) with manifest policy validation (Phase 4C5D)
 * into a single compatibility decision report.
 *
 * Official Android & Media3 Platform Facts:
 * - Android platform supported media formats docs list H.264/AVC decoder support as baseline,
 *   HEVC/H.265 decoder support from Android 5.0+, and AV1 decoder support from Android 10+ with
 *   encoder/decoder mandatory beginning Android 14.
 * - Media3 ExoPlayer supports HLS and DASH containers, but contained audio/video sample formats
 *   must also be supported by the device.
 * - Product Policy: Future server ladders may add HEVC and AV1 renditions, but AVC/H.264 fallback
 *   must remain mandatory so older Android devices and iOS mirrors do not hiccup.
 *
 * Verification Invariants:
 * - Evaluates compatibility decision reports across host-supplied or canonical public streams.
 * - Confirms device-safe codec selection and baseline fallback presence.
 * - Pure diagnostic smoke: no media decoders, renderers, or playback sessions instantiated.
 */
object AdaptiveStreamingCompatibilityDecisionSmokeHarness {

    const val PHASE = AdaptiveStreamingCompatibilityDecisionReport.PHASE
    const val SERVER_LADDER_POLICY = AdaptiveStreamingCompatibilityDecisionReport.SERVER_LADDER_POLICY
    const val IOS_MIRROR_NOTE = AdaptiveStreamingCompatibilityDecisionReport.IOS_MIRROR_NOTE

    /**
     * Runs compatibility decision report smoke across the canonical public test streams (HLS, DASH, LL-HLS).
     */
    fun runDefaultPublicCompatibilityDecisionSmoke(): Map<String, Any?> {
        val defaultSpecs = AdaptiveStreamingManifestPolicySmokeHarness.defaultPublicStreamSpecs()
        return runHostCompatibilityDecision(defaultSpecs)
    }

    /**
     * Runs compatibility decision report smoke across host-supplied manifest specs.
     */
    fun runHostCompatibilityDecision(specs: List<Map<*, *>>): Map<String, Any?> {
        if (specs.isEmpty()) {
            return mapOf(
                "phase" to PHASE,
                "pass" to false,
                "totalReports" to 0,
                "passedReports" to 0,
                "failedReports" to 0,
                "codecProbePass" to false,
                "avcSupported" to false,
                "hevcSupported" to false,
                "av1Supported" to false,
                "av1HardwareSafe" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "reports" to emptyList<Map<String, Any?>>(),
                "raw" to "status=FAIL;reason=no_manifest_specs",
            )
        }

        return try {
            AdaptiveStreamingCompatibilityDecisionReport.buildReports(specs)
        } catch (t: Throwable) {
            mapOf(
                "phase" to PHASE,
                "pass" to false,
                "totalReports" to specs.size,
                "passedReports" to 0,
                "failedReports" to specs.size,
                "codecProbePass" to false,
                "avcSupported" to false,
                "hevcSupported" to false,
                "av1Supported" to false,
                "av1HardwareSafe" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "reports" to emptyList<Map<String, Any?>>(),
                "raw" to "status=UNEXPECTED_ERROR;reason=${t.javaClass.simpleName}:${t.message}",
            )
        }
    }
}
