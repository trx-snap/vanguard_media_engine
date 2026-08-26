package com.connects.vanguard_media_engine.export

import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File

// ── AndroidAudioDirectCopyValidator (Export/Audio Unit B) ─────────────────────
//
// Android parity of the iOS VGAudioExportMuxer Phase 10-F direct-copy
// eligibility check (_trackQualifiesForDirectCopy:). A sidecar plan qualifies
// for bit-exact audio stream copy when ALL of the following hold:
//   a. Exactly one active track.
//   b. role == "original".
//   c. volume ≈ 1.0 (tolerance 0.001).
//   d. mixGain ≈ 1.0 (tolerance 0.001).
//   e. No fade-in / fade-out (tolerance 0.001).
//   f. volumeKeyframes absent or empty.
//   g. Source file exists and its first audio track is AAC in a form Android's
//      MediaMuxer accepts for MP4: MIME "audio/mp4a-latm", or an audio format
//      carrying an AAC profile key.
//
// The validator never throws — probe failures become ineligible verdicts.

/// Structured direct-copy verdict. [reason] is "eligible" on success or a
/// machine-readable ineligibility cause.
data class AndroidAudioDirectCopyVerdict(
    val eligible: Boolean,
    val reason: String,
)

object AndroidAudioDirectCopyValidator {

    private const val TOLERANCE = 0.001
    private const val AAC_MP4_MIME = "audio/mp4a-latm"

    fun validate(activeTracks: List<AndroidAudioTrackSpec>): AndroidAudioDirectCopyVerdict {
        if (activeTracks.size != 1) {
            return ineligible("active_track_count=${activeTracks.size}")
        }
        val track = activeTracks.first()

        if (track.role != "original") {
            return ineligible("role=${track.role ?: "null"}")
        }
        if (kotlin.math.abs(track.volume - 1.0) > TOLERANCE) {
            return ineligible("volume=${track.volume}")
        }
        if (kotlin.math.abs(track.mixGain - 1.0) > TOLERANCE) {
            return ineligible("mixGain=${track.mixGain}")
        }
        if (track.fadeInSeconds > TOLERANCE) {
            return ineligible("fadeInSeconds=${track.fadeInSeconds}")
        }
        if (track.fadeOutSeconds > TOLERANCE) {
            return ineligible("fadeOutSeconds=${track.fadeOutSeconds}")
        }
        if (track.hasVolumeKeyframes) {
            return ineligible("volume_keyframes_present")
        }
        if (!File(track.url).exists()) {
            return ineligible("source_file_missing")
        }
        return validateSourceAudioIsAac(track.url)
    }

    private fun validateSourceAudioIsAac(sourcePath: String): AndroidAudioDirectCopyVerdict {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(sourcePath)
            var audioFormat: MediaFormat? = null
            var audioMime = ""
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioFormat = format
                    audioMime = mime
                    break
                }
            }
            if (audioFormat == null) {
                return ineligible("no_audio_track")
            }
            val isAac = audioMime.startsWith(AAC_MP4_MIME) ||
                audioFormat.containsKey(MediaFormat.KEY_AAC_PROFILE)
            if (!isAac) {
                return ineligible("audio_codec_not_aac;mime=$audioMime")
            }
            return AndroidAudioDirectCopyVerdict(eligible = true, reason = "eligible")
        } catch (e: Exception) {
            return ineligible("source_probe_failed:${e.javaClass.simpleName}")
        } finally {
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    private fun ineligible(reason: String): AndroidAudioDirectCopyVerdict =
        AndroidAudioDirectCopyVerdict(eligible = false, reason = reason)
}
