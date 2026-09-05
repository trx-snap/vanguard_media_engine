package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State as TransportState

// ── VanguardRealtimeAudioPlaybackSeekSequencer (Y10a modularity prep;
//    Y10b-1a repeated-seek) ──────────────────────────────────────────────
//
// Behavior-identical extraction of the Y9 seek step sequence and its
// bookkeeping, previously inline in [VanguardRealtimeAudioPlaybackSession].
// Owns no thread of its own: every step runs synchronously on whichever
// thread calls [run] (the session's command-lock holder, i.e. the caller's
// thread). It issues transport/sink/feed commands in the exact fixed Y9
// order documented on the session, once per ordered seek; the session still
// owns admission (arming, hold-frame pin), the public `seek(targetFrame)`
// gate checks, and state transitions around [run]. Scalar bookkeeping
// fields are overwritten by every [run] call and so alias the LAST
// completed seek; the session issues seeks one at a time to completion, so
// no field is ever read mid-run for a seek other than the one in flight.
//
// Y10b-1a (repeated seek), additive: [run] takes a zero-based `index` (0 for
// the first of up to two ordered seeks, 1 for the second) plus two hold
// frames that coincide for the first seek and diverge for the second:
// `contentHoldFrame` is the decoder/native POSITION domain (what the feed's
// anchor and the native snapshot's positionFrame reach, jumping to each
// seek's target); `sinkHoldFrame` is the cumulative SINK domain (what the
// sink's read/write counters and the native snapshot's pushed/drained
// counters reach, which keep counting forward through a seek jump instead
// of resetting to it). For the first seek the two coincide (H1); for the
// second, sinkHoldFrame = H1 + (H2 - T1) while contentHoldFrame = H2. Every
// per-seek sink/feed command (park, flush, transport.seek, reanchor,
// unpark) is counted cumulatively by its own bridge/feed across the whole
// session, so this sequencer checks each one against `index + 1` rather
// than a fixed 1.
//
// Y17 (P4-AUDIO-REALTIME-PLAYBACK-PRODUCTION-BACKWARD-SEEK), additive: [run]
// takes `backward`; the step order, every wait, every native/transport
// accounting check and the read-budget arithmetic (sink hold + declared - T)
// are direction-agnostic, so a backward seek runs the SAME fixed sequence.
// The direction is only DECLARED downstream -- to the sink's requestFlush
// (which then opens the seek epoch through the clock's declared-backward
// entry point at unpark) and to the feed's re-anchor request (which
// validates 0 <= T < H) -- and echoed back through sink telemetry, which
// this sequencer checks matches the declaration. No clock snapshot ever
// gates a step here (no-feedback rule); the clock snapshots taken at park /
// before / after unpark stay telemetry.
class VanguardRealtimeAudioPlaybackSeekSequencer(
    private val config: Config,
    private val host: Host,
) {

    data class Config(val maxFramesPerMix: Int)

    // Session-owned facilities the sequencer needs without owning the
    // session's lock, deadline, cancel flag or failure record itself.
    interface Host {
        // Non-null exactly when [VanguardRealtimeAudioPlaybackSession]'s own
        // checkDeadlineAndCancel()/failure would reject a seek wait: mirrors
        // "cancelled" / "deadline_exceeded" / the recorded failure, in that order.
        fun pollSeekWaitReason(): String?
        fun noteCommandIssued()
    }

    companion object {
        private const val WAIT_SLICE_MS = 5L
        private const val PARK_ACK_TIMEOUT_MS = 2_000L
        private const val UNPARK_ACK_TIMEOUT_MS = 2_000L
        private const val INITIAL_WRITE_WAIT_MS = 2_000L
        private const val QUIESCE_WAIT_MS = 10_000L
        private const val SNAPSHOT_SETTLE_WAIT_MS = 2_000L
        private const val FLUSH_ACK_TIMEOUT_MS = 2_000L
        private const val REANCHOR_WAIT_MS = 5_000L
        private const val POST_SEEK_PREROLL_WAIT_MS = 5_000L
    }

    private class FailClosed(val reason: String) : Exception(reason)

    // ── Bookkeeping (command-lock holder writes; published through the
    // session's snapshot()) ─────────────────────────────────────────────────

    @Volatile var seekAccepted = false
        private set
    @Volatile var seekStaleGeneration = -1L
        private set
    @Volatile var seekGeneration = -1L
        private set
    @Volatile var seekPauseAccepted = false
        private set
    @Volatile var seekPauseGeneration = -1L
        private set
    @Volatile var seekResumeAccepted = false
        private set
    @Volatile var seekResumeGeneration = -1L
        private set
    @Volatile var seekInitialWriteWaitMs = -1L
        private set
    @Volatile var seekQuiesceWaitMs = -1L
        private set
    @Volatile var seekQuiesceFeedHeld = false
        private set
    @Volatile var seekQuiesceSinkReadFrames = -1L
        private set
    @Volatile var seekQuiesceSinkWrittenFrames = -1L
        private set
    @Volatile var seekQuiesceAccountingOk = false
        private set
    @Volatile var seekPreSeekSettleMs = -1L
        private set
    @Volatile var seekPreSeekReply: Reply? = null
        private set
    @Volatile var seekPreSeekTransportState: TransportState? = null
        private set
    @Volatile var seekPostPauseReply: Reply? = null
        private set
    @Volatile var seekFlushRequestedWhilePaused = false
        private set
    @Volatile var seekFlushAckWaitMs = -1L
        private set
    @Volatile var seekFlushAckedBeforeSeek = false
        private set
    @Volatile var seekSinkPhaseAtSeek = ""
        private set
    @Volatile var seekPostSeekReply: Reply? = null
        private set
    @Volatile var seekPostSeekTransportState: TransportState? = null
        private set
    @Volatile var seekReanchorWaitMs = -1L
        private set
    @Volatile var seekPostSeekPreRollWaitMs = -1L
        private set
    @Volatile var seekPostSeekPreRollReply: Reply? = null
        private set
    @Volatile var seekPostSeekPreRollTransportState: TransportState? = null
        private set
    @Volatile var seekTransportStateAtUnpark: TransportState? = null
        private set
    @Volatile var seekParkRequestedAtMs = -1L
        private set
    @Volatile var seekParkAckedAtMs = -1L
        private set
    @Volatile var seekUnparkedAtMs = -1L
        private set
    @Volatile var seekResumedAtMs = -1L
        private set
    @Volatile var seekHoldObservedMs = -1L
        private set
    @Volatile var seekWallMs = -1L
        private set
    @Volatile var seekClockAtPark: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
        private set
    @Volatile var seekClockBeforeUnpark: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
        private set
    @Volatile var seekClockAfterUnpark: VanguardRealtimePlaybackPresentationClock.Snapshot? = null
        private set
    // Y17: direction the last [run] declared to the sink/feed (false on every forward run).
    @Volatile var seekDeclaredBackward = false
        private set

    // Runs the fixed Y9 order once for ONE ordered seek (command-lock holder,
    // state SEEKING). `index` is 0 for the first of up to two ordered seeks,
    // 1 for the second; `nextContentHoldFrame` is the next content hold the
    // feed idles at after this seek's re-anchor (H2 for the first seek of a
    // repeated run, else Long.MAX_VALUE for the run's final seek). Y17:
    // `backward` declares 0 <= T < contentHoldFrame (class comment); the
    // session admits the direction, this only forwards and echoes it.
    // Returns null on success (every step verified), else the failure reason
    // (the session fails closed and tears down with it).
    fun run(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        f: VanguardRealtimePlaybackDecoderFeed,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        declaredFrameCount: Long,
        index: Int,
        contentHoldFrame: Long,
        sinkHoldFrame: Long,
        targetFrame: Long,
        nextContentHoldFrame: Long,
        backward: Boolean = false,
    ): String? = try {
        val seekStartedAt = SystemClock.elapsedRealtime()
        seekDeclaredBackward = backward
        if (backward && nextContentHoldFrame != Long.MAX_VALUE) throw FailClosed("backward_seek_next_hold_unsupported:$nextContentHoldFrame")
        if (backward && (targetFrame < 0L || targetFrame >= contentHoldFrame)) {
            throw FailClosed("backward_seek_target_not_below_hold:$targetFrame:$contentHoldFrame")
        }
        // The pause below must not itself advance the generation (only
        // start/seek/stop do); this is the baseline it is checked against,
        // captured fresh per seek since a prior seek in the same run already
        // advanced the transport's generation by one.
        val entryGeneration = machine.currentGeneration
        awaitInitialWritesLocked(s, machine)
        awaitQuiescenceLocked(f, s, machine, contentHoldFrame, sinkHoldFrame)
        parkForSeekLocked(s, index)
        verifyPreSeekQuiescenceLocked(f, s, machine, contentHoldFrame, sinkHoldFrame)
        pauseForSeekLocked(machine, sinkHoldFrame, entryGeneration)
        flushSinkLocked(s, machine, declaredFrameCount, sinkHoldFrame, targetFrame, index, backward)
        seekTransportLocked(s, machine, sinkHoldFrame, targetFrame, index)
        reanchorFeedLocked(f, machine, contentHoldFrame, sinkHoldFrame, targetFrame, index, nextContentHoldFrame, backward)
        unparkSinkLocked(s, machine, targetFrame, index, backward)
        resumeAfterSeekLocked(s, machine)
        seekWallMs = SystemClock.elapsedRealtime() - seekStartedAt
        null
    } catch (fc: FailClosed) {
        fc.reason
    } catch (t: Throwable) {
        "exception:${t.javaClass.simpleName}:${t.message}"
    }

    // ── Y9 seek steps (command-lock holder, state SEEKING) ─────────────────

    private fun snapshotReplyLocked(phase: String, machine: VanguardRealtimePlaybackTransportStateMachine): Reply {
        val res = machine.snapshot()
        if (!res.accepted) throw FailClosed("snapshot_rejected_$phase:${res.reason}")
        return res.reply ?: throw FailClosed("snapshot_null_reply_$phase")
    }

    private fun pollSeekWait() {
        host.pollSeekWaitReason()?.let { throw FailClosed(it) }
    }

    private fun sleepSlice() {
        try {
            Thread.sleep(WAIT_SLICE_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    // The seek must land on a really playing sink.
    private fun awaitInitialWritesLocked(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
    ) {
        val waitStart = SystemClock.elapsedRealtime()
        val waitDeadline = waitStart + INITIAL_WRITE_WAIT_MS
        while (!s.hasPlayed || s.framesWritten <= 0L) {
            pollSeekWait()
            if (!s.isAlive) throw FailClosed("sink_exited_before_first_write:${s.currentExitReason}")
            if (SystemClock.elapsedRealtime() > waitDeadline) throw FailClosed("no_initial_sink_write")
            sleepSlice()
        }
        seekInitialWriteWaitMs = SystemClock.elapsedRealtime() - waitStart
        val transportState = machine.currentState
        if (transportState != TransportState.PLAYING) throw FailClosed("seek_precondition_state:${transportState.name.lowercase()}")
    }

    // Feed held at the content hold and sink read (hence written: a park
    // follows a fully written window) up to the cumulative sink hold,
    // transport PLAYING, sink RUNNING. The two hold values coincide for the
    // first seek of a run and diverge for the second (class comment).
    private fun awaitQuiescenceLocked(
        f: VanguardRealtimePlaybackDecoderFeed,
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        contentHold: Long,
        sinkHold: Long,
    ) {
        val waitStart = SystemClock.elapsedRealtime()
        val waitDeadline = waitStart + QUIESCE_WAIT_MS
        while (!(f.heldAtHoldFrame && f.anchorFrame == contentHold && s.framesRead == sinkHold)) {
            pollSeekWait()
            if (!s.isAlive) throw FailClosed("sink_exited_before_quiesce:${s.currentExitReason}")
            if (!f.isAlive) throw FailClosed("feed_exited_before_quiesce:${f.exitReason}")
            if (s.framesRead > sinkHold) throw FailClosed("sink_read_past_hold:${s.framesRead}:$sinkHold")
            if (machine.currentState != TransportState.PLAYING) throw FailClosed("quiesce_state:${machine.currentState.name.lowercase()}")
            if (s.phase != VanguardRealtimeAudioPlaybackSinkBridge.Phase.RUNNING) throw FailClosed("quiesce_sink_phase:${s.phase.name.lowercase()}")
            if (SystemClock.elapsedRealtime() > waitDeadline) {
                throw FailClosed(
                    "quiesce_timeout:anchor=${f.anchorFrame}:held=${f.heldAtHoldFrame}:read=${s.framesRead}:" +
                        "contentHold=$contentHold:sinkHold=$sinkHold",
                )
            }
            sleepSlice()
        }
        seekQuiesceWaitMs = SystemClock.elapsedRealtime() - waitStart
        seekQuiesceFeedHeld = f.heldAtHoldFrame
        seekQuiesceSinkReadFrames = s.framesRead
    }

    // Seek park: AudioTrack paused on the sink thread, epoch closed at the
    // last published position, hold capped by maxSeekHoldMs. Park/seek-park
    // counts are cumulative across the whole session, so the expected count
    // is this seek's 1-based ordinal (index + 1).
    private fun parkForSeekLocked(s: VanguardRealtimeAudioPlaybackSinkBridge, index: Int) {
        val expectedCount = index + 1
        seekParkRequestedAtMs = SystemClock.elapsedRealtime()
        if (!s.requestSeekPark()) throw FailClosed("sink_seek_park_rejected:${s.phase.name.lowercase()}")
        val ackDeadline = seekParkRequestedAtMs + PARK_ACK_TIMEOUT_MS
        while (!s.awaitParked(WAIT_SLICE_MS)) {
            pollSeekWait()
            if (!s.isAlive) throw FailClosed("sink_exited_before_seek_park_ack:${s.currentExitReason}")
            if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_seek_park_ack_timeout")
        }
        seekParkAckedAtMs = SystemClock.elapsedRealtime()
        seekClockAtPark = s.clockSnapshot()
        val k = s.telemetry()
        if (k.playStateAtPark != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("sink_not_paused_at_seek_park:${k.playStateAtPark}")
        if (k.parkCount != expectedCount || k.seekParkCount != expectedCount) {
            throw FailClosed("sink_seek_park_count:${k.parkCount}:${k.seekParkCount}:$expectedCount")
        }
        seekQuiesceSinkWrittenFrames = s.framesWritten
    }

    // Pre-seek native snapshot: position == content hold, pushed == drained
    // == cumulative sink hold, discarded 0, output ring empty, native
    // PLAYING, sink PARKED, transport PLAYING. [f.acceptedFrames] is a
    // cumulative decode-thread counter (sink domain, unaffected by a seek's
    // position jump), so it is checked against the sink hold too.
    private fun verifyPreSeekQuiescenceLocked(
        f: VanguardRealtimePlaybackDecoderFeed,
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        contentHold: Long,
        sinkHold: Long,
    ) {
        val window = config.maxFramesPerMix.toLong()
        val settleStart = SystemClock.elapsedRealtime()
        val settleDeadline = settleStart + SNAPSHOT_SETTLE_WAIT_MS
        var snap: Reply
        while (true) {
            snap = snapshotReplyLocked("pre_seek", machine)
            if (snap.pushedFrames == sinkHold && snap.drainedFrames == sinkHold && snap.positionFrame == contentHold) break
            pollSeekWait()
            if (SystemClock.elapsedRealtime() > settleDeadline) {
                throw FailClosed(
                    "pre_seek_snapshot_unsettled:pos=${snap.positionFrame}:pushed=${snap.pushedFrames}:drained=${snap.drainedFrames}:" +
                        "contentHold=$contentHold:sinkHold=$sinkHold",
                )
            }
            sleepSlice()
        }
        seekPreSeekSettleMs = SystemClock.elapsedRealtime() - settleStart
        seekPreSeekReply = snap
        val transportState = machine.currentState
        seekPreSeekTransportState = transportState
        val d = f.seekTelemetry()
        // contentHold is a post-seek epoch window boundary relative to the
        // prior seek's target for the second seek of a repeated run (class
        // comment), not necessarily absolute-frame-grid aligned; only the
        // cumulative sinkHold is required window-aligned here.
        seekQuiesceAccountingOk = sinkHold % window == 0L &&
            d.anchorFrame == contentHold && d.heldAtHoldFrame && d.acceptedFrames == sinkHold &&
            snap.state == NativeState.PLAYING && transportState == TransportState.PLAYING &&
            snap.positionFrame == contentHold && snap.pushedFrames == sinkHold && snap.drainedFrames == sinkHold &&
            snap.discardedFrames == 0L && snap.outputAvailableReadFrames == 0L &&
            !snap.eosPushed && !snap.eosDrained &&
            s.framesRead == sinkHold && s.framesWritten == sinkHold &&
            s.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED
        if (!seekQuiesceAccountingOk) {
            throw FailClosed(
                "seek_quiesce_accounting:contentHold=$contentHold:sinkHold=$sinkHold:anchor=${d.anchorFrame}:held=${d.heldAtHoldFrame}:" +
                    "accepted=${d.acceptedFrames}:native=${snap.stateToken}:transport=${transportState.name.lowercase()}:" +
                    "pos=${snap.positionFrame}:pushed=${snap.pushedFrames}:drained=${snap.drainedFrames}:discarded=${snap.discardedFrames}:" +
                    "avail=${snap.outputAvailableReadFrames}:read=${s.framesRead}:written=${s.framesWritten}:sink=${s.phase.name.lowercase()}",
            )
        }
    }

    // transport.pause after the sink park; PAUSED recheck with the cumulative
    // sink hold's pushed/drained accounting unchanged.
    private fun pauseForSeekLocked(machine: VanguardRealtimePlaybackTransportStateMachine, sinkHold: Long, entryGeneration: Long) {
        val res = machine.pause()
        host.noteCommandIssued()
        seekPauseAccepted = res.accepted && res.state == TransportState.PAUSED
        seekPauseGeneration = machine.currentGeneration
        if (!seekPauseAccepted) throw FailClosed("seek_pause_rejected:${res.reason}")
        if (seekPauseGeneration != entryGeneration) throw FailClosed("seek_pause_generation_moved:$entryGeneration:$seekPauseGeneration")
        val snap = snapshotReplyLocked("post_pause", machine)
        seekPostPauseReply = snap
        if (snap.state != NativeState.PAUSED || snap.pushedFrames != sinkHold ||
            snap.drainedFrames != sinkHold || snap.discardedFrames != 0L
        ) {
            throw FailClosed("post_pause_accounting:${snap.stateToken}:${snap.pushedFrames}:${snap.drainedFrames}:${snap.discardedFrames}")
        }
    }

    // AudioTrack.flush() once on the sink thread while sink PARKED/PAUSED and
    // transport PAUSED; read budget becomes the cumulative sink hold +
    // (declared - T). Flush/park counts are cumulative across the whole
    // session, so the expected count is this seek's 1-based ordinal. Y17: the
    // seek direction is declared to the sink here (with the flush request)
    // and must be echoed back by its telemetry.
    private fun flushSinkLocked(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        declared: Long,
        sinkHold: Long,
        targetFrame: Long,
        index: Int,
        backward: Boolean,
    ) {
        val target = targetFrame
        val expectedCount = index + 1
        if (machine.currentState != TransportState.PAUSED) throw FailClosed("flush_before_transport_pause:${machine.currentState.name.lowercase()}")
        if (s.phase != VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED) throw FailClosed("flush_before_sink_park:${s.phase.name.lowercase()}")
        seekFlushRequestedWhilePaused = true
        val flushAt = SystemClock.elapsedRealtime()
        if (!s.requestFlush(declared - target, target, backward)) throw FailClosed("sink_flush_request_rejected:${s.phase.name.lowercase()}")
        val ackDeadline = flushAt + FLUSH_ACK_TIMEOUT_MS
        while (!s.awaitFlushed(WAIT_SLICE_MS, expectedCount)) {
            pollSeekWait()
            if (!s.isAlive) throw FailClosed("sink_exited_before_flush_ack:${s.currentExitReason}")
            if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_flush_ack_timeout:${s.currentFlushCount}:$expectedCount")
        }
        seekFlushAckWaitMs = SystemClock.elapsedRealtime() - flushAt
        val k = s.telemetry()
        val ok = k.flushCount == expectedCount && k.flushRequestCount == expectedCount && k.flushExecutedOnSinkThread &&
            k.playStateBeforeFlush == AudioTrack.PLAYSTATE_PAUSED && k.playStateAfterFlush == AudioTrack.PLAYSTATE_PAUSED &&
            k.framesWrittenAtFlush == sinkHold && k.framesReadAtFlush == sinkHold &&
            k.postSeekExpectedFrames == declared - target && k.readBudgetFrames == sinkHold + (declared - target) &&
            k.seekTargetFrame == target && k.timestampPollsDuringFlush == 0L && k.seekDeclaredBackward == backward &&
            s.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED && machine.currentState == TransportState.PAUSED
        if (!ok) {
            throw FailClosed(
                "sink_flush_verification:count=${k.flushCount}:requests=${k.flushRequestCount}:before=${k.playStateBeforeFlush}:" +
                    "after=${k.playStateAfterFlush}:written=${k.framesWrittenAtFlush}:read=${k.framesReadAtFlush}:" +
                    "expected=${k.postSeekExpectedFrames}:budget=${k.readBudgetFrames}:sink=${s.phase.name.lowercase()}:want=$expectedCount:" +
                    "backward=${k.seekDeclaredBackward}:declared=$backward",
            )
        }
    }

    // transport.seek(T) while PAUSED into an empty output ring: stays PAUSED,
    // generation + 1, native cursor T, pushed/drained unchanged at the
    // cumulative sink hold, nothing discarded.
    private fun seekTransportLocked(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        sinkHold: Long,
        targetFrame: Long,
        index: Int,
    ) {
        val target = targetFrame
        val expectedCount = index + 1
        if (machine.currentState != TransportState.PAUSED) throw FailClosed("seek_before_pause:${machine.currentState.name.lowercase()}")
        seekFlushAckedBeforeSeek = s.currentFlushCount == expectedCount
        if (!seekFlushAckedBeforeSeek) throw FailClosed("seek_before_flush:${s.currentFlushCount}:$expectedCount")
        seekSinkPhaseAtSeek = s.phase.name
        seekStaleGeneration = machine.currentGeneration
        val res = machine.seek(target)
        host.noteCommandIssued()
        seekAccepted = res.accepted && res.state == TransportState.PAUSED
        seekGeneration = machine.currentGeneration
        if (!seekAccepted) throw FailClosed("seek_rejected:${res.reason}:${res.state.name.lowercase()}")
        if (seekGeneration != seekStaleGeneration + 1L) throw FailClosed("seek_generation_not_advanced:$seekStaleGeneration:$seekGeneration")
        val snap = snapshotReplyLocked("post_seek", machine)
        seekPostSeekReply = snap
        val transportState = machine.currentState
        seekPostSeekTransportState = transportState
        val ok = transportState == TransportState.PAUSED && snap.state == NativeState.PAUSED &&
            snap.positionFrame == target && snap.pushedFrames == sinkHold && snap.drainedFrames == sinkHold &&
            snap.discardedFrames == 0L && !snap.eosPushed && !snap.eosDrained
        if (!ok) {
            throw FailClosed(
                "seek_command_accounting:transport=${transportState.name.lowercase()}:native=${snap.stateToken}:pos=${snap.positionFrame}:" +
                    "pushed=${snap.pushedFrames}:drained=${snap.drainedFrames}:discarded=${snap.discardedFrames}",
            )
        }
    }

    // Feed re-anchor on the decode thread (post-seek generation, stale probe
    // rejected before JNI), then >= one window of THIS seek's own post-seek
    // pre-roll while PAUSED. `nextContentHoldFrame` re-pins the feed's next
    // idle point (H2 for the first seek of a repeated run, else no further
    // hold); reanchor/pre-roll counts are cumulative, so the expected count
    // is this seek's 1-based ordinal.
    private fun reanchorFeedLocked(
        f: VanguardRealtimePlaybackDecoderFeed,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        contentHold: Long,
        sinkHold: Long,
        targetFrame: Long,
        index: Int,
        nextContentHoldFrame: Long,
        backward: Boolean,
    ) {
        val hold = contentHold
        val target = targetFrame
        val expectedCount = index + 1
        val reanchorAt = SystemClock.elapsedRealtime()
        val requested = f.requestSeekReanchor(
            VanguardRealtimePlaybackDecoderSeekRequest(
                targetFrame = target,
                preSeekAnchorFrame = hold,
                newGeneration = seekGeneration,
                staleGeneration = seekStaleGeneration,
                index = index,
                nextHoldFrame = nextContentHoldFrame,
                backward = backward,
            ),
        )
        if (!requested) throw FailClosed("feed_reanchor_request_rejected")
        val reanchorDeadline = reanchorAt + REANCHOR_WAIT_MS
        while (!f.awaitReanchor(WAIT_SLICE_MS, expectedCount)) {
            pollSeekWait()
            if (!f.isAlive) throw FailClosed("feed_exited_before_reanchor:${f.exitReason}")
            if (SystemClock.elapsedRealtime() > reanchorDeadline) throw FailClosed("feed_reanchor_timeout")
        }
        seekReanchorWaitMs = SystemClock.elapsedRealtime() - reanchorAt
        if (!(f.reanchorOk && f.seekReanchorCount == expectedCount)) throw FailClosed("feed_reanchor_failed:${f.exitReason}")
        if (f.seekBackward != backward) throw FailClosed("feed_reanchor_direction_mismatch:${f.seekBackward}:$backward")
        if (machine.currentState != TransportState.PAUSED) throw FailClosed("reanchor_state_moved:${machine.currentState.name.lowercase()}")

        val prerollAt = SystemClock.elapsedRealtime()
        val prerollDeadline = prerollAt + POST_SEEK_PREROLL_WAIT_MS
        while (!f.awaitPostSeekPreRoll(WAIT_SLICE_MS, expectedCount)) {
            pollSeekWait()
            if (!f.isAlive) throw FailClosed("feed_exited_before_post_seek_preroll:${f.exitReason}")
            if (SystemClock.elapsedRealtime() > prerollDeadline) throw FailClosed("post_seek_preroll_timeout:${f.postSeekAcceptedFrames}")
        }
        seekPostSeekPreRollWaitMs = SystemClock.elapsedRealtime() - prerollAt
        val transportState = machine.currentState
        seekPostSeekPreRollTransportState = transportState
        val preRollOk = f.postSeekPreRollFrames >= config.maxFramesPerMix.toLong() && f.postSeekPreRollStatePaused &&
            transportState == TransportState.PAUSED
        if (!preRollOk) {
            throw FailClosed("post_seek_preroll_short:${f.postSeekPreRollFrames}:${f.postSeekPreRollStatePaused}:${transportState.name.lowercase()}")
        }
        // Still PAUSED: the worker rendered nothing since the seek.
        val snap = snapshotReplyLocked("post_seek_preroll", machine)
        seekPostSeekPreRollReply = snap
        if (snap.state != NativeState.PAUSED || snap.pushedFrames != sinkHold || snap.positionFrame != target || snap.discardedFrames != 0L) {
            throw FailClosed("post_seek_preroll_accounting:${snap.stateToken}:${snap.pushedFrames}:${snap.positionFrame}:${snap.discardedFrames}")
        }
    }

    // Transport still PAUSED: the sink thread plays the flushed instance,
    // opens the seek epoch at T and publishes RUNNING before this returns.
    // Unpark count is cumulative across the whole session, so the expected
    // count is this seek's 1-based ordinal. Y17: the sink must have opened
    // the epoch through the direction it was declared (its
    // clockDeclaredBackwardOpenCalls is the 1-based ordinal only for a
    // backward seek, else 0); the clock snapshots stay telemetry.
    private fun unparkSinkLocked(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        targetFrame: Long,
        index: Int,
        backward: Boolean,
    ) {
        val target = targetFrame
        val expectedCount = index + 1
        val transportState = machine.currentState
        seekTransportStateAtUnpark = transportState
        if (transportState != TransportState.PAUSED) throw FailClosed("unpark_transport_not_paused:${transportState.name.lowercase()}")
        if (!s.isAlive) throw FailClosed("sink_exited_during_seek:${s.currentExitReason}")
        seekClockBeforeUnpark = s.clockSnapshot()
        val unparkAt = SystemClock.elapsedRealtime()
        if (!s.unpark()) throw FailClosed("sink_seek_unpark_rejected:${s.phase.name.lowercase()}:${s.currentFlushCount}")
        val ackDeadline = unparkAt + UNPARK_ACK_TIMEOUT_MS
        while (!s.awaitRunning(WAIT_SLICE_MS)) {
            pollSeekWait()
            if (!s.isAlive) throw FailClosed("sink_exited_before_seek_unpark_ack:${s.currentExitReason}")
            if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_seek_unpark_ack_timeout")
        }
        seekUnparkedAtMs = SystemClock.elapsedRealtime()
        seekHoldObservedMs = seekUnparkedAtMs - seekParkAckedAtMs
        seekClockAfterUnpark = s.clockSnapshot()
        val k = s.telemetry()
        if (k.playStateAfterUnpark != AudioTrack.PLAYSTATE_PLAYING) throw FailClosed("sink_not_playing_after_seek_unpark:${k.playStateAfterUnpark}")
        if (k.unparkCount != expectedCount || k.seekEpochOpenedAtUnpark == VanguardRealtimeAudioPlaybackSinkBridge.EPOCH_NONE ||
            k.seekEpochBaseFrame != target
        ) {
            throw FailClosed("seek_epoch_not_opened:${k.unparkCount}:${k.seekEpochOpenedAtUnpark}:${k.seekEpochBaseFrame}:$target:$expectedCount")
        }
        val expectedBackwardOpens = if (backward) 1 else 0
        if (k.seekDeclaredBackward != backward || k.clockDeclaredBackwardOpenCalls != expectedBackwardOpens) {
            throw FailClosed(
                "seek_epoch_direction:${k.seekDeclaredBackward}:${k.clockDeclaredBackwardOpenCalls}:declared=$backward:want=$expectedBackwardOpens",
            )
        }
    }

    // Only after the sink is RUNNING again; generation stays at the post-seek value.
    private fun resumeAfterSeekLocked(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
    ) {
        if (s.phase != VanguardRealtimeAudioPlaybackSinkBridge.Phase.RUNNING) throw FailClosed("resume_before_sink_unpark:${s.phase.name.lowercase()}")
        val res = machine.resume()
        host.noteCommandIssued()
        seekResumeAccepted = res.accepted && res.state == TransportState.PLAYING
        seekResumeGeneration = machine.currentGeneration
        if (!seekResumeAccepted) throw FailClosed("seek_resume_rejected:${res.reason}")
        if (seekResumeGeneration != seekGeneration) throw FailClosed("seek_resume_generation_moved:$seekGeneration:$seekResumeGeneration")
        seekResumedAtMs = SystemClock.elapsedRealtime()
    }
}
