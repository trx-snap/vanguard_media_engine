package com.connects.vanguard_media_engine.export

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import java.io.File
import java.nio.ByteBuffer

// ── AndroidAudioRemuxer (Export/Audio Unit B) ─────────────────────────────────
//
// Stream-copies the first video track from [videoPath] and (optionally) the
// first audio track from [audioPath] into [finalPath] using
// MediaExtractor + MediaMuxer. No re-encode.
//
// MediaMuxer contract (Android official API constraints):
//   - All tracks are added via addTrack() BEFORE muxer.start().
//   - Samples are written after start() and before stop().
//   - Per-track PTS is strictly non-decreasing (extractor read order); tracks
//     are interleaved by the next available sample timestamp.
//   - stop() throws in the wrong state, so it is only called when the muxer
//     started AND at least one video sample was written AND, when audio is
//     required, at least one audio sample was written.
//   - release() always runs in finally, as do extractor releases.
//
// Failure behaviour: the partial [finalPath] is deleted; the source video and
// audio files are never touched.

/// Structured remux outcome. [reason] is "success" or a machine-readable
/// failure cause.
data class AndroidAudioRemuxResult(
    val success: Boolean,
    val reason: String,
    val videoSamples: Int,
    val audioSamples: Int,
    val outputSizeBytes: Long,
)

object AndroidAudioRemuxer {

    private const val TAG = "VanguardAudioRemux"
    private const val COPY_BUFFER_BYTES = 1024 * 1024

    /// Remuxes video (+ optional audio) into [finalPath].
    /// When [audioPath] is non-null the audio track is required: a missing
    /// audio track or zero written audio samples is a failure.
    ///
    /// [context] is an optional Context used ONLY when [videoPath] or
    /// [audioPath] is a `content://` URI (a direct-copy original-sound track
    /// over an Android gallery-reference clip); POSIX inputs never touch it.
    /// [finalPath] is always a POSIX MediaMuxer output and is unaffected. A
    /// `content://` input with a null Context fails closed as
    /// `exception:IllegalArgumentException` through the existing catch --
    /// extractor/muxer releases in `finally` are unchanged.
    fun remux(
        videoPath: String,
        audioPath: String?,
        finalPath: String,
        context: Context? = null,
    ): AndroidAudioRemuxResult {
        val videoExtractor = MediaExtractor()
        var audioExtractor: MediaExtractor? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var muxerStoppedCleanly = false
        var videoSamples = 0
        var audioSamples = 0
        var failureReason: String? = null

        try {
            AndroidUriDataSourceHelper.setExtractorDataSource(videoExtractor, videoPath, context)
            val videoTrackFormat = selectFirstTrack(videoExtractor, "video/")
            if (videoTrackFormat == null) {
                failureReason = "no_video_track"
                return failed(failureReason, videoSamples, audioSamples)
            }

            var audioTrackFormat: MediaFormat? = null
            val audioRequired = audioPath != null
            if (audioPath != null) {
                val ae = MediaExtractor()
                audioExtractor = ae
                AndroidUriDataSourceHelper.setExtractorDataSource(ae, audioPath, context)
                audioTrackFormat = selectFirstTrack(ae, "audio/")
                if (audioTrackFormat == null) {
                    failureReason = "no_audio_track"
                    return failed(failureReason, videoSamples, audioSamples)
                }
            }

            // All tracks added before start().
            val mx = MediaMuxer(finalPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mx
            val muxVideoTrack = mx.addTrack(videoTrackFormat)
            val muxAudioTrack = audioTrackFormat?.let { mx.addTrack(it) } ?: -1
            mx.start()
            muxerStarted = true

            // One cursor per selected extractor. End-of-stream is decided only
            // by readSampleData() < 0 — never by a pre-read sampleTime probe,
            // which some extractors report as -1 before the first read.
            val videoCursor = SampleCursor(videoExtractor)
            val audioCursor = audioExtractor?.let { SampleCursor(it) }
            videoCursor.prime()
            audioCursor?.prime()

            // Interleave by the primed cursors' next presentationTimeUs; each
            // extractor delivers its own samples in increasing PTS order.
            while (videoCursor.hasSample || audioCursor?.hasSample == true) {
                val writeVideo = when {
                    !videoCursor.hasSample -> false
                    audioCursor?.hasSample != true -> true
                    else -> videoCursor.info.presentationTimeUs <= audioCursor.info.presentationTimeUs
                }
                if (writeVideo) {
                    mx.writeSampleData(muxVideoTrack, videoCursor.buffer, videoCursor.info)
                    videoSamples++
                    videoCursor.advanceAndPrime()
                } else {
                    mx.writeSampleData(muxAudioTrack, audioCursor!!.buffer, audioCursor.info)
                    audioSamples++
                    audioCursor.advanceAndPrime()
                }
            }

            if (videoSamples <= 0) {
                failureReason = "no_video_samples_written"
                return failed(failureReason, videoSamples, audioSamples)
            }
            if (audioRequired && audioSamples <= 0) {
                failureReason = "no_audio_samples_written"
                return failed(failureReason, videoSamples, audioSamples)
            }

            // Safe to stop: started, video written, and audio written if required.
            mx.stop()
            muxerStoppedCleanly = true

            val outputFile = File(finalPath)
            val outputSize = if (outputFile.exists()) outputFile.length() else 0L
            if (outputSize <= 0L) {
                failureReason = "output_file_empty_or_missing"
                return failed(failureReason, videoSamples, audioSamples)
            }

            Log.i(TAG, "remux OK — video=$videoSamples audio=$audioSamples bytes=$outputSize → $finalPath")
            return AndroidAudioRemuxResult(
                success = true,
                reason = "success",
                videoSamples = videoSamples,
                audioSamples = audioSamples,
                outputSizeBytes = outputSize,
            )
        } catch (t: Throwable) {
            failureReason = "exception:${t.javaClass.simpleName}"
            Log.e(TAG, "remux failed: $t")
            return failed(failureReason, videoSamples, audioSamples)
        } finally {
            if (muxerStarted && !muxerStoppedCleanly) {
                // Wrong-state stop can throw; swallow — release still runs.
                try { muxer?.stop() } catch (_: Throwable) {}
            }
            try { muxer?.release() } catch (_: Throwable) {}
            try { videoExtractor.release() } catch (_: Throwable) {}
            try { audioExtractor?.release() } catch (_: Throwable) {}
            if (failureReason != null) {
                // Delete the partial final output; sources are preserved.
                try {
                    val f = File(finalPath)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {}
            }
        }
    }

    /// Finds and selects the first track whose MIME starts with [mimePrefix].
    private fun selectFirstTrack(extractor: MediaExtractor, mimePrefix: String): MediaFormat? {
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            if (format.getString(MediaFormat.KEY_MIME)?.startsWith(mimePrefix) == true) {
                extractor.selectTrack(i)
                return format
            }
        }
        return null
    }

    /// Read cursor over one selected extractor track. Owns its own buffer and
    /// BufferInfo; [prime] reads the next sample and [hasSample] is false only
    /// when readSampleData() returned < 0 (true end of stream).
    private class SampleCursor(private val extractor: MediaExtractor) {
        val buffer: ByteBuffer = ByteBuffer.allocate(COPY_BUFFER_BYTES)
        val info = MediaCodec.BufferInfo()
        var hasSample = false
            private set

        fun prime() {
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) {
                hasSample = false
                return
            }
            info.offset = 0
            info.size = size
            // Clamp only a negative timestamp reported for an actual sample.
            info.presentationTimeUs = extractor.sampleTime.coerceAtLeast(0L)
            info.flags = extractor.sampleFlags
            hasSample = true
        }

        fun advanceAndPrime() {
            extractor.advance()
            prime()
        }
    }

    private fun failed(reason: String, videoSamples: Int, audioSamples: Int): AndroidAudioRemuxResult =
        AndroidAudioRemuxResult(
            success = false,
            reason = reason,
            videoSamples = videoSamples,
            audioSamples = audioSamples,
            outputSizeBytes = 0L,
        )
}
