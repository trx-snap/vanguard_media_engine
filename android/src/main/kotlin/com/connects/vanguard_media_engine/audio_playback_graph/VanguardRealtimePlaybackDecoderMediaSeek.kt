package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.MediaExtractor
import android.media.MediaFormat

// ── VanguardRealtimePlaybackDecoderMediaSeek (Y10a modularity prep) ────────
//
// Behavior-identical extraction of the low-level, previous-sync-seat and
// reopen-on-EOS-landing MediaExtractor mechanics previously inline in
// [VanguardRealtimePlaybackDecoderFeed]. Every method here is stateless and
// executes synchronously on whichever thread calls it (the decode thread,
// for every call site the feed has); this class holds no MediaExtractor or
// MediaCodec reference of its own between calls, keeps no telemetry and
// issues no transport command, so the decode thread remains the sole owner
// of MediaExtractor/MediaCodec and of the Y9 single-use reanchor sequencing,
// which stays orchestrated inside [VanguardRealtimePlaybackDecoderFeed].
class VanguardRealtimePlaybackDecoderMediaSeek(private val sourcePath: String) {

    class FailClosed(val reason: String) : Exception(reason)

    // Re-seats `extractor` at `targetUs` (PREVIOUS_SYNC); landed sample time, or -1 on EOS landing.
    //
    // Y17 frame-zero backward seek: for a non-positive target some
    // extractors (observed on Samsung SM-A566B / Android 16) answer a
    // PREVIOUS_SYNC seek at 0 with an EOS landing (-1) even on a freshly
    // reopened track, because no sync sample precedes the first sample.
    // In that one case the seat falls back to a start-of-track NEXT_SYNC
    // seek at 0 so the extractor lands on the first audio sample. Positive
    // targets keep the exact PREVIOUS_SYNC behavior and their EOS landing
    // still surfaces as -1 so the feed's reopen/fail-closed policy is
    // unchanged for them.
    fun seatExtractor(extractor: MediaExtractor, targetUs: Long): Long {
        extractor.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val landedUs = extractor.sampleTime
        if (landedUs >= 0L || targetUs > 0L) return landedUs
        extractor.seekTo(0L, MediaExtractor.SEEK_TO_NEXT_SYNC)
        return extractor.sampleTime
    }

    // Opens a fresh MediaExtractor on the same source/track for a Y9
    // reopen-on-EOS landing, verifying the reopened track's mime still
    // matches the original before selecting it.
    fun openExtractorForReopen(sourceTrackIndex: Int, sourceMime: String): MediaExtractor {
        val ex = MediaExtractor()
        ex.setDataSource(sourcePath)
        if (sourceTrackIndex >= ex.trackCount) throw FailClosed("media_reopen_track_missing:$sourceTrackIndex")
        val reopenedMime = ex.getTrackFormat(sourceTrackIndex).getString(MediaFormat.KEY_MIME)
        if (reopenedMime != sourceMime) throw FailClosed("media_reopen_mime_changed:$reopenedMime")
        ex.selectTrack(sourceTrackIndex)
        return ex
    }
}
