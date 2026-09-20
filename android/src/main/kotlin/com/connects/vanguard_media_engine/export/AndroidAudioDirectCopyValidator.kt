package com.connects.vanguard_media_engine.export

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
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

    /// [context] is an optional Context used ONLY when the track url is a
    /// `content://` URI (AndroidUriDataSourceHelper) -- for the existence
    /// preflight (g) and the AAC probe. POSIX urls keep the byte-identical
    /// File.exists() preflight and setDataSource(String) probe. A
    /// `content://` url with a null Context is an ineligible verdict
    /// (`source_file_missing`), never a throw.
    fun validate(
        activeTracks: List<AndroidAudioTrackSpec>,
        context: Context? = null,
    ): AndroidAudioDirectCopyVerdict {
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
        val sourceMissing = if (AndroidUriDataSourceHelper.isContentUri(track.url)) {
            !AndroidUriDataSourceHelper.isReadable(track.url, context)
        } else {
            !File(track.url).exists()
        }
        if (sourceMissing) {
            return ineligible("source_file_missing")
        }
        return validateSourceAudioIsAac(track.url, context)
    }

    private fun validateSourceAudioIsAac(sourcePath: String, context: Context?): AndroidAudioDirectCopyVerdict {
        val extractor = MediaExtractor()
        try {
            AndroidUriDataSourceHelper.setExtractorDataSource(extractor, sourcePath, context)
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
