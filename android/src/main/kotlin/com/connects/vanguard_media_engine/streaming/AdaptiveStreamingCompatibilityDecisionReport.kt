package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C5E: Streaming Codec + Manifest Compatibility Decision Report.
 *
 * Official Android & Media3 Platform Facts:
 * - Android platform supported media formats docs list H.264/AVC decoder support as baseline,
 *   HEVC/H.265 decoder support from Android 5.0+, and AV1 decoder support from Android 10+ with
 *   encoder/decoder mandatory beginning Android 14.
 * - Android docs state actual device support may vary by device, profile, level, and form factor;
 *   app code must inspect device codecs instead of assuming a server-only ladder is safe.
 * - Media3 ExoPlayer supports HLS and DASH containers, but contained audio/video sample formats
 *   must also be supported by the device.
 * - Product Policy: Future server ladders may add HEVC and AV1 renditions, but AVC/H.264 fallback
 *   must remain mandatory so older Android devices and iOS mirrors do not hiccup.
 * - Compatibility Decision Brain: Joins Phase 4C5A device codec capability diagnostics with
 *   Phase 4C5D host manifest policy validation into a single diagnostic compatibility report.
 *
 * Mechanical Invariants:
 * - Pure diagnostic brain: MUST NEVER instantiate ExoPlayer, MediaCodec, MediaExtractor,
 *   Surface, ImageReader, HardwareBuffer, Vulkan, GLES, DAG renderers, LiveKit, WebRTC,
 *   or any audio/room SDKs.
 * - Calls only [AdaptiveStreamingCodecCapabilityProbe.probe] and
 *   [AdaptiveStreamingManifestPolicyValidator.validateSpec].
 * - Must not perform direct network fetches itself; manifest fetching remains delegated to
 *   the manifest inspector / policy validator.
 * - Returns structured maps/lists suitable for MethodChannel serialization.
 */
object AdaptiveStreamingCompatibilityDecisionReport {

    const val PHASE = "Phase4C5E"
    const val SERVER_LADDER_POLICY = AdaptiveStreamingCodecCapabilityProbe.SERVER_LADDER_POLICY
    const val IOS_MIRROR_NOTE =
        "iOS implementer must combine AVFoundation/CoreMedia capability with HLS manifest ladders and preserve AVC fallback; iOS DASH remains deferred."

    // Warning constants
    const val WARNING_MISSING_AVC_FALLBACK = "missing_avc_fallback"
    const val WARNING_AV1_SOFTWARE_ONLY = "av1_software_only"
    const val WARNING_AV1_UNSUPPORTED = "av1_unsupported"
    const val WARNING_HEVC_SOFTWARE_ONLY = "hevc_software_only"
    const val WARNING_HEVC_UNSUPPORTED = "hevc_unsupported"
    const val WARNING_NO_DEVICE_SAFE_VIDEO_CODEC = "no_device_safe_video_codec"
    const val WARNING_MANIFEST_POLICY_FAILED = "manifest_policy_failed"
    const val WARNING_NO_ADAPTIVE_LADDER = "no_adaptive_ladder"

    // Decision constants
    const val DECISION_PREFER_AV1_HARDWARE = "prefer_av1_hardware"
    const val DECISION_PREFER_HEVC_HARDWARE = "prefer_hevc_hardware"
    const val DECISION_PREFER_AVC_FALLBACK = "prefer_avc_fallback"
    const val DECISION_BLOCKED_NO_SAFE_CODEC = "blocked_no_safe_codec"
    const val DECISION_BLOCKED_MANIFEST_POLICY_FAILED = "blocked_manifest_policy_failed"

    /**
     * Builds a single compatibility decision report joining the given manifest spec validation
     * with device codec capabilities.
     *
     * @param spec Host-supplied manifest spec map.
     * @param codecProbe Optional pre-probed codec capabilities from [AdaptiveStreamingCodecCapabilityProbe.probe].
     * @return Structured diagnostic compatibility report.
     */
    fun buildReport(
        spec: Map<*, *>,
        codecProbe: Map<String, Any?> = AdaptiveStreamingCodecCapabilityProbe.probe(),
    ): Map<String, Any?> {
        val key = (spec["key"] as? String)?.trim() ?: ""
        val uri = (spec["uri"] as? String)?.trim() ?: ""
        val formatHint = (spec["formatHint"] as? String)?.trim()?.uppercase() ?: "AUTO"

        val manifestValidation = AdaptiveStreamingManifestPolicyValidator.validateSpec(spec)
        val manifestPolicyPass = manifestValidation["pass"] == true
        val hasAdaptiveLadder = manifestValidation["hasAdaptiveLadder"] == true
        val avcManifestPresent = manifestValidation["hasAvc"] == true
        val hevcManifestPresent = manifestValidation["hasHevc"] == true
        val av1ManifestPresent = manifestValidation["hasAv1"] == true

        val avcDeviceSupported = codecProbe["avcSupported"] == true
        val hevcDeviceSupported = codecProbe["hevcSupported"] == true
        val av1DeviceSupported = codecProbe["av1Supported"] == true

        @Suppress("UNCHECKED_CAST")
        val codecsList = codecProbe["codecs"] as? List<Map<String, Any?>> ?: emptyList()
        val avcEntry = codecsList.find { it["codecKey"] == "avc" }
        val hevcEntry = codecsList.find { it["codecKey"] == "hevc" }
        val av1Entry = codecsList.find { it["codecKey"] == "av1" }

        val avcHardwareSafe = avcEntry?.get("hardwareDecoderPresent") == true
        val hevcHardwareSafe = hevcEntry?.get("hardwareDecoderPresent") == true
        val av1HardwareSafe = av1Entry?.get("hardwareDecoderPresent") == true

        // Extract renditions and calculate bandwidth stats
        val inspection = manifestValidation["inspection"] as? Map<*, *>
        @Suppress("UNCHECKED_CAST")
        val variants = (inspection?.get("variants") as? List<Map<String, Any?>>)
            ?: (inspection?.get("representations") as? List<Map<String, Any?>>)
            ?: emptyList()

        val renditionCount = (manifestValidation["variantCount"] as? Number)?.toInt()
            ?: (manifestValidation["representationCount"] as? Number)?.toInt()
            ?: variants.size

        val bandwidths = variants.mapNotNull {
            (it["bandwidth"] as? Number)?.toLong()
        }.filter { it > 0L }

        val lowestBandwidth = bandwidths.minOrNull() ?: 0L
        val highestBandwidth = bandwidths.maxOrNull() ?: 0L

        // Codec selection & classification
        val preferredCodecFamily: String = when {
            av1ManifestPresent && av1HardwareSafe -> "av1"
            hevcManifestPresent && hevcHardwareSafe -> "hevc"
            avcManifestPresent && avcDeviceSupported -> "avc"
            else -> "none"
        }

        val fallbackCodecFamily: String = when {
            avcManifestPresent && avcDeviceSupported -> "avc"
            else -> "none"
        }

        val safeCodecFamilies = mutableListOf<String>()
        if (avcManifestPresent && avcDeviceSupported) {
            safeCodecFamilies.add("avc")
        }
        if (hevcManifestPresent && hevcHardwareSafe) {
            safeCodecFamilies.add("hevc")
        }
        if (av1ManifestPresent && av1HardwareSafe) {
            safeCodecFamilies.add("av1")
        }

        val riskyCodecFamilies = mutableListOf<String>()
        if (hevcManifestPresent && (!hevcDeviceSupported || !hevcHardwareSafe)) {
            riskyCodecFamilies.add("hevc")
        }
        if (av1ManifestPresent && (!av1DeviceSupported || !av1HardwareSafe)) {
            riskyCodecFamilies.add("av1")
        }

        // Warnings computation
        val warnings = mutableListOf<String>()
        if (!manifestPolicyPass) {
            warnings.add(WARNING_MANIFEST_POLICY_FAILED)
        }
        if (!hasAdaptiveLadder || renditionCount <= 1) {
            warnings.add(WARNING_NO_ADAPTIVE_LADDER)
        }
        if (!avcManifestPresent || !avcDeviceSupported) {
            warnings.add(WARNING_MISSING_AVC_FALLBACK)
        }
        if (hevcManifestPresent && !hevcDeviceSupported) {
            warnings.add(WARNING_HEVC_UNSUPPORTED)
        }
        if (hevcManifestPresent && hevcDeviceSupported && !hevcHardwareSafe) {
            warnings.add(WARNING_HEVC_SOFTWARE_ONLY)
        }
        if (av1ManifestPresent && !av1DeviceSupported) {
            warnings.add(WARNING_AV1_UNSUPPORTED)
        }
        if (av1ManifestPresent && av1DeviceSupported && !av1HardwareSafe) {
            warnings.add(WARNING_AV1_SOFTWARE_ONLY)
        }
        if (safeCodecFamilies.isEmpty()) {
            warnings.add(WARNING_NO_DEVICE_SAFE_VIDEO_CODEC)
        }

        // Decision computation
        val decision: String = when {
            !manifestPolicyPass -> DECISION_BLOCKED_MANIFEST_POLICY_FAILED
            preferredCodecFamily == "none" || safeCodecFamilies.isEmpty() -> DECISION_BLOCKED_NO_SAFE_CODEC
            preferredCodecFamily == "av1" -> DECISION_PREFER_AV1_HARDWARE
            preferredCodecFamily == "hevc" -> DECISION_PREFER_HEVC_HARDWARE
            preferredCodecFamily == "avc" -> DECISION_PREFER_AVC_FALLBACK
            else -> DECISION_BLOCKED_NO_SAFE_CODEC
        }

        // Pass criteria:
        // - manifest policy passes,
        // - preferred codec is not none,
        // - fallback codec is avc when HEVC or AV1 is present in the manifest,
        // - no blocked_* decision.
        val pass = manifestPolicyPass &&
            preferredCodecFamily != "none" &&
            (!hevcManifestPresent && !av1ManifestPresent || fallbackCodecFamily == "avc") &&
            !decision.startsWith("blocked_")

        val rawStatus = if (pass) {
            "status=OK;key=$key;decision=$decision;preferred=$preferredCodecFamily;fallback=$fallbackCodecFamily;" +
                "safeCodecs=${safeCodecFamilies.joinToString(",")};renditionCount=$renditionCount;" +
                "lowestBandwidth=$lowestBandwidth;highestBandwidth=$highestBandwidth"
        } else {
            "status=COMPATIBILITY_DECISION_FAILED;key=$key;decision=$decision;preferred=$preferredCodecFamily;" +
                "fallback=$fallbackCodecFamily;warnings=${warnings.joinToString(",")};" +
                "manifestPolicyPass=$manifestPolicyPass"
        }

        return mapOf(
            "key" to key,
            "uri" to uri,
            "formatHint" to formatHint,
            "pass" to pass,
            "manifestPolicyPass" to manifestPolicyPass,
            "avcManifestPresent" to avcManifestPresent,
            "hevcManifestPresent" to hevcManifestPresent,
            "av1ManifestPresent" to av1ManifestPresent,
            "avcDeviceSupported" to avcDeviceSupported,
            "hevcDeviceSupported" to hevcDeviceSupported,
            "av1DeviceSupported" to av1DeviceSupported,
            "avcHardwareSafe" to avcHardwareSafe,
            "hevcHardwareSafe" to hevcHardwareSafe,
            "av1HardwareSafe" to av1HardwareSafe,
            "preferredCodecFamily" to preferredCodecFamily,
            "fallbackCodecFamily" to fallbackCodecFamily,
            "safeCodecFamilies" to safeCodecFamilies,
            "riskyCodecFamilies" to riskyCodecFamilies,
            "warnings" to warnings,
            "renditionCount" to renditionCount,
            "lowestBandwidth" to lowestBandwidth,
            "highestBandwidth" to highestBandwidth,
            "decision" to decision,
            "raw" to rawStatus,
            "manifestValidation" to manifestValidation,
        )
    }

    /**
     * Builds compatibility decision reports for a list of manifest specs.
     *
     * @param specs List of host-supplied manifest specs.
     * @param codecProbe Pre-probed codec capabilities (probed once if not supplied).
     * @return Aggregate compatibility decision report map.
     */
    fun buildReports(
        specs: List<Map<*, *>>,
        codecProbe: Map<String, Any?> = AdaptiveStreamingCodecCapabilityProbe.probe(),
    ): Map<String, Any?> {
        val reports = specs.map { buildReport(it, codecProbe) }
        val totalReports = reports.size
        val passedReports = reports.count { it["pass"] == true }
        val failedReports = totalReports - passedReports

        val codecProbePass = codecProbe["pass"] == true
        val avcSupported = codecProbe["avcSupported"] == true
        val hevcSupported = codecProbe["hevcSupported"] == true
        val av1Supported = codecProbe["av1Supported"] == true

        @Suppress("UNCHECKED_CAST")
        val codecsList = codecProbe["codecs"] as? List<Map<String, Any?>> ?: emptyList()
        val hevcCodec = codecsList.find { it["codecKey"] == "hevc" }
        val hevcHardwareSafe = hevcCodec?.get("hardwareDecoderPresent") == true
        val av1Codec = codecsList.find { it["codecKey"] == "av1" }
        val av1HardwareSafe = av1Codec?.get("hardwareDecoderPresent") == true

        val deviceWarnings = mutableListOf<String>()
        if (!avcSupported) {
            deviceWarnings.add(WARNING_MISSING_AVC_FALLBACK)
        }
        if (!hevcSupported) {
            deviceWarnings.add(WARNING_HEVC_UNSUPPORTED)
        } else if (!hevcHardwareSafe) {
            deviceWarnings.add(WARNING_HEVC_SOFTWARE_ONLY)
        }
        if (!av1Supported) {
            deviceWarnings.add(WARNING_AV1_UNSUPPORTED)
        } else if (!av1HardwareSafe) {
            deviceWarnings.add(WARNING_AV1_SOFTWARE_ONLY)
        }

        val allReportsPass = totalReports > 0 && failedReports == 0
        val pass = allReportsPass && codecProbePass && avcSupported

        val rawStatus = if (pass) {
            "status=OK;total=$totalReports;passed=$passedReports;failed=0;codecProbePass=true;avcSupported=true"
        } else {
            "status=COMPATIBILITY_DECISION_FAILED;total=$totalReports;passed=$passedReports;failed=$failedReports;" +
                "codecProbePass=$codecProbePass;avcSupported=$avcSupported"
        }

        return mapOf(
            "phase" to PHASE,
            "pass" to pass,
            "totalReports" to totalReports,
            "passedReports" to passedReports,
            "failedReports" to failedReports,
            "codecProbePass" to codecProbePass,
            "avcSupported" to avcSupported,
            "hevcSupported" to hevcSupported,
            "av1Supported" to av1Supported,
            "av1HardwareSafe" to av1HardwareSafe,
            "deviceWarnings" to deviceWarnings,
            "serverLadderPolicy" to SERVER_LADDER_POLICY,
            "iosMirrorNote" to IOS_MIRROR_NOTE,
            "reports" to reports,
            "raw" to rawStatus,
        )
    }
}
