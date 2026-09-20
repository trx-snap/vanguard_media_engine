package com.connects.vanguard_media_engine.editor

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.connects.vanguard_media_engine.util.AndroidUriDataSourceHelper
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Phase 7.8I-Android: editor-preview original embedded audio runtime.
 *
 * Plays back exactly one plain local video clip's own embedded audio track, mirrored alongside
 * that clip's [com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackControlSession]
 * video decode/render, using a single [MediaPlayer] confined to its own dedicated
 * [HandlerThread]/[Handler] (`audioHandler`). Every MediaPlayer call and listener callback runs
 * on that one thread, and nothing posted there ever blocks waiting on another thread — a
 * MediaPlayer callback can never deadlock against the caller's own orchestration thread.
 *
 * Preview-only: original-clip audio for plain sequential local video timelines. Never touches
 * export, audio-sidecar mixing, SFX, transitions, or any other audio lane.
 *
 * One instance backs exactly one active clip; [AndroidEditorSequentialPlaybackSession] creates a
 * fresh instance per clip activation (mirroring how it creates a fresh
 * [com.connects.vanguard_media_engine.codec.AndroidDagTexturePlaybackControlSession] per
 * activation) and calls [release] on the outgoing instance before the replacement touches
 * anything.
 *
 * Failure handling: any MediaPlayer setup/prepare/seek/start error disables this instance
 * (internal `enabled = false`) and every subsequent call becomes a silent no-op / immediately
 * completing op — a clip with corrupt/unsupported audio, or no audio track at all, never blocks
 * or fails the accompanying video preview.
 *
 * [context] is used to request/abandon [AudioManager] playback focus as a courtesy to other
 * apps, and (reference-import Slice 3A) to open a `content://` source through its
 * ContentResolver. It is optional because focus is not a precondition for a local-file
 * [MediaPlayer] to actually produce sound. When null, focus management is skipped, POSIX-path
 * playback proceeds unaffected, and a `content://` source is treated as unreadable (audio
 * skipped non-fatally, video activation untouched).
 *
 * [gain] is the native original-audio preview policy gain (the derived role="original"
 * sidecar track's `volume * mixGain`, see [AndroidEditorPlaybackCoordinator]) applied as the
 * [MediaPlayer] left/right volume once the player is prepared, so a reduced originalMixGain is
 * audible in preview. Defaults to unity; clamped to [0.0, 1.0]; a non-finite value falls back
 * to unity. A muted clip (gain <= 0) is expected to never construct a runtime at all (see
 * [AndroidEditorSequentialPlaybackSession.activateClipBlocking]); if one is constructed anyway,
 * the clamped 0.0 volume keeps it silent as a defensive no-op.
 */
class AndroidEditorOriginalAudioPreviewRuntime(
    private val context: Context?,
    gain: Float = 1.0f,
) {
    companion object {
        private const val TAG = "EditorOrigAudioPreview"
        private const val LOG_PREFIX = "VG_EDITOR_AUDIO_PREVIEW"
    }

    /** Clamped preview volume applied to the [MediaPlayer] on prepare (see [gain] doc above). */
    private val volumeGain: Float = if (gain.isFinite()) gain.coerceIn(0.0f, 1.0f) else 1.0f

    private val audioThread = HandlerThread("EditorOrigAudioPreview").also { it.start() }
    private val audioHandler = Handler(audioThread.looper)

    private val released = AtomicBoolean(false)

    // ── audioHandler-confined state (all MediaPlayer/AudioManager calls happen there) ────────
    private var player: MediaPlayer? = null
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false

    /** True once a usable, playable [MediaPlayer] exists for the active clip. */
    private var enabled = false

    // ── prepare ────────────────────────────────────────────────────────────

    /**
     * Prepares audio for [sourcePath], preroll-seeked to [initialSourcePtsUs] (source-local
     * microseconds — the same PTS space as the accompanying video decoder) before [onDone]
     * fires. [onDone] always fires exactly once, posted on [audioHandler]; a missing, corrupt,
     * or unsupported-audio source disables this instance and still calls [onDone] normally so a
     * caller's blocking activation sequence (audio prepared, then video prepared/seeked) never
     * stalls on a bad audio track.
     */
    fun prepare(sourcePath: String, initialSourcePtsUs: Long, onDone: () -> Unit) {
        audioHandler.post {
            if (released.get()) {
                Log.i(TAG, "$LOG_PREFIX prepare_skip_released")
                onDone()
                return@post
            }
            teardownPlayerLocked()

            // Slice 3A: POSIX paths keep the File.exists()/canRead() preflight; content://
            // URIs are probed through the ContentResolver and return false (no throw, no
            // hang) when unreadable or when context is null. Either way audio is skipped
            // non-fatally and onDone still fires so video activation never stalls.
            if (!AndroidUriDataSourceHelper.isReadable(sourcePath, context)) {
                Log.w(
                    TAG,
                    "$LOG_PREFIX prepare_missing_file contentUri=${AndroidUriDataSourceHelper.isContentUri(sourcePath)} " +
                        "hasContext=${context != null}",
                )
                onDone()
                return@post
            }

            val doneOnce = AtomicBoolean(false)
            fun finish() {
                if (doneOnce.compareAndSet(false, true)) onDone()
            }

            val mp = MediaPlayer()
            Log.i(TAG, "$LOG_PREFIX prepare_start file=${sourcePath.substringAfterLast('/')} initialSourcePtsUs=$initialSourcePtsUs gain=$volumeGain")
            try {
                mp.setOnErrorListener { _, what, extra ->
                    Log.w(TAG, "$LOG_PREFIX prepare_error_listener what=$what extra=$extra")
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
                    // Apply the native original-audio policy gain before any seek/start so the
                    // first audible sample already honors it. A setVolume failure is logged but
                    // never disables the runtime: the video preview and the audio itself stay
                    // alive at whatever volume the player retained.
                    try {
                        mp.setVolume(volumeGain, volumeGain)
                    } catch (t: Throwable) {
                        Log.w(TAG, "$LOG_PREFIX prepared_set_volume_error gain=$volumeGain", t)
                    }
                    val targetMs = (initialSourcePtsUs / 1000L)
                        .coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
                    Log.i(TAG, "$LOG_PREFIX prepared durationMs=${mp.duration} targetMs=$targetMs gain=$volumeGain enabled=$enabled")
                    if (targetMs > 0L) {
                        mp.setOnSeekCompleteListener {
                            Log.i(TAG, "$LOG_PREFIX prepare_seek_complete targetMs=$targetMs")
                            finish()
                        }
                        Log.i(TAG, "$LOG_PREFIX prepare_seek_start targetMs=$targetMs")
                        try {
                            mp.seekTo(targetMs.toInt())
                        } catch (t: Throwable) {
                            Log.w(TAG, "prepare: seekTo failed for $sourcePath", t)
                            finish()
                        }
                    } else {
                        finish()
                    }
                }
                AndroidUriDataSourceHelper.setMediaPlayerDataSource(mp, sourcePath, context)
                mp.prepareAsync()
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX prepare_setup_error", t)
                try { mp.release() } catch (_: Throwable) {}
                finish()
            }
        }
    }

    // ── play / pause ───────────────────────────────────────────────────────

    /** Requests audio focus (best-effort) and starts playback if enabled. No-op otherwise. */
    fun play() {
        audioHandler.post {
            if (released.get() || !enabled) {
                Log.i(TAG, "$LOG_PREFIX play_skip reason=${if (released.get()) "released" else "disabled"}")
                return@post
            }
            val mp = player
            if (mp == null) {
                Log.i(TAG, "$LOG_PREFIX play_skip reason=no_player")
                return@post
            }
            val hasFocusBefore = hasFocus
            requestFocusLocked()
            Log.i(TAG, "$LOG_PREFIX play_start hasFocusBefore=$hasFocusBefore hasFocusAfter=$hasFocus")
            try {
                mp.start()
                Log.i(TAG, "$LOG_PREFIX play_started isPlaying=${mp.isPlaying} currentPositionMs=${mp.currentPosition}")
            } catch (t: Throwable) {
                Log.w(TAG, "$LOG_PREFIX play_start_error", t)
                disableLocked(mp, "play_start_error")
            }
        }
    }

    /** Pauses playback (if playing) and abandons audio focus. No-op if disabled/released. */
    fun pause() {
        audioHandler.post {
            Log.i(TAG, "$LOG_PREFIX pause_start")
            abandonFocusLocked()
            if (released.get() || !enabled) {
                Log.i(TAG, "$LOG_PREFIX pause_done reason=${if (released.get()) "released" else "disabled"}")
                return@post
            }
            val mp = player
            if (mp == null) {
                Log.i(TAG, "$LOG_PREFIX pause_done reason=no_player")
                return@post
            }
            try {
                if (mp.isPlaying) mp.pause()
            } catch (t: Throwable) {
                Log.w(TAG, "pause: MediaPlayer.pause failed", t)
            }
            Log.i(TAG, "$LOG_PREFIX pause_done")
        }
    }

    // ── seek ───────────────────────────────────────────────────────────────

    /**
     * Seeks the active clip's audio to [sourcePtsUs] (source-local microseconds). Resumes
     * playback (requesting focus) only when [resumeAfterSeek] is true. [onDone] always fires
     * exactly once, posted on [audioHandler]; an immediate no-op call when disabled/released.
     */
    fun seek(sourcePtsUs: Long, resumeAfterSeek: Boolean, onDone: () -> Unit) {
        audioHandler.post {
            val mp = player
            if (released.get() || !enabled || mp == null) {
                val reason = when {
                    released.get() -> "released"
                    !enabled -> "disabled"
                    else -> "no_player"
                }
                Log.i(TAG, "$LOG_PREFIX seek_skip reason=$reason")
                onDone()
                return@post
            }

            val doneOnce = AtomicBoolean(false)
            fun finish() {
                if (doneOnce.compareAndSet(false, true)) onDone()
            }

            val targetMs = (sourcePtsUs / 1000L)
                .coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
            Log.i(TAG, "$LOG_PREFIX seek_start targetMs=$targetMs resumeAfterSeek=$resumeAfterSeek")
            try {
                mp.setOnSeekCompleteListener {
                    Log.i(TAG, "$LOG_PREFIX seek_complete targetMs=$targetMs")
                    if (resumeAfterSeek) {
                        requestFocusLocked()
                        try {
                            mp.start()
                            Log.i(TAG, "$LOG_PREFIX seek_resume_started")
                        } catch (t: Throwable) {
                            Log.w(TAG, "$LOG_PREFIX seek_resume_error", t)
                            disableLocked(mp, "seek_resume_error")
                        }
                    }
                    finish()
                }
                mp.seekTo(targetMs.toInt())
            } catch (t: Throwable) {
                Log.w(TAG, "seek: MediaPlayer.seekTo failed", t)
                disableLocked(mp, "seek_error")
                finish()
            }
        }
    }

    // ── release ────────────────────────────────────────────────────────────

    /**
     * Releases the active MediaPlayer (if any), abandons audio focus, and quits [audioThread].
     * Idempotent. [onDone] (if provided) always fires exactly once: immediately on the caller's
     * thread if already released, otherwise posted from [audioHandler] after teardown.
     */
    fun release(onDone: (() -> Unit)? = null) {
        if (!released.compareAndSet(false, true)) {
            onDone?.invoke()
            return
        }
        audioHandler.post {
            Log.i(TAG, "$LOG_PREFIX release_start")
            abandonFocusLocked()
            teardownPlayerLocked()
            Log.i(TAG, "$LOG_PREFIX release_done")
            onDone?.invoke()
            try { audioThread.quitSafely() } catch (_: Throwable) {}
        }
    }

    // ── internal helpers (confined to audioHandler) ─────────────────────────

    private fun disableLocked(mp: MediaPlayer, reason: String = "unknown") {
        Log.w(TAG, "$LOG_PREFIX disable reason=$reason")
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
            Log.i(TAG, "$LOG_PREFIX focus_result skipped reason=already_has_focus")
            return
        }
        val ctx = context
        if (ctx == null) {
            Log.i(TAG, "$LOG_PREFIX focus_result skipped reason=no_context")
            return
        }
        try {
            val am = audioManager ?: (ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.also {
                audioManager = it
            }
            if (am == null) {
                Log.i(TAG, "$LOG_PREFIX focus_result skipped reason=no_audio_manager")
                return
            }
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .build()
            focusRequest = request
            hasFocus = am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            Log.i(TAG, "$LOG_PREFIX focus_result ${if (hasFocus) "granted" else "not_granted"}")
        } catch (t: Throwable) {
            Log.w(TAG, "$LOG_PREFIX focus_result error", t)
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
                Log.w(TAG, "abandonFocusLocked: failed", t)
            }
        }
    }
}
