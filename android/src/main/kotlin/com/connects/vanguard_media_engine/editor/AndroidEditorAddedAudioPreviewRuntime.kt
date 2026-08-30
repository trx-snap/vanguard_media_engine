package com.connects.vanguard_media_engine.editor

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Immutable added-music track config for [AndroidEditorAddedAudioPreviewRuntime].
 *
 * [durationUs] / [sourceTrimStartUs] are microseconds; [effectiveGain] is linear gain
 * (volume * mixGain from the wire sidecar track) clamped to `[0.0, 1.0]` by the runtime.
 * This slice requires the track's wire `startTime` to be exactly `0.0`, so the added
 * track's own timeline is the same PTS space as the global editor timeline.
 */
data class AndroidEditorAddedAudioTrackConfig(
    val trackId: String,
    val sourcePath: String,
    val durationUs: Long,
    val sourceTrimStartUs: Long,
    val effectiveGain: Double,
)

/**
 * Single-clip editor-preview added music runtime.
 *
 * Plays back exactly one added music sidecar track using a single [MediaPlayer] confined to its
 * own dedicated [HandlerThread]/[Handler] (`audioHandler`) — mirroring
 * [AndroidEditorOriginalAudioPreviewRuntime]'s confinement style. Preview only; never touches
 * export/mux behavior, fades, keyframes, SFX, voiceover, delayed start, multi-track mixing,
 * multi-clip clocking, ducking, or waveform logic.
 *
 * Since [AndroidEditorAddedAudioTrackConfig] always has wire `startTime == 0.0` in this slice,
 * a global timeline PTS maps 1:1 onto this track's own timeline PTS, and onto source-file PTS via
 * `sourceTrimStartUs + timelinePtsUs`.
 *
 * Failure handling: any MediaPlayer setup/prepare/seek/start error disables this instance
 * (`enabled = false`) and every subsequent call becomes a silent no-op — a corrupt/unsupported
 * added-audio source never blocks or fails the accompanying video preview.
 *
 * [context] is used only to request/abandon [AudioManager] playback focus; optional, and skipped
 * entirely when null.
 */
class AndroidEditorAddedAudioPreviewRuntime(
    private val context: Context?,
    private val config: AndroidEditorAddedAudioTrackConfig,
) {
    companion object {
        private const val TAG = "EditorAddedAudioPreview"
        private const val LOG_PREFIX = "VG_EDITOR_ADDED_AUDIO_PREVIEW"
    }

    private val gain = config.effectiveGain.coerceIn(0.0, 1.0).toFloat()

    private val audioThread = HandlerThread("EditorAddedAudioPreview_${config.trackId}").also { it.start() }
    private val audioHandler = Handler(audioThread.looper)

    private val released = AtomicBoolean(false)

    // ── audioHandler-confined state (all MediaPlayer/AudioManager calls happen there) ────────
    private var player: MediaPlayer? = null
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false

    /** True once a usable, playable [MediaPlayer] exists for this track. */
    private var enabled = false

    /**
     * This track's own current position on the global/track timeline (they are the same space —
     * see class doc), microseconds. Updated on successful [seek] and on [pause] (read back from
     * [MediaPlayer.getCurrentPosition]); used to gate [play] and to compute the remaining-duration
     * end runnable.
     */
    private var currentTimelinePtsUs: Long = 0L

    private val endRunnable = Runnable { onTrackEndReachedLocked() }

    // ── prepare ────────────────────────────────────────────────────────────

    /**
     * Prepares this track's [MediaPlayer], preroll-seeked to [AndroidEditorAddedAudioTrackConfig
     * .sourceTrimStartUs]. [onDone] always fires exactly once, posted on [audioHandler]; a
     * missing/corrupt/unsupported source disables this instance and still calls [onDone] so a
     * caller's activation sequence never stalls on a bad added-audio track.
     */
    fun prepare(onDone: () -> Unit) {
        audioHandler.post {
            Log.i(TAG, "$LOG_PREFIX prepare_started trackId=${config.trackId}")
            if (released.get()) {
                Log.i(TAG, "$LOG_PREFIX prepare_skip_released trackId=${config.trackId}")
                onDone()
                return@post
            }
            teardownPlayerLocked()

            val file = File(config.sourcePath)
            if (!file.exists() || !file.canRead()) {
                Log.w(TAG, "$LOG_PREFIX prepare_failed reason=file_unreadable trackId=${config.trackId}")
                enabled = false
                onDone()
                return@post
            }

            val doneOnce = AtomicBoolean(false)
            fun finish() {
                if (doneOnce.compareAndSet(false, true)) onDone()
            }

            val mp = MediaPlayer()
            try {
                mp.setOnErrorListener { _, what, extra ->
                    Log.w(TAG, "$LOG_PREFIX prepare_failed reason=error_listener what=$what extra=$extra trackId=${config.trackId}")
                    disableLocked(mp, "prepare_error_listener")
                    finish()
                    true
                }
                mp.setOnPreparedListener {
                    if (released.get()) {
                        try { mp.release() } catch (_: Throwable) {}
                        finish()
                        return@setOnPreparedListener
                    }
                    player = mp
                    enabled = true
                    currentTimelinePtsUs = 0L
                    try {
                        mp.setVolume(gain, gain)
                    } catch (t: Throwable) {
                        Log.w(TAG, "$LOG_PREFIX prepare_set_volume_error trackId=${config.trackId}", t)
                    }
                    val targetMs = (config.sourceTrimStartUs / 1000L)
                        .coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
                    if (targetMs > 0L) {
                        mp.setOnSeekCompleteListener {
                            Log.i(TAG, "$LOG_PREFIX prepare_success trackId=${config.trackId} durationMs=${mp.duration}")
                            finish()
                        }
                        try {
                            mp.seekTo(targetMs.toInt())
                        } catch (t: Throwable) {
                            Log.w(TAG, "$LOG_PREFIX prepare_failed reason=preroll_seek_error trackId=${config.trackId}", t)
                            disableLocked(mp, "prepare_preroll_seek_error")
                            finish()
                        }
                    } else {
                        Log.i(TAG, "$LOG_PREFIX prepare_success trackId=${config.trackId} durationMs=${mp.duration}")
                        finish()
                    }
                }
                mp.setDataSource(config.sourcePath)
                mp.prepareAsync()
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX prepare_failed reason=setup_error trackId=${config.trackId}", t)
                try { mp.release() } catch (_: Throwable) {}
                enabled = false
                finish()
            }
        }
    }

    // ── play / pause ───────────────────────────────────────────────────────

    /**
     * Requests audio focus (best-effort) and starts playback if enabled and the current timeline
     * position is within `[0, durationUs)`. No-op otherwise. Schedules [endRunnable] for the
     * remaining track duration.
     */
    fun play() {
        audioHandler.post {
            if (released.get() || !enabled) {
                Log.i(TAG, "$LOG_PREFIX play_skip reason=${if (released.get()) "released" else "disabled"} trackId=${config.trackId}")
                return@post
            }
            val mp = player
            if (mp == null) {
                Log.i(TAG, "$LOG_PREFIX play_skip reason=no_player trackId=${config.trackId}")
                return@post
            }
            if (currentTimelinePtsUs < 0L || currentTimelinePtsUs >= config.durationUs) {
                Log.i(TAG, "$LOG_PREFIX play_skip reason=out_of_range currentTimelinePtsUs=$currentTimelinePtsUs durationUs=${config.durationUs} trackId=${config.trackId}")
                return@post
            }
            requestFocusLocked()
            try {
                mp.start()
                scheduleEndRunnableLocked()
                Log.i(TAG, "$LOG_PREFIX play_started trackId=${config.trackId} currentTimelinePtsUs=$currentTimelinePtsUs")
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX play_start_error trackId=${config.trackId}", t)
                disableLocked(mp, "play_start_error")
            }
        }
    }

    /**
     * Cancels the end runnable, updates [currentTimelinePtsUs] from the player's current
     * position where possible, pauses playback (if playing), and abandons audio focus.
     */
    fun pause() {
        audioHandler.post {
            Log.i(TAG, "$LOG_PREFIX pause_start trackId=${config.trackId}")
            audioHandler.removeCallbacks(endRunnable)
            abandonFocusLocked()
            if (released.get() || !enabled) {
                Log.i(TAG, "$LOG_PREFIX pause_done reason=${if (released.get()) "released" else "disabled"} trackId=${config.trackId}")
                return@post
            }
            val mp = player
            if (mp == null) {
                Log.i(TAG, "$LOG_PREFIX pause_done reason=no_player trackId=${config.trackId}")
                return@post
            }
            try {
                val sourcePosUs = mp.currentPosition.toLong() * 1000L
                currentTimelinePtsUs = (sourcePosUs - config.sourceTrimStartUs).coerceIn(0L, config.durationUs)
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX pause_position_read_error trackId=${config.trackId}", t)
            }
            try {
                if (mp.isPlaying) mp.pause()
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX pause_error trackId=${config.trackId}", t)
            }
            Log.i(TAG, "$LOG_PREFIX pause_done trackId=${config.trackId} currentTimelinePtsUs=$currentTimelinePtsUs")
        }
    }

    // ── seek ───────────────────────────────────────────────────────────────

    /**
     * Seeks this track to [targetTimelinePtsUs]. A target outside `[0, durationUs)` pauses/seeks
     * to [AndroidEditorAddedAudioTrackConfig.sourceTrimStartUs] (this track's timeline 0) and
     * never resumes; a target inside seeks to the mapped source position and resumes only when
     * [resumeAfterSeek] is true and the seek succeeds. [onDone] always fires exactly once, posted
     * on [audioHandler].
     */
    fun seek(targetTimelinePtsUs: Long, resumeAfterSeek: Boolean, onDone: () -> Unit) {
        audioHandler.post {
            audioHandler.removeCallbacks(endRunnable)
            val mp = player
            if (released.get() || !enabled || mp == null) {
                val reason = when {
                    released.get() -> "released"
                    !enabled -> "disabled"
                    else -> "no_player"
                }
                Log.i(TAG, "$LOG_PREFIX seek_skip reason=$reason trackId=${config.trackId}")
                onDone()
                return@post
            }

            val doneOnce = AtomicBoolean(false)
            fun finish() {
                if (doneOnce.compareAndSet(false, true)) onDone()
            }

            val inRange = targetTimelinePtsUs >= 0L && targetTimelinePtsUs < config.durationUs
            if (!inRange) {
                try {
                    if (mp.isPlaying) mp.pause()
                } catch (t: Throwable) {
                    Log.w(TAG, "$LOG_PREFIX seek_out_of_range_pause_error trackId=${config.trackId}", t)
                }
                abandonFocusLocked()
                val targetMs = (config.sourceTrimStartUs / 1000L)
                    .coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
                try {
                    mp.setOnSeekCompleteListener {
                        currentTimelinePtsUs = 0L
                        Log.i(TAG, "$LOG_PREFIX seek_completed resume=false outOfRange=true trackId=${config.trackId}")
                        finish()
                    }
                    mp.seekTo(targetMs.toInt())
                } catch (t: Throwable) {
                    Log.w(TAG, "$LOG_PREFIX seek_error trackId=${config.trackId}", t)
                    disableLocked(mp, "seek_error")
                    finish()
                }
                return@post
            }

            val targetSourceUs = config.sourceTrimStartUs + targetTimelinePtsUs
            val targetMs = (targetSourceUs / 1000L).coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
            try {
                mp.setOnSeekCompleteListener {
                    currentTimelinePtsUs = targetTimelinePtsUs
                    if (resumeAfterSeek) {
                        requestFocusLocked()
                        try {
                            mp.start()
                            scheduleEndRunnableLocked()
                        } catch (t: Throwable) {
                            Log.w(TAG, "$LOG_PREFIX seek_resume_error trackId=${config.trackId}", t)
                            disableLocked(mp, "seek_resume_error")
                        }
                    }
                    Log.i(TAG, "$LOG_PREFIX seek_completed resume=$resumeAfterSeek outOfRange=false trackId=${config.trackId} targetTimelinePtsUs=$targetTimelinePtsUs")
                    finish()
                }
                mp.seekTo(targetMs.toInt())
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX seek_error trackId=${config.trackId}", t)
                disableLocked(mp, "seek_error")
                finish()
            }
        }
    }

    // ── release ────────────────────────────────────────────────────────────

    /**
     * Releases the [MediaPlayer] (if any), abandons audio focus, and quits [audioThread].
     * Idempotent. [onDone] (if provided) always fires exactly once: immediately on the caller's
     * thread if already released, otherwise posted from [audioHandler] after teardown.
     */
    fun release(onDone: (() -> Unit)? = null) {
        if (!released.compareAndSet(false, true)) {
            onDone?.invoke()
            return
        }
        audioHandler.post {
            Log.i(TAG, "$LOG_PREFIX release_start trackId=${config.trackId}")
            audioHandler.removeCallbacks(endRunnable)
            abandonFocusLocked()
            teardownPlayerLocked()
            Log.i(TAG, "$LOG_PREFIX release_done trackId=${config.trackId}")
            onDone?.invoke()
            try { audioThread.quitSafely() } catch (_: Throwable) {}
        }
    }

    // ── internal helpers (confined to audioHandler) ─────────────────────────

    private fun scheduleEndRunnableLocked() {
        audioHandler.removeCallbacks(endRunnable)
        val remainingUs = (config.durationUs - currentTimelinePtsUs).coerceAtLeast(0L)
        audioHandler.postDelayed(endRunnable, remainingUs / 1000L)
    }

    private fun onTrackEndReachedLocked() {
        val mp = player
        try {
            if (mp != null && mp.isPlaying) mp.pause()
        } catch (t: Throwable) {
            Log.w(TAG, "$LOG_PREFIX track_end_pause_error trackId=${config.trackId}", t)
        }
        currentTimelinePtsUs = config.durationUs
        abandonFocusLocked()
        Log.i(TAG, "$LOG_PREFIX track_end_reached trackId=${config.trackId}")
    }

    private fun disableLocked(mp: MediaPlayer, reason: String = "unknown") {
        Log.w(TAG, "$LOG_PREFIX disable reason=$reason trackId=${config.trackId}")
        enabled = false
        abandonFocusLocked()
        if (player === mp) {
            player = null
        }
        try { mp.reset() } catch (_: Throwable) {}
        try { mp.release() } catch (_: Throwable) {}
    }

    private fun teardownPlayerLocked() {
        enabled = false
        val mp = player
        player = null
        if (mp != null) {
            try { mp.reset() } catch (_: Throwable) {}
            try { mp.release() } catch (_: Throwable) {}
        }
    }

    private fun requestFocusLocked() {
        if (hasFocus) {
            Log.i(TAG, "$LOG_PREFIX focus_result skipped reason=already_has_focus trackId=${config.trackId}")
            return
        }
        val ctx = context
        if (ctx == null) {
            Log.i(TAG, "$LOG_PREFIX focus_result skipped reason=no_context trackId=${config.trackId}")
            return
        }
        try {
            val am = audioManager ?: (ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.also {
                audioManager = it
            }
            if (am == null) {
                Log.i(TAG, "$LOG_PREFIX focus_result skipped reason=no_audio_manager trackId=${config.trackId}")
                return
            }
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .build()
            focusRequest = request
            hasFocus = am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            Log.i(TAG, "$LOG_PREFIX focus_result ${if (hasFocus) "granted" else "not_granted"} trackId=${config.trackId}")
        } catch (t: Throwable) {
            Log.w(TAG, "$LOG_PREFIX focus_result error trackId=${config.trackId}", t)
            hasFocus = false
        }
    }

    private fun abandonFocusLocked() {
        if (!hasFocus) return
        hasFocus = false
        val am = audioManager
        val request = focusRequest
        focusRequest = null
        if (am != null && request != null) {
            try {
                am.abandonAudioFocusRequest(request)
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX abandonFocusLocked_error trackId=${config.trackId}", t)
            }
        }
    }
}
