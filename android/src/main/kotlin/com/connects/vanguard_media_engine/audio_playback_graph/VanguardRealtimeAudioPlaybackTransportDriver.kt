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
// already been cancelled and joined. No seek and no focus/routing response
// exists on this route (validated at session start).
//
// Bounded pause/resume (Y22, P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-
// SESSION-PAUSE-RESUME), additive and opt-in per driver: a driver that
// reports [supportsPauseResume] = true admits exactly ONE session pause/
// resume cycle through four bounded, command-lock-holder-thread primitives
// the session sequences in this fixed order around its own sink park/unpark
// -- [prepareForPause] (quiesce the driver's own feed at a clean boundary
// WHILE the sink still drains; the session parks the sink only after this
// returns true) -> sink park + ack -> [pause] -> ... -> [confirmHold]
// (mandatory proof the driven transport stayed frozen across the hold;
// the session never resumes after a failed proof) -> [resume] -> sink
// unpark. Every primitive is false on timeout, rejection, or failure; the
// session fails closed on any false and tears down through the existing
// [cancel] / [close] wake-up paths. The defaults below (unsupported, all
// false) keep every existing driver's behavior unchanged.
//
// Bounded forward seek (Y23, P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-
// SESSION-SEEK), additive and opt-in per driver: a driver that reports
// [supportsSeek] = true admits exactly ONE forward seek per run through two
// bounded, command-lock-holder-thread primitives the session sequences
// around its own sink seek park / flush / unpark -- [prepareForSeek]
// (arm the driver's own feed cap at the window-aligned hold frame H WHILE
// the sink still drains, returning once the feed is held exactly there at
// a clean boundary) -> session waits for exact drain-to-H equality on BOTH
// its sink and [framesConsumedBySinkObserved] -> sink seek park + ack ->
// sink flush + ack -> [seek] (the driven transport jumps to T; called only
// after the sink flush acked) -> sink unpark. The session admits H/T at
// start against [earliestSeekHoldFrame] (a conservative frame no earlier
// than the driver's own pre-start fill / feed lead). Every primitive is
// false on timeout, rejection, or failure; the session fails closed on any
// false, never unparks the sink after a failed prepare / flush / seek, and
// tears down through [cancel] / [close]. The defaults below (unsupported,
// -1, all false) keep every existing driver's behavior unchanged.
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

    // ── Y22 bounded pause/resume (additive defaults; class comment) ─────────

    // True only for a driver that implements the four primitives below; the
    // session rejects (typed, no mutation) a pause/resume against a driver
    // that reports false.
    val supportsPauseResume: Boolean get() = false

    // Holds the driver's own feed at its next clean boundary while the sink
    // keeps draining; must precede the session's sink park. False on
    // timeout/rejection/failure (a withdrawn timeout may leave the feed held).
    fun prepareForPause(timeoutMs: Long): Boolean = false

    // Pauses the driven transport; called only after [prepareForPause]
    // returned true and the sink has acked its park. False on timeout/rejection/failure.
    fun pause(timeoutMs: Long): Boolean = false

    // Proves the driven transport stayed frozen during the hold; called
    // before [resume], which must not run if this returns false.
    fun confirmHold(timeoutMs: Long): Boolean = false

    // Resumes the driven transport and releases its feed; called before the
    // session unparks the sink. False on timeout/rejection/failure.
    fun resume(timeoutMs: Long): Boolean = false

    // ── Y23 bounded forward seek (additive defaults; class comment) ─────────

    // True only for a driver that implements the primitives below; the
    // session fails a driver-route run closed (typed, before the driver is
    // opened) when a seek is armed against a driver that reports false.
    val supportsSeek: Boolean get() = false

    // Cumulative frames the production sink has consumed from this driver's
    // frame source, as observed on the driver side; -1 when unsupported /
    // not yet observable. The session requires this to equal its own sink's
    // read count at exactly the hold frame before it parks the sink.
    val framesConsumedBySinkObserved: Long get() = -1L

    // Conservative window-aligned lower bound (exclusive) for a seek hold
    // frame: no earlier than every frame the driver commits before / ahead
    // of the sink's first consumption, so a hold frame strictly past it can
    // still be reached by [prepareForSeek] rather than already passed.
    // Valid once [open] has returned true; -1 when unsupported.
    val earliestSeekHoldFrame: Long get() = -1L

    // Arms the driver's own feed cap at the window-aligned [holdFrame] while
    // the sink keeps draining and returns true once the feed is held exactly
    // there at a clean boundary (drains still serviced). Must precede the
    // session's sink seek park. False on timeout/rejection/failure (hold
    // frame invalid or already passed, timeline complete).
    fun prepareForSeek(holdFrame: Long, timeoutMs: Long): Boolean = false

    // Executes the ONE forward seek of the driven transport to the window-
    // aligned [targetFrame]; called only after [prepareForSeek] returned
    // true, the sink drained exactly to the hold frame, seek-parked and
    // acked its flush. Releases the driver's feed on success. False on
    // timeout/rejection/failure; the session never unparks the sink then.
    fun seek(targetFrame: Long, timeoutMs: Long): Boolean = false
}
