package com.connects.vanguard_media_engine.export

import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import java.io.File

// AndroidPassthroughRemuxCapabilityProbe (Phase 2-Unit Z)
//
// Diagnostic-only native source capability probe that inspects whether a single
// local media file has MP4 MediaMuxer-compatible video/audio tracks for future
// passthrough remux.
//
// Constraints:
// - Uses MediaExtractor only (setDataSource + track format inspection).
// - Never calls readSampleData().
// - Never instantiates MediaMuxer or MediaCodec.
// - Always releases extractor in finally.
// - Supported video MIME: video/avc, video/hevc only.
// - Supported audio MIME: empty/no audio allowed, or audio/mp4a-latm only.
// - Diagnostic only: no mux, no decode, no production exportTimeline wiring.

object AndroidPassthroughRemuxCapabilityProbe {

    private const val TAG = "VanguardPassthroughRemuxProbe"
    private const val PROOF_BOUNDARY =
        "native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples"

    private val NON_CLAIMS = mapOf(
        "mediaMuxerStarted" to false,
        "mediaCodecAllocated" to false,
        "samplesRead" to false,
        "outputFileWritten" to false,
        "productionExportTimelineBypass" to false,
        "cppPassthroughRemuxSinkNode" to false,
        "connectAppTouched" to false,
    )

    fun probe(sourcePath: String): Map<String, Any?> {
        val srcFile = File(sourcePath)
        val fileExists = srcFile.exists()
        val fileReadable = fileExists && srcFile.canRead()

        if (!fileExists || !fileReadable) {
            val reason = "source_missing_or_unreadable;sourcePath=$sourcePath"
            logResult(
                status = "FAIL",
                reason = reason,
                videoMime = "none",
                audioMime = "none",
                trackCount = 0,
            )
            return mapOf(
                "canPassthroughRemux" to false,
                "reason" to reason,
                "sourcePath" to sourcePath,
                "fileExists" to fileExists,
                "fileReadable" to fileReadable,
                "extractorOpened" to false,
                "trackCount" to 0,
                "video" to null,
                "audio" to null,
                "proofBoundary" to PROOF_BOUNDARY,
                "nonClaims" to NON_CLAIMS,
            )
        }

        val extractor = MediaExtractor()
        var extractorOpened = false
        var trackCount = 0
        var videoTrackMap: Map<String, Any?>? = null
        var audioTrackMap: Map<String, Any?>? = null
        var overallReason: String
        var canPassthroughRemux = false

        try {
            extractor.setDataSource(sourcePath)
            extractorOpened = true
            trackCount = extractor.trackCount

            for (i in 0 until trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = getOptionalString(format, MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/") && videoTrackMap == null) {
                    val width = getOptionalInt(format, MediaFormat.KEY_WIDTH)
                    val height = getOptionalInt(format, MediaFormat.KEY_HEIGHT)
                    val durationUs = getOptionalLong(format, MediaFormat.KEY_DURATION)
                    val rotationDegrees = getRotationDegrees(format)
                    val maxInputSize = getMaxInputSize(format)
                    val isSupported = mime == "video/avc" || mime == "video/hevc"
                    val trackReason = if (isSupported) "supported" else "unsupported_video_mime"

                    val vMap = mutableMapOf<String, Any?>(
                        "trackIndex" to i,
                        "mime" to mime,
                        "rotationDegrees" to rotationDegrees,
                        "supported" to isSupported,
                        "reason" to trackReason,
                    )
                    if (width != null) vMap["width"] = width
                    if (height != null) vMap["height"] = height
                    if (durationUs != null) vMap["durationUs"] = durationUs
                    if (maxInputSize != null) vMap["maxInputSize"] = maxInputSize
                    videoTrackMap = vMap
                } else if (mime.startsWith("audio/") && audioTrackMap == null) {
                    val durationUs = getOptionalLong(format, MediaFormat.KEY_DURATION)
                    val channelCount = getOptionalInt(format, MediaFormat.KEY_CHANNEL_COUNT)
                    val sampleRate = getOptionalInt(format, MediaFormat.KEY_SAMPLE_RATE)
                    val maxInputSize = getMaxInputSize(format)
                    val isSupported = mime == "audio/mp4a-latm"
                    val trackReason = if (isSupported) "supported" else "unsupported_audio_mime"

                    val aMap = mutableMapOf<String, Any?>(
                        "trackIndex" to i,
                        "mime" to mime,
                        "supported" to isSupported,
                        "reason" to trackReason,
                    )
                    if (durationUs != null) aMap["durationUs"] = durationUs
                    if (channelCount != null) aMap["channelCount"] = channelCount
                    if (sampleRate != null) aMap["sampleRate"] = sampleRate
                    if (maxInputSize != null) aMap["maxInputSize"] = maxInputSize
                    audioTrackMap = aMap
                }
            }

            if (videoTrackMap == null) {
                canPassthroughRemux = false
                overallReason = "no_video_track"
            } else if (videoTrackMap["supported"] != true) {
                canPassthroughRemux = false
                overallReason = "unsupported_video_mime:${videoTrackMap["mime"]}"
            } else if (audioTrackMap != null && audioTrackMap["supported"] != true) {
                canPassthroughRemux = false
                overallReason = "unsupported_audio_mime:${audioTrackMap["mime"]}"
            } else {
                canPassthroughRemux = true
                overallReason = "supported"
            }
        } catch (t: Throwable) {
            canPassthroughRemux = false
            overallReason = "extractor_open_failed:${t.javaClass.simpleName}"
        } finally {
            try {
                extractor.release()
            } catch (_: Throwable) {}
        }

        val videoMimeStr = (videoTrackMap?.get("mime") as? String) ?: "none"
        val audioMimeStr = (audioTrackMap?.get("mime") as? String) ?: "none"
        val statusStr = if (canPassthroughRemux) "PASS" else "FAIL"
        logResult(
            status = statusStr,
            reason = overallReason,
            videoMime = videoMimeStr,
            audioMime = audioMimeStr,
            trackCount = trackCount,
        )

        return mapOf(
            "canPassthroughRemux" to canPassthroughRemux,
            "reason" to overallReason,
            "sourcePath" to sourcePath,
            "fileExists" to fileExists,
            "fileReadable" to fileReadable,
            "extractorOpened" to extractorOpened,
            "trackCount" to trackCount,
            "video" to videoTrackMap,
            "audio" to audioTrackMap,
            "proofBoundary" to PROOF_BOUNDARY,
            "nonClaims" to NON_CLAIMS,
        )
    }

    private fun logResult(
        status: String,
        reason: String,
        videoMime: String,
        audioMime: String,
        trackCount: Int,
    ) {
        Log.i(
            TAG,
            "ANDROID_PASSTHROUGH_REMUX_CAPABILITY_PROBE_RESULT status=$status;reason=$reason;videoMime=$videoMime;audioMime=$audioMime;trackCount=$trackCount",
        )
    }

    private fun getOptionalInt(format: MediaFormat, key: String): Int? {
        return try {
            if (format.containsKey(key)) format.getInteger(key) else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun getOptionalLong(format: MediaFormat, key: String): Long? {
        return try {
            if (format.containsKey(key)) format.getLong(key) else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun getOptionalString(format: MediaFormat, key: String): String? {
        return try {
            if (format.containsKey(key)) format.getString(key) else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun getRotationDegrees(format: MediaFormat): Int {
        return try {
            if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                format.getInteger(MediaFormat.KEY_ROTATION)
            } else if (format.containsKey("rotation-degrees")) {
                format.getInteger("rotation-degrees")
            } else {
                0
            }
        } catch (_: Throwable) {
            0
        }
    }

    private fun getMaxInputSize(format: MediaFormat): Int? {
        return try {
            if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            } else {
                null
            }
        } catch (_: Throwable) {
            null
        }
    }
}
