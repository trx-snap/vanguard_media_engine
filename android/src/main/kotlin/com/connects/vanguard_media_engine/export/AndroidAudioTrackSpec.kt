package com.connects.vanguard_media_engine.export

// ── AndroidAudioTrackSpec (Export/Audio Unit B) ───────────────────────────────
//
// Kotlin parser for the sidecar audio track wire contract defined in
// lib/vg_audio_sidecar_plan.dart (VGAudioSidecarTrack.toMap()).
//
// Wire keys: trackId, url, startTime, duration, volume, role, fadeInSeconds,
// fadeOutSeconds, sourceTrimStart, volumeKeyframes, mixGain.
//
// Parse rules mirror the Dart VGAudioSidecarTrack.fromMap():
//   - trackId / url: required non-empty strings.
//   - startTime: required number.
//   - duration: required number, > 0.
//   - volume defaults to 1.0; fades default to 0.0; sourceTrimStart defaults
//     to 0.0; mixGain defaults to 1.0.
//   - volumeKeyframes: optional list of {time, volume} maps; entries missing
//     either number are dropped; an empty parsed list becomes null.
//   - Invalid tracks return null — callers skip them with evidence, no crash.

/// A single volume automation keyframe. [time] is seconds in the output
/// timeline (same basis as [AndroidAudioTrackSpec.startTime]); [volume] is
/// linear gain (clamped to [0,1] later by the envelope, not here).
data class AndroidAudioVolumeKeyframe(
    val time: Double,
    val volume: Double,
) {
    companion object {
        fun fromMap(map: Map<*, *>): AndroidAudioVolumeKeyframe? {
            val time = (map["time"] as? Number)?.toDouble() ?: return null
            val volume = (map["volume"] as? Number)?.toDouble() ?: return null
            return AndroidAudioVolumeKeyframe(time = time, volume = volume)
        }
    }
}

/// Parsed sidecar audio track descriptor. Pure value type — no media I/O.
data class AndroidAudioTrackSpec(
    val trackId: String,
    val url: String,
    val startTime: Double,
    val duration: Double,
    val volume: Double,
    val role: String?,
    val fadeInSeconds: Double,
    val fadeOutSeconds: Double,
    val sourceTrimStart: Double,
    val volumeKeyframes: List<AndroidAudioVolumeKeyframe>?,
    val mixGain: Double,
) {
    val hasVolumeKeyframes: Boolean
        get() = !volumeKeyframes.isNullOrEmpty()

    companion object {
        /// Parses one track map from the wire contract. Returns null when the
        /// required fields are missing or invalid; the caller records the skip.
        fun fromMap(map: Map<*, *>): AndroidAudioTrackSpec? {
            val trackId = map["trackId"] as? String
            if (trackId.isNullOrEmpty()) return null

            val url = map["url"] as? String
            if (url.isNullOrEmpty()) return null

            val startTime = (map["startTime"] as? Number)?.toDouble() ?: return null

            val duration = (map["duration"] as? Number)?.toDouble() ?: return null
            if (duration <= 0.0) return null

            val volume = (map["volume"] as? Number)?.toDouble() ?: 1.0
            val role = map["role"] as? String
            val fadeIn = (map["fadeInSeconds"] as? Number)?.toDouble() ?: 0.0
            val fadeOut = (map["fadeOutSeconds"] as? Number)?.toDouble() ?: 0.0
            val sourceTrimStart = (map["sourceTrimStart"] as? Number)?.toDouble() ?: 0.0

            var keyframes: List<AndroidAudioVolumeKeyframe>? = null
            val rawKf = map["volumeKeyframes"]
            if (rawKf is List<*> && rawKf.isNotEmpty()) {
                val parsed = rawKf.mapNotNull { entry ->
                    (entry as? Map<*, *>)?.let { AndroidAudioVolumeKeyframe.fromMap(it) }
                }
                if (parsed.isNotEmpty()) keyframes = parsed
            }

            val mixGain = (map["mixGain"] as? Number)?.toDouble() ?: 1.0

            return AndroidAudioTrackSpec(
                trackId = trackId,
                url = url,
                startTime = startTime,
                duration = duration,
                volume = volume,
                role = role,
                fadeInSeconds = fadeIn,
                fadeOutSeconds = fadeOut,
                sourceTrimStart = sourceTrimStart,
                volumeKeyframes = keyframes,
                mixGain = mixGain,
            )
        }

        /// Parses a list of track maps. Invalid entries are skipped and their
        /// indices reported so the harness can surface evidence in raw status.
        fun parseList(rawTracks: List<*>): Pair<List<AndroidAudioTrackSpec>, List<Int>> {
            val specs = mutableListOf<AndroidAudioTrackSpec>()
            val skippedIndices = mutableListOf<Int>()
            rawTracks.forEachIndexed { index, entry ->
                val spec = (entry as? Map<*, *>)?.let { fromMap(it) }
                if (spec != null) specs.add(spec) else skippedIndices.add(index)
            }
            return Pair(specs, skippedIndices)
        }
    }
}
