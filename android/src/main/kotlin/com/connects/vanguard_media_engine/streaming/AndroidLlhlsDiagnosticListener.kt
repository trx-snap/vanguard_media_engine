// Copyright (c) Connects - Android LL-HLS diagnostic instrumentation: read-only Media3 observer.
// One AnalyticsListener per ExoPlayer, attached only by debuggable builds of experimental sessions.
// Every event is one bounded JSON line under the AndroidLlhlsDiag tag.  The observer reads player
// state and clocks; it never changes playback, calls the session, or owns any lifecycle.

package com.connects.vanguard_media_engine.streaming

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.SystemClock
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

/**
 * Read-only diagnostic [AnalyticsListener] for one ExoPlayer graph.
 *
 * ## Ownership
 * - The player's own AnalyticsCollector owns this observer; there is no registry, cleanup API,
 *   thread, handler, timer, file, network or lock.  Graph retirement releases the player, which
 *   delivers [onPlayerReleased]; the observer then marks itself terminal and drops later callbacks.
 * - Every record carries the immutable [epoch] and a player identity, so events of a retired player
 *   cannot be mistaken for events of the current one.
 *
 * ## Contract
 * - Attaches and emits only when the host app is debuggable ([ApplicationInfo.FLAG_DEBUGGABLE]);
 *   the [Context] is used for that check alone and is never retained.
 * - Never calls session / listener / control APIs, never alters or cancels playback, never sets
 *   clocks.  Every entry point is non-throwing.
 * - Callbacks run on the player's application looper, so reading the player is thread-correct.
 *   The released player is never read.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class AndroidLlhlsDiagnosticListener private constructor(
    private val player: ExoPlayer,
    private val epoch: Long,
) : AnalyticsListener {

    companion object {
        /** Registers one observer on [player] when the host app is debuggable. */
        fun attach(context: Context, player: ExoPlayer, epoch: Long) {
            try {
                if (!isDebuggable(context)) return
                player.addAnalyticsListener(AndroidLlhlsDiagnosticListener(player, epoch))
                emitDiag("observer_attached", epoch, playerIdOf(player), null, null)
            } catch (t: Throwable) {
                // Diagnostics never affect playback.
            }
        }

        /** Emits one event with a read-only snapshot of [player]; [fields] hold bounded scalars. */
        fun record(
            context: Context,
            player: ExoPlayer,
            epoch: Long,
            event: String,
            fields: Map<String, Any?> = emptyMap(),
        ) {
            try {
                if (!isDebuggable(context)) return
                emitDiag(event, epoch, playerIdOf(player), null, player) { f ->
                    for ((key, value) in fields) f.put(key, value)
                }
            } catch (t: Throwable) {
                // Diagnostics never affect playback.
            }
        }

        private fun isDebuggable(context: Context): Boolean = try {
            (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        } catch (t: Throwable) {
            false
        }
    }

    private val playerId: String = playerIdOf(player)

    /** Set by [onPlayerReleased]; later callbacks are dropped. */
    @Volatile
    private var terminal = false

    // Last values reported through callbacks, so the release record never reads a released player.
    private var lastPlaybackState: Int? = null
    private var lastPlayWhenReady: Boolean? = null
    private var lastIsPlaying: Boolean? = null
    private var lastIsLoading: Boolean? = null
    private var lastSpeed: Float? = null
    private var lastLoadSnapshotMs = DIAG_NEVER

    private var loadsStarted = 0
    private var loadsCompleted = 0
    private var loadsCanceled = 0
    private var loadErrors = 0
    private var playerErrors = 0
    private var speedChanges = 0
    private var audioUnderruns = 0
    private var droppedFramesTotal = 0L

    private inline fun live(block: () -> Unit) {
        if (!terminal) block()
    }

    private fun emit(
        eventTime: EventTime?,
        event: String,
        withSnapshot: Boolean,
        fill: (DiagFields) -> Unit = {},
    ) = emitDiag(event, epoch, playerId, eventTime, if (withSnapshot) player else null, fill)

    // --- State -------------------------------------------------------------------------------

    override fun onPlaybackStateChanged(eventTime: EventTime, state: Int) = live {
        lastPlaybackState = state
        emit(eventTime, "state_changed", true) { f ->
            f.put("state", state)
            f.put("stateName", stateName(state))
        }
    }

    override fun onPlayWhenReadyChanged(eventTime: EventTime, playWhenReady: Boolean, reason: Int) = live {
        lastPlayWhenReady = playWhenReady
        emit(eventTime, "play_when_ready_changed", true) { f ->
            f.put("playWhenReady", playWhenReady)
            f.put("reason", reason)
        }
    }

    override fun onIsPlayingChanged(eventTime: EventTime, isPlaying: Boolean) = live {
        lastIsPlaying = isPlaying
        emit(eventTime, "is_playing_changed", true) { f -> f.put("isPlaying", isPlaying) }
    }

    override fun onIsLoadingChanged(eventTime: EventTime, isLoading: Boolean) = live {
        lastIsLoading = isLoading
        emit(eventTime, "is_loading_changed", true) { f -> f.put("isLoading", isLoading) }
    }

    override fun onPlaybackParametersChanged(eventTime: EventTime, playbackParameters: PlaybackParameters) = live {
        speedChanges++
        lastSpeed = playbackParameters.speed
        emit(eventTime, "speed_changed", true) { f ->
            f.put("speed", playbackParameters.speed)
            f.put("pitch", playbackParameters.pitch)
        }
    }

    override fun onRenderedFirstFrame(eventTime: EventTime, output: Any, renderTimeMs: Long) = live {
        emit(eventTime, "first_frame", true) { f ->
            f.put("renderTimeMs", renderTimeMs)
            f.put("outputClass", classNameOf(output))
        }
    }

    override fun onPositionDiscontinuity(
        eventTime: EventTime,
        oldPosition: Player.PositionInfo,
        newPosition: Player.PositionInfo,
        reason: Int,
    ) = live {
        emit(eventTime, "position_discontinuity", true) { f ->
            f.put("reason", reason)
            f.put("reasonName", discontinuityName(reason))
            f.time("oldPositionMs", oldPosition.positionMs)
            f.time("oldContentPositionMs", oldPosition.contentPositionMs)
            f.time("newPositionMs", newPosition.positionMs)
            f.time("newContentPositionMs", newPosition.contentPositionMs)
        }
    }

    // --- Errors and media-path signals -------------------------------------------------------

    override fun onPlayerError(eventTime: EventTime, error: PlaybackException) = live {
        playerErrors++
        emit(eventTime, "player_error", true) { f ->
            f.put("errorCode", error.errorCode)
            f.put("errorCodeName", error.errorCodeName)
            f.put("causeClass", error.cause?.let { classNameOf(it) })
            responseCodeOf(error)?.let { f.put("responseCode", it) }
        }
    }

    override fun onAudioUnderrun(
        eventTime: EventTime,
        bufferSize: Int,
        bufferSizeMs: Long,
        elapsedSinceLastFeedMs: Long,
    ) = live {
        audioUnderruns++
        emit(eventTime, "audio_underrun", false) { f ->
            f.put("bufferSize", bufferSize)
            f.time("bufferSizeMs", bufferSizeMs)
            f.time("elapsedSinceLastFeedMs", elapsedSinceLastFeedMs)
        }
    }

    override fun onDroppedVideoFrames(eventTime: EventTime, droppedFrames: Int, elapsedMs: Long) = live {
        droppedFramesTotal += droppedFrames
        emit(eventTime, "dropped_frames", false) { f ->
            f.put("droppedFrames", droppedFrames)
            f.put("elapsedMs", elapsedMs)
            f.put("droppedFramesTotal", droppedFramesTotal)
        }
    }

    // --- Loads (compact timing records; a full player snapshot at most once per second) ------

    override fun onLoadStarted(eventTime: EventTime, loadEventInfo: LoadEventInfo, mediaLoadData: MediaLoadData) = live {
        loadsStarted++
        emit(eventTime, "load_started", false) { f -> f.putLoad(loadEventInfo, mediaLoadData) }
    }

    override fun onLoadCompleted(eventTime: EventTime, loadEventInfo: LoadEventInfo, mediaLoadData: MediaLoadData) = live {
        loadsCompleted++
        val now = SystemClock.elapsedRealtime()
        val withSnapshot = lastLoadSnapshotMs == DIAG_NEVER || now - lastLoadSnapshotMs >= DIAG_LOAD_SNAPSHOT_INTERVAL_MS
        if (withSnapshot) lastLoadSnapshotMs = now
        emit(eventTime, "load_completed", withSnapshot) { f -> f.putLoad(loadEventInfo, mediaLoadData) }
    }

    override fun onLoadCanceled(eventTime: EventTime, loadEventInfo: LoadEventInfo, mediaLoadData: MediaLoadData) = live {
        loadsCanceled++
        emit(eventTime, "load_canceled", false) { f -> f.putLoad(loadEventInfo, mediaLoadData) }
    }

    override fun onLoadError(
        eventTime: EventTime,
        loadEventInfo: LoadEventInfo,
        mediaLoadData: MediaLoadData,
        error: IOException,
        wasCanceled: Boolean,
    ) = live {
        loadErrors++
        emit(eventTime, "load_error", true) { f ->
            f.putLoad(loadEventInfo, mediaLoadData)
            f.put("wasCanceled", wasCanceled)
            f.put("exceptionClass", classNameOf(error))
            responseCodeOf(error)?.let { f.put("responseCode", it) }
        }
    }

    // --- Terminal ----------------------------------------------------------------------------

    /** Logs the last callback-reported state and totals, then drops every later callback. */
    override fun onPlayerReleased(eventTime: EventTime) {
        if (terminal) return
        emit(eventTime, "player_released", false) { f ->
            f.cached("lastPlaybackState", lastPlaybackState)
            f.cached("lastPlayWhenReady", lastPlayWhenReady)
            f.cached("lastIsPlaying", lastIsPlaying)
            f.cached("lastIsLoading", lastIsLoading)
            f.cached("lastSpeed", lastSpeed)
            f.put("loadsStarted", loadsStarted)
            f.put("loadsCompleted", loadsCompleted)
            f.put("loadsCanceled", loadsCanceled)
            f.put("loadErrors", loadErrors)
            f.put("playerErrors", playerErrors)
            f.put("speedChanges", speedChanges)
            f.put("audioUnderruns", audioUnderruns)
            f.put("droppedFramesTotal", droppedFramesTotal)
        }
        terminal = true
    }
}

// --- Serialization (file-private; shared by the observer and the companion entry points) ------

private const val DIAG_TAG = "AndroidLlhlsDiag"
private const val DIAG_PREFIX = "hls_diag "
private const val DIAG_SCHEMA_VERSION = 1
private const val DIAG_MAX_LINE_BYTES = 3000
private const val DIAG_MAX_STRING_CHARS = 96
private const val DIAG_MAX_PATH_CHARS = 200
private const val DIAG_LOAD_SNAPSHOT_INTERVAL_MS = 1000L
private const val DIAG_NEVER = Long.MIN_VALUE

private val DIAG_HEADER_KEYS = arrayOf(
    "schemaVersion", "event", "pid", "epoch", "playerId", "seq",
    "callbackElapsedRealtimeMs", "callbackNanoTime", "wallClockMs", "eventRealtimeMs",
)

/** Process-wide, strictly increasing record sequence. */
private val diagSeq = AtomicLong(0L)

/** Bounded-scalar JSON builder.  Unavailable, unset and non-finite values become null with a reason. */
private class DiagFields {
    val json = JSONObject()
    private val reasons = JSONObject()

    fun put(key: String, value: Any?, maxChars: Int = DIAG_MAX_STRING_CHARS) {
        when (value) {
            null -> nul(key, "unavailable")
            is Boolean, is Int, is Long -> json.put(key, value)
            is Float -> if (value.isFinite()) json.put(key, value.toString().toDouble()) else nul(key, "nonfinite")
            is Double -> if (value.isFinite()) json.put(key, value) else nul(key, "nonfinite")
            is String -> json.put(key, value.take(maxChars))
            else -> json.put(key, value.toString().take(maxChars))
        }
    }

    /** A time in milliseconds; [C.TIME_UNSET] is null with a reason. */
    fun time(key: String, ms: Long) {
        if (ms == C.TIME_UNSET) nul(key, "time_unset") else json.put(key, ms)
    }

    fun unsetInt(key: String, value: Int) {
        if (value == Format.NO_VALUE) nul(key, "unset") else json.put(key, value)
    }

    fun cached(key: String, value: Any?) {
        if (value == null) nul(key, "never_reported") else put(key, value)
    }

    fun nul(key: String, reason: String) {
        json.put(key, JSONObject.NULL)
        reasons.put(key, reason)
    }

    /** Runs a player getter; a getter failure becomes null with a reason and never escapes. */
    fun read(key: String, isTime: Boolean = false, block: () -> Any?) {
        try {
            val value = block()
            if (isTime && value is Long) time(key, value) else put(key, value)
        } catch (t: Throwable) {
            nul(key, "getter_failed:" + t.javaClass.simpleName)
        }
    }

    fun finish(): JSONObject {
        if (reasons.length() > 0) json.put("nullReasons", reasons)
        return json
    }
}

private fun playerIdOf(player: Any): String = Integer.toHexString(System.identityHashCode(player))

private fun classNameOf(value: Any): String = value.javaClass.simpleName.ifEmpty { value.javaClass.name }

/** [HttpDataSource.InvalidResponseCodeException.responseCode] from [error] or a near cause. */
private fun responseCodeOf(error: Throwable?): Int? {
    var current = error
    var depth = 0
    while (current != null && depth < 4) {
        if (current is HttpDataSource.InvalidResponseCodeException) return current.responseCode
        current = current.cause
        depth++
    }
    return null
}

private fun stateName(state: Int): String = when (state) {
    Player.STATE_IDLE -> "idle"
    Player.STATE_BUFFERING -> "buffering"
    Player.STATE_READY -> "ready"
    Player.STATE_ENDED -> "ended"
    else -> "unknown_$state"
}

private fun discontinuityName(reason: Int): String = when (reason) {
    Player.DISCONTINUITY_REASON_AUTO_TRANSITION -> "auto_transition"
    Player.DISCONTINUITY_REASON_SEEK -> "seek"
    Player.DISCONTINUITY_REASON_SEEK_ADJUSTMENT -> "seek_adjustment"
    Player.DISCONTINUITY_REASON_SKIP -> "skip"
    Player.DISCONTINUITY_REASON_REMOVE -> "remove"
    Player.DISCONTINUITY_REASON_INTERNAL -> "internal"
    else -> "unknown_$reason"
}

/** Compact load timing: URI path only (no query, userinfo or headers), capped. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private fun DiagFields.putLoad(info: LoadEventInfo, data: MediaLoadData) {
    put("loadTaskId", info.loadTaskId)
    put("dataType", data.dataType)
    put("trackType", data.trackType)
    time("mediaStartTimeMs", data.mediaStartTimeMs)
    time("mediaEndTimeMs", data.mediaEndTimeMs)
    val format = data.trackFormat
    if (format == null) {
        nul("formatId", "no_track_format")
    } else {
        put("formatId", format.id)
        unsetInt("formatBitrate", format.bitrate)
        unsetInt("formatWidth", format.width)
        unsetInt("formatHeight", format.height)
    }
    put("loadDurationMs", info.loadDurationMs)
    put("bytesLoaded", info.bytesLoaded)
    put("loadElapsedRealtimeMs", info.elapsedRealtimeMs)
    put("uriPath", info.uri.encodedPath, DIAG_MAX_PATH_CHARS)
}

/** Current read-only player state.  Only called on the player's application looper. */
private fun playerSnapshot(player: ExoPlayer): JSONObject {
    val f = DiagFields()
    f.read("playbackState") { player.playbackState }
    f.read("playWhenReady") { player.playWhenReady }
    f.read("isPlaying") { player.isPlaying }
    f.read("isLoading") { player.isLoading }
    f.read("currentPositionMs", isTime = true) { player.currentPosition }
    f.read("currentLiveOffsetMs", isTime = true) { player.currentLiveOffset }
    f.read("totalBufferedDurationMs", isTime = true) { player.totalBufferedDuration }
    f.read("speed") { player.playbackParameters.speed }
    f.read("pitch") { player.playbackParameters.pitch }
    return f.finish()
}

/**
 * Builds and logs one record.  Never throws.  [fill] adds event fields; a [fill] failure keeps the
 * header and snapshot and marks the record instead of dropping it.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private fun emitDiag(
    event: String,
    epoch: Long,
    playerId: String,
    eventTime: EventTime?,
    snapshotPlayer: ExoPlayer?,
    fill: (DiagFields) -> Unit = {},
) {
    try {
        val f = DiagFields()
        f.put("schemaVersion", DIAG_SCHEMA_VERSION)
        f.put("event", event)
        f.put("pid", android.os.Process.myPid())
        f.put("epoch", epoch)
        f.put("playerId", playerId)
        f.put("seq", diagSeq.incrementAndGet())
        f.put("callbackElapsedRealtimeMs", SystemClock.elapsedRealtime())
        f.put("callbackNanoTime", System.nanoTime())
        f.put("wallClockMs", System.currentTimeMillis())
        if (eventTime != null) {
            f.put("eventRealtimeMs", eventTime.realtimeMs)
            f.time("eventPlaybackPositionMs", eventTime.eventPlaybackPositionMs)
            f.time("currentPlaybackPositionMs", eventTime.currentPlaybackPositionMs)
            f.time("totalBufferedDurationMs", eventTime.totalBufferedDurationMs)
        }
        try {
            fill(f)
        } catch (t: Throwable) {
            f.put("fieldsFailed", classNameOf(t))
        }
        if (snapshotPlayer != null) f.json.put("player", playerSnapshot(snapshotPlayer))
        writeDiag(f.finish())
    } catch (t: Throwable) {
        // A logging failure is dropped; diagnostics never affect playback.
    }
}

/** Logs [json] as one line; a line of [DIAG_MAX_LINE_BYTES] or more is cut down to its header. */
private fun writeDiag(json: JSONObject) {
    var line = DIAG_PREFIX + json.toString()
    val bytes = line.toByteArray(Charsets.UTF_8).size
    if (bytes >= DIAG_MAX_LINE_BYTES) {
        val bounded = JSONObject()
        for (key in DIAG_HEADER_KEYS) json.opt(key)?.let { bounded.put(key, it) }
        bounded.put("truncated", true)
        bounded.put("originalBytes", bytes)
        line = DIAG_PREFIX + bounded.toString()
    }
    Log.i(DIAG_TAG, line)
}
