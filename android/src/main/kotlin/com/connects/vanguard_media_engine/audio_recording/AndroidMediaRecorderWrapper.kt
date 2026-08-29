package com.connects.vanguard_media_engine.audio_recording

import android.content.Context
import android.media.MediaRecorder
import android.os.Build

// ── AndroidMediaRecorderWrapper (Phase 4-Unit H / Phase 5-Unit AC) ───────────
//
// Thin wrapper around a single-use MediaRecorder configured MIC -> MPEG_4 ->
// AAC, 44100 Hz mono, 64000 bps. All methods here perform blocking I/O
// (prepare/start/stop/release) and must be called off the main thread by the
// owning coordinator.
class AndroidMediaRecorderWrapper private constructor(
    private val recorder: MediaRecorder,
) {
    companion object {
        private const val SAMPLE_RATE_HZ = 44100
        private const val CHANNEL_COUNT = 1
        private const val BIT_RATE_BPS = 64000

        fun create(context: Context, outputPath: String): AndroidMediaRecorderWrapper {
            val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioSamplingRate(SAMPLE_RATE_HZ)
            recorder.setAudioChannels(CHANNEL_COUNT)
            recorder.setAudioEncodingBitRate(BIT_RATE_BPS)
            recorder.setOutputFile(outputPath)
            return AndroidMediaRecorderWrapper(recorder)
        }
    }

    /** Blocking. Must be called off the main thread. */
    fun prepareAndStart() {
        recorder.prepare()
        recorder.start()
    }

    /** Blocking. Must be called off the main thread. */
    fun stopAndRelease() {
        try {
            recorder.stop()
        } finally {
            recorder.release()
        }
    }

    /** Best-effort teardown for failure/detach paths -- swallows all errors. */
    fun releaseQuietly() {
        try { recorder.stop() } catch (_: Throwable) {}
        try { recorder.release() } catch (_: Throwable) {}
    }
}
