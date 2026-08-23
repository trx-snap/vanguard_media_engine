package com.connects.vanguard_media_engine.streaming

/**
 * Vanguard Android True-DAG Phase 4C5A: Streaming codec capability smoke harness.
 *
 * Official Android & Media3 Platform Facts:
 * - Android platform supported media formats docs list H.264/AVC decoder support as baseline,
 *   HEVC/H.265 decoder support from Android 5.0+, and AV1 decoder support from Android 10+ with
 *   encoder/decoder mandatory beginning Android 14.
 * - Android docs state actual device support may vary by device, profile, level, and form factor;
 *   app code must inspect device codecs instead of assuming a server-only ladder is safe.
 * - Media3 ExoPlayer supports HLS and DASH containers, but contained audio/video sample formats
 *   must also be supported by the device.
 * - Product policy: future server HEVC/AV1 renditions must be additive. Do not remove H.264 fallback
 *   until telemetry proves it is safe.
 *
 * Verification Invariants:
 * - Probes device decoders for AVC, HEVC, and AV1.
 * - Confirms baseline AVC decoder availability.
 * - Validates codec list cardinality (exactly 3 probed codecs: AVC, HEVC, AV1).
 * - Validates product server ladder policy and iOS mirror note compliance.
 * - Telemetry on HEVC and AV1 capabilities is recorded without treating lack of HEVC/AV1 as a smoke failure.
 */
object AdaptiveStreamingCodecCapabilitySmokeHarness {

    /**
     * Executes the diagnostic capability smoke suite.
     *
     * @return Structured diagnostic map with pass verdict, individual check booleans, and probe telemetry.
     */
    fun run(): Map<String, Any?> {
        return try {
            val probeResult = AdaptiveStreamingCodecCapabilityProbe.probe()
            val probePass = probeResult["pass"] == true
            val avcSupported = probeResult["avcSupported"] == true
            val hevcSupported = probeResult["hevcSupported"] == true
            val av1Supported = probeResult["av1Supported"] == true

            @Suppress("UNCHECKED_CAST")
            val codecs = probeResult["codecs"] as? List<Map<String, Any?>> ?: emptyList()
            val serverLadderPolicy = probeResult["serverLadderPolicy"] as? String ?: ""
            val iosMirrorNote = probeResult["iosMirrorNote"] as? String ?: ""

            val avcPass = avcSupported
            val codecCountPass = codecs.size == 3
            val fallbackPolicyPass = serverLadderPolicy == AdaptiveStreamingCodecCapabilityProbe.SERVER_LADDER_POLICY
            val iosMirrorNotePass = iosMirrorNote.isNotBlank()

            val overallPass = probePass &&
                avcPass &&
                codecCountPass &&
                fallbackPolicyPass &&
                iosMirrorNotePass

            val rawStatus = if (overallPass) {
                "status=OK;avcPass=true;codecCountPass=true;fallbackPolicyPass=true;iosMirrorNotePass=true;hevcSupported=$hevcSupported;av1Supported=$av1Supported"
            } else {
                "status=CODEC_CAPABILITY_VERIFICATION_FAILED;probePass=$probePass;avcPass=$avcPass;codecCountPass=$codecCountPass;fallbackPolicyPass=$fallbackPolicyPass;iosMirrorNotePass=$iosMirrorNotePass"
            }

            mapOf(
                "pass" to overallPass,
                "phase" to AdaptiveStreamingCodecCapabilityProbe.PHASE,
                "avcPass" to avcPass,
                "codecCountPass" to codecCountPass,
                "fallbackPolicyPass" to fallbackPolicyPass,
                "iosMirrorNotePass" to iosMirrorNotePass,
                "avcSupported" to avcSupported,
                "hevcSupported" to hevcSupported,
                "av1Supported" to av1Supported,
                "probe" to probeResult,
                "raw" to rawStatus,
            )
        } catch (t: Throwable) {
            mapOf(
                "pass" to false,
                "phase" to AdaptiveStreamingCodecCapabilityProbe.PHASE,
                "avcPass" to false,
                "codecCountPass" to false,
                "fallbackPolicyPass" to false,
                "iosMirrorNotePass" to false,
                "avcSupported" to false,
                "hevcSupported" to false,
                "av1Supported" to false,
                "raw" to "status=UNEXPECTED_ERROR;reason=${t.javaClass.simpleName}:${t.message}",
            )
        }
    }
}
