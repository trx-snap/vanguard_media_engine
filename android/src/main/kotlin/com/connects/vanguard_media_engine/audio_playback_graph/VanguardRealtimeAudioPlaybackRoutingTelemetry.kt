package com.connects.vanguard_media_engine.audio_playback_graph

// ── VanguardRealtimeAudioPlaybackRoutingTelemetry (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-ROUTE-CHANGE, Y12) ─
//
// Any-thread immutable view of the production route-change / disconnect
// response owned by [VanguardRealtimeAudioPlaybackSession], published
// through [VanguardRealtimeAudioPlaybackSession.Snapshot.routing]. Defaults
// (all false/zero/empty) mean "routing response disabled" or "not yet
// reached" for a field the session hasn't set. Pure data: no lifecycle
// decision lives here; only primitive/string fields so it stays usable from
// a diagnostics evaluator without depending on the controller's own types.
data class VanguardRealtimeAudioPlaybackRoutingTelemetry(
    val enabled: Boolean,
    // ── VanguardRealtimePlaybackRoutingController attach/detach lifecycle
    // (owned by VanguardRealtimeAudioPlaybackSinkBridge) ──
    val controllerAttached: Boolean,
    val controllerReleased: Boolean,
    val attachCount: Int,
    val detachCount: Int,
    val lastAttachError: String,
    val lastDetachError: String,
    // ── Session-owned routing monitor thread (the controller's only consumer) ──
    val monitorStarted: Boolean,
    val monitorExited: Boolean,
    val monitorJoined: Boolean,
    val monitorThreadId: Long,
    // ── Controller event queue counters (read live from the controller) ──
    val eventsEnqueued: Long,
    val eventsDrained: Long,
    val eventsDropped: Long,
    val eventsPending: Int,
    // ── Per-action applied counts (routing monitor thread writes) ──
    val routeChangedAppliedCount: Long,
    val routeDisconnectAppliedCount: Long,
    // ── Current state ──
    val routingTerminalDisconnect: Boolean,
    val routingPausedByPolicy: Boolean,
    // ── Last observed event / reaction ──
    val lastEventTag: String,
    val lastEventSeq: Long,
    val lastEventSource: String,
    val lastAction: String,
    val lastReason: String,
)
