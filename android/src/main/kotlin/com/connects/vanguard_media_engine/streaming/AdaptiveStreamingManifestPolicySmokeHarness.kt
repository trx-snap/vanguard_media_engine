package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C5D: Streaming Manifest Policy Smoke Harness.
 *
 * Official Android & Media3 Platform Facts:
 * - Media3 ExoPlayer supports HLS, Apple LL-HLS, and DASH containers.
 * - Multivariant adaptation in HLS depends on variant #EXT-X-STREAM-INF entries plus device capabilities.
 * - DASH adaptation relies on Period -> AdaptationSet -> Representation hierarchies.
 * - ExoPlayer network stacks are DataSource-based; diagnostic manifest policy validation is decoupled
 *   from playback sessions.
 * - Product Policy: Future server ladders may add HEVC and AV1 renditions, but AVC/H.264 fallback
 *   must remain mandatory so older Android devices and iOS mirrors do not hiccup.
 *
 * Verification Invariants:
 * - Validates host-supplied manifest specs against Vanguard ladder policy.
 * - Default smoke runs against the canonical public test streams (HLS, DASH, LL-HLS).
 * - Enforces segment rejection security assertion (rejection of media segment URLs before fetch).
 * - Aggregate result surfaces pass/fail counts, individual validation results, and mirror notes.
 */
object AdaptiveStreamingManifestPolicySmokeHarness {

    const val PHASE = "Phase4C5D"
    const val SERVER_LADDER_POLICY = AdaptiveStreamingManifestRenditionInspector.SERVER_LADDER_POLICY
    const val IOS_MIRROR_NOTE = AdaptiveStreamingManifestRenditionInspector.IOS_MIRROR_NOTE

    const val HLS_TEST_URI = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
    const val DASH_TEST_URI = "https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd"
    const val LL_HLS_TEST_URI = "https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8"
    const val FAKE_SEGMENT_TEST_URI = "https://example.com/video/segment_00001.m4s"

    /**
     * Default canonical public stream specs for smoke verification.
     */
    fun defaultPublicStreamSpecs(): List<Map<String, Any?>> = listOf(
        mapOf(
            "key" to "mux_hls_test",
            "uri" to HLS_TEST_URI,
            "formatHint" to "HLS",
            "requireAdaptiveLadder" to true,
            "requireAvcFallback" to true,
            "requireLlHlsTags" to false,
            "allowMediaPlaylist" to false,
        ),
        mapOf(
            "key" to "shaka_angel_one_dash",
            "uri" to DASH_TEST_URI,
            "formatHint" to "DASH",
            "requireAdaptiveLadder" to true,
            "requireAvcFallback" to true,
            "requireLlHlsTags" to false,
            "allowMediaPlaylist" to false,
        ),
        mapOf(
            "key" to "mux_ll_hls_test",
            "uri" to LL_HLS_TEST_URI,
            "formatHint" to "HLS",
            "requireAdaptiveLadder" to true,
            "requireAvcFallback" to true,
            "requireLlHlsTags" to false,
            "allowMediaPlaylist" to false,
        ),
    )

    /**
     * Runs the default public manifest policy smoke test suite.
     */
    fun runDefaultPublicManifestPolicySmoke(): Map<String, Any?> {
        return runHostManifestPolicyValidation(defaultPublicStreamSpecs())
    }

    /**
     * Runs host-supplied manifest policy validation for given specs and verifies segment rejection.
     */
    fun runHostManifestPolicyValidation(specs: List<Map<*, *>>): Map<String, Any?> {
        if (specs.isEmpty()) {
            return mapOf(
                "phase" to PHASE,
                "pass" to false,
                "totalManifestsValidated" to 0,
                "passedManifests" to 0,
                "failedManifests" to 0,
                "segmentRejectionPass" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "results" to emptyList<Map<String, Any?>>(),
                "segmentRejectionResult" to emptyMap<String, Any?>(),
                "raw" to "status=FAIL;reason=no_manifest_specs",
            )
        }

        return try {
            // 1. Validate host/public manifest specs
            val results = AdaptiveStreamingManifestPolicyValidator.validateSpecs(specs)
            val totalManifestsValidated = results.size
            val passedManifests = results.count { it["pass"] == true }
            val failedManifests = totalManifestsValidated - passedManifests

            // 2. Perform internal segment rejection security assertion
            val fakeSegmentSpec = mapOf(
                "key" to "segment_rejection_probe",
                "uri" to FAKE_SEGMENT_TEST_URI,
                "formatHint" to "AUTO",
            )
            val segmentResult = AdaptiveStreamingManifestPolicyValidator.validateSpec(fakeSegmentSpec)
            val segmentRaw = segmentResult["raw"] as? String ?: ""
            val segmentInspectionRaw = (segmentResult["inspection"] as? Map<*, *>)?.get("raw") as? String ?: ""
            // Segment must be rejected before fetch (fetchSuccess false and contains media_segment_uri_rejected)
            val segmentRejectionPass = segmentResult["fetchSuccess"] == false &&
                (segmentRaw.contains("media_segment_uri_rejected") ||
                    segmentInspectionRaw.contains("media_segment_uri_rejected") ||
                    segmentResult["policyFailures"] == listOf(AdaptiveStreamingManifestPolicyValidator.FAILURE_FETCH_FAILED))

            // 3. Overall pass verdict: all manifests passed, at least 1 validated, and segment rejection passed
            val allManifestsPass = failedManifests == 0 && totalManifestsValidated > 0
            val overallPass = allManifestsPass && segmentRejectionPass

            val rawStatus = if (overallPass) {
                "status=OK;total=$totalManifestsValidated;passed=$passedManifests;failed=0;" +
                    "segmentRejectionPass=true;allManifestsPass=true"
            } else {
                "status=MANIFEST_POLICY_VALIDATION_FAILED;total=$totalManifestsValidated;passed=$passedManifests;" +
                    "failed=$failedManifests;segmentRejectionPass=$segmentRejectionPass;allManifestsPass=$allManifestsPass"
            }

            mapOf(
                "phase" to PHASE,
                "pass" to overallPass,
                "totalManifestsValidated" to totalManifestsValidated,
                "passedManifests" to passedManifests,
                "failedManifests" to failedManifests,
                "segmentRejectionPass" to segmentRejectionPass,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "results" to results,
                "segmentRejectionResult" to segmentResult,
                "raw" to rawStatus,
            )
        } catch (t: Throwable) {
            mapOf(
                "phase" to PHASE,
                "pass" to false,
                "totalManifestsValidated" to specs.size,
                "passedManifests" to 0,
                "failedManifests" to specs.size,
                "segmentRejectionPass" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "results" to emptyList<Map<String, Any?>>(),
                "raw" to "status=UNEXPECTED_ERROR;reason=${t.javaClass.simpleName}:${t.message}",
            )
        }
    }
}
