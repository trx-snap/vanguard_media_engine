package com.connects.vanguard_media_engine.codec

import android.media.MediaCodecList
import android.util.Log

/**
 * Vanguard Android True-DAG P2-CONCURRENT-DEC: advisory decoder instance-count policy.
 *
 * Queries the platform-reported [android.media.MediaCodecInfo.CodecCapabilities.getMaxSupportedInstances]
 * for the first hardware-accelerated decoder capable of [mime]. This is an advisory
 * upper bound only -- it never guarantees that N concurrent instances will actually
 * create/configure/start successfully. Real admission authority is always the actual
 * MediaCodec create/configure/start outcome; callers must still fail closed on that
 * outcome and must not treat a favorable advisory number as a guarantee.
 */
class AndroidConcurrentDecoderSlotPolicy {
    companion object {
        private const val TAG = "ConcurrentDecoderSlotPolicy"
        private const val FALLBACK_ADVISORY_MAX = 1
    }

    fun getAdvisoryMaxInstances(mime: String): Int {
        try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            for (info in list.codecInfos) {
                if (info.isEncoder) continue
                if (!info.isHardwareAccelerated) continue
                if (!info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) continue
                val caps = try {
                    info.getCapabilitiesForType(mime)
                } catch (_: Throwable) {
                    null
                } ?: continue
                val maxInstances = caps.maxSupportedInstances
                if (maxInstances > 0) {
                    return maxInstances
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "getAdvisoryMaxInstances failed for mime=$mime: $t")
        }
        return FALLBACK_ADVISORY_MAX
    }
}
