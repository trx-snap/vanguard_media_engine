package com.connects.vanguard_media_engine.streaming

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build

/**
 * Vanguard Android True-DAG Phase 4C5A: Streaming codec capability diagnostics.
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
 * Mechanical Invariants:
 * - Pure diagnostic probe using Android [MediaCodecList] and [MediaCodecInfo] APIs.
 * - Must NEVER instantiate [android.media.MediaCodec], decode media, open network connections,
 *   instantiate ExoPlayer, or touch Surface, Image, or HardwareBuffer instances.
 */
object AdaptiveStreamingCodecCapabilityProbe {

    const val PHASE = "Phase4C5A"
    const val SERVER_LADDER_POLICY = "add_hevc_av1_renditions_but_keep_avc_fallback"
    const val IOS_MIRROR_NOTE = "iOS implementer must mirror capability-based codec selection with AVFoundation/CoreMedia and keep H.264 fallback."

    private data class CodecSpec(
        val codecKey: String,
        val mimeType: String,
    )

    private val PROBED_CODECS = listOf(
        CodecSpec(codecKey = "avc", mimeType = "video/avc"),
        CodecSpec(codecKey = "hevc", mimeType = "video/hevc"),
        CodecSpec(codecKey = "av1", mimeType = "video/av01"),
    )

    /**
     * Executes the diagnostic probe across AVC ("video/avc"), HEVC ("video/hevc"), and AV1 ("video/av01").
     *
     * @return Map containing pass verdict, SDK level, probed codec capabilities, and ladder policy.
     */
    fun probe(): Map<String, Any?> {
        return try {
            val codecInfos = try {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            } catch (_: Throwable) {
                emptyArray<MediaCodecInfo>()
            }

            val decoders = codecInfos.filter { !it.isEncoder }

            val probedResults = mutableListOf<Map<String, Any?>>()
            var avcSupported = false
            var hevcSupported = false
            var av1Supported = false

            for (spec in PROBED_CODECS) {
                val matchingDecoders = decoders.filter { codecInfo ->
                    try {
                        codecInfo.supportedTypes.any { it.equals(spec.mimeType, ignoreCase = true) }
                    } catch (_: Throwable) {
                        false
                    }
                }

                val decoderNames = matchingDecoders.map { it.name }
                var hardwareDecoderPresent = false
                var softwareDecoderPresent = false
                var totalProfileLevels = 0

                for (decoder in matchingDecoders) {
                    val (isHw, isSw) = classifyDecoder(decoder)
                    if (isHw) hardwareDecoderPresent = true
                    if (isSw) softwareDecoderPresent = true

                    try {
                        val caps = decoder.getCapabilitiesForType(spec.mimeType)
                        val profileLevels = caps.profileLevels
                        if (profileLevels != null) {
                            totalProfileLevels += profileLevels.size
                        }
                    } catch (_: Throwable) {
                        // getCapabilitiesForType can throw if codec configuration is unsupported; safe ignore
                    }
                }

                val supported = matchingDecoders.isNotEmpty()
                when (spec.codecKey) {
                    "avc" -> avcSupported = supported
                    "hevc" -> hevcSupported = supported
                    "av1" -> av1Supported = supported
                }

                probedResults.add(
                    mapOf(
                        "codecKey" to spec.codecKey,
                        "mimeType" to spec.mimeType,
                        "supported" to supported,
                        "hardwareDecoderPresent" to (supported && hardwareDecoderPresent),
                        "softwareDecoderPresent" to (supported && softwareDecoderPresent),
                        "decoderCount" to matchingDecoders.size,
                        "decoderNames" to decoderNames,
                        "profileLevelCount" to totalProfileLevels,
                    )
                )
            }

            val rawStatus = "status=OK;avcSupported=$avcSupported;hevcSupported=$hevcSupported;av1Supported=$av1Supported;androidSdk=${Build.VERSION.SDK_INT}"

            mapOf(
                "pass" to true,
                "phase" to PHASE,
                "androidSdk" to Build.VERSION.SDK_INT,
                "codecs" to probedResults,
                "avcSupported" to avcSupported,
                "hevcSupported" to hevcSupported,
                "av1Supported" to av1Supported,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "raw" to rawStatus,
            )
        } catch (t: Throwable) {
            mapOf(
                "pass" to false,
                "phase" to PHASE,
                "androidSdk" to Build.VERSION.SDK_INT,
                "codecs" to emptyList<Map<String, Any?>>(),
                "avcSupported" to false,
                "hevcSupported" to false,
                "av1Supported" to false,
                "serverLadderPolicy" to SERVER_LADDER_POLICY,
                "iosMirrorNote" to IOS_MIRROR_NOTE,
                "raw" to "status=FAIL;reason=probe_exception:${t.javaClass.simpleName}:${t.message}",
            )
        }
    }

    private fun classifyDecoder(codecInfo: MediaCodecInfo): Pair<Boolean, Boolean> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val hw = codecInfo.isHardwareAccelerated
                val sw = codecInfo.isSoftwareOnly
                Pair(hw, sw)
            } catch (_: Throwable) {
                classifyByLegacyName(codecInfo.name)
            }
        } else {
            classifyByLegacyName(codecInfo.name)
        }
    }

    private fun classifyByLegacyName(name: String): Pair<Boolean, Boolean> {
        val lower = name.lowercase()
        val isSoftware = lower.startsWith("omx.google.") ||
            lower.startsWith("c2.android.") ||
            lower.contains(".sw.") ||
            lower.contains("sw") ||
            lower.contains("software")
        return Pair(!isSoftware, isSoftware)
    }
}
