package com.connects.vanguard_media_engine.audio_playback

import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

// ── AndroidAudioPlaybackCoordinator (Phase 5-Unit Y / Phase 4-Unit G) ─────────
//
// Owns the seven `audioPlayback_*` MethodChannel routes, mirroring
// VGAudioPlaybackService.m (iOS): a single active android.media.MediaPlayer
// backs standalone local-file audio playback.
//
//   - load() tears down any prior player, then creates and prepares a new one
//     asynchronously (prepareAsync) so file probing never blocks the UI thread.
//   - A monotonically increasing generation counter is bound to each player at
//     creation time; onPrepared/onError/onSeekComplete/onCompletion callbacks
//     compare their captured generation against the current one and drop stale
//     callbacks from a superseded/released player.
//   - Every MethodChannel.Result is wrapped by [GuardedReply]: an AtomicBoolean
//     compareAndSet ensures at most one reply per call, posted through
//     [mainHandler], and every posted runnable checks [detached] first so no
//     channel call happens after the plugin has detached.
class AndroidAudioPlaybackCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "AudioPlaybackCoordinator"

        private val OWNED_METHODS = setOf(
            "audioPlayback_load",
            "audioPlayback_play",
            "audioPlayback_pause",
            "audioPlayback_stop",
            "audioPlayback_seekTo",
            "audioPlayback_setVolume",
            "audioPlayback_getPosition",
        )

        fun ownsMethod(method: String): Boolean = method in OWNED_METHODS
    }

    /** AtomicBoolean-guarded, detach-aware [MethodChannel.Result] wrapper. */
    private inner class GuardedReply(private val result: MethodChannel.Result) {
        private val fired = AtomicBoolean(false)

        fun success(map: Map<String, Any?>?) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.success(map)
                }
            }
        }

        fun error(code: String, message: String?) {
            if (fired.compareAndSet(false, true)) {
                mainHandler.post {
                    if (detached) return@post
                    result.error(code, message, null)
                }
            }
        }
    }

    private enum class PlaybackState { PREPARING, PREPARED, PLAYING, PAUSED, COMPLETED, FAILED }

    @Volatile private var detached = false

    private var player: MediaPlayer? = null
    private var state: PlaybackState? = null
    private var generation = 0

    private var pendingLoadReply: GuardedReply? = null
    private var pendingSeekReply: GuardedReply? = null

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        when (method) {
            "audioPlayback_load" -> handleLoad(args, result)
            "audioPlayback_play" -> handlePlay(result)
            "audioPlayback_pause" -> handlePause(result)
            "audioPlayback_stop" -> handleStop(result)
            "audioPlayback_seekTo" -> handleSeekTo(args, result)
            "audioPlayback_setVolume" -> handleSetVolume(args, result)
            "audioPlayback_getPosition" -> handleGetPosition(result)
        }
    }

    // ── audioPlayback_load ───────────────────────────────────────────────────

    private fun handleLoad(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val path = (args?.get("path") as? String)?.takeIf { it.isNotEmpty() }
        if (path == null) {
            reply.error("INVALID_ARG", "path is required and must be non-empty")
            return
        }

        val file = File(path)
        if (!file.exists() || !file.canRead()) {
            reply.error("LOAD_FAILED", "File not found or unreadable: $path")
            return
        }

        // Complete any pending seek and supersede any pending load, then release
        // the prior player now that the path is confirmed readable — before the
        // background audio-track probe starts — so a readable no-audio load
        // failure leaves no active player, matching iOS.
        completePendingSeek()
        failPendingLoad("LOAD_FAILED", "superseded by new load")
        releasePlayer()

        val myGeneration = ++generation
        pendingLoadReply = reply
        state = PlaybackState.PREPARING

        // The MediaMetadataRetriever audio-track probe touches the filesystem and
        // must not run on the platform thread; run it on a one-off daemon thread
        // and drop the result if [myGeneration] has since been superseded.
        Thread {
            val retriever = MediaMetadataRetriever()
            var hasAudioTrack = false
            var probeErrorMessage: String? = null
            try {
                retriever.setDataSource(path)
                hasAudioTrack = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            } catch (e: Exception) {
                probeErrorMessage = e.message ?: e.javaClass.simpleName
            } finally {
                try { retriever.release() } catch (_: Exception) {}
            }

            mainHandler.post {
                if (detached || myGeneration != generation) return@post
                if (probeErrorMessage != null || !hasAudioTrack) {
                    val failureMessage = probeErrorMessage ?: "File contains no audio track: $path"
                    Log.e(TAG, "handleLoad: audio-track probe failed: $failureMessage")
                    val loadReply = pendingLoadReply
                    pendingLoadReply = null
                    state = null
                    loadReply?.error("LOAD_FAILED", failureMessage)
                    return@post
                }
                startPreparingPlayer(myGeneration, path)
            }
        }.apply { isDaemon = true }.start()
    }

    /** Runs on the main thread after a successful audio-track probe for [myGeneration]. */
    private fun startPreparingPlayer(myGeneration: Int, path: String) {
        val mp = MediaPlayer()
        player = mp

        mp.setOnPreparedListener {
            if (myGeneration != generation) return@setOnPreparedListener
            state = PlaybackState.PREPARED
            val durationMs = mp.duration
            val durationSeconds = (if (durationMs > 0) durationMs.toDouble() else 0.0) / 1000.0
            val loadReply = pendingLoadReply
            pendingLoadReply = null
            loadReply?.success(mapOf("durationSeconds" to durationSeconds))
        }
        mp.setOnErrorListener { _, what, extra ->
            if (myGeneration != generation) return@setOnErrorListener true
            val loadReply = pendingLoadReply
            pendingLoadReply = null
            if (player === mp) {
                player = null
            }
            state = PlaybackState.FAILED
            try { mp.reset() } catch (_: Exception) {}
            try { mp.release() } catch (_: Exception) {}
            loadReply?.error("LOAD_FAILED", "MediaPlayer error: what=$what extra=$extra")
            true
        }
        mp.setOnSeekCompleteListener {
            if (myGeneration != generation) return@setOnSeekCompleteListener
            val seekReply = pendingSeekReply
            pendingSeekReply = null
            seekReply?.success(null)
        }
        mp.setOnCompletionListener {
            if (myGeneration != generation) return@setOnCompletionListener
            state = PlaybackState.COMPLETED
        }

        try {
            mp.setDataSource(path)
            mp.prepareAsync()
        } catch (e: Exception) {
            Log.e(TAG, "handleLoad: setDataSource/prepareAsync failed: $e")
            val loadReply = pendingLoadReply
            pendingLoadReply = null
            state = PlaybackState.FAILED
            generation++
            player = null
            try { mp.release() } catch (_: Exception) {}
            loadReply?.error("LOAD_FAILED", e.message ?: e.javaClass.simpleName)
        }
    }

    // ── audioPlayback_play ───────────────────────────────────────────────────

    private fun handlePlay(result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val mp = player
        val current = state
        if (mp != null && (current == PlaybackState.PREPARED ||
                current == PlaybackState.PAUSED ||
                current == PlaybackState.COMPLETED)) {
            try {
                mp.start()
                state = PlaybackState.PLAYING
            } catch (e: Exception) {
                Log.e(TAG, "handlePlay: $e")
            }
        }
        reply.success(null)
    }

    // ── audioPlayback_pause ──────────────────────────────────────────────────

    private fun handlePause(result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val mp = player
        if (mp != null && state == PlaybackState.PLAYING) {
            try {
                mp.pause()
                state = PlaybackState.PAUSED
            } catch (e: Exception) {
                Log.e(TAG, "handlePause: $e")
            }
        }
        reply.success(null)
    }

    // ── audioPlayback_stop ───────────────────────────────────────────────────

    private fun handleStop(result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        completePendingSeek()
        failPendingLoad("LOAD_FAILED", "cancelled by stop")
        releasePlayer()
        reply.success(null)
    }

    // ── audioPlayback_seekTo ─────────────────────────────────────────────────

    private fun handleSeekTo(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val seconds = (args?.get("seconds") as? Number)?.toDouble()
        if (seconds == null || !seconds.isFinite() || seconds < 0.0) {
            reply.error("INVALID_ARG", "seconds is required and must be finite and >= 0")
            return
        }

        val mp = player
        if (mp == null || state == null || state == PlaybackState.PREPARING ||
            state == PlaybackState.FAILED) {
            reply.success(null)
            return
        }

        // Complete any prior pending seek before starting a new one so no reply
        // is ever left hanging.
        completePendingSeek()

        val ms = (seconds * 1000.0).let { if (it > Int.MAX_VALUE.toDouble()) Int.MAX_VALUE else it.toInt() }
        pendingSeekReply = reply
        try {
            mp.seekTo(ms)
        } catch (e: Exception) {
            Log.e(TAG, "handleSeekTo: $e")
            val seekReply = pendingSeekReply
            pendingSeekReply = null
            seekReply?.success(null)
        }
    }

    // ── audioPlayback_setVolume ──────────────────────────────────────────────

    private fun handleSetVolume(args: Map<*, *>?, result: MethodChannel.Result) {
        val reply = GuardedReply(result)

        val volume = (args?.get("volume") as? Number)?.toDouble()
        if (volume == null || !volume.isFinite()) {
            reply.error("INVALID_ARG", "volume is required and must be a finite number")
            return
        }

        val clamped = volume.coerceIn(0.0, 1.0).toFloat()
        val mp = player
        if (mp != null) {
            try {
                mp.setVolume(clamped, clamped)
            } catch (e: Exception) {
                Log.e(TAG, "handleSetVolume: $e")
            }
        }
        reply.success(null)
    }

    // ── audioPlayback_getPosition ────────────────────────────────────────────

    private fun handleGetPosition(result: MethodChannel.Result) {
        val reply = GuardedReply(result)
        val mp = player
        val seconds = if (mp == null || state == null || state == PlaybackState.PREPARING ||
            state == PlaybackState.FAILED) {
            0.0
        } else {
            try {
                mp.currentPosition.toDouble() / 1000.0
            } catch (e: IllegalStateException) {
                0.0
            }
        }
        reply.success(mapOf("seconds" to seconds))
    }

    // ── Shared teardown helpers ──────────────────────────────────────────────

    /** Completes a pending seek with success(null) so it is never left hanging. */
    private fun completePendingSeek() {
        val seekReply = pendingSeekReply
        pendingSeekReply = null
        seekReply?.success(null)
    }

    /** Completes a pending load with an error so it is never left hanging. */
    private fun failPendingLoad(code: String, message: String) {
        val loadReply = pendingLoadReply
        pendingLoadReply = null
        loadReply?.error(code, message)
    }

    private fun releasePlayer() {
        val mp = player
        player = null
        state = null
        generation++
        if (mp != null) {
            try { mp.reset() } catch (_: Exception) {}
            try { mp.release() } catch (_: Exception) {}
        }
    }

    // ── Disposal ─────────────────────────────────────────────────────────────

    /** Idempotently detaches, releases the active player, and clears pending replies. */
    fun disposeAll() {
        detached = true
        pendingLoadReply = null
        pendingSeekReply = null
        val mp = player
        player = null
        state = null
        generation++
        if (mp != null) {
            try { mp.reset() } catch (_: Exception) {}
            try { mp.release() } catch (_: Exception) {}
        }
    }
}
