package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C5D: Host-Supplied Streaming Manifest Policy Validator.
 *
 * Official Android & Media3 Platform Facts:
 * - Media3 ExoPlayer supports HLS, Apple LL-HLS, and DASH containers.
 * - Multivariant adaptation in HLS depends on variant #EXT-X-STREAM-INF entries plus device capabilities.
 * - DASH adaptation relies on Period -> AdaptationSet -> Representation hierarchies.
 * - ExoPlayer network stacks are DataSource-based; this diagnostic policy validator is pure and
 *   does not alter playback network stack or session behavior.
 * - Product Policy: Future server ladders may add HEVC and AV1 renditions, but AVC/H.264 fallback
 *   must remain mandatory so older Android devices and iOS mirrors do not hiccup.
 *
 * Mechanical Invariants:
 * - Calls only [AdaptiveStreamingManifestRenditionInspector.inspectUri].
 * - Pure diagnostic route: MUST NEVER instantiate ExoPlayer, MediaCodec, Surface, ImageReader,
 *   HardwareBuffer, Vulkan, GLES, DAG renderers, LiveKit, WebRTC, or any audio/room SDK.
 * - MUST NEVER download media segments. Segment rejection is strictly delegated and enforced.
 * - Returns structured maps/lists suitable for MethodChannel serialization.
 */
object AdaptiveStreamingManifestPolicyValidator {

    private const val TAG = "ManifestPolicyVal"

    const val PHASE = "Phase4C5D"
    const val SERVER_LADDER_POLICY = AdaptiveStreamingManifestRenditionInspector.SERVER_LADDER_POLICY
    const val IOS_MIRROR_NOTE = AdaptiveStreamingManifestRenditionInspector.IOS_MIRROR_NOTE

    // Policy failure reason constants
    const val FAILURE_FETCH_FAILED = "fetch_failed"
    const val FAILURE_PARSE_FAILED = "parse_failed"
    const val FAILURE_ADAPTIVE_LADDER_REQUIRED = "adaptive_ladder_required"
    const val FAILURE_MEDIA_PLAYLIST_NOT_ALLOWED = "media_playlist_not_allowed"
    const val FAILURE_AVC_FALLBACK_REQUIRED = "avc_fallback_required_for_modern_codecs"
    const val FAILURE_LL_HLS_TAGS_REQUIRED = "ll_hls_tags_required"
    const val FAILURE_INVALID_MANIFEST_SPEC = "invalid_manifest_spec"

    /**
     * Validates a single host-supplied manifest spec against Vanguard streaming ladder policies.
     *
     * @param spec Map containing manifest specification parameters:
     *   - `key`: String (required, non-blank)
     *   - `uri`: String (required, non-blank)
     *   - `formatHint`: String (optional, "AUTO", "HLS", "DASH"; default "AUTO")
     *   - `httpHeaders`: Map<String, String> (optional)
     *   - `requireAdaptiveLadder`: Boolean (optional, default true)
     *   - `requireAvcFallback`: Boolean (optional, default true)
     *   - `requireLlHlsTags`: Boolean (optional, default false)
     *   - `allowMediaPlaylist`: Boolean (optional, default false)
     * @return Validation output map.
     */
    fun validateSpec(spec: Map<*, *>?): Map<String, Any?> {
        if (spec == null) {
            return buildInvalidResult("", "", "AUTO", listOf(FAILURE_INVALID_MANIFEST_SPEC))
        }

        val key = (spec["key"] as? String)?.trim() ?: ""
        val uri = (spec["uri"] as? String)?.trim() ?: ""
        val formatHint = (spec["formatHint"] as? String)?.trim()?.uppercase() ?: "AUTO"

        val validFormatHints = setOf("AUTO", "HLS", "DASH")
        if (key.isBlank() || uri.isBlank() || formatHint !in validFormatHints) {
            return buildInvalidResult(key, uri, formatHint, listOf(FAILURE_INVALID_MANIFEST_SPEC))
        }

        val requireAdaptiveLadder = (spec["requireAdaptiveLadder"] as? Boolean) ?: true
        val requireAvcFallback = (spec["requireAvcFallback"] as? Boolean) ?: true
        val requireLlHlsTags = (spec["requireLlHlsTags"] as? Boolean) ?: false
        val allowMediaPlaylist = (spec["allowMediaPlaylist"] as? Boolean) ?: false

        @Suppress("UNCHECKED_CAST")
        val httpHeaders = (spec["httpHeaders"] as? Map<*, *>)?.mapNotNull { (k, v) ->
            if (k is String && v is String) k to v else null
        }?.toMap()

        val inspection = AdaptiveStreamingManifestRenditionInspector.inspectUri(
            uri = uri,
            formatHint = if (formatHint == "AUTO") null else formatHint,
            httpHeaders = httpHeaders,
        )

        val fetchSuccess = inspection["fetchSuccess"] == true
        val parseSuccess = inspection["parseSuccess"] == true
        val isMediaPlaylist = inspection["isMediaPlaylist"] == true
        val variantCount = (inspection["variantCount"] as? Number)?.toInt() ?: 0
        val representationCount = (inspection["representationCount"] as? Number)?.toInt() ?: variantCount
        val hasAdaptiveLadder = inspection["hasAdaptiveLadder"] == true
        val hasAvc = inspection["hasAvc"] == true
        val hasHevc = inspection["hasHevc"] == true
        val hasAv1 = inspection["hasAv1"] == true
        val serverPolicyPass = inspection["serverPolicyPass"] == true

        val policyFailures = mutableListOf<String>()

        if (!fetchSuccess) {
            policyFailures.add(FAILURE_FETCH_FAILED)
        } else if (!parseSuccess) {
            policyFailures.add(FAILURE_PARSE_FAILED)
        } else {
            if (!allowMediaPlaylist && isMediaPlaylist) {
                policyFailures.add(FAILURE_MEDIA_PLAYLIST_NOT_ALLOWED)
            }
            if (requireAdaptiveLadder && !hasAdaptiveLadder) {
                policyFailures.add(FAILURE_ADAPTIVE_LADDER_REQUIRED)
            }
            if (requireAvcFallback && !serverPolicyPass) {
                policyFailures.add(FAILURE_AVC_FALLBACK_REQUIRED)
            }
            if (requireLlHlsTags) {
                val llHlsIndicators = inspection["llHlsIndicators"] as? Map<*, *>
                val isLlHls = llHlsIndicators?.get("isLlHls") == true
                if (!isLlHls) {
                    policyFailures.add(FAILURE_LL_HLS_TAGS_REQUIRED)
                }
            }
        }

        val pass = policyFailures.isEmpty()
        val rawStatus = if (pass) {
            "status=OK;key=$key;formatHint=$formatHint;variantCount=$variantCount;hasAdaptiveLadder=$hasAdaptiveLadder;" +
                "hasAvc=$hasAvc;hasHevc=$hasHevc;hasAv1=$hasAv1;serverPolicyPass=$serverPolicyPass"
        } else {
            "status=FAIL;key=$key;formatHint=$formatHint;failures=${policyFailures.joinToString(",")};" +
                "rawInspection=${inspection["raw"]}"
        }

        return mapOf(
            "key" to key,
            "uri" to uri,
            "formatHint" to formatHint,
            "pass" to pass,
            "fetchSuccess" to fetchSuccess,
            "parseSuccess" to parseSuccess,
            "hasAdaptiveLadder" to hasAdaptiveLadder,
            "variantCount" to variantCount,
            "representationCount" to representationCount,
            "hasAvc" to hasAvc,
            "hasHevc" to hasHevc,
            "hasAv1" to hasAv1,
            "serverPolicyPass" to serverPolicyPass,
            "policyFailures" to policyFailures,
            "raw" to rawStatus,
            "inspection" to inspection,
        )
    }

    /**
     * Validates a batch of host-supplied manifest specs.
     */
    fun validateSpecs(specs: List<Map<*, *>>): List<Map<String, Any?>> {
        return specs.map { validateSpec(it) }
    }

    private fun buildInvalidResult(
        key: String,
        uri: String,
        formatHint: String,
        failures: List<String>,
    ): Map<String, Any?> {
        return mapOf(
            "key" to key,
            "uri" to uri,
            "formatHint" to formatHint,
            "pass" to false,
            "fetchSuccess" to false,
            "parseSuccess" to false,
            "hasAdaptiveLadder" to false,
            "variantCount" to 0,
            "representationCount" to 0,
            "hasAvc" to false,
            "hasHevc" to false,
            "hasAv1" to false,
            "serverPolicyPass" to false,
            "policyFailures" to failures,
            "raw" to "status=FAIL;key=$key;failures=${failures.joinToString(",")}",
            "inspection" to emptyMap<String, Any?>(),
        )
    }
}
