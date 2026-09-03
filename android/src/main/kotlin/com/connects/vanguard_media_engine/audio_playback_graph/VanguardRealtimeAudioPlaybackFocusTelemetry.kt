package com.connects.vanguard_media_engine.audio_playback_graph

// ── VanguardRealtimeAudioPlaybackFocusTelemetry (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-FOCUS-RESPONSE, Y11b) ─
//
// Any-thread immutable view of the production audio-focus / becoming-noisy
// response owned by [VanguardRealtimeAudioPlaybackSession], published
// through [VanguardRealtimeAudioPlaybackSession.Snapshot.focus]. Defaults
// (all false/zero/empty) mean "focus response disabled" or "not yet
// reached" for a field the session hasn't set. Pure data: no lifecycle
// decision lives here; only primitive/string fields so it stays usable from
// a diagnostics evaluator without depending on the controller's own types.
data class VanguardRealtimeAudioPlaybackFocusTelemetry(
    val enabled: Boolean,
    // ── VanguardRealtimePlaybackAudioFocusController registration ──
    val controllerRequested: Boolean,
    val controllerGranted: Boolean,
    val controllerRequestResult: Int,
    val controllerRequestError: String,
    val controllerNoisyRegistered: Boolean,
    val controllerRegisterError: String,
    val controllerReleased: Boolean,
    // ── Session-owned focus monitor thread (the controller's only consumer) ──
    val monitorStarted: Boolean,
    val monitorExited: Boolean,
    val monitorJoined: Boolean,
    val monitorThreadId: Long,
    // ── Controller event queue counters (read live from the controller) ──
    val eventsEnqueued: Long,
    val eventsDrained: Long,
    val eventsDropped: Long,
    val eventsPending: Int,
    // ── Per-action applied counts (focus monitor thread writes) ──
    val duckAppliedCount: Long,
    val gainRestoreAppliedCount: Long,
    val pauseTransientAppliedCount: Long,
    val pausePermanentAppliedCount: Long,
    val pauseNoisyAppliedCount: Long,
    val pauseDroppedParkAppliedCount: Long,
    val autoResumeAppliedCount: Long,
    val unknownEventCount: Long,
    // ── Sink gain round-trip (requestGain / awaitGainApplied only) ──
    val gainRequestCount: Long,
    val gainAppliedCount: Long,
    val gainFailCount: Long,
    // ── Current state ──
    val focusState: String,
    val userIntentPlaying: Boolean,
    val focusPausedByPolicy: Boolean,
    val terminalPermanentLoss: Boolean,
    val terminalNoisyLoss: Boolean,
    // ── Last observed event / reaction ──
    val lastEventTag: String,
    val lastEventSeq: Long,
    val lastEventSource: String,
    val lastAction: String,
    val lastReason: String,
)
