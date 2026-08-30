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
 * [context] is used only to request/abandon [AudioManager] playback focus as a courtesy to other
 * apps; it is optional because focus is not a precondition for a local-file [MediaPlayer] to
 * actually produce sound. When null, focus management is skipped and playback proceeds
 * unaffected.
 */
class AndroidEditorOriginalAudioPreviewRuntime(
    private val context: Context?,
) {
    companion object {
        private const val TAG = "EditorOrigAudioPreview"
    }

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
                onDone()
                return@post
            }
            teardownPlayerLocked()

            val file = File(sourcePath)
            if (!file.exists() || !file.canRead()) {
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
                    Log.w(TAG, "prepare: MediaPlayer error what=$what extra=$extra for $sourcePath")
                    disableLocked(mp)
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
                    val targetMs = (initialSourcePtsUs / 1000L)
                        .coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
                    if (targetMs > 0L) {
                        mp.setOnSeekCompleteListener { finish() }
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
                mp.setDataSource(sourcePath)
                mp.prepareAsync()
            } catch (t: Throwable) {
                Log.w(TAG, "prepare: MediaPlayer setup failed for $sourcePath", t)
                try { mp.release() } catch (_: Throwable) {}
                finish()
            }
        }
    }

    // ── play / pause ───────────────────────────────────────────────────────

    /** Requests audio focus (best-effort) and starts playback if enabled. No-op otherwise. */
    fun play() {
        audioHandler.post {
            if (released.get() || !enabled) return@post
            val mp = player ?: return@post
            requestFocusLocked()
            try {
                mp.start()
            } catch (t: Throwable) {
                Log.w(TAG, "play: MediaPlayer.start failed", t)
                disableLocked(mp)
            }
        }
    }

    /** Pauses playback (if playing) and abandons audio focus. No-op if disabled/released. */
    fun pause() {
        audioHandler.post {
            abandonFocusLocked()
            if (released.get() || !enabled) return@post
            val mp = player ?: return@post
            try {
                if (mp.isPlaying) mp.pause()
            } catch (t: Throwable) {
                Log.w(TAG, "pause: MediaPlayer.pause failed", t)
            }
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
                onDone()
                return@post
            }

            val doneOnce = AtomicBoolean(false)
            fun finish() {
                if (doneOnce.compareAndSet(false, true)) onDone()
            }

            val targetMs = (sourcePtsUs / 1000L)
                .coerceIn(0L, mp.duration.toLong().coerceAtLeast(0L))
            try {
                mp.setOnSeekCompleteListener {
                    if (resumeAfterSeek) {
                        requestFocusLocked()
                        try {
                            mp.start()
                        } catch (t: Throwable) {
                            Log.w(TAG, "seek: MediaPlayer.start after seek failed", t)
                            disableLocked(mp)
                        }
                    }
                    finish()
                }
                mp.seekTo(targetMs.toInt())
            } catch (t: Throwable) {
                Log.w(TAG, "seek: MediaPlayer.seekTo failed", t)
                disableLocked(mp)
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
            abandonFocusLocked()
            teardownPlayerLocked()
            onDone?.invoke()
            try { audioThread.quitSafely() } catch (_: Throwable) {}
        }
    }

    // ── internal helpers (confined to audioHandler) ─────────────────────────

    private fun disableLocked(mp: MediaPlayer) {
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
        if (hasFocus) return
        val ctx = context ?: return
        try {
            val am = audioManager ?: (ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.also {
                audioManager = it
            }
            if (am == null) return
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .build()
            focusRequest = request
            hasFocus = am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } catch (t: Throwable) {
            Log.w(TAG, "requestFocusLocked: failed", t)
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
