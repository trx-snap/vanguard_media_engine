package com.connects.vanguard_media_engine.export

// ── AndroidAudioVolumeEnvelope (Export/Audio Unit B) ──────────────────────────
//
// Android parity of the iOS VGAudioExportMuxer Phase 8.15A keyframe
// normalisation and evaluation rules. All times are output-timeline seconds
// (the same basis as AndroidAudioTrackSpec.startTime).
//
// Normalisation (iOS _pass1AudioMixdown keyframe path):
//   1. mixGain outside [0,1] resets to 1.0; keyframe volumes are clamped to
//      [0,1] and then multiplied by mixGain.
//   2. Keyframes outside the effective track range [trackStart, trackEnd] are
//      discarded.
//   3. Keyframes are sorted by time ascending.
//   4. Adjacent keyframes closer than 1 ms are merged, keeping the later
//      volume.
//   5. A start keyframe (volume 0.0) is synthesised at trackStart when the
//      first keyframe is later than trackStart + 1 ms.
//   6. A terminal keyframe holding the last volume is synthesised at trackEnd
//      when the last keyframe is earlier than trackEnd - 1 ms.
//   7. Sub-millisecond ramps between consecutive keyframes are skipped
//      (evaluation holds the earlier volume across a sub-ms gap).
//
// Static (non-keyframe) tracks are expressed as synthesised keyframes from
// volume * mixGain plus fade-in/fade-out ramps, mirroring the iOS static path
// (fades clamped to the track duration, overlapping fades scaled
// proportionally).

class AndroidAudioVolumeEnvelope private constructor(
    private val keyframes: List<AndroidAudioVolumeKeyframe>,
) {

    /// Evaluates the linear gain at [timeSec] (output-timeline seconds).
    /// Before the first keyframe the first volume holds; after the last
    /// keyframe the last volume holds; between keyframes gain is linearly
    /// interpolated. Sub-ms segments hold the earlier volume (skip the ramp).
    fun evaluate(timeSec: Double): Double {
        if (keyframes.isEmpty()) return 0.0
        if (timeSec <= keyframes.first().time) return keyframes.first().volume
        if (timeSec >= keyframes.last().time) return keyframes.last().volume
        for (i in 0 until keyframes.size - 1) {
            val a = keyframes[i]
            val b = keyframes[i + 1]
            if (timeSec >= a.time && timeSec < b.time) {
                val span = b.time - a.time
                if (span < MERGE_EPSILON_SECONDS) return a.volume
                val fraction = (timeSec - a.time) / span
                return a.volume + (b.volume - a.volume) * fraction
            }
        }
        return keyframes.last().volume
    }

    /// Normalised keyframes (exposed for diagnostics/raw evidence).
    fun normalizedKeyframes(): List<AndroidAudioVolumeKeyframe> = keyframes

    companion object {
        private const val MERGE_EPSILON_SECONDS = 0.001

        /// Builds the envelope for [track] over the effective output range
        /// [trackStartSec, trackEndSec]. Uses the keyframe path when the track
        /// carries keyframes that survive normalisation; otherwise falls back
        /// to the static volume/fade path (iOS parity).
        fun forTrack(
            track: AndroidAudioTrackSpec,
            trackStartSec: Double,
            trackEndSec: Double,
        ): AndroidAudioVolumeEnvelope {
            val mixGain = normalizeMixGain(track.mixGain)
            val rawKeyframes = track.volumeKeyframes
            if (!rawKeyframes.isNullOrEmpty()) {
                val normalized = normalize(rawKeyframes, trackStartSec, trackEndSec, mixGain)
                if (normalized.isNotEmpty()) {
                    return AndroidAudioVolumeEnvelope(normalized)
                }
                // All keyframes discarded — iOS falls through to the static path.
            }
            return fromStatic(
                volume = track.volume,
                mixGain = mixGain,
                fadeInSeconds = track.fadeInSeconds,
                fadeOutSeconds = track.fadeOutSeconds,
                trackStartSec = trackStartSec,
                trackEndSec = trackEndSec,
            )
        }

        /// Applies the iOS keyframe normalisation rules. Returns an empty list
        /// when no keyframe survives (caller falls back to the static path).
        fun normalize(
            rawKeyframes: List<AndroidAudioVolumeKeyframe>,
            trackStartSec: Double,
            trackEndSec: Double,
            mixGain: Double,
        ): List<AndroidAudioVolumeKeyframe> {
            // 1+2. Clamp volume to [0,1], apply mixGain, discard out-of-range.
            val valid = rawKeyframes.mapNotNull { kf ->
                if (kf.time < trackStartSec || kf.time > trackEndSec) return@mapNotNull null
                val clamped = kf.volume.coerceIn(0.0, 1.0) * mixGain
                AndroidAudioVolumeKeyframe(time = kf.time, volume = clamped)
            }
            if (valid.isEmpty()) return emptyList()

            // 3. Sort ascending; 4. merge sub-ms neighbours keeping later volume.
            val merged = mergeSubMillisecond(valid.sortedBy { it.time })
            if (merged.isEmpty()) return emptyList()

            val result = mutableListOf<AndroidAudioVolumeKeyframe>()

            // 5. Synthesised silent start keyframe.
            if (merged.first().time > trackStartSec + MERGE_EPSILON_SECONDS) {
                result.add(AndroidAudioVolumeKeyframe(time = trackStartSec, volume = 0.0))
            }
            result.addAll(merged)

            // 6. Synthesised terminal keyframe holding the last volume.
            val last = result.last()
            if (last.time < trackEndSec - MERGE_EPSILON_SECONDS) {
                result.add(AndroidAudioVolumeKeyframe(time = trackEndSec, volume = last.volume))
            }
            return result
        }

        /// Static volume/fade path expressed as keyframes (iOS 8.14B parity):
        /// ramp 0 → v over the fade-in, hold v, ramp v → 0 over the fade-out.
        fun fromStatic(
            volume: Double,
            mixGain: Double,
            fadeInSeconds: Double,
            fadeOutSeconds: Double,
            trackStartSec: Double,
            trackEndSec: Double,
        ): AndroidAudioVolumeEnvelope {
            val duration = (trackEndSec - trackStartSec).coerceAtLeast(0.0)
            val effectiveVolume = volume * normalizeMixGain(mixGain)

            var fadeIn = fadeInSeconds.coerceAtLeast(0.0).coerceAtMost(duration)
            var fadeOut = fadeOutSeconds.coerceAtLeast(0.0).coerceAtMost(duration)
            if (fadeIn + fadeOut > duration && fadeIn + fadeOut > 0.0) {
                val total = fadeIn + fadeOut
                fadeIn = (fadeIn / total) * duration
                fadeOut = (fadeOut / total) * duration
            }

            val kfs = mutableListOf<AndroidAudioVolumeKeyframe>()
            if (fadeIn > 0.0) {
                kfs.add(AndroidAudioVolumeKeyframe(trackStartSec, 0.0))
                kfs.add(AndroidAudioVolumeKeyframe(trackStartSec + fadeIn, effectiveVolume))
            } else {
                kfs.add(AndroidAudioVolumeKeyframe(trackStartSec, effectiveVolume))
            }
            if (fadeOut > 0.0) {
                kfs.add(AndroidAudioVolumeKeyframe(trackEndSec - fadeOut, effectiveVolume))
                kfs.add(AndroidAudioVolumeKeyframe(trackEndSec, 0.0))
            } else {
                kfs.add(AndroidAudioVolumeKeyframe(trackEndSec, effectiveVolume))
            }
            return AndroidAudioVolumeEnvelope(mergeSubMillisecond(kfs.sortedBy { it.time }))
        }

        private fun mergeSubMillisecond(
            sorted: List<AndroidAudioVolumeKeyframe>,
        ): List<AndroidAudioVolumeKeyframe> {
            val merged = mutableListOf<AndroidAudioVolumeKeyframe>()
            for (kf in sorted) {
                val prev = merged.lastOrNull()
                if (prev != null && (kf.time - prev.time) < MERGE_EPSILON_SECONDS) {
                    merged.removeAt(merged.size - 1)
                }
                merged.add(kf)
            }
            return merged
        }

        // iOS parity: mixGain outside [0,1] resets to unity.
        private fun normalizeMixGain(mixGain: Double): Double =
            if (mixGain < 0.0 || mixGain > 1.0) 1.0 else mixGain
    }
}
