package com.connects.vanguard_media_engine.audio_playback_graph

import android.content.Context
import android.os.Handler
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackAudioFocusController.Tag as FocusTag
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController.Tag as RoutingTag
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State as TransportState
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// ── VanguardRealtimeAudioPlaybackSession (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SINK-CLOCK, Y8a) ─
//
// Production engine owner of one realtime audio playback:
//   MediaExtractor/MediaCodec ([VanguardRealtimePlaybackDecoderFeed], decode
//   thread) -> Y5a external ingest -> Y1 native transport (owner
//   HandlerThread inside [VanguardRealtimePlaybackTransportStateMachine]) ->
//   [VanguardRealtimeAudioPlaybackSinkBridge] (sink thread: AudioTrack +
//   presentation clock).
// Ownership: the decoder feed thread only posts generation-pinned ingest;
// the transport HandlerThread only owns the native session; the sink thread
// only owns the AudioTrack and the clock writes; THIS session (caller's
// thread, serialized by one lock) is the only transport command issuer. No
// MethodChannel, product, editor or app code lives here.
//
// Lifecycle: IDLE -start-> STARTING -> PLAYING <-> PAUSED (bounded) ->
// COMPLETED (sink drained EOS) / STOPPED (stop) / FAILED (first failure
// wins) -> DISPOSED (idempotent). Start: format probe, load, prepare, attach
// feed, pre-roll while PREPARED, sink READY before transport start,
// transport start, then sink drain allowed. Bounded pause: sink park -> ack
// (AudioTrack paused, clock epoch closed at the last published position) ->
// transport.pause; resume: transport.resume -> sink unpark -> ack (same
// instance, new clock epoch). A hold longer than [Config.maxPauseHoldMs]
// fails closed inside the sink (AudioTrack released, decoder cancelled via
// [onSinkExited]), below the decoder feed's own ingest stall budget.
// Stop/dispose: sink cancel, decoder cancel, bounded joins, transport stop
// (only after both threads exited), terminal snapshot, transport dispose
// exactly once. Dead object (Y8b): only the sink's ONE armed synthetic
// ERROR_DEAD_OBJECT ([Config.syntheticDeadObjectInjectAfterFrames] > 0,
// default off) is recovered, inside the sink thread's write loop; a real
// or second dead object exits the sink non-EOS and fails closed here.
//
// Seek (Y9, P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-SEEK), default OFF: with
// [Config.seekTargetSec] > 0, start admits ONE forward seek (C10: preRoll <
// H < T < declared - 2 windows, H = first window boundary at least
// [Config.preSeekHoldWindows] windows past the pre-roll) and pins H on the
// feed before the transport starts. [seek] runs PLAYING -> SEEKING ->
// PLAYING under the command lock in this fixed order (one *Locked step
// each): initial writes -> quiescence at H (feed held, sink read H,
// transport PLAYING, sink RUNNING) -> sink seek park -> pre-seek native
// snapshot (sink PARKED, transport PLAYING, position == pushed == drained
// == H, discarded 0, output ring empty) -> transport.pause + PAUSED
// recheck -> AudioTrack.flush once on the sink thread (read budget H +
// declared - T) -> transport.seek(T) (stays PAUSED, generation + 1, cursor
// T, nothing discarded) -> feed re-anchor on the decode thread with the
// deliberate stale-generation probe rejected before JNI -> post-seek
// pre-roll while still PAUSED (pushed unchanged at H) -> sink unpark
// (AudioTrack.play, clock epoch+1 based at T) -> transport.resume. Any
// rejection, timeout, exited thread, cancel or accounting divergence fails
// closed through the common teardown; cancel/dispose mid-seek use the
// existing bounded-wait wake-ups; a second seek is rejected without teardown.
// The seek bookkeeping is published as [VanguardRealtimeAudioPlaybackSeekObservation].
//
// Repeated seek (Y10b-1a, P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-REPEATED-
// SEEK), default OFF, additive: with [Config.secondSeekTargetSec] also > 0,
// start admits a SECOND ordered forward seek T2 alongside T1 (H1 < T1 < H2 <
// T2 < declared - 2 windows, H2 = a post-seek epoch window boundary: T1 +
// preSeekHoldWindows windows, relative to T1 rather than the absolute frame
// grid). [seek] then accepts exactly the
// current ordered target: T1 first (index 0), T2 second (index 1); a third
// call is rejected the same way a second one is in the Y9-only case, without
// teardown or mutation. Each seek runs the identical fixed order above, once
// per call, distinguishing two frame domains that coincide for the first
// seek and diverge for the second: content hold frames (H1/H2) are the
// decoder/native POSITION domain (jump to each seek's target); sink hold
// frames are the CUMULATIVE sink domain (keep counting forward through a
// seek's position jump instead of resetting to it) -- for the second seek,
// sinkHold = H1 + (H2 - T1), so the expected final sink frame count after
// both seeks is H1 + (H2 - T1) + (declared - T2). Every per-seek sink/feed
// command (park, flush, transport.seek, reanchor, unpark, post-seek
// pre-roll) is counted cumulatively across the whole session and awaited by
// its 1-based serial ordinal, so the second seek proves its OWN paused
// pre-roll rather than inheriting the first seek's already-accumulated
// frames. See [VanguardRealtimeAudioPlaybackSeekSequencer] for the per-step
// domain bookkeeping.
//
// Backward seek (Y17, P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-BACKWARD-SEEK),
// default OFF, additive: with [Config.seekBackward] the ONE armed seek is a
// backward seek whose target T = seekTargetSec (0.0 = frame 0 is valid) is
// admitted at start against the SAME hold frame H (first window boundary at
// least preSeekHoldWindows windows past the pre-roll) with four independent
// checks: preRoll < H, H window-aligned, H < declared - 2 windows, and
// 0 <= T <= H - 2 windows. It is incompatible with the second seek (no
// repeated/composed backward seek). [seek] then runs the identical fixed
// order above through the same sequencer, declaring the direction to the
// sink (flush request; its unpark opens the seek epoch through the
// presentation clock's declared-backward entry point, the only sanctioned
// published-position decrease) and to the feed (re-anchor request;
// 0 <= T < H validated, bounded pre-target discard). Transport/native
// commands are direction-agnostic and untouched; whole-run sink frames are
// H + (declared - T) and completion still reports the declared position.
//
// Production focus/noisy response (Y11b, P4-AUDIO-REALTIME-PLAYBACK-
// PRODUCTION-FOCUS-RESPONSE), default OFF ([Config.enableAudioFocusResponse]):
// this session owns exactly one [VanguardRealtimePlaybackAudioFocusController]
// and exactly one focus monitor thread that is its only event consumer
// (Opus Option B). Start requests AUDIOFOCUS_GAIN and registers the
// becoming-noisy receiver before the sink exists; the monitor itself only
// starts once the sink is READY, before the transport starts (class comment
// order), so it can never observe a gain/duck event with no sink yet to
// apply it to; any setup failure fails closed pre-audible and releases the
// controller. The monitor never holds commandLock while blocked on the
// controller's queue; it acquires commandLock only to run a transport
// command through the SAME bounded pause/resume sequence as the public API
// (the [pauseBoundedLocked] / [resumeLocked] helpers), so there is exactly
// one transport-command path.
// User intent ([userIntentPlaying], set by [start]/[resume]/[pauseBounded])
// and focus-induced pause ([focusPausedByPolicy]) are tracked separately: a
// duck (FOCUS_LOSS_TRANSIENT_CAN_DUCK) only requests/awaits a bounded sink
// gain change; a transient loss/drop pauses and marks focusPausedByPolicy;
// a focus gain restores volume and, only when userIntentPlaying and
// focusPausedByPolicy are both true, the state is PAUSED and neither
// terminal-loss flag is set, resumes through the bounded resume order.
// Permanent loss and becoming-noisy pause once (when PLAYING) and set a
// terminal flag that blocks any later auto-resume; a user pause always
// clears userIntentPlaying regardless of focus state. Teardown signals the
// monitor to stop, releases commandLock while joining it bounded (never
// while holding it, and never self-joins when torn down from the monitor's
// own thread), then releases the controller, before the existing sink/
// decoder/transport teardown. [postSyntheticFocusChange] /
// [postSyntheticBecomingNoisy] are a diagnostic seam onto the same
// controller queue; both are false when focus response is disabled. All of
// this is published through [Snapshot.focus] as
// [VanguardRealtimeAudioPlaybackFocusTelemetry].
//
// Production route-change/disconnect response (Y12, P4-AUDIO-REALTIME-
// PLAYBACK-PRODUCTION-ROUTE-CHANGE), default OFF
// ([Config.enableAudioRoutingResponse]): this session owns exactly one
// [VanguardRealtimePlaybackRoutingController] and exactly one routing
// monitor thread that is its only event consumer, mirroring the Y11b focus
// monitor (Opus Option B) rather than introducing a second consumer
// pattern. The controller is created before the sink exists (so
// [VanguardRealtimeAudioPlaybackSinkBridge.Config.routingController] can
// receive the SAME instance) and the monitor itself only starts once the
// sink is READY, before the transport starts (class comment order): the
// sink owns ONLY the AudioTrack listener attach/detach lifecycle (attach
// after the AudioTrack is initialized and gain applied; detach/release
// before its own final AudioTrack release; detach-then-reattach across a
// Y8b dead-object replacement before play/remainder resume) and never
// consumes a routing event itself.
// ROUTE_CHANGED is observation-only (counted, no transport command).
// ROUTE_DISCONNECT is a terminal fail-closed pause: it sets
// [routingTerminalDisconnect] before anything else, then (only when
// PLAYING) runs the SAME bounded pause order as the public API
// ([pauseBoundedLocked]); once set, the terminal flag is never cleared by
// this session, so both the public [resume] and the Y11b FOCUS_GAIN
// auto-resume path reject/skip a resume with routing_terminal_disconnect
// while it holds. A rise in the controller's droppedCount fails the whole
// session closed (routing_event_dropped) rather than parking, unlike the
// focus monitor's queue-drop handling, because a dropped route event's
// consequence for the current output device is unknown and cannot be
// treated as merely transient. Teardown signals the monitor to stop,
// releases commandLock while joining it bounded (same pattern as the focus
// monitor), then releases the controller; the sink bridge also releases
// the SAME controller before its own final AudioTrack release, so
// whichever runs first performs the actual listener detach (idempotent).
// [postSyntheticRouteChanged] / [postSyntheticRouteDisconnect] are a
// diagnostic seam onto the same controller queue; both are false when
// routing response is disabled. All of this is published through
// [Snapshot.routing] as [VanguardRealtimeAudioPlaybackRoutingTelemetry].
//
// Modularity note: this session file stays a single cohesive class rather
// than being split by lifecycle concern. Y12 is another additive,
// default-OFF lifecycle extension of the existing production session/sink
// model (seek, focus, now routing), grouped with its siblings under
// matching "── Y<n> ... internals ──" sections below; extracting it would
// separate tightly command-lock-coupled state without reducing the actual
// coordination the class performs.
class VanguardRealtimeAudioPlaybackSession(private val config: Config) {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val gain: Float = VanguardRealtimeAudioPlaybackSinkBridge.DEFAULT_GAIN,
        val deadlineMs: Long = 30_000L,
        val maxPauseHoldMs: Long = DEFAULT_MAX_PAUSE_HOLD_MS,
        val threadNamePrefix: String = "VanguardRealtimeAudio",
        // Y8b diagnostic seam, default OFF (0): forwarded to the sink; see
        // [VanguardRealtimeAudioPlaybackSinkBridge.Config].
        val syntheticDeadObjectInjectAfterFrames: Long = 0L,
        // Y9 seek arming, default OFF (0.0): the ONE forward seek target in
        // seconds; must stay below maxDurationSec. Admitted against the
        // probed format at start.
        val seekTargetSec: Double = 0.0,
        // Y10b-1a second seek target in seconds, default OFF (0.0): when
        // > 0.0 (and seekTargetSec is also armed and this is strictly past
        // it), admits a second ordered forward seek T2 alongside T1. Must
        // stay below maxDurationSec; admitted against the probed format at
        // start together with T1 (class comment).
        val secondSeekTargetSec: Double = 0.0,
        // Y17 backward seek, default OFF (false): when true the ONE armed
        // seek is BACKWARD -- seekTargetSec is its target T (0.0 = frame 0
        // is valid, so arming does not key on seekTargetSec > 0.0) and is
        // admitted at start against 0 <= T <= H - 2 windows (class
        // comment). Incompatible with secondSeekTargetSec > 0.0.
        val seekBackward: Boolean = false,
        // Y9: windows fed after the pre-roll before the feed holds at H.
        val preSeekHoldWindows: Int = DEFAULT_PRE_SEEK_HOLD_WINDOWS,
        // Y9: hard cap on the sink's seek park (distinct from the pause cap).
        val maxSeekHoldMs: Long = DEFAULT_MAX_SEEK_HOLD_MS,
        // Y11b production focus/noisy response, default OFF (false): every
        // field below is validated only when this is true (class comment).
        val context: Context? = null,
        val mainHandler: Handler? = null,
        val enableAudioFocusResponse: Boolean = false,
        // Linear gain applied on FOCUS_LOSS_TRANSIENT_CAN_DUCK; must stay in [0.0, gain].
        val duckGain: Float = 0.1f,
        // Bounded slice the focus monitor blocks on the controller's queue per iteration.
        val focusEventPollMs: Long = 10L,
        // Bounded wait for the sink to ack a requestGain seq (duck or restore).
        val focusGainApplyTimeoutMs: Long = 500L,
        // Bounded join of the focus monitor thread at teardown.
        val focusMonitorJoinMs: Long = 1000L,
        // Y12 production route-change/disconnect response, default OFF
        // (false): every field below is validated only when this is true
        // (class comment). Reuses [mainHandler] above (already required by
        // Y11b) as the routing listener's callback Handler.
        val enableAudioRoutingResponse: Boolean = false,
        // Bounded slice the routing monitor blocks on the controller's queue per iteration.
        val routingEventPollMs: Long = 10L,
        // Bounded join of the routing monitor thread at teardown.
        val routingMonitorJoinMs: Long = 1000L,
        // Y21 ring/driver route (P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-
        // SESSION-INTEGRATION), default OFF (absent): the ONE route
        // selector. When non-null, [start] builds exactly one
        // [VanguardRealtimeAudioPlaybackTransportDriver] from this factory
        // (after the session deadline above is computed) and drives
        // playback through it instead of the default decoder-feed/
        // transport-state-machine route; every seek variant, focus
        // response and routing response is validated OFF for this route
        // (class comment). Absent leaves the default route entirely
        // unchanged.
        val driverFactory: ((VanguardRealtimeAudioPlaybackTransportDriver.Context) -> VanguardRealtimeAudioPlaybackTransportDriver)? = null,
    )

    enum class State { IDLE, STARTING, PLAYING, PAUSED, SEEKING, COMPLETED, STOPPED, FAILED, DISPOSED }

    data class CommandResult(val accepted: Boolean, val state: State, val reason: String)

    // Any-thread, immutable view for diagnostics/reporting.
    data class Snapshot(
        val state: State,
        val generation: Long,
        val failureReason: String,
        val cancelled: Boolean,
        val format: VanguardRealtimePlaybackDecoderFeed.Format?,
        val transportState: TransportState?,
        val transportGeneration: Long,
        val transportTransitions: String,
        val transportCompletedCallbacks: Int,
        val transportFailedCallbacks: Int,
        val listenerCallbacksOnOwner: Long,
        val listenerCallbacksOffOwner: Long,
        val commandsIssued: Int,
        val prepareGeneration: Long,
        val startGeneration: Long,
        val pauseGeneration: Long,
        val resumeGeneration: Long,
        val startAccepted: Boolean,
        val pauseAccepted: Boolean,
        val resumeAccepted: Boolean,
        val transportStopAccepted: Boolean,
        val transportStateBeforeDispose: TransportState?,
        val transportStateAfterDispose: TransportState?,
        val transportDisposeCalls: Int,
        val preRollFrames: Long,
        val preRollRingFullObserved: Boolean,
        val preRollStatePrepared: Boolean,
        val sinkReadyBeforeTransportStart: Boolean,
        val drainAllowedAfterTransportStart: Boolean,
        val sinkReadyAtMs: Long,
        val transportStartAtMs: Long,
        val drainAllowedAtMs: Long,
        val pauseRequestedAtMs: Long,
        val pauseAckedAtMs: Long,
        val resumedAtMs: Long,
        val pauseHoldObservedMs: Long,
        val clockAtPauseAck: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        val clockBeforeResume: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        val clockAfterResume: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        val clock: VanguardRealtimePlaybackPresentationClock.Snapshot?,
        val sink: VanguardRealtimeAudioPlaybackSinkTelemetry?,
        val decoderExitReason: String,
        val decoderThreadId: Long,
        val decoderThreadIsTransportOwner: Boolean,
        val decoderAcceptedFrames: Long,
        val decoderPaddedFrames: Long,
        val decoderChecksumHex: String,
        val decoderMediaReleaseCount: Long,
        val decoderMediaReleaseClean: Boolean,
        val decoderIngestCallbacksOnOwner: Long,
        val decoderIngestCallbacksOffOwner: Long,
        val decoderIngestCalls: Long,
        val decoderCancelRequested: Boolean,
        val decoderJoined: Boolean,
        val sinkJoined: Boolean,
        val terminalReply: Reply?,
        val sessionWallMs: Long,
        val seek: VanguardRealtimeAudioPlaybackSeekObservation,
        val focus: VanguardRealtimeAudioPlaybackFocusTelemetry,
        val routing: VanguardRealtimeAudioPlaybackRoutingTelemetry,
        // Y21 ring/driver route (small harness fields, class comment): never
        // populates [format] or any decoder field above.
        val driverEnabled: Boolean = false,
        val driverExitReason: String = "",
        val driverClosed: Boolean = false,
        val driverStageLabel: String = "",
        val driverSampleRate: Int = -1,
        val driverChannelCount: Int = -1,
        val driverMaxFramesPerMix: Int = -1,
        val driverDeclaredFrameCount: Long = -1L,
    )

    companion object {
        const val DEFAULT_MAX_PAUSE_HOLD_MS = VanguardRealtimeAudioPlaybackSinkBridge.DEFAULT_MAX_PAUSE_HOLD_MS
        const val DEFAULT_MAX_SEEK_HOLD_MS = VanguardRealtimeAudioPlaybackSinkBridge.DEFAULT_MAX_SEEK_HOLD_MS
        const val DEFAULT_PRE_SEEK_HOLD_WINDOWS = 64
        const val MAX_PRE_SEEK_HOLD_WINDOWS = 1_024
        const val REASON_OK = "ok"
        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val SINK_READY_TIMEOUT_MS = 5_000L
        private const val PARK_ACK_TIMEOUT_MS = 2_000L
        private const val UNPARK_ACK_TIMEOUT_MS = 2_000L

        private fun alignUp(frame: Long, window: Long): Long = ((frame + window - 1L) / window) * window
    }

    private class FailClosed(val reason: String) : Exception(reason)

    private val commandLock = ReentrantLock()
    private val cancelled = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)
    private val teardownDone = AtomicBoolean(false)
    private val failure = AtomicReference<String?>(null)
    private val completedCount = AtomicInteger(0)
    private val failedCount = AtomicInteger(0)
    private val listenerOnOwner = AtomicLong(0L)
    private val listenerOffOwner = AtomicLong(0L)
    private val transitions = StringBuilder()

    @Volatile private var state = State.IDLE
    @Volatile private var generation = 0L
    @Volatile private var transport: VanguardRealtimePlaybackTransportStateMachine? = null
    @Volatile private var feed: VanguardRealtimePlaybackDecoderFeed? = null
    @Volatile private var sink: VanguardRealtimeAudioPlaybackSinkBridge? = null
    @Volatile private var format: VanguardRealtimePlaybackDecoderFeed.Format? = null
    // Y21: non-null only on the ring/driver route ([Config.driverFactory]);
    // [transport] and [feed] stay null for the whole run on that route.
    @Volatile private var driver: VanguardRealtimeAudioPlaybackTransportDriver? = null
    @Volatile private var deadlineAtMs = Long.MAX_VALUE
    @Volatile private var decoderCancelRequested = false

    // Command-lock-confined bookkeeping (published through snapshot()).
    @Volatile private var commandsIssued = 0
    @Volatile private var prepareGeneration = -1L
    @Volatile private var startGeneration = -1L
    @Volatile private var pauseGeneration = -1L
    @Volatile private var resumeGeneration = -1L
    @Volatile private var startAccepted = false
    @Volatile private var pauseAccepted = false
    @Volatile private var resumeAccepted = false
    @Volatile private var transportStopAccepted = false
    @Volatile private var transportStateBeforeDispose: TransportState? = null
    @Volatile private var transportStateAfterDispose: TransportState? = null
    @Volatile private var transportDisposeCalls = 0
    @Volatile private var preRollFrames = 0L
    @Volatile private var preRollRingFullObserved = false
    @Volatile private var preRollStatePrepared = false
    @Volatile private var sinkReadyAtMs = -1L
    @Volatile private var transportStartAtMs = -1L
    @Volatile private var drainAllowedAtMs = -1L
    @Volatile private var pauseRequestedAtMs = -1L
    @Volatile private var pauseAckedAtMs = -1L
    @Volatile private var resumedAtMs = -1L
    @Volatile private var pauseHoldObservedMs = -1L
    @Volatile private var clockAtPauseAck: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
    @Volatile private var clockBeforeResume: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
    @Volatile private var clockAfterResume: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
    @Volatile private var decoderJoined = false
    @Volatile private var sinkJoined = false
    // Y21: set from [VanguardRealtimeAudioPlaybackTransportDriver.close]'s
    // own return value at teardown; stays false when no driver route ran.
    @Volatile private var driverClosed = false
    @Volatile private var terminalReply: Reply? = null
    @Volatile private var sessionStartedAtMs = -1L
    @Volatile private var sessionWallMs = 0L

    // Y9 seek admission bookkeeping (command-lock holder writes); the step
    // sequence and its own bookkeeping live in [seekSequencer]. Y10b-1a: when
    // [repeatedSeekArmed], a second ordered forward seek (T2, content hold
    // H2) is admitted alongside the first (T1, content hold H1 = the pinned
    // [preSeekHoldFrame]); [seekCount] then runs 0..2 instead of 0..1.
    @Volatile private var seekArmed = false
    @Volatile private var seekTargetFrame = -1L
    @Volatile private var preSeekHoldFrame = -1L
    @Volatile private var seekAdmissionOk = false
    @Volatile private var seekHoldPinned = false
    @Volatile private var seekCount = 0
    @Volatile private var repeatedSeekArmed = false
    @Volatile private var secondSeekTargetFrame = -1L
    @Volatile private var secondPreSeekHoldFrame = -1L
    // Y17: the ONE armed seek is backward (admitted 0 <= T <= H - 2 windows).
    @Volatile private var seekBackwardArmed = false

    // Y10a: extracted Y9 seek step sequence; runs synchronously under this
    // session's command lock, on the caller's thread (see [seek]).
    private val seekSequencer = VanguardRealtimeAudioPlaybackSeekSequencer(
        VanguardRealtimeAudioPlaybackSeekSequencer.Config(maxFramesPerMix = config.maxFramesPerMix),
        object : VanguardRealtimeAudioPlaybackSeekSequencer.Host {
            override fun pollSeekWaitReason(): String? {
                if (cancelled.get()) return "cancelled"
                if (SystemClock.elapsedRealtime() > deadlineAtMs) return "deadline_exceeded"
                return failure.get()
            }

            override fun noteCommandIssued() {
                commandsIssued++
            }
        },
    )

    // Y11b production focus/noisy response (command-lock-confined mutation
    // of the transport-facing flags; the monitor thread otherwise
    // single-writes its own bookkeeping below, published through
    // [buildFocusTelemetry] / [Snapshot.focus]).
    @Volatile private var focusController: VanguardRealtimePlaybackAudioFocusController? = null
    @Volatile private var focusMonitorThread: Thread? = null
    private val focusMonitorShutdown = AtomicBoolean(false)
    @Volatile private var focusMonitorStarted = false
    @Volatile private var focusMonitorExited = false
    @Volatile private var focusMonitorJoined = false
    @Volatile private var focusMonitorThreadId = -1L
    @Volatile private var userIntentPlaying = false
    @Volatile private var focusPausedByPolicy = false
    @Volatile private var focusTerminalPermanentLoss = false
    @Volatile private var focusTerminalNoisyLoss = false
    @Volatile private var focusState = ""
    @Volatile private var focusDuckAppliedCount = 0L
    @Volatile private var focusGainRestoreAppliedCount = 0L
    @Volatile private var focusPauseTransientAppliedCount = 0L
    @Volatile private var focusPausePermanentAppliedCount = 0L
    @Volatile private var focusPauseNoisyAppliedCount = 0L
    @Volatile private var focusPauseDroppedParkAppliedCount = 0L
    @Volatile private var focusAutoResumeAppliedCount = 0L
    @Volatile private var focusUnknownEventCount = 0L
    @Volatile private var focusGainRequestCount = 0L
    @Volatile private var focusGainAppliedCount = 0L
    @Volatile private var focusGainFailCount = 0L
    @Volatile private var lastFocusEventTag = ""
    @Volatile private var lastFocusEventSeq = -1L
    @Volatile private var lastFocusEventSource = ""
    @Volatile private var lastFocusAction = ""
    @Volatile private var lastFocusReason = ""

    // Y12 production route-change/disconnect response (command-lock-confined
    // mutation of the transport-facing flags; the monitor thread otherwise
    // single-writes its own bookkeeping below, published through
    // [buildRoutingTelemetry] / [Snapshot.routing]).
    @Volatile private var routingController: VanguardRealtimePlaybackRoutingController? = null
    @Volatile private var routingMonitorThread: Thread? = null
    private val routingMonitorShutdown = AtomicBoolean(false)
    @Volatile private var routingMonitorStarted = false
    @Volatile private var routingMonitorExited = false
    @Volatile private var routingMonitorJoined = false
    @Volatile private var routingMonitorThreadId = -1L
    @Volatile private var routingTerminalDisconnect = false
    @Volatile private var routingPausedByPolicy = false
    @Volatile private var routeChangedAppliedCount = 0L
    @Volatile private var routeDisconnectAppliedCount = 0L
    @Volatile private var lastRoutingEventTag = ""
    @Volatile private var lastRoutingEventSeq = -1L
    @Volatile private var lastRoutingEventSource = ""
    @Volatile private var lastRoutingAction = ""
    @Volatile private var lastRoutingReason = ""

    val currentState: State get() = state
    val failureReason: String get() = failure.get() ?: ""

    // Y13/Y14 (P4-AUDIO-REALTIME-PLAYBACK-PRESENTATION-CLOCK-QUERY-SURFACE /
    // P4-AUDIO-REALTIME-PLAYBACK-POSITION-QUERY-LIFECYCLE-CONTRACT): any-
    // thread, non-allocating, lock-free forwarders onto the sink's owned
    // presentation clock; -1 before a sink exists; after stop/dispose the
    // retained joined sink may return its final latched position. Never
    // acquires [commandLock] and never mutates session state -- a bounded
    // diagnostic query only (class comment), not a claim that P4-AUDIO-
    // MIXBUS or P4-AUDIO-GRAPH-TRANSPORT-CLOCK are complete.
    // Forbidden change: do not null/latch the sink before sink join because
    // that can create regression.
    fun currentPositionFrames(): Long = sink?.currentPositionFrames() ?: -1L
    fun currentPositionUs(): Long = sink?.currentPositionUs() ?: -1L

    // Y15a (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-CORRELATION-OBSERVATION): any-
    // thread, read-only pairing of a live native transport snapshot (the
    // worker-published AudioClock mirror) with the sink's presentation
    // clock snapshot. An OBSERVATION seam only -- it never touches
    // [currentPositionFrames]/[currentPositionUs] above (still the sole
    // downstream presentation-clock authority), never acquires
    // [commandLock], and issues no transport command beyond the existing
    // read-only [VanguardRealtimePlaybackTransportStateMachine.snapshot]
    // (Op.SNAPSHOT), so it never touches start/pause/resume/seek/drain
    // decisions. Null before a transport/sink exist, or once the transport
    // is disposed (a disposed machine's snapshot rejects with a null reply,
    // which this method also treats as terminal-safe null).
    fun observeClockCorrelation(): VanguardRealtimeAudioPlaybackClockCorrelation? {
        val machine = transport ?: return null
        val s = sink ?: return null
        val reply = machine.snapshot().reply ?: return null
        return VanguardRealtimeAudioPlaybackClockCorrelation.from(reply, s.clockSnapshot())
    }

    private val listener = object : VanguardRealtimePlaybackTransportStateMachine.Listener {
        override fun onStateChanged(previous: TransportState, current: TransportState, generation: Long) {
            countListener()
            synchronized(transitions) {
                if (transitions.isEmpty()) transitions.append(previous.name)
                transitions.append('>').append(current.name)
            }
        }

        override fun onCompleted(generation: Long) {
            countListener()
            completedCount.incrementAndGet()
        }

        override fun onFailed(reason: String, generation: Long) {
            countListener()
            failedCount.incrementAndGet()
            recordFailure("transport:$reason")
        }

        private fun countListener() {
            val t = transport
            if (t != null && t.isOwnerThread) listenerOnOwner.incrementAndGet() else listenerOffOwner.incrementAndGet()
        }
    }

    // ── Commands (caller thread, serialized) ───────────────────────────────

    // Probe -> load/prepare -> attach -> pre-roll -> (seek armed: admit and
    // pin the hold frame) -> sink READY -> transport start -> sink drain
    // allowed. Any failure tears down and reports it.
    fun start(): CommandResult = commandLock.withLock {
        if (state != State.IDLE) return reject("invalid_state_${state.name.lowercase()}")
        if (config.sourcePath.isBlank()) return failClosed("source_path_required")
        if (config.maxDurationSec <= 0.0 ||
            config.maxDurationSec > VanguardRealtimePlaybackDecoderFeed.HARD_MAX_DURATION_SEC
        ) {
            return failClosed("invalid_max_duration")
        }
        if (config.maxFramesPerMix <= 0 ||
            config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP
        ) {
            return failClosed("invalid_max_frames_per_mix")
        }
        if (!(config.gain > 0f) || config.gain > 1f) return failClosed("invalid_gain")
        if (config.deadlineMs <= 0L) return failClosed("invalid_deadline")
        if (config.maxPauseHoldMs <= 0L) return failClosed("invalid_max_pause_hold")
        if (config.maxSeekHoldMs <= 0L) return failClosed("invalid_max_seek_hold")
        if (config.syntheticDeadObjectInjectAfterFrames < 0L) return failClosed("invalid_dead_object_inject_after_frames")
        if (config.seekTargetSec < 0.0 || config.seekTargetSec.isNaN() || config.seekTargetSec >= config.maxDurationSec) {
            return failClosed("invalid_seek_target")
        }
        if (config.secondSeekTargetSec < 0.0 || config.secondSeekTargetSec.isNaN() ||
            config.secondSeekTargetSec >= config.maxDurationSec
        ) {
            return failClosed("invalid_second_seek_target")
        }
        if (config.secondSeekTargetSec > 0.0 &&
            (config.seekTargetSec <= 0.0 || config.secondSeekTargetSec <= config.seekTargetSec)
        ) {
            return failClosed("invalid_second_seek_target")
        }
        // Y17: exactly one backward seek; never composed with a second seek.
        if (config.seekBackward && config.secondSeekTargetSec > 0.0) return failClosed("backward_seek_repeated_unsupported")
        if (config.preSeekHoldWindows <= 0 || config.preSeekHoldWindows > MAX_PRE_SEEK_HOLD_WINDOWS) {
            return failClosed("invalid_pre_seek_hold_windows")
        }
        // Y11b: validated only when enabled (class comment); the disabled
        // default leaves every other config field unchecked and unused.
        if (config.enableAudioFocusResponse) {
            if (config.context == null) return failClosed("focus_context_required")
            if (config.mainHandler == null) return failClosed("focus_main_handler_required")
            if (!config.duckGain.isFinite() || config.duckGain < 0f || config.duckGain > config.gain) {
                return failClosed("invalid_duck_gain")
            }
            if (config.focusEventPollMs <= 0L) return failClosed("invalid_focus_event_poll_ms")
            if (config.focusGainApplyTimeoutMs <= 0L) return failClosed("invalid_focus_gain_apply_timeout_ms")
            if (config.focusMonitorJoinMs <= 0L) return failClosed("invalid_focus_monitor_join_ms")
        }
        // Y12: validated only when enabled (class comment); mainHandler is
        // required independently here so routing can be enabled without
        // focus response also being on.
        if (config.enableAudioRoutingResponse) {
            if (config.mainHandler == null) return failClosed("routing_main_handler_required")
            if (config.routingEventPollMs <= 0L) return failClosed("invalid_routing_event_poll_ms")
            if (config.routingMonitorJoinMs <= 0L) return failClosed("invalid_routing_monitor_join_ms")
        }
        // Y21: the ring/driver route is validated before STARTING or any
        // object creation (class comment) -- incompatible with every seek
        // variant and with focus/routing response; the Y8b synthetic
        // dead-object seam never arms on this route either, since it is a
        // sink-thread AudioTrack recovery concern the driver route does not
        // route through the same way.
        if (config.driverFactory != null) {
            if (config.seekTargetSec > 0.0) return failClosed("driver_route_seek_unsupported")
            if (config.secondSeekTargetSec > 0.0) return failClosed("driver_route_seek_unsupported")
            if (config.seekBackward) return failClosed("driver_route_seek_unsupported")
            if (config.enableAudioFocusResponse) return failClosed("driver_route_focus_unsupported")
            if (config.enableAudioRoutingResponse) return failClosed("driver_route_routing_unsupported")
            if (config.syntheticDeadObjectInjectAfterFrames > 0L) return failClosed("driver_route_dead_object_unsupported")
        }
        state = State.STARTING
        // Only an accepted start attempt (validation above already passed)
        // begins the session and sets user intent; a rejected invalid-
        // state/config start must never mutate it.
        userIntentPlaying = true
        generation++
        sessionStartedAtMs = SystemClock.elapsedRealtime()
        deadlineAtMs = sessionStartedAtMs + config.deadlineMs
        try {
            openAndStartLocked()
            state = State.PLAYING
            accept()
        } catch (f: FailClosed) {
            failClosed(f.reason)
        } catch (t: Throwable) {
            failClosed("exception:${t.javaClass.simpleName}:${t.message}")
        }
    }

    private fun openAndStartLocked() {
        // Y21: the ring/driver route is a full alternative to everything
        // below (default route unchanged when [Config.driverFactory] is
        // null, class comment).
        val driverFactory = config.driverFactory
        if (driverFactory != null) {
            openAndStartDriverRouteLocked(driverFactory)
            return
        }
        val f = VanguardRealtimePlaybackDecoderFeed(
            VanguardRealtimePlaybackDecoderFeed.Config(
                sourcePath = config.sourcePath,
                maxDurationSec = config.maxDurationSec,
                maxFramesPerMix = config.maxFramesPerMix,
                deadlineAtMs = deadlineAtMs,
                threadName = "${config.threadNamePrefix}DecoderFeed",
                externallyCancelled = { cancelled.get() },
            ),
        )
        feed = f
        if (!f.start()) throw FailClosed("feed_start_rejected")
        val fmt = f.awaitFormat(remainingMs()) ?: throw FailClosed("format_probe_failed:${f.exitReason}")
        format = fmt
        checkDeadlineAndCancel()

        val sessionConfig = VanguardRealtimePlaybackNativeSession.Config(
            sampleRate = fmt.sampleRate,
            channelCount = fmt.channelCount,
            maxFramesPerMix = config.maxFramesPerMix,
            trackCount = VanguardRealtimePlaybackDecoderFeed.TRACK_COUNT,
            declaredFrameCount = fmt.declaredFrameCount,
            externalIngestTrackMask = VanguardRealtimePlaybackDecoderFeed.EXTERNAL_INGEST_TRACK_MASK,
        )
        VanguardRealtimePlaybackNativeSession.validate(sessionConfig)?.let {
            throw FailClosed("session_config_invalid:${it.name.lowercase()}")
        }
        val machine = VanguardRealtimePlaybackTransportStateMachine(
            sessionConfig, listener, threadName = "${config.threadNamePrefix}Transport",
        )
        transport = machine

        val loadRes = machine.load()
        commandsIssued++
        if (!loadRes.accepted) throw FailClosed("load_rejected:${loadRes.reason}")
        val prepareRes = machine.prepare()
        commandsIssued++
        if (!prepareRes.accepted || prepareRes.state != TransportState.PREPARED) {
            throw FailClosed("prepare_rejected:${prepareRes.reason}")
        }
        prepareGeneration = machine.currentGeneration
        f.attachTransport(machine, prepareGeneration)

        while (!f.awaitPreRoll(WAIT_SLICE_MS)) {
            checkDeadlineAndCancel()
            failure.get()?.let { throw FailClosed(it) }
            if (!f.isAlive) throw FailClosed("feed_exited_during_preroll:${f.exitReason}")
        }
        preRollFrames = f.preRollFrames
        preRollRingFullObserved = f.preRollRingFullObserved
        preRollStatePrepared = machine.currentState == TransportState.PREPARED
        if (preRollFrames <= 0L) throw FailClosed("preroll_empty:${f.exitReason}")

        // Y9/Y10b-1a seek admission (C10) and hold pin before the transport
        // starts: H1 = first window-aligned frame >= preRoll +
        // preSeekHoldWindows windows. When secondSeekTargetSec > 0.0 a second
        // ordered forward seek is admitted too: H2 = T1 + preSeekHoldWindows
        // windows, a post-seek epoch window boundary relative to T1 (not the
        // absolute frame grid), with H1 < T1 < H2 < T2 < declared - 2 windows.
        // Y17: a backward seek arms on [Config.seekBackward] alone (T may be
        // frame 0) against the same H, with four independent checks
        // (class comment) each named in the fail-closed reason.
        if (config.seekBackward || config.seekTargetSec > 0.0) {
            val window = config.maxFramesPerMix.toLong()
            val declared = fmt.declaredFrameCount
            val target = (config.seekTargetSec * fmt.sampleRate).toLong()
            val hold = alignUp(preRollFrames + config.preSeekHoldWindows.toLong() * window, window)
            seekArmed = true
            seekTargetFrame = target
            preSeekHoldFrame = hold
            if (config.seekBackward) {
                seekBackwardArmed = true
                val preRollBelowHold = hold > preRollFrames
                val holdAligned = hold % window == 0L
                val holdBelowEnd = hold < declared - 2L * window
                val targetInRange = target >= 0L && target <= hold - 2L * window
                seekAdmissionOk = preRollBelowHold && holdAligned && holdBelowEnd && targetInRange
                if (!seekAdmissionOk) {
                    throw FailClosed(
                        "backward_seek_admission:preroll=$preRollFrames:hold=$hold:target=$target:declared=$declared:" +
                            "prerollBelowHold=$preRollBelowHold:holdAligned=$holdAligned:holdBelowEnd=$holdBelowEnd:" +
                            "targetInRange=$targetInRange",
                    )
                }
            } else {
                var admissionOk = hold % window == 0L && hold > preRollFrames && hold < target &&
                    target < declared - 2L * window
                if (config.secondSeekTargetSec > 0.0) {
                    repeatedSeekArmed = true
                    val target2 = (config.secondSeekTargetSec * fmt.sampleRate).toLong()
                    val hold2 = target + config.preSeekHoldWindows.toLong() * window
                    secondSeekTargetFrame = target2
                    secondPreSeekHoldFrame = hold2
                    admissionOk = admissionOk && (hold2 - target) % window == 0L && hold2 > target && hold2 < target2 &&
                        target2 < declared - 2L * window
                }
                seekAdmissionOk = admissionOk
                if (!seekAdmissionOk) {
                    throw FailClosed(
                        "seek_admission:preroll=$preRollFrames:hold=$hold:target=$target:" +
                            "hold2=$secondPreSeekHoldFrame:target2=$secondSeekTargetFrame:declared=$declared",
                    )
                }
            }
            seekHoldPinned = f.setPreSeekHoldFrame(hold)
            if (!seekHoldPinned) throw FailClosed("seek_hold_pin_rejected:$hold")
        }

        // Y11b production focus/noisy response, default OFF: request
        // AUDIOFOCUS_GAIN and register the ACTION_AUDIO_BECOMING_NOISY
        // receiver before the sink exists or the transport starts (class
        // comment). Any setup failure here fails closed before audible
        // output and releases the controller through the common teardown.
        // The monitor thread itself is NOT started here: it is only started
        // once the sink exists and is READY (below), so an early OS
        // FOCUS_GAIN/CAN_DUCK callback can never reach [applyFocusGain]
        // while [sink] is still null.
        if (config.enableAudioFocusResponse) {
            val focusContext = config.context ?: throw FailClosed("focus_context_required")
            val focusHandler = config.mainHandler ?: throw FailClosed("focus_main_handler_required")
            val controller = VanguardRealtimePlaybackAudioFocusController(focusContext, focusHandler)
            focusController = controller
            if (!controller.requestFocus()) {
                throw FailClosed("focus_request_denied:${controller.telemetry()["focusRequestError"]}")
            }
            if (!controller.registerNoisyReceiver()) {
                throw FailClosed("focus_noisy_register_failed:${controller.telemetry()["receiverRegisterError"]}")
            }
            focusState = "held"
        }

        // Y12 production route-change/disconnect response, default OFF:
        // this session owns exactly one [VanguardRealtimePlaybackRoutingController],
        // created before the sink so its [VanguardRealtimeAudioPlaybackSinkBridge.Config]
        // can be handed the SAME instance to attach/detach against its
        // AudioTrack (class comment). The monitor thread itself is NOT
        // started here, mirroring Y11b: only once the sink exists and is
        // READY, below.
        if (config.enableAudioRoutingResponse) {
            val routingHandler = config.mainHandler ?: throw FailClosed("routing_main_handler_required")
            routingController = VanguardRealtimePlaybackRoutingController(routingHandler)
        }

        // Sink exists and is READY (AudioTrack created, gain set) before the
        // transport starts; it only drains after allowDrain().
        val s = VanguardRealtimeAudioPlaybackSinkBridge(
            VanguardRealtimeAudioPlaybackSinkBridge.Config(
                stateMachine = machine,
                sampleRate = fmt.sampleRate,
                channelCount = fmt.channelCount,
                maxFramesPerMix = config.maxFramesPerMix,
                declaredFrameCount = fmt.declaredFrameCount,
                gain = config.gain,
                maxPauseHoldMs = config.maxPauseHoldMs,
                maxSeekHoldMs = config.maxSeekHoldMs,
                deadlineAtMs = deadlineAtMs,
                threadName = "${config.threadNamePrefix}Sink",
                externallyCancelled = { cancelled.get() },
                onExited = { reason -> onSinkExited(reason) },
                syntheticDeadObjectInjectAfterFrames = config.syntheticDeadObjectInjectAfterFrames,
                routingController = routingController,
            ),
        )
        sink = s
        if (!s.start()) throw FailClosed("sink_start_rejected")
        val readyDeadline = SystemClock.elapsedRealtime() + SINK_READY_TIMEOUT_MS
        while (!s.awaitReady(WAIT_SLICE_MS)) {
            checkDeadlineAndCancel()
            failure.get()?.let { throw FailClosed(it) }
            if (!s.isAlive) throw FailClosed("sink_exited_before_ready:${s.currentExitReason}")
            if (SystemClock.elapsedRealtime() > readyDeadline) throw FailClosed("sink_ready_timeout")
        }
        sinkReadyAtMs = SystemClock.elapsedRealtime()

        // Y11b: the ONE session-owned focus monitor thread starts only now
        // that the sink exists and is READY, and strictly before
        // transport.start/allowDrain below, so the request/register-before-
        // audible-output contract (class comment) still holds while a gain
        // event can always find a live sink to apply against.
        if (config.enableAudioFocusResponse) {
            val monitor = Thread({ runFocusMonitor() }, "${config.threadNamePrefix}FocusMonitor")
            focusMonitorThread = monitor
            monitor.start()
            focusMonitorStarted = true
        }

        // Y12: the ONE session-owned routing monitor thread starts only now
        // that the sink exists and is READY, and strictly before
        // transport.start/allowDrain below (class comment / Y11b
        // precedent), so a ROUTE_CHANGED/ROUTE_DISCONNECT can always find a
        // live sink and command path to react against.
        if (config.enableAudioRoutingResponse) {
            val monitor = Thread({ runRoutingMonitor() }, "${config.threadNamePrefix}RoutingMonitor")
            routingMonitorThread = monitor
            monitor.start()
            routingMonitorStarted = true
        }

        val startRes = machine.start()
        commandsIssued++
        transportStartAtMs = SystemClock.elapsedRealtime()
        startAccepted = startRes.accepted && startRes.state == TransportState.PLAYING
        if (!startAccepted) throw FailClosed("start_rejected:${startRes.reason}")
        startGeneration = machine.currentGeneration
        f.updateGeneration(startGeneration)
        f.markTransportStarted()
        s.allowDrain()
        drainAllowedAtMs = SystemClock.elapsedRealtime()
    }

    // Y21 ring/driver route (P4-AUDIO-REALTIME-PLAYBACK-RING-TRANSPORT-
    // SESSION-INTEGRATION), default OFF: builds and starts the pipeline from
    // ONE caller-supplied [VanguardRealtimeAudioPlaybackTransportDriver]
    // instead of the decoder feed + native transport state machine above --
    // no MediaExtractor/MediaCodec, no
    // [VanguardRealtimePlaybackTransportStateMachine], no native call in
    // this file. Fixed order (class comment): create the driver once ->
    // [VanguardRealtimeAudioPlaybackTransportDriver.open] -> read its
    // geometry -> construct the sink with `stateMachine = null`,
    // `frameSource = driver.frameSource` and that geometry -> sink started
    // and READY -> [VanguardRealtimeAudioPlaybackTransportDriver.start] ->
    // sink.allowDrain(). [transport] and [feed] are never assigned on this
    // route.
    private fun openAndStartDriverRouteLocked(
        factory: (VanguardRealtimeAudioPlaybackTransportDriver.Context) -> VanguardRealtimeAudioPlaybackTransportDriver,
    ) {
        val d = factory(
            VanguardRealtimeAudioPlaybackTransportDriver.Context(
                deadlineAtMs = deadlineAtMs,
                maxFramesPerMix = config.maxFramesPerMix,
                externallyCancelled = { cancelled.get() },
            ),
        )
        driver = d
        if (!d.open(remainingMs())) throw FailClosed("driver_open_failed:${d.exitReason}")
        checkDeadlineAndCancel()

        // Frozen order (class comment): driver open -> read and validate
        // geometry -> sink construction. The mirrored admission table is the
        // SAME one the default route validates against above.
        val sampleRate = d.sampleRate
        val channelCount = d.channelCount
        val maxFramesPerMix = d.maxFramesPerMix
        val declaredFrameCount = d.declaredFrameCount
        if (maxFramesPerMix != config.maxFramesPerMix) {
            throw FailClosed("driver_geometry_invalid:max_frames_per_mix_mismatch")
        }
        val driverSessionConfig = VanguardRealtimePlaybackNativeSession.Config(
            sampleRate = sampleRate,
            channelCount = channelCount,
            maxFramesPerMix = maxFramesPerMix,
            trackCount = 1,
            declaredFrameCount = declaredFrameCount,
        )
        VanguardRealtimePlaybackNativeSession.validate(driverSessionConfig)?.let {
            throw FailClosed("driver_geometry_invalid:${it.name.lowercase()}")
        }

        // Sink exists and is READY (AudioTrack created, gain set) before the
        // driver starts; it only drains after allowDrain() (same ordering
        // contract as the default route above).
        val s = VanguardRealtimeAudioPlaybackSinkBridge(
            VanguardRealtimeAudioPlaybackSinkBridge.Config(
                stateMachine = null,
                sampleRate = sampleRate,
                channelCount = channelCount,
                maxFramesPerMix = maxFramesPerMix,
                declaredFrameCount = declaredFrameCount,
                gain = config.gain,
                maxPauseHoldMs = config.maxPauseHoldMs,
                maxSeekHoldMs = config.maxSeekHoldMs,
                deadlineAtMs = deadlineAtMs,
                threadName = "${config.threadNamePrefix}Sink",
                externallyCancelled = { cancelled.get() },
                onExited = { reason -> onSinkExited(reason) },
                frameSource = d.frameSource,
            ),
        )
        sink = s
        if (!s.start()) throw FailClosed("sink_start_rejected")
        val readyDeadline = SystemClock.elapsedRealtime() + SINK_READY_TIMEOUT_MS
        while (!s.awaitReady(WAIT_SLICE_MS)) {
            checkDeadlineAndCancel()
            failure.get()?.let { throw FailClosed(it) }
            if (!s.isAlive) throw FailClosed("sink_exited_before_ready:${s.currentExitReason}")
            if (SystemClock.elapsedRealtime() > readyDeadline) throw FailClosed("sink_ready_timeout")
        }
        sinkReadyAtMs = SystemClock.elapsedRealtime()

        if (!d.start(remainingMs())) throw FailClosed("driver_start_rejected:${d.exitReason}")
        startAccepted = true
        transportStartAtMs = SystemClock.elapsedRealtime()
        s.allowDrain()
        drainAllowedAtMs = SystemClock.elapsedRealtime()
    }

    // Sink park -> ack -> transport.pause. The hold is bounded by the sink.
    // A user pause always clears user intent (Y11b); a focus-induced pause
    // goes through [pauseBoundedLocked] directly and never touches it.
    fun pauseBounded(): CommandResult = commandLock.withLock {
        userIntentPlaying = false
        pauseBoundedLocked()
    }

    // Command-lock holder only (already held by [pauseBounded] or by the
    // Y11b focus monitor's own commandLock.withLock around a focus event);
    // never mutates [userIntentPlaying].
    private fun pauseBoundedLocked(): CommandResult {
        if (state != State.PLAYING) return reject("invalid_state_${state.name.lowercase()}")
        // Y21: the ring/driver route has no bounded pause; reject with a
        // typed reason and mutate nothing (not fail closed).
        if (config.driverFactory != null) return reject("driver_route_pause_unsupported")
        failure.get()?.let { return failClosed(it) }
        val s = sink ?: return failClosed("sink_missing")
        val machine = transport ?: return failClosed("transport_missing")
        return try {
            pauseRequestedAtMs = SystemClock.elapsedRealtime()
            if (!s.requestPark()) throw FailClosed("sink_park_rejected:${s.phase.name.lowercase()}")
            val ackDeadline = pauseRequestedAtMs + PARK_ACK_TIMEOUT_MS
            while (!s.awaitParked(WAIT_SLICE_MS)) {
                checkDeadlineAndCancel()
                failure.get()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_park_ack:${s.currentExitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_park_ack_timeout")
            }
            pauseAckedAtMs = SystemClock.elapsedRealtime()
            clockAtPauseAck = s.clockSnapshot()
            val res = machine.pause()
            commandsIssued++
            pauseAccepted = res.accepted && res.state == TransportState.PAUSED
            pauseGeneration = machine.currentGeneration
            if (!pauseAccepted) throw FailClosed("pause_rejected:${res.reason}")
            state = State.PAUSED
            accept()
        } catch (f: FailClosed) {
            failClosed(f.reason)
        } catch (t: Throwable) {
            failClosed("exception:${t.javaClass.simpleName}:${t.message}")
        }
    }

    // transport.resume -> sink unpark -> ack (AudioTrack.play, new epoch).
    // A user resume always sets user intent (Y11b); the focus monitor's own
    // auto-resume goes through [resumeLocked] directly and never touches it.
    // Y12: a terminal route disconnect must reject without mutating any
    // session flags, so [routingTerminalDisconnect] is checked before
    // [userIntentPlaying] is ever set.
    fun resume(): CommandResult = commandLock.withLock {
        if (routingTerminalDisconnect) return reject("routing_terminal_disconnect")
        userIntentPlaying = true
        resumeLocked()
    }

    // Command-lock holder only (already held by [resume] or by the Y11b
    // focus monitor's own commandLock.withLock around a FOCUS_GAIN auto-
    // resume); never mutates [userIntentPlaying].
    private fun resumeLocked(): CommandResult {
        if (state != State.PAUSED) return reject("invalid_state_${state.name.lowercase()}")
        // Y21: the ring/driver route has no bounded resume (it never
        // reaches PAUSED via [pauseBoundedLocked] above, but this stays
        // defensive/symmetric); reject with a typed reason and mutate
        // nothing (not fail closed).
        if (config.driverFactory != null) return reject("driver_route_resume_unsupported")
        // Y12: a terminal route disconnect fails any resume closed-off
        // (never cleared by this session) without altering state or flags.
        if (routingTerminalDisconnect) return reject("routing_terminal_disconnect")
        failure.get()?.let { return failClosed(it) }
        val s = sink ?: return failClosed("sink_missing")
        val machine = transport ?: return failClosed("transport_missing")
        return try {
            if (!s.isAlive) throw FailClosed("sink_exited_during_pause:${s.currentExitReason}")
            clockBeforeResume = s.clockSnapshot()
            val res = machine.resume()
            commandsIssued++
            resumeAccepted = res.accepted && res.state == TransportState.PLAYING
            resumeGeneration = machine.currentGeneration
            if (!resumeAccepted) throw FailClosed("resume_rejected:${res.reason}")
            val unparkAt = SystemClock.elapsedRealtime()
            if (!s.unpark()) throw FailClosed("sink_unpark_rejected:${s.phase.name.lowercase()}")
            val ackDeadline = unparkAt + UNPARK_ACK_TIMEOUT_MS
            while (!s.awaitRunning(WAIT_SLICE_MS)) {
                checkDeadlineAndCancel()
                failure.get()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_unpark_ack:${s.currentExitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_unpark_ack_timeout")
            }
            resumedAtMs = SystemClock.elapsedRealtime()
            pauseHoldObservedMs = resumedAtMs - pauseAckedAtMs
            clockAfterResume = s.clockSnapshot()
            state = State.PLAYING
            focusPausedByPolicy = false
            accept()
        } catch (f: FailClosed) {
            failClosed(f.reason)
        } catch (t: Throwable) {
            failClosed("exception:${t.javaClass.simpleName}:${t.message}")
        }
    }

    // Y9 (default): the ONE armed forward seek (targetFrame must equal the
    // armed target), PLAYING -> SEEKING -> PLAYING in the class-comment
    // order. Y10b-1a, when [repeatedSeekArmed]: two ordered forward seeks are
    // admitted; each call accepts only the CURRENT ordered target (T1 first,
    // then T2), by index (0, then 1). Y17, when [seekBackwardArmed]: the ONE
    // armed seek runs the same order with the direction declared to the
    // sequencer. Not PLAYING, not armed, a target past the armed count
    // (repeated) or a foreign target: rejected without teardown or mutation.
    fun seek(targetFrame: Long): CommandResult = commandLock.withLock {
        if (state != State.PLAYING) return reject("invalid_state_${state.name.lowercase()}")
        if (!seekArmed || !seekHoldPinned) return reject("seek_not_armed")
        val maxSeeks = if (repeatedSeekArmed) 2 else 1
        if (seekCount >= maxSeeks) return reject("seek_repeated")
        val index = seekCount
        val expectedTarget = if (index == 0) seekTargetFrame else secondSeekTargetFrame
        if (targetFrame != expectedTarget) return reject("seek_target_mismatch:$targetFrame:$expectedTarget")
        failure.get()?.let { return failClosed(it) }
        val s = sink ?: return failClosed("sink_missing")
        val f = feed ?: return failClosed("feed_missing")
        val machine = transport ?: return failClosed("transport_missing")
        val fmt = format ?: return failClosed("format_missing")
        // Content hold frames (H1/H2) are decoder/native position domain;
        // sink hold frames are cumulative sink domain (class comment). The
        // two coincide for the first seek and diverge for the second.
        val contentHold = if (index == 0) preSeekHoldFrame else secondPreSeekHoldFrame
        val sinkHold = if (index == 0) preSeekHoldFrame else preSeekHoldFrame + (secondPreSeekHoldFrame - seekTargetFrame)
        val nextContentHold = if (index == 0 && repeatedSeekArmed) secondPreSeekHoldFrame else Long.MAX_VALUE
        seekCount = index + 1
        state = State.SEEKING
        val reason = seekSequencer.run(
            s, f, machine, fmt.declaredFrameCount, index, contentHold, sinkHold, targetFrame, nextContentHold,
            backward = seekBackwardArmed,
        )
        if (reason == null) {
            state = State.PLAYING
            accept()
        } else {
            failClosed(reason)
        }
    }

    // Any state. Tears the pipeline down (sink, decoder, transport) once.
    fun stop(): CommandResult = commandLock.withLock {
        if (state == State.DISPOSED) return reject("disposed")
        if (state == State.IDLE) {
            state = State.STOPPED
            return accept()
        }
        teardownLocked()
        state = if (failure.get() != null) State.FAILED else State.STOPPED
        CommandResult(failure.get() == null, state, failure.get() ?: REASON_OK)
    }

    // Idempotent; any state.
    fun dispose() {
        commandLock.withLock {
            if (!disposed.compareAndSet(false, true)) return
            if (state != State.IDLE) teardownLocked()
            state = State.DISPOSED
        }
    }

    // Lock-free, any thread: every bounded wait (decoder, sink, command
    // loops) observes the flag; the command in flight fails closed with
    // "cancelled" and tears down on its own thread. Never blocks.
    fun cancel() {
        cancelled.set(true)
        sink?.cancel()
        feed?.cancel()
        // Y21: non-blocking wake so the ring/driver route owner never runs
        // until the deadline (class comment); a no-op on the default route.
        driver?.cancel()
        // Y11b: non-blocking wake so the focus monitor (if any) notices
        // cancellation without waiting for its next poll slice; the bounded
        // join itself only happens at teardown.
        focusMonitorShutdown.set(true)
        focusMonitorThread?.takeIf { it.isAlive && Thread.currentThread() !== it }?.interrupt()
        // Y12: same non-blocking wake for the routing monitor (if any).
        routingMonitorShutdown.set(true)
        routingMonitorThread?.takeIf { it.isAlive && Thread.currentThread() !== it }?.interrupt()
    }

    // Y11b diagnostic seam (any thread): posts one synthetic focus-change /
    // becoming-noisy event onto the SAME controller queue the focus monitor
    // drains, so it is indistinguishable from a real OS callback. False
    // whenever focus response is disabled or the controller is absent or
    // already released (never throws).
    fun postSyntheticFocusChange(focusChange: Int): Boolean {
        if (!config.enableAudioFocusResponse) return false
        return focusController?.postSyntheticFocusChange(focusChange) ?: false
    }

    fun postSyntheticBecomingNoisy(): Boolean {
        if (!config.enableAudioFocusResponse) return false
        return focusController?.postSyntheticBecomingNoisy() ?: false
    }

    // Y12 diagnostic seam (any thread): posts one synthetic route-changed /
    // route-disconnect event onto the SAME controller queue the routing
    // monitor drains, so it is indistinguishable from a real OS callback /
    // policy trigger. False whenever routing response is disabled or the
    // controller is absent or already released (never throws).
    fun postSyntheticRouteChanged(): Boolean {
        if (!config.enableAudioRoutingResponse) return false
        return routingController?.postSyntheticRouteChanged() ?: false
    }

    fun postSyntheticRouteDisconnect(): Boolean {
        if (!config.enableAudioRoutingResponse) return false
        return routingController?.postSyntheticRouteDisconnect() ?: false
    }

    // ── Waits (any thread; lock-free) ──────────────────────────────────────

    // True once the AudioTrack played real frames and clock epoch 0 is open.
    fun awaitFirstAudio(timeoutMs: Long): Boolean {
        val until = SystemClock.elapsedRealtime() + timeoutMs
        while (true) {
            val s = sink ?: return false
            if (s.hasPlayed && s.framesWritten > 0L && s.clockSnapshot().epochOpen) return true
            if (pollFailure() != null || !s.isAlive) return false
            if (SystemClock.elapsedRealtime() > until) return false
            sleepSlice()
        }
    }

    // True when the sink drained EOS and the decoder exited at EOS; the
    // session then publishes COMPLETED (transport left alive until stop).
    fun awaitCompletion(timeoutMs: Long): Boolean {
        val until = SystemClock.elapsedRealtime() + timeoutMs
        val s = sink ?: return false
        // Y21: the ring/driver route has no decoder feed (class comment);
        // completion there is sink EOS plus the driver's own terminal/no-
        // failure signal instead of a feed EOS exit.
        val d = driver
        if (d != null) return awaitDriverCompletion(s, d, until)
        val f = feed ?: return false
        while (!s.awaitExit(WAIT_SLICE_MS)) {
            if (pollFailure() != null) return false
            if (SystemClock.elapsedRealtime() > until) return false
        }
        if (s.currentExitReason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS) return false
        if (!f.awaitExit(maxOf(1L, until - SystemClock.elapsedRealtime()))) return false
        if (f.exitReason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS) {
            recordFailure("decoder:${f.exitReason}")
            return false
        }
        if (pollFailure() != null) return false
        commandLock.withLock {
            if (state == State.PLAYING || state == State.PAUSED) state = State.COMPLETED
        }
        return state == State.COMPLETED
    }

    // Y21 ring/driver route (any thread; lock-free until the final publish):
    // mirrors [awaitCompletion]'s sink-EOS + producer-EOS gate above, using
    // the driver's own [VanguardRealtimeAudioPlaybackTransportDriver.isEosTerminal]
    // in place of the decoder feed's EXIT_EOS (this route has no feed).
    private fun awaitDriverCompletion(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        d: VanguardRealtimeAudioPlaybackTransportDriver,
        until: Long,
    ): Boolean {
        while (!s.awaitExit(WAIT_SLICE_MS)) {
            if (pollFailure() != null) return false
            if (SystemClock.elapsedRealtime() > until) return false
        }
        if (s.currentExitReason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS) return false
        if (!d.isEosTerminal) {
            recordFailure("driver:${d.exitReason.ifEmpty { "not_terminal_${d.currentStageLabel}" }}")
            return false
        }
        if (pollFailure() != null) return false
        commandLock.withLock {
            if (state == State.PLAYING || state == State.PAUSED) state = State.COMPLETED
        }
        return state == State.COMPLETED
    }

    // ── Snapshot / metrics (any thread) ────────────────────────────────────

    fun snapshot(): Snapshot {
        pollFailure()
        val f = feed
        val s = sink
        val machine = transport
        val wall = if (sessionStartedAtMs < 0L) 0L else if (sessionWallMs > 0L) sessionWallMs else SystemClock.elapsedRealtime() - sessionStartedAtMs
        return Snapshot(
            state = state,
            generation = generation,
            failureReason = failure.get() ?: "",
            cancelled = cancelled.get(),
            format = format,
            transportState = machine?.currentState,
            transportGeneration = machine?.currentGeneration ?: -1L,
            transportTransitions = synchronized(transitions) { transitions.toString() },
            transportCompletedCallbacks = completedCount.get(),
            transportFailedCallbacks = failedCount.get(),
            listenerCallbacksOnOwner = listenerOnOwner.get(),
            listenerCallbacksOffOwner = listenerOffOwner.get(),
            commandsIssued = commandsIssued,
            prepareGeneration = prepareGeneration,
            startGeneration = startGeneration,
            pauseGeneration = pauseGeneration,
            resumeGeneration = resumeGeneration,
            startAccepted = startAccepted,
            pauseAccepted = pauseAccepted,
            resumeAccepted = resumeAccepted,
            transportStopAccepted = transportStopAccepted,
            transportStateBeforeDispose = transportStateBeforeDispose,
            transportStateAfterDispose = transportStateAfterDispose,
            transportDisposeCalls = transportDisposeCalls,
            preRollFrames = preRollFrames,
            preRollRingFullObserved = preRollRingFullObserved,
            preRollStatePrepared = preRollStatePrepared,
            sinkReadyBeforeTransportStart = sinkReadyAtMs >= 0L && transportStartAtMs >= sinkReadyAtMs,
            drainAllowedAfterTransportStart = drainAllowedAtMs >= 0L && drainAllowedAtMs >= transportStartAtMs,
            sinkReadyAtMs = sinkReadyAtMs,
            transportStartAtMs = transportStartAtMs,
            drainAllowedAtMs = drainAllowedAtMs,
            pauseRequestedAtMs = pauseRequestedAtMs,
            pauseAckedAtMs = pauseAckedAtMs,
            resumedAtMs = resumedAtMs,
            pauseHoldObservedMs = pauseHoldObservedMs,
            clockAtPauseAck = clockAtPauseAck,
            clockBeforeResume = clockBeforeResume,
            clockAfterResume = clockAfterResume,
            clock = s?.clockSnapshot(),
            sink = s?.telemetry(),
            decoderExitReason = f?.exitReason ?: VanguardRealtimePlaybackDecoderFeed.EXIT_NOT_STARTED,
            decoderThreadId = f?.threadId ?: -1L,
            decoderThreadIsTransportOwner = f?.threadIsTransportOwner ?: false,
            decoderAcceptedFrames = f?.acceptedFrames ?: 0L,
            decoderPaddedFrames = f?.paddedFrames ?: 0L,
            decoderChecksumHex = f?.checksumHex ?: "",
            decoderMediaReleaseCount = f?.mediaReleaseCount?.get() ?: 0L,
            decoderMediaReleaseClean = f?.mediaReleaseClean ?: false,
            decoderIngestCallbacksOnOwner = f?.ingestCallbacksOnOwner?.get() ?: 0L,
            decoderIngestCallbacksOffOwner = f?.ingestCallbacksOffOwner?.get() ?: 0L,
            decoderIngestCalls = f?.ingestCalls ?: 0L,
            decoderCancelRequested = decoderCancelRequested,
            decoderJoined = decoderJoined,
            sinkJoined = sinkJoined,
            terminalReply = terminalReply,
            sessionWallMs = wall,
            seek = VanguardRealtimeAudioPlaybackSeekObservation(
                armed = seekArmed,
                targetFrame = seekTargetFrame,
                holdFrame = preSeekHoldFrame,
                admissionOk = seekAdmissionOk,
                holdPinned = seekHoldPinned,
                seekCount = seekCount,
                seekAccepted = seekSequencer.seekAccepted,
                staleGeneration = seekSequencer.seekStaleGeneration,
                seekGeneration = seekSequencer.seekGeneration,
                pauseAccepted = seekSequencer.seekPauseAccepted,
                pauseGeneration = seekSequencer.seekPauseGeneration,
                resumeAccepted = seekSequencer.seekResumeAccepted,
                resumeGeneration = seekSequencer.seekResumeGeneration,
                initialWriteWaitMs = seekSequencer.seekInitialWriteWaitMs,
                quiesceWaitMs = seekSequencer.seekQuiesceWaitMs,
                quiesceFeedHeld = seekSequencer.seekQuiesceFeedHeld,
                quiesceSinkReadFrames = seekSequencer.seekQuiesceSinkReadFrames,
                quiesceSinkWrittenFrames = seekSequencer.seekQuiesceSinkWrittenFrames,
                quiesceAccountingOk = seekSequencer.seekQuiesceAccountingOk,
                preSeekSettleMs = seekSequencer.seekPreSeekSettleMs,
                preSeekReply = seekSequencer.seekPreSeekReply,
                preSeekTransportState = seekSequencer.seekPreSeekTransportState,
                postPauseReply = seekSequencer.seekPostPauseReply,
                flushRequestedWhilePaused = seekSequencer.seekFlushRequestedWhilePaused,
                flushAckWaitMs = seekSequencer.seekFlushAckWaitMs,
                flushAckedBeforeSeek = seekSequencer.seekFlushAckedBeforeSeek,
                sinkPhaseAtSeek = seekSequencer.seekSinkPhaseAtSeek,
                postSeekReply = seekSequencer.seekPostSeekReply,
                postSeekTransportState = seekSequencer.seekPostSeekTransportState,
                reanchorWaitMs = seekSequencer.seekReanchorWaitMs,
                postSeekPreRollWaitMs = seekSequencer.seekPostSeekPreRollWaitMs,
                postSeekPreRollReply = seekSequencer.seekPostSeekPreRollReply,
                postSeekPreRollTransportState = seekSequencer.seekPostSeekPreRollTransportState,
                transportStateAtUnpark = seekSequencer.seekTransportStateAtUnpark,
                parkRequestedAtMs = seekSequencer.seekParkRequestedAtMs,
                parkAckedAtMs = seekSequencer.seekParkAckedAtMs,
                unparkedAtMs = seekSequencer.seekUnparkedAtMs,
                resumedAtMs = seekSequencer.seekResumedAtMs,
                holdObservedMs = seekSequencer.seekHoldObservedMs,
                seekWallMs = seekSequencer.seekWallMs,
                clockAtPark = seekSequencer.seekClockAtPark,
                clockBeforeUnpark = seekSequencer.seekClockBeforeUnpark,
                clockAfterUnpark = seekSequencer.seekClockAfterUnpark,
                decoder = f?.seekTelemetry(),
                backward = seekBackwardArmed,
                declaredBackward = seekSequencer.seekDeclaredBackward,
            ),
            focus = buildFocusTelemetry(),
            routing = buildRoutingTelemetry(),
            driverEnabled = config.driverFactory != null,
            driverExitReason = driver?.exitReason ?: "",
            driverClosed = driverClosed,
            driverStageLabel = driver?.currentStageLabel ?: "",
            driverSampleRate = driver?.sampleRate ?: -1,
            driverChannelCount = driver?.channelCount ?: -1,
            driverMaxFramesPerMix = driver?.maxFramesPerMix ?: -1,
            driverDeclaredFrameCount = driver?.declaredFrameCount ?: -1L,
        )
    }

    // ── Internals ──────────────────────────────────────────────────────────

    private fun accept(): CommandResult = CommandResult(true, state, REASON_OK)
    private fun reject(reason: String): CommandResult = CommandResult(false, state, reason)

    // Command-lock holder only: records the failure, tears down, FAILED.
    private fun failClosed(reason: String): CommandResult {
        recordFailure(reason)
        if (state != State.DISPOSED) {
            if (state != State.IDLE) teardownLocked()
            state = State.FAILED
        }
        return CommandResult(false, state, failure.get() ?: reason)
    }

    private fun recordFailure(reason: String) {
        failure.compareAndSet(null, reason)
    }

    // Sink thread callback after its AudioTrack was released. A non-EOS
    // exit fails closed: the decoder is cancelled so it never stalls
    // against a transport nobody drains; the transport is disposed by the
    // next stop()/dispose() on the caller's thread.
    private fun onSinkExited(reason: String) {
        if (reason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS) return
        if (reason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_CANCELLED && cancelled.get()) return
        recordFailure("sink:$reason")
        cancelDecoder()
        // Y21: non-blocking wake so the ring/driver route owner never runs
        // until the deadline (class comment); a no-op on the default route.
        driver?.cancel()
        if (state == State.STARTING || state == State.PLAYING || state == State.PAUSED || state == State.SEEKING) state = State.FAILED
    }

    private fun cancelDecoder() {
        val f = feed ?: return
        decoderCancelRequested = true
        f.cancel()
    }

    // Polls the failure sources once; returns the first failure if any.
    private fun pollFailure(): String? {
        failure.get()?.let { return it }
        val machine = transport
        if (machine != null && machine.currentState == TransportState.FAILED) recordFailure("transport_failed")
        val f = feed
        if (f != null && !f.isAlive) {
            val reason = f.exitReason
            if (reason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS &&
                reason != VanguardRealtimePlaybackDecoderFeed.EXIT_RUNNING &&
                !(reason == VanguardRealtimePlaybackDecoderFeed.EXIT_CANCELLED && (cancelled.get() || decoderCancelRequested))
            ) {
                recordFailure("decoder:$reason")
            }
        }
        // Y21: checked before the sink branch below so a driver failure's
        // typed root cause wins the race against the sink's own generic
        // drain-rejected exit for the same underlying event (class comment).
        val d = driver
        if (d != null && !d.isAlive) {
            val reason = d.exitReason
            if (reason.isNotEmpty() &&
                !(reason == VanguardRealtimeAudioPlaybackTransportDriver.REASON_CANCELLED && cancelled.get())
            ) {
                recordFailure("driver:$reason")
            }
        }
        val s = sink
        if (s != null && !s.isAlive) {
            val reason = s.currentExitReason
            if (reason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_EOS &&
                reason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_RUNNING &&
                reason != VanguardRealtimeAudioPlaybackSinkBridge.EXIT_NOT_STARTED &&
                !(reason == VanguardRealtimeAudioPlaybackSinkBridge.EXIT_CANCELLED && cancelled.get())
            ) {
                recordFailure("sink:$reason")
            }
        }
        if (sessionStartedAtMs >= 0L && !teardownDone.get() && SystemClock.elapsedRealtime() > deadlineAtMs) {
            recordFailure("deadline_exceeded")
        }
        return failure.get()
    }

    // Command-lock holder only; exactly once. Order: sink cancel, decoder
    // cancel, bounded joins, transport stop (only once both producer and
    // consumer threads are gone, so no late ingest/drain races the stop),
    // terminal snapshot, transport dispose once.
    private fun teardownLocked() {
        if (!teardownDone.compareAndSet(false, true)) return
        cancelled.set(true)
        shutdownAndJoinFocusMonitorUnlocked()
        shutdownAndJoinRoutingMonitorUnlocked()
        val s = sink
        val f = feed
        s?.cancel()
        if (f != null) cancelDecoder()
        sinkJoined = s?.join(JOIN_TIMEOUT_MS) ?: true
        decoderJoined = f?.join(JOIN_TIMEOUT_MS) ?: true
        val machine = transport
        if (machine != null) {
            val before = machine.currentState
            // Native stop discards the output ring and zeroes drained/EOS
            // accounting. For a completed playthrough the terminal reply is
            // the pre-stop EOS drain (sink's last reply, else a pre-stop
            // snapshot); it must be captured before stop() can reset it.
            val preStopReply: Reply? =
                if (before == TransportState.COMPLETED || state == State.COMPLETED) {
                    s?.telemetry()?.lastReply?.takeIf { it.eosDrained } ?: machine.snapshot().reply
                } else {
                    null
                }
            if (sinkJoined && decoderJoined &&
                (before == TransportState.PREPARED || before == TransportState.PLAYING ||
                    before == TransportState.PAUSED || before == TransportState.COMPLETED)
            ) {
                val res = machine.stop()
                commandsIssued++
                transportStopAccepted = res.accepted && res.state == TransportState.STOPPED
            }
            val snap = machine.snapshot()
            terminalReply = preStopReply ?: snap.reply ?: s?.telemetry()?.lastReply
            transportStateBeforeDispose = machine.currentState
            machine.dispose()
            transportDisposeCalls++
            transportStateAfterDispose = machine.currentState
        }
        // Y21 ring/driver route (class comment): no transport exists on
        // this route (`machine` stays null above), so transportStopAccepted
        // / transportDisposeCalls / the transport state fields are left
        // untouched here; the driver's own bounded close replaces transport
        // stop/dispose, and its terminal reply comes from the sink's own
        // last drain reply (no native transport snapshot to fall back to).
        val d = driver
        if (d != null) {
            driverClosed = d.close(JOIN_TIMEOUT_MS)
            // Guard against a self-join from the driver's own owner thread:
            // [VanguardRealtimeAudioPlaybackTransportDriver.close] already
            // returns false (never blocks) when called from that thread, so
            // a false result here is treated the same as any other bounded-
            // close failure, with the driver's own typed reason preserved.
            if (!driverClosed) recordFailure("driver:close_failed:${d.exitReason}")
            if (state == State.COMPLETED) terminalReply = s?.telemetry()?.lastReply
        }
        if (sessionStartedAtMs >= 0L) sessionWallMs = SystemClock.elapsedRealtime() - sessionStartedAtMs
    }

    // ── Y11b production focus/noisy response internals ─────────────────────

    // Command-lock holder only, called from [teardownLocked]. Releases
    // commandLock while joining so the monitor thread (whose only lock use
    // is a short, bounded commandLock.withLock around one focus event) can
    // finish its current transition and observe the shutdown flag, then
    // reacquires the lock before returning (matched unlock/lock pair; every
    // teardownLocked() caller already holds commandLock exactly once here).
    // Never joins the monitor from its own thread (its own fail-closed path
    // re-enters teardownLocked on that same thread).
    private fun shutdownAndJoinFocusMonitorUnlocked() {
        val controller = focusController ?: return
        focusMonitorShutdown.set(true)
        val t = focusMonitorThread
        if (t != null && t.isAlive && Thread.currentThread() !== t) {
            t.interrupt()
            commandLock.unlock()
            try {
                t.join(config.focusMonitorJoinMs)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } finally {
                commandLock.lock()
            }
        }
        focusMonitorJoined = t == null || !t.isAlive
        controller.release()
    }

    // The session's ONE focus monitor thread and the controller's ONE event
    // consumer (Opus Option B). Bounded-slices on the controller's queue so
    // [focusMonitorShutdown] / [cancelled] are re-checked regularly; never
    // holds commandLock across that wait, only around one event's
    // transport-command reaction.
    private fun runFocusMonitor() {
        focusMonitorThreadId = Thread.currentThread().id
        val controller = focusController
        if (controller == null) {
            focusMonitorExited = true
            return
        }
        var lastDropped = controller.droppedCount
        try {
            while (!focusMonitorShutdown.get() && !cancelled.get()) {
                val event = try {
                    controller.awaitEvent(config.focusEventPollMs) { !focusMonitorShutdown.get() && !cancelled.get() }
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    null
                }
                if (focusMonitorShutdown.get() || cancelled.get()) break
                if (event != null) handleFocusEvent(event)
                val dropped = controller.droppedCount
                if (dropped > lastDropped) {
                    lastDropped = dropped
                    handleDroppedEventPark()
                }
            }
        } catch (t: Throwable) {
            commandLock.withLock { failClosed("focus_monitor_exception:${t.javaClass.simpleName}:${t.message}") }
        } finally {
            focusMonitorExited = true
        }
    }

    // Focus monitor thread only. One event, one reaction (class comment /
    // functional requirement 5): duck and gain-restore only round-trip the
    // sink's gain queue; every pause reaction runs the SAME bounded pause
    // order as the public API via [pauseBoundedLocked], gated by whether the
    // transport is actually PLAYING (a no-op reject when it is not).
    private fun handleFocusEvent(event: VanguardRealtimePlaybackAudioFocusController.Event) {
        lastFocusEventTag = event.tag.name
        lastFocusEventSeq = event.seq
        lastFocusEventSource = event.source.name
        lastFocusReason = event.tag.name.lowercase()
        when (event.tag) {
            FocusTag.FOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                focusState = "ducked"
                lastFocusAction = "duck"
                if (applyFocusGain(config.duckGain, "focus_duck_gain")) focusDuckAppliedCount++
            }
            FocusTag.FOCUS_GAIN -> {
                focusState = "held"
                lastFocusAction = "gain_restore"
                if (applyFocusGain(config.gain, "focus_gain_restore")) {
                    focusGainRestoreAppliedCount++
                    // Auto-resume only when the user still wants to play, the
                    // pause was ours, we are actually PAUSED and neither
                    // terminal-loss flag is set (functional requirement 4).
                    commandLock.withLock {
                        // Y12: a terminal route disconnect blocks this
                        // auto-resume the same way it blocks a public
                        // [resume] call, without clearing the flag.
                        if (userIntentPlaying && focusPausedByPolicy && state == State.PAUSED &&
                            !focusTerminalPermanentLoss && !focusTerminalNoisyLoss && !routingTerminalDisconnect
                        ) {
                            if (resumeLocked().accepted) {
                                lastFocusAction = "auto_resume"
                                lastFocusReason = "focus_gain_auto_resume"
                                focusAutoResumeAppliedCount++
                            }
                        }
                    }
                }
            }
            FocusTag.FOCUS_LOSS_TRANSIENT -> {
                focusState = "lost_transient"
                lastFocusAction = "pause_transient"
                commandLock.withLock {
                    if (pauseBoundedLocked().accepted) {
                        focusPausedByPolicy = true
                        focusPauseTransientAppliedCount++
                    }
                }
            }
            FocusTag.FOCUS_LOSS_PERMANENT -> {
                focusState = "lost_permanent"
                focusTerminalPermanentLoss = true
                lastFocusAction = "pause_permanent"
                commandLock.withLock {
                    if (pauseBoundedLocked().accepted) focusPausePermanentAppliedCount++
                }
            }
            FocusTag.BECOMING_NOISY -> {
                focusState = "noisy"
                focusTerminalNoisyLoss = true
                lastFocusAction = "pause_noisy"
                commandLock.withLock {
                    if (pauseBoundedLocked().accepted) focusPauseNoisyAppliedCount++
                }
            }
            FocusTag.FOCUS_UNKNOWN -> {
                focusUnknownEventCount++
                lastFocusAction = "unknown_ignored"
            }
        }
    }

    // Focus monitor thread only: the controller's queue was full at offer()
    // time, so the dropped event itself is unrecoverable; treated as a
    // transient loss/park (functional requirement 5).
    private fun handleDroppedEventPark() {
        lastFocusAction = "dropped_park"
        lastFocusReason = "queue_dropped_event"
        commandLock.withLock {
            if (pauseBoundedLocked().accepted) {
                focusPausedByPolicy = true
                focusPauseDroppedParkAppliedCount++
            }
        }
    }

    // Focus monitor thread only: any-thread gain round-trip through the
    // sink bridge's queued volume request (never an AudioTrack call here,
    // Opus Option B). A rejected request or a timed-out ack fails the whole
    // session closed with a focus-tagged reason, same as every other
    // unrecoverable condition in this class.
    private fun applyFocusGain(target: Float, reasonPrefix: String): Boolean {
        focusGainRequestCount++
        val s = sink
        if (s == null) {
            focusGainFailCount++
            commandLock.withLock { failClosed("${reasonPrefix}_sink_missing") }
            return false
        }
        val seq = s.requestGain(target)
        if (seq < 0L) {
            focusGainFailCount++
            commandLock.withLock { failClosed("${reasonPrefix}_request_rejected") }
            return false
        }
        if (!s.awaitGainApplied(seq, config.focusGainApplyTimeoutMs)) {
            focusGainFailCount++
            commandLock.withLock { failClosed("${reasonPrefix}_apply_timeout") }
            return false
        }
        focusGainAppliedCount++
        return true
    }

    // Any thread, lock-free: mirrors the controller's own counters live
    // (its accessors stay valid after release()) plus this session's
    // single-writer bookkeeping. Disabled / not-yet-set-up sessions report
    // enabled=false / empty defaults without needing a separate branch.
    private fun buildFocusTelemetry(): VanguardRealtimeAudioPlaybackFocusTelemetry {
        val controller = focusController
        val tel = controller?.telemetry()
        return VanguardRealtimeAudioPlaybackFocusTelemetry(
            enabled = config.enableAudioFocusResponse,
            controllerRequested = controller?.isFocusRequested ?: false,
            controllerGranted = controller?.isFocusGranted ?: false,
            controllerRequestResult = (tel?.get("focusRequestResult") as? Int)
                ?: VanguardRealtimePlaybackAudioFocusController.RESULT_NOT_ATTEMPTED,
            controllerRequestError = (tel?.get("focusRequestError") as? String) ?: "",
            controllerNoisyRegistered = controller?.isReceiverRegistered ?: false,
            controllerRegisterError = (tel?.get("receiverRegisterError") as? String) ?: "",
            controllerReleased = controller?.isReleased ?: false,
            monitorStarted = focusMonitorStarted,
            monitorExited = focusMonitorExited,
            monitorJoined = focusMonitorJoined,
            monitorThreadId = focusMonitorThreadId,
            eventsEnqueued = controller?.enqueuedCount ?: 0L,
            eventsDrained = controller?.drainedCount ?: 0L,
            eventsDropped = controller?.droppedCount ?: 0L,
            eventsPending = controller?.pendingCount ?: 0,
            duckAppliedCount = focusDuckAppliedCount,
            gainRestoreAppliedCount = focusGainRestoreAppliedCount,
            pauseTransientAppliedCount = focusPauseTransientAppliedCount,
            pausePermanentAppliedCount = focusPausePermanentAppliedCount,
            pauseNoisyAppliedCount = focusPauseNoisyAppliedCount,
            pauseDroppedParkAppliedCount = focusPauseDroppedParkAppliedCount,
            autoResumeAppliedCount = focusAutoResumeAppliedCount,
            unknownEventCount = focusUnknownEventCount,
            gainRequestCount = focusGainRequestCount,
            gainAppliedCount = focusGainAppliedCount,
            gainFailCount = focusGainFailCount,
            focusState = focusState,
            userIntentPlaying = userIntentPlaying,
            focusPausedByPolicy = focusPausedByPolicy,
            terminalPermanentLoss = focusTerminalPermanentLoss,
            terminalNoisyLoss = focusTerminalNoisyLoss,
            lastEventTag = lastFocusEventTag,
            lastEventSeq = lastFocusEventSeq,
            lastEventSource = lastFocusEventSource,
            lastAction = lastFocusAction,
            lastReason = lastFocusReason,
        )
    }

    // ── Y12 production route-change/disconnect response internals ──────────

    // Command-lock holder only, called from [teardownLocked]. Mirrors
    // [shutdownAndJoinFocusMonitorUnlocked]: releases commandLock while
    // joining the routing monitor thread (whose only lock use is a short,
    // bounded commandLock.withLock around one ROUTE_DISCONNECT reaction),
    // then reacquires the lock before returning. Never joins the monitor
    // from its own thread. Release here is idempotent even though the sink
    // bridge already releases the SAME controller before its own final
    // AudioTrack release (class comment); whichever runs first performs the
    // actual listener detach.
    private fun shutdownAndJoinRoutingMonitorUnlocked() {
        val controller = routingController ?: return
        routingMonitorShutdown.set(true)
        val t = routingMonitorThread
        if (t != null && t.isAlive && Thread.currentThread() !== t) {
            t.interrupt()
            commandLock.unlock()
            try {
                t.join(config.routingMonitorJoinMs)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } finally {
                commandLock.lock()
            }
        }
        routingMonitorJoined = t == null || !t.isAlive
        controller.release()
    }

    // The session's ONE routing monitor thread and the controller's ONE
    // event consumer (mirrors [runFocusMonitor], Opus Option B).
    // Bounded-slices on the controller's queue so [routingMonitorShutdown] /
    // [cancelled] are re-checked regularly; never holds commandLock across
    // that wait, only around one event's transport-command reaction.
    private fun runRoutingMonitor() {
        routingMonitorThreadId = Thread.currentThread().id
        val controller = routingController
        if (controller == null) {
            routingMonitorExited = true
            return
        }
        var lastDropped = controller.droppedCount
        try {
            while (!routingMonitorShutdown.get() && !cancelled.get()) {
                val event = try {
                    controller.awaitEvent(config.routingEventPollMs) { !routingMonitorShutdown.get() && !cancelled.get() }
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    null
                }
                if (routingMonitorShutdown.get() || cancelled.get()) break
                if (event != null) handleRoutingEvent(event)
                val dropped = controller.droppedCount
                if (dropped > lastDropped) {
                    lastDropped = dropped
                    handleRoutingEventDropped()
                }
            }
        } catch (t: Throwable) {
            commandLock.withLock { failClosed("routing_monitor_exception:${t.javaClass.simpleName}:${t.message}") }
        } finally {
            routingMonitorExited = true
        }
    }

    // Routing monitor thread only. ROUTE_CHANGED is observation-only
    // (telemetry: applied count, last seq/source/action); no transport
    // command runs for it. ROUTE_DISCONNECT is a terminal fail-closed pause
    // (class comment): set the terminal flag first (so it stays set even if
    // the transport was already PAUSED for another reason, and no racing
    // resume can slip past it), then pause through the SAME bounded pause
    // order as the public API only when PLAYING; the applied count and
    // [routingPausedByPolicy] are only bumped on an accepted pause.
    private fun handleRoutingEvent(event: VanguardRealtimePlaybackRoutingController.Event) {
        lastRoutingEventTag = event.tag.name
        lastRoutingEventSeq = event.seq
        lastRoutingEventSource = event.source.name
        when (event.tag) {
            RoutingTag.ROUTE_CHANGED -> {
                lastRoutingAction = "observed"
                lastRoutingReason = "route_changed"
                routeChangedAppliedCount++
            }
            RoutingTag.ROUTE_DISCONNECT -> {
                lastRoutingAction = "terminal_disconnect"
                lastRoutingReason = "route_disconnect"
                routingTerminalDisconnect = true
                commandLock.withLock {
                    // Already PAUSED (e.g. by focus policy): the terminal
                    // flag above still stands; no pause is attempted here
                    // and the FOCUS_GAIN auto-resume gate now also checks
                    // !routingTerminalDisconnect, so nothing auto-resumes it.
                    if (state == State.PLAYING) {
                        if (pauseBoundedLocked().accepted) {
                            routingPausedByPolicy = true
                            routeDisconnectAppliedCount++
                        }
                    }
                }
            }
        }
    }

    // Routing monitor thread only: the controller's queue was full at
    // offer() time, so the dropped event's routing consequence for the
    // current output device is unknown and unrecoverable; unlike the focus
    // monitor's queue-drop (which only parks), this fails the whole session
    // closed (class comment).
    private fun handleRoutingEventDropped() {
        lastRoutingAction = "dropped_fail_closed"
        lastRoutingReason = "routing_event_dropped"
        commandLock.withLock { failClosed("routing_event_dropped") }
    }

    // Any thread, lock-free: mirrors the controller's own counters live
    // (its accessors stay valid after release()) plus this session's
    // single-writer bookkeeping. Disabled / not-yet-set-up sessions report
    // enabled=false / empty defaults without needing a separate branch.
    private fun buildRoutingTelemetry(): VanguardRealtimeAudioPlaybackRoutingTelemetry {
        val controller = routingController
        return VanguardRealtimeAudioPlaybackRoutingTelemetry(
            enabled = config.enableAudioRoutingResponse,
            controllerAttached = controller?.isAttached ?: false,
            controllerReleased = controller?.isReleased ?: false,
            attachCount = controller?.attachCount ?: 0,
            detachCount = controller?.detachCount ?: 0,
            lastAttachError = controller?.lastAttachError ?: "",
            lastDetachError = controller?.lastDetachError ?: "",
            monitorStarted = routingMonitorStarted,
            monitorExited = routingMonitorExited,
            monitorJoined = routingMonitorJoined,
            monitorThreadId = routingMonitorThreadId,
            eventsEnqueued = controller?.enqueuedCount ?: 0L,
            eventsDrained = controller?.drainedCount ?: 0L,
            eventsDropped = controller?.droppedCount ?: 0L,
            eventsPending = controller?.pendingCount ?: 0,
            routeChangedAppliedCount = routeChangedAppliedCount,
            routeDisconnectAppliedCount = routeDisconnectAppliedCount,
            routingTerminalDisconnect = routingTerminalDisconnect,
            routingPausedByPolicy = routingPausedByPolicy,
            lastEventTag = lastRoutingEventTag,
            lastEventSeq = lastRoutingEventSeq,
            lastEventSource = lastRoutingEventSource,
            lastAction = lastRoutingAction,
            lastReason = lastRoutingReason,
        )
    }

    private fun remainingMs(): Long = maxOf(1L, deadlineAtMs - SystemClock.elapsedRealtime())

    private fun checkDeadlineAndCancel() {
        if (cancelled.get()) throw FailClosed("cancelled")
        if (SystemClock.elapsedRealtime() > deadlineAtMs) throw FailClosed("deadline_exceeded")
    }

    private fun sleepSlice() {
        try {
            Thread.sleep(WAIT_SLICE_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }
}
