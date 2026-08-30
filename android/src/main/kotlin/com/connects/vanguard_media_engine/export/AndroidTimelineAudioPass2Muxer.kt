package com.connects.vanguard_media_engine.export

import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.File
import kotlin.math.abs

// ── AndroidTimelineAudioPass2Muxer (Export Unit C / Audio Direct-Copy Fallback) ──
//
// Owns AndroidTimelineExportSession's pass-2 audio policy: direct-copy
// eligibility (Unit C's trim-start/duration checks layered on top of
// AndroidAudioDirectCopyValidator), the empty-sidecar video-only remux, the
// direct-copy remux, and the PCM-mixdown -> AAC-encode -> remux path --
// including graceful fallback (V4.3 audio contract) when a direct-copy remux
// fails after eligibility was already confirmed true.
//
// On a direct-copy remux failure the video temp is never touched by this
// class (it is only read by [remuxFn]); any partial output left behind at
// [finalTmpPath] by the failed attempt is deleted before falling back to the
// PCM mixdown path, and exactly one VG_AUDIO_DIRECT_COPY_FALLBACK structured
// log line is emitted for that recovery.
//
// [remuxFn]/[mixFn]/[aacEncodeFn] are narrow diagnostic injection seams --
// production always uses the bound defaults; no product/MethodChannel flag
// selects an alternate implementation.
class AndroidTimelineAudioPass2Muxer(
    private val remuxFn: (String, String?, String) -> AndroidAudioRemuxResult = AndroidAudioRemuxer::remux,
    private val mixFn: (List<AndroidAudioTrackSpec>) -> AndroidAudioMixdownResult = AndroidAudioMixdownEngine::mix,
    private val aacEncodeFn: (ShortArray, Int, Int, String) -> AndroidAacEncodeResult =
        AndroidAacEncoder::encodePcm16ToM4a,
) {

    /// Returns null on success, or a machine-readable failure reason string.
    fun run(
        specs: List<AndroidAudioTrackSpec>,
        videoTempPath: String,
        audioTempPath: String,
        finalTmpPath: String,
    ): String? {
        if (specs.isEmpty()) {
            val remux = remuxFn(videoTempPath, null, finalTmpPath)
            return if (remux.success) null else "remux:${remux.reason}"
        }

        if (tryDirectCopy(specs, videoTempPath)) {
            val track = specs.first()
            val remux = remuxFn(videoTempPath, track.url, finalTmpPath)
            if (remux.success) return null
            Log.i(
                TAG,
                "VG_AUDIO_DIRECT_COPY_FALLBACK from=direct_copy to=pcm_mixdown reason=${remux.reason}",
            )
            deletePartialFinal(finalTmpPath)
            return runMixdown(specs, videoTempPath, audioTempPath, finalTmpPath)
        }

        return runMixdown(specs, videoTempPath, audioTempPath, finalTmpPath)
    }

    private fun runMixdown(
        specs: List<AndroidAudioTrackSpec>,
        videoTempPath: String,
        audioTempPath: String,
        finalTmpPath: String,
    ): String? {
        val mix = mixFn(specs)
        if (!mix.success || mix.pcm == null) {
            return "mixdown:${mix.reason}"
        }
        val aacResult = aacEncodeFn(mix.pcm, mix.sampleRate, mix.channelCount, audioTempPath)
        if (!aacResult.success) {
            return "aac_encode:${aacResult.reason}"
        }
        val remux = remuxFn(videoTempPath, audioTempPath, finalTmpPath)
        return if (remux.success) null else "mixdown_remux:${remux.reason}"
    }

    /// Deletes a partial [finalTmpPath] left behind by a failed direct-copy
    /// remux attempt before the mixdown fallback writes its own output there.
    private fun deletePartialFinal(finalTmpPath: String) {
        try { File(finalTmpPath).takeIf { it.exists() }?.delete() } catch (_: Throwable) {}
    }

    /// Unit C direct-copy eligibility additionally requires (beyond Unit B's
    /// validator): sourceTrimStart ≈ 0.0, and the track duration must match
    /// both the probed source audio duration and the pass-1 video duration
    /// within 50 ms. Any mismatch falls back to the mixdown path.
    private fun tryDirectCopy(specs: List<AndroidAudioTrackSpec>, videoTempPath: String): Boolean {
        val verdict = AndroidAudioDirectCopyValidator.validate(specs)
        if (!verdict.eligible) return false

        val track = specs.first()
        if (abs(track.sourceTrimStart) > TRIM_START_TOLERANCE_SECONDS) return false

        val sourceAudioDuration = probeMediaDurationSeconds(track.url) ?: return false
        val pass1VideoDuration = probeMediaDurationSeconds(videoTempPath) ?: return false

        if (abs(track.duration - sourceAudioDuration) > DURATION_TOLERANCE_SECONDS) return false
        if (abs(track.duration - pass1VideoDuration) > DURATION_TOLERANCE_SECONDS) return false

        return true
    }

    private fun probeMediaDurationSeconds(path: String): Double? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val ms = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: return null
            return ms / 1000.0
        } catch (t: Throwable) {
            Log.e(TAG, "probeMediaDurationSeconds failed for $path: $t")
            return null
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    companion object {
        private const val TAG = "VGTimelineAudioPass2"
        private const val TRIM_START_TOLERANCE_SECONDS = 0.001
        private const val DURATION_TOLERANCE_SECONDS = 0.05
    }
}
