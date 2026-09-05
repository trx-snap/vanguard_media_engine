package com.connects.vanguard_media_engine.audio_playback_graph

// ── VanguardRealtimeAudioPlaybackTransportDriver (P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-SESSION-INTEGRATION, Y21) ─
//
// Default-OFF alternative route selector for [VanguardRealtimeAudioPlaybackSession]:
// when [VanguardRealtimeAudioPlaybackSession.Config.driverFactory] is non-null, the
// session drives one playback run through exactly ONE instance of this
// interface instead of its default route (decoder feed +
// [VanguardRealtimePlaybackTransportStateMachine]). This interface exposes
// only primitives and the existing [VanguardRealtimeAudioPlaybackFrameSource]
// production seam -- no ring type, no geometry type, no diagnostics type and
// no ring-specific API name, so this package never imports or names a
// diagnostics class. A diagnostics-owned adapter (the Y18c real-decoder ring
// frame source, wrapped for this seam) supplies the real behavior; neither
// this interface nor [VanguardRealtimeAudioPlaybackSession] knows anything
// about that implementation.
//
// Session-side contract (mirrors the default route's own class-comment
// ordering): [open] then [start] must both be called from the session's
// command-lock holder thread, with the production sink constructed from
// this driver's geometry and [frameSource] in between -- sink READY must be
// observed before [start], and the sink's allowDrain() must happen only
// after [start] returns true. [cancel] is any-thread and non-blocking (a
// wake-up only, mirroring the sink/decoder feed's own `cancel()`); [close]
// is bounded and idempotent, called once at teardown after the sink has
// already been cancelled and joined. No seek, no pause/resume, no focus/
// routing response exists on this route (validated at session start).
interface VanguardRealtimeAudioPlaybackTransportDriver {

    // Caller-supplied construction context (Opus architecture requirement):
    // built by the session AFTER its own deadline is computed, then handed
    // to [VanguardRealtimeAudioPlaybackSession.Config.driverFactory] to
    // create the ONE driver instance for this session's run.
    data class Context(
        val deadlineAtMs: Long,
        val maxFramesPerMix: Int,
        val externallyCancelled: () -> Boolean,
    )

    companion object {
        // A driver that exited after [cancel] reports exactly this reason
        // (mirrors the sink/decoder-feed EXIT_CANCELLED constants) so a
        // deliberate stop is never mistaken for a real failure.
        const val REASON_CANCELLED = "cancelled"
    }

    // Geometry primitives; valid once [open] has returned true.
    val sampleRate: Int
    val channelCount: Int
    val maxFramesPerMix: Int
    val declaredFrameCount: Long

    // The ONE frame source the session hands to
    // [VanguardRealtimeAudioPlaybackSinkBridge.Config.frameSource]
    // (`stateMachine` stays null on this route); valid once [open] has
    // returned true.
    val frameSource: VanguardRealtimeAudioPlaybackFrameSource

    // False once this driver has fully exited (failed or cleanly closed);
    // polled the same way the session already polls the decoder feed / sink
    // for an unexpected exit.
    val isAlive: Boolean

    // Empty while no failure has been recorded; the typed root-cause reason otherwise.
    val exitReason: String

    // Lower-case label for a stall/failure reason, analogous to
    // [VanguardRealtimeAudioPlaybackFrameSource.currentStateLabel].
    val currentStageLabel: String

    // True once this driver's own content stream reached its terminal end
    // (EOS or later) with no failure recorded; consulted alongside the
    // sink's own EOS exit to gate session completion on this route.
    val isEosTerminal: Boolean

    // Opens/prepares the driver and freezes its geometry. False on timeout or failure.
    fun open(timeoutMs: Long): Boolean

    // Starts the driven transport; must only be called after the sink is READY. False on timeout or failure.
    fun start(timeoutMs: Long): Boolean

    // Any thread, non-blocking: asks the driver to stop without waiting.
    fun cancel()

    // Stops and releases the driver; bounded. False on timeout, failure, or
    // when called from the driver's own owner thread.
    fun close(timeoutMs: Long): Boolean
}
