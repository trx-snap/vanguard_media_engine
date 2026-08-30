package com.connects.vanguard_media_engine.editor

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Immutable added-music track config for [AndroidEditorAddedAudioPreviewRuntime].
 *
 * [durationUs] / [sourceTrimStartUs] / [trackStartUs] are microseconds; [effectiveGain] is
 * linear gain (volume * mixGain from the wire sidecar track) clamped to `[0.0, 1.0]` by the
 * runtime. [trackStartUs] is this track's delayed start position on the global editor timeline
 * (Phase 7.8K-Android): the track is silent outside `[trackStartUs, trackStartUs + durationUs)`.
 */
data class AndroidEditorAddedAudioTrackConfig(
    val trackId: String,
    val sourcePath: String,
    val durationUs: Long,
    val sourceTrimStartUs: Long,
    val trackStartUs: Long,
    val effectiveGain: Double,
)

/**
 * Single-clip editor-preview added music runtime.
 *
 * Plays back exactly one added music sidecar track using a single [MediaPlayer] confined to its
 * own dedicated [HandlerThread]/[Handler] (`audioHandler`) — mirroring
 * [AndroidEditorOriginalAudioPreviewRuntime]'s confinement style. Preview only; never touches
 * export/mux behavior, fades, keyframes, SFX, voiceover, multi-track mixing, multi-clip clocking,
 * ducking, or waveform logic.
 *
 * A global timeline PTS ([currentTimelinePtsUs]) maps onto this track's own timeline via
 * [AndroidEditorAddedAudioTrackConfig.trackStartUs] (Phase 7.8K-Android: the track may start/end
 * anywhere on the global timeline, not just at PTS 0), and onto source-file PTS via
 * `sourceTrimStartUs + (timelinePtsUs - trackStartUs)` while inside the track's window
 * `[trackStartUs, trackStartUs + durationUs)`.
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

    /** Exclusive end of this track's window on the global timeline, microseconds. */
    private val trackEndUs = config.trackStartUs + config.durationUs

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
     * This track's current position on the *global* editor timeline, microseconds. While the
     * position is before [AndroidEditorAddedAudioTrackConfig.trackStartUs], the [MediaPlayer]
     * (if any) is kept parked, paused, at [AndroidEditorAddedAudioTrackConfig.sourceTrimStartUs]
     * — that invariant lets a scheduled [startRunnable] fire without a re-seek. Updated on
     * successful [seek], on [pause] (from wall-clock while waiting to start, or read back from
     * [MediaPlayer.getCurrentPosition] once started), and on [onTrackEndReachedLocked].
     */
    private var currentTimelinePtsUs: Long = 0L

    /** True from a [play] call (or a resuming [seek]) until [pause]/EOS/[seek] ends the session. */
    private var playing = false

    /** True once [MediaPlayer.start] has actually been invoked for the current [playing] session. */
    private var mediaStarted = false

    /** [SystemClock.uptimeMillis] recorded when the current before-start [playing] wait began. */
    private var playBaselineUptimeMs: Long = 0L

    private val startRunnable = Runnable { onDelayedStartFiredLocked() }
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
                    playing = false
                    mediaStarted = false
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
     * Starts (or schedules the delayed start of) this track, if enabled and the current global
     * timeline position is before [trackEndUs]. No-op otherwise (including a repeat call while
     * already [playing]).
     *
     * - Before [AndroidEditorAddedAudioTrackConfig.trackStartUs]: schedules [startRunnable] for
     *   the remaining delay and does not request audio focus or touch the [MediaPlayer] until it
     *   actually fires.
     * - Inside the track window: seeks (if needed) and starts the [MediaPlayer] immediately,
     *   requests focus immediately, and schedules [endRunnable] for the remaining duration.
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
            if (playing) {
                Log.i(TAG, "$LOG_PREFIX play_skip reason=already_playing trackId=${config.trackId}")
                return@post
            }
            if (currentTimelinePtsUs >= trackEndUs) {
                Log.i(TAG, "$LOG_PREFIX play_skip reason=out_of_range currentTimelinePtsUs=$currentTimelinePtsUs trackEndUs=$trackEndUs trackId=${config.trackId}")
                return@post
            }

            playing = true
            playBaselineUptimeMs = SystemClock.uptimeMillis()
            if (currentTimelinePtsUs < config.trackStartUs) {
                val delayMs = (config.trackStartUs - currentTimelinePtsUs) / 1000L
                audioHandler.removeCallbacks(startRunnable)
                audioHandler.postDelayed(startRunnable, delayMs)
                Log.i(TAG, "$LOG_PREFIX delayed_start_scheduled trackId=${config.trackId} delayMs=$delayMs currentTimelinePtsUs=$currentTimelinePtsUs trackStartUs=${config.trackStartUs}")
            } else {
                startMediaAtCurrentPtsLocked(mp, seekFirst = true)
            }
        }
    }

    /**
     * Fires when a delayed start's schedule elapses. By the before-start invariant the
     * [MediaPlayer] is already parked at [AndroidEditorAddedAudioTrackConfig.sourceTrimStartUs]
     * (== the source position at [AndroidEditorAddedAudioTrackConfig.trackStartUs]), so this
     * starts it directly without a re-seek. A no-op if [pause]/[seek] cancelled this wait first.
     */
    private fun onDelayedStartFiredLocked() {
        if (released.get() || !enabled || !playing || mediaStarted) return
        val mp = player ?: return
        currentTimelinePtsUs = config.trackStartUs
        startMediaAtCurrentPtsLocked(mp, seekFirst = false)
    }

    /**
     * Starts [mp] at the source position mapped from [currentTimelinePtsUs], requests audio
     * focus, and schedules [endRunnable]. [seekFirst] seeks to the mapped source position before
     * starting (needed when entering the track window directly via [play]/[seek], since the
     * MediaPlayer may still be parked elsewhere); false skips the seek when the caller already
     * knows the MediaPlayer is correctly positioned (the delayed-start-fired path).
     */
    private fun startMediaAtCurrentPtsLocked(mp: MediaPlayer, seekFirst: Boolean) {
        fun doStart() {
            requestFocusLocked()
            try {
                mp.start()
                mediaStarted = true
                scheduleEndRunnableLocked()
                Log.i(TAG, "$LOG_PREFIX play_started trackId=${config.trackId} currentTimelinePtsUs=$currentTimelinePtsUs")
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX play_start_error trackId=${config.trackId}", t)
                playing = false
                disableLocked(mp, "play_start_error")
            }
        }

        if (!seekFirst) {
            doStart()
            return
        }
        val targetSourceUs = config.sourceTrimStartUs + (currentTimelinePtsUs - config.trackStartUs)
        val targetMs = (targetSourceUs / 1000L).coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
        try {
            mp.setOnSeekCompleteListener { doStart() }
            mp.seekTo(targetMs.toInt())
        } catch (t: Throwable) {
            Log.w(TAG, "$LOG_PREFIX play_seek_error trackId=${config.trackId}", t)
            playing = false
            disableLocked(mp, "play_seek_error")
        }
    }

    /**
     * Cancels the start/end runnables, updates [currentTimelinePtsUs] (from wall-clock if the
     * track had not started yet, or from the player's current position otherwise), pauses
     * playback (if playing), and abandons audio focus.
     */
    fun pause() {
        audioHandler.post {
            Log.i(TAG, "$LOG_PREFIX pause_start trackId=${config.trackId}")
            audioHandler.removeCallbacks(startRunnable)
            audioHandler.removeCallbacks(endRunnable)
            abandonFocusLocked()
            if (released.get() || !enabled) {
                playing = false
                mediaStarted = false
                Log.i(TAG, "$LOG_PREFIX pause_done reason=${if (released.get()) "released" else "disabled"} trackId=${config.trackId}")
                return@post
            }
            val mp = player
            if (mp == null) {
                playing = false
                mediaStarted = false
                Log.i(TAG, "$LOG_PREFIX pause_done reason=no_player trackId=${config.trackId}")
                return@post
            }
            if (playing) {
                if (mediaStarted) {
                    try {
                        val sourcePosUs = mp.currentPosition.toLong() * 1000L
                        currentTimelinePtsUs = (sourcePosUs - config.sourceTrimStartUs + config.trackStartUs)
                            .coerceIn(config.trackStartUs, trackEndUs)
                    } catch (t: Throwable) {
                        Log.w(TAG, "$LOG_PREFIX pause_position_read_error trackId=${config.trackId}", t)
                    }
                } else {
                    val elapsedMs = SystemClock.uptimeMillis() - playBaselineUptimeMs
                    currentTimelinePtsUs += elapsedMs.coerceAtLeast(0L) * 1000L
                }
                try {
                    if (mp.isPlaying) mp.pause()
                } catch (t: Throwable) {
                    Log.w(TAG, "$LOG_PREFIX pause_error trackId=${config.trackId}", t)
                }
            }
            playing = false
            mediaStarted = false
            Log.i(TAG, "$LOG_PREFIX pause_done trackId=${config.trackId} currentTimelinePtsUs=$currentTimelinePtsUs")
        }
    }

    // ── seek ───────────────────────────────────────────────────────────────

    /**
     * Seeks this track to [targetTimelinePtsUs] (a global timeline PTS). Cancels the start/end
     * runnables and pauses/abandons focus first. A target before
     * [AndroidEditorAddedAudioTrackConfig.trackStartUs] parks the [MediaPlayer] at
     * [AndroidEditorAddedAudioTrackConfig.sourceTrimStartUs] and, if [resumeAfterSeek], schedules
     * a fresh delayed [play] using the retained target; a target inside the window seeks to the
     * mapped source position and starts immediately when [resumeAfterSeek]; a target at/after the
     * window end just records the position (no MediaPlayer seek, never starts). [onDone] always
     * fires exactly once, posted on [audioHandler].
     */
    fun seek(targetTimelinePtsUs: Long, resumeAfterSeek: Boolean, onDone: () -> Unit) {
        audioHandler.post {
            audioHandler.removeCallbacks(startRunnable)
            audioHandler.removeCallbacks(endRunnable)
            playing = false
            mediaStarted = false
            abandonFocusLocked()

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

            try {
                if (mp.isPlaying) mp.pause()
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX seek_pause_error trackId=${config.trackId}", t)
            }

            when {
                targetTimelinePtsUs >= trackEndUs -> {
                    currentTimelinePtsUs = targetTimelinePtsUs
                    Log.i(TAG, "$LOG_PREFIX seek_completed resume=false region=at_or_after_end trackId=${config.trackId} targetTimelinePtsUs=$targetTimelinePtsUs")
                    finish()
                }
                targetTimelinePtsUs < config.trackStartUs -> {
                    val targetMs = (config.sourceTrimStartUs / 1000L)
                        .coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
                    try {
                        mp.setOnSeekCompleteListener {
                            currentTimelinePtsUs = targetTimelinePtsUs
                            Log.i(TAG, "$LOG_PREFIX seek_completed resume=$resumeAfterSeek region=before_start trackId=${config.trackId} targetTimelinePtsUs=$targetTimelinePtsUs")
                            if (resumeAfterSeek) {
                                play()
                            }
                            finish()
                        }
                        mp.seekTo(targetMs.toInt())
                    } catch (t: Throwable) {
                        Log.w(TAG, "$LOG_PREFIX seek_error trackId=${config.trackId}", t)
                        disableLocked(mp, "seek_error")
                        finish()
                    }
                }
                else -> {
                    val targetSourceUs = config.sourceTrimStartUs + (targetTimelinePtsUs - config.trackStartUs)
                    val targetMs = (targetSourceUs / 1000L).coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
                    try {
                        mp.setOnSeekCompleteListener {
                            currentTimelinePtsUs = targetTimelinePtsUs
                            if (resumeAfterSeek) {
                                playing = true
                                playBaselineUptimeMs = SystemClock.uptimeMillis()
                                startMediaAtCurrentPtsLocked(mp, seekFirst = false)
                            }
                            Log.i(TAG, "$LOG_PREFIX seek_completed resume=$resumeAfterSeek region=inside_window trackId=${config.trackId} targetTimelinePtsUs=$targetTimelinePtsUs")
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
            audioHandler.removeCallbacks(startRunnable)
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
        val remainingUs = (trackEndUs - currentTimelinePtsUs).coerceAtLeast(0L)
        audioHandler.postDelayed(endRunnable, remainingUs / 1000L)
    }

    private fun onTrackEndReachedLocked() {
        val mp = player
        try {
            if (mp != null && mp.isPlaying) mp.pause()
        } catch (t: Throwable) {
            Log.w(TAG, "$LOG_PREFIX track_end_pause_error trackId=${config.trackId}", t)
        }
        currentTimelinePtsUs = trackEndUs
        playing = false
        mediaStarted = false
        abandonFocusLocked()
        Log.i(TAG, "$LOG_PREFIX track_end_reached trackId=${config.trackId}")
    }

    private fun disableLocked(mp: MediaPlayer, reason: String = "unknown") {
        Log.w(TAG, "$LOG_PREFIX disable reason=$reason trackId=${config.trackId}")
        enabled = false
        playing = false
        mediaStarted = false
        audioHandler.removeCallbacks(startRunnable)
        audioHandler.removeCallbacks(endRunnable)
        abandonFocusLocked()
        if (player === mp) {
            player = null
        }
        try { mp.reset() } catch (_: Throwable) {}
        try { mp.release() } catch (_: Throwable) {}
    }

    private fun teardownPlayerLocked() {
        enabled = false
        playing = false
        mediaStarted = false
        audioHandler.removeCallbacks(startRunnable)
        audioHandler.removeCallbacks(endRunnable)
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
