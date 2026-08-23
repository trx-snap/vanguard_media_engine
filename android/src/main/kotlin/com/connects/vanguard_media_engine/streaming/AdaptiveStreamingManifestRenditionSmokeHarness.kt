package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C5C: Streaming Manifest & Rendition Ladder Smoke Harness.
 *
 * Official Android & Media3 Platform Facts:
 * - Media3 ExoPlayer supports HLS, Apple LL-HLS, and DASH containers.
 * - Multivariant adaptation in HLS depends on variant #EXT-X-STREAM-INF entries plus device capabilities.
 * - DASH adaptation relies on Period -> AdaptationSet -> Representation hierarchies.
 * - ExoPlayer network stacks are injected through DataSource factories, but diagnostic ladder
 *   inspection must remain pure, bounded, and decoupled from playback session lifecycles.
 * - Product Policy: Future server ladders may add HEVC and AV1 renditions, but AVC/H.264 fallback
 *   must remain mandatory so older Android devices and iOS mirrors do not hiccup.
 *
 * Verification Invariants:
 * - Inspects three canonical test streams:
 *   1. HLS (Mux multivariant test stream)
 *   2. DASH (Shaka demo Angel One multi-representation MPD)
 *   3. LL-HLS (Mux low-latency test stream)
 * - Verifies manifest fetch succeeded, parsing succeeded without error, representation/variant
 *   metadata is populated (> 0), and server ladder policy (AVC fallback presence) is satisfied.
 * - LL-HLS tags are diagnostic only; lack of LL-HLS tags does not fail the smoke test.
 */
object AdaptiveStreamingManifestRenditionSmokeHarness {

    const val PHASE = "Phase4C5C"
    const val SERVER_LADDER_POLICY = AdaptiveStreamingManifestRenditionInspector.SERVER_LADDER_POLICY
    const val IOS_MIRROR_NOTE = AdaptiveStreamingManifestRenditionInspector.IOS_MIRROR_NOTE

    const val HLS_TEST_URI = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
    const val DASH_TEST_URI = "https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd"
    const val LL_HLS_TEST_URI = "https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8"

    /**
     * Executes the diagnostic manifest rendition smoke suite across HLS, DASH, and LL-HLS streams.
     *
     * @return Structured diagnostic map with pass verdict, individual stream results, aggregate counts, and raw summary.
     */
    fun run(): Map<String, Any?> {
        return try {
            // 1. Inspect HLS stream
            val hlsResult = AdaptiveStreamingManifestRenditionInspector.inspectUri(HLS_TEST_URI, "HLS")
            val hlsFetchSuccess = hlsResult["fetchSuccess"] == true
            val hlsParseSuccess = hlsResult["parseSuccess"] == true
            val hlsVariantCount = (hlsResult["variantCount"] as? Number)?.toInt() ?: 0
            val hlsServerPolicyPass = hlsResult["serverPolicyPass"] == true
            val hlsPass = hlsFetchSuccess && hlsParseSuccess && hlsVariantCount > 0 && hlsServerPolicyPass

            // 2. Inspect DASH stream
            val dashResult = AdaptiveStreamingManifestRenditionInspector.inspectUri(DASH_TEST_URI, "DASH")
            val dashFetchSuccess = dashResult["fetchSuccess"] == true
            val dashParseSuccess = dashResult["parseSuccess"] == true
            val dashRepCount = (dashResult["representationCount"] as? Number)?.toInt()
                ?: (dashResult["variantCount"] as? Number)?.toInt() ?: 0
            val dashServerPolicyPass = dashResult["serverPolicyPass"] == true
            val dashPass = dashFetchSuccess && dashParseSuccess && dashRepCount > 0 && dashServerPolicyPass

            // 3. Inspect LL-HLS stream
            val llHlsResult = AdaptiveStreamingManifestRenditionInspector.inspectUri(LL_HLS_TEST_URI, "HLS")
            val llHlsFetchSuccess = llHlsResult["fetchSuccess"] == true
            val llHlsParseSuccess = llHlsResult["parseSuccess"] == true
            val llHlsVariantCount = (llHlsResult["variantCount"] as? Number)?.toInt() ?: 0
            val llHlsServerPolicyPass = llHlsResult["serverPolicyPass"] == true
            val llHlsPass = llHlsFetchSuccess && llHlsParseSuccess && llHlsVariantCount > 0 && llHlsServerPolicyPass

            val allServerPoliciesPass = hlsServerPolicyPass && dashServerPolicyPass && llHlsServerPolicyPass
            val totalVariants = hlsVariantCount + dashRepCount + llHlsVariantCount
            val overallPass = hlsPass && dashPass && llHlsPass && allServerPoliciesPass

            val rawStatus = if (overallPass) {
                "status=OK;hlsPass=true(variants=$hlsVariantCount);dashPass=true(reps=$dashRepCount);" +
                    "llHlsPass=true(variants=$llHlsVariantCount);totalVariants=$totalVariants;allServerPoliciesPass=true"
            } else {
                "status=MANIFEST_RENDITION_VERIFICATION_FAILED;hlsPass=$hlsPass;dashPass=$dashPass;" +
                    "llHlsPass=$llHlsPass;allServerPoliciesPass=$allServerPoliciesPass"
            }

            mapOf(
                "pass" to overallPass,
                "phase" to PHASE,
                "hlsPass" to hlsPass,
                "dashPass" to dashPass,
                "llHlsPass" to llHlsPass,
                "allServerPoliciesPass" to allServerPoliciesPass,
                "totalStreamsInspected" to 3,
                "totalVariantsDiscovered" to totalVariants,
                "hlsVariantCount" to hlsVariantCount,
                "dashRepresentationCount" to dashRepCount,
                "llHlsVariantCount" to llHlsVariantCount,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "hls" to hlsResult,
                "dash" to dashResult,
                "llHls" to llHlsResult,
                "raw" to rawStatus,
            )
        } catch (t: Throwable) {
            mapOf(
                "pass" to false,
                "phase" to PHASE,
                "hlsPass" to false,
                "dashPass" to false,
                "llHlsPass" to false,
                "allServerPoliciesPass" to false,
                "totalStreamsInspected" to 3,
                "totalVariantsDiscovered" to 0,
                "hlsVariantCount" to 0,
                "dashRepresentationCount" to 0,
                "llHlsVariantCount" to 0,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "raw" to "status=UNEXPECTED_ERROR;reason=${t.javaClass.simpleName}:${t.message}",
            )
        }
    }
}
