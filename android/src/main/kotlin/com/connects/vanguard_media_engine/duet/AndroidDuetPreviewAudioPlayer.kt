package com.connects.vanguard_media_engine.duet

// -----------------------------------------------------------------------------
// ANDROID-DUET-SLICE-1A: Source-video audio preview during a live Duet take.
// -----------------------------------------------------------------------------
//
// Plays the source clip's own audio track (android.media.MediaPlayer) while a
// take is being recorded, positioned at the Duet preview clock's source cursor
// and rate-matched to the clock's speed policy through PlaybackParams. The
// player output goes to the device audio path only; it is never fed to the
// take recorder (zero software loopback — the microphone lane records what the
// mic hears, nothing more).
//
// Contract (main thread only; the coordinator owns the instance):
//   - prepare()  : async MediaPlayer preparation; play/seek requests issued
//                  before readiness are queued and applied on prepared.
//   - play(positionMs, speed, gain): seek + start at speed; gain <= MUTE_EPSILON
//                  mutes (player keeps running so the clock/preview stay in
//                  lock-step and un-muting is instant).
//   - pause()/seekTo()/setVolume()/release(): idempotent, never throw.
//   - Speed changes apply on the next play() (mid-take rate changes are not a
//     Duet clock feature: the clock captures the speed at segment start).
//
// Non-claim: playback position follows MediaPlayer's own seek/speed accuracy;
// the preview clock (not this player) remains the source-cursor authority.

import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.PlaybackParams
import android.os.Build
import android.os.Handler
import android.util.Log

class AndroidDuetPreviewAudioPlayer(
    private val sourcePath: String,
    @Suppress("unused") private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "DuetPreviewAudio"
        private const val MUTE_EPSILON = 0.0001
    }

    private var player: MediaPlayer? = null
    private var prepared = false
    private var released = false
    private var playing = false

    /** Requests parked until [prepared]. */
    private var pendingPlay = false
    private var pendingSeekMs = -1

    private var speed = 1.0
    private var gain = 1.0

    /** Non-null once preparation failed; every later call is a logged no-op. */
    var failureReason: String? = null
        private set

    val isPrepared: Boolean get() = prepared

    /** Starts asynchronous preparation; the player is primed at [initialPositionMs] once ready. */
    fun prepare(initialPositionMs: Int = 0) {
        if (released || player != null || failureReason != null) return
        pendingSeekMs = maxOf(0, initialPositionMs)
        val mp = MediaPlayer()
        try {
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            mp.setDataSource(sourcePath)
            mp.isLooping = false
            mp.setOnPreparedListener { onPrepared(it) }
            mp.setOnErrorListener { p, what, extra ->
                Log.w(TAG, "ANDROID_DUET_PREVIEW_AUDIO_ERROR what=$what extra=$extra prepared=$prepared")
                if (!prepared && p === player) {
                    failureReason = "media_player_error_${what}_$extra"
                    releaseQuietly()
                }
                true
            }
            mp.setOnCompletionListener { playing = false }
            player = mp
            mp.prepareAsync()
        } catch (t: Throwable) {
            failureReason = "prepare_failed:${t.javaClass.simpleName}"
            Log.w(TAG, "ANDROID_DUET_PREVIEW_AUDIO_UNAVAILABLE reason=$failureReason ${t.message}")
            try { mp.release() } catch (_: Throwable) {}
            player = null
        }
    }

    private fun onPrepared(mp: MediaPlayer) {
        if (released || mp !== player) return
        prepared = true
        applyVolume()
        Log.i(TAG, "ANDROID_DUET_PREVIEW_AUDIO_READY durationMs=${try { mp.duration } catch (_: Throwable) { -1 }} " +
            "pendingPlay=$pendingPlay pendingSeekMs=$pendingSeekMs")
        if (pendingPlay) {
            pendingPlay = false
            startInternal(pendingSeekMs)
        } else if (pendingSeekMs >= 0) {
            seekInternal(pendingSeekMs)
        }
        pendingSeekMs = -1
    }

    /** Seeks to [sourcePositionMs] and starts playback at [speed] with [gain]; parks until prepared. */
    fun play(sourcePositionMs: Int, speed: Double, gain: Double) {
        if (released || failureReason != null) return
        this.speed = if (speed.isFinite() && speed > 0.0) speed else 1.0
        this.gain = gain
        if (!prepared) {
            pendingPlay = true
            pendingSeekMs = maxOf(0, sourcePositionMs)
            return
        }
        applyVolume()
        startInternal(maxOf(0, sourcePositionMs))
    }

    private fun startInternal(positionMs: Int) {
        val mp = player ?: return
        try {
            seekInternal(positionMs)
            // On a prepared/paused MediaPlayer, setting PlaybackParams with a
            // non-zero speed is the documented equivalent of start() at that
            // speed; a rejected speed falls back to plain start() at 1.0x.
            try {
                mp.playbackParams = PlaybackParams().setSpeed(speed.toFloat())
            } catch (t: Throwable) {
                Log.w(TAG, "ANDROID_DUET_PREVIEW_AUDIO_SPEED_UNSUPPORTED speed=$speed ${t.javaClass.simpleName}: ${t.message}")
                mp.start()
            }
            if (!mp.isPlaying) mp.start()
            playing = true
        } catch (t: Throwable) {
            Log.w(TAG, "play failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    fun pause() {
        if (released) return
        pendingPlay = false
        if (!prepared) return
        val mp = player ?: return
        try {
            if (mp.isPlaying) mp.pause()
        } catch (t: Throwable) {
            Log.w(TAG, "pause failed: ${t.message}")
        }
        playing = false
    }

    fun seekTo(sourcePositionMs: Int) {
        if (released || failureReason != null) return
        if (!prepared) {
            pendingSeekMs = maxOf(0, sourcePositionMs)
            return
        }
        seekInternal(maxOf(0, sourcePositionMs))
    }

    private fun seekInternal(positionMs: Int) {
        val mp = player ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                mp.seekTo(positionMs.toLong(), MediaPlayer.SEEK_CLOSEST)
            } else {
                mp.seekTo(positionMs)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "seekTo($positionMs) failed: ${t.message}")
        }
    }

    /** Applies [gain] (0..1) immediately when prepared; values below [MUTE_EPSILON] mute. */
    fun setVolume(gain: Double) {
        this.gain = gain
        if (released || !prepared) return
        applyVolume()
    }

    private fun applyVolume() {
        val mp = player ?: return
        val v = if (!gain.isFinite() || gain < MUTE_EPSILON) 0f else gain.coerceIn(0.0, 1.0).toFloat()
        try { mp.setVolume(v, v) } catch (t: Throwable) { Log.w(TAG, "setVolume failed: ${t.message}") }
    }

    /** Terminal, idempotent. */
    fun release() {
        if (released) return
        released = true
        pendingPlay = false
        playing = false
        releaseQuietly()
    }

    private fun releaseQuietly() {
        val mp = player ?: return
        player = null
        prepared = false
        try { mp.setOnPreparedListener(null) } catch (_: Throwable) {}
        try { mp.setOnErrorListener(null) } catch (_: Throwable) {}
        try { mp.setOnCompletionListener(null) } catch (_: Throwable) {}
        try { if (mp.isPlaying) mp.stop() } catch (_: Throwable) {}
        try { mp.reset() } catch (_: Throwable) {}
        try { mp.release() } catch (_: Throwable) {}
    }
}
