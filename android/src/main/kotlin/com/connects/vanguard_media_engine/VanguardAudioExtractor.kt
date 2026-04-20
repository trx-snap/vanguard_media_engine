package com.connects.vanguard_media_engine

// ── VanguardAudioExtractor (Phase B4-S1 — extractAudio) ───────────────────────
//
// Android equivalent of iOS AVAssetExportSession (audio-only preset).
//
// Pipeline:
//   MediaExtractor (audio track only)
//   → stream-copy (no re-encode — preserves AAC/MP4a quality, very fast)
//   → MediaMuxer → .m4a
//
// Design decisions:
//   1. Stream-copy only — quality preserved, latency ~10–50ms for typical clips.
//   2. PTS rebasing: output PTS starts at 0, not at trimStartUs.
//      Matches iOS behaviour and avoids player seek-to-start confusion.
//   3. double.infinity from Dart trimEnd → caller passes null after isFinite() guard.
//   4. Blocking — always called from a background Thread in the plugin.
//   5. If no audio track found, throws IllegalStateException — caller forwards to result.error.

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.nio.ByteBuffer

internal object VanguardAudioExtractor {

    private const val TAG = "VanguardAudioEx"

    /**
     * Extracts the audio track from [videoPath] and writes it to [outputPath] (.m4a / .mp4).
     *
     * Audio is stream-copied (not re-encoded), preserving original quality.
     * Output PTS is rebased to start at 0 regardless of [trimStartSec].
     *
     * @param videoPath    Absolute path to source video (or audio-only) file.
     * @param outputPath   Absolute path to write the extracted audio (should end in .m4a).
     * @param trimStartSec Start offset in seconds. Seeks to nearest I-frame.
     * @param trimEndSec   End offset in seconds, or null for full duration.
     * @return [outputPath] on success.
     * @throws IllegalStateException if the source has no audio track.
     * @throws Exception on I/O or muxer errors.
     */
    fun extract(
        videoPath: String,
        outputPath: String,
        trimStartSec: Double = 0.0,
        trimEndSec: Double? = null,
    ): String {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(videoPath)

            // 1. Find the audio track
            var audioTrackIndex = -1
            var audioFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    audioTrackIndex = i
                    audioFormat = f
                    break
                }
            }
            if (audioTrackIndex < 0 || audioFormat == null) {
                throw IllegalStateException("No audio track found in: $videoPath")
            }
            extractor.selectTrack(audioTrackIndex)

            // 2. Seek to trimStart
            val trimStartUs = (trimStartSec * 1_000_000L).toLong()
            if (trimStartUs > 0L) {
                extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }
            val trimEndUs = trimEndSec?.let { (it * 1_000_000L).toLong() } ?: Long.MAX_VALUE

            // 3. Set up muxer — addTrack must be called before muxer.start()
            val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val outTrack = muxer.addTrack(audioFormat)
            muxer.start()

            // 4. Stream-copy audio frames — 512 KB handles any AAC frame size
            val buf = ByteBuffer.allocate(512 * 1024)
            val info = MediaCodec.BufferInfo()
            var frameCount = 0

            while (true) {
                val size = extractor.readSampleData(buf, 0)
                if (size < 0) break                      // natural EOS
                val sampleTimeUs = extractor.sampleTime
                if (sampleTimeUs > trimEndUs) break      // past trim end

                // Rebase PTS so output always starts at t=0
                val outputPts = (sampleTimeUs - trimStartUs).coerceAtLeast(0L)

                info.offset             = 0
                info.size               = size
                info.presentationTimeUs = outputPts
                info.flags              = extractor.sampleFlags

                muxer.writeSampleData(outTrack, buf, info)
                extractor.advance()
                frameCount++
            }

            muxer.stop()
            muxer.release()
            Log.i(TAG, "extract OK — $frameCount frames → $outputPath")
            return outputPath

        } finally {
            try { extractor.release() } catch (_: Exception) {}
        }
    }
}
