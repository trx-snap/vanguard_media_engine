package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State as TransportState

// ── VanguardRealtimeAudioPlaybackSeekSequencer (Y10a modularity prep) ──────
//
// Behavior-identical extraction of the Y9 seek step sequence and its
// bookkeeping, previously inline in [VanguardRealtimeAudioPlaybackSession].
// Owns no thread of its own: every step runs synchronously on whichever
// thread calls [run] (the session's command-lock holder, i.e. the caller's
// thread). It issues transport/sink/feed commands in the exact fixed Y9
// order documented on the session; the session still owns admission
// (arming, hold-frame pin), the public `seek(targetFrame)` gate checks, and
// state transitions around [run].
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
        val startGeneration: Long
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

    // Runs the fixed Y9 order once (command-lock holder, state SEEKING).
    // Returns null on success (every step verified), else the failure reason
    // (the session fails closed and tears down with it).
    fun run(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        f: VanguardRealtimePlaybackDecoderFeed,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        declaredFrameCount: Long,
        holdFrame: Long,
        targetFrame: Long,
    ): String? = try {
        val seekStartedAt = SystemClock.elapsedRealtime()
        awaitInitialWritesLocked(s, machine)
        awaitQuiescenceLocked(f, s, machine, holdFrame)
        parkForSeekLocked(s)
        verifyPreSeekQuiescenceLocked(f, s, machine, holdFrame)
        pauseForSeekLocked(machine, holdFrame)
        flushSinkLocked(s, machine, declaredFrameCount, holdFrame, targetFrame)
        seekTransportLocked(s, machine, holdFrame, targetFrame)
        reanchorFeedLocked(f, machine, holdFrame, targetFrame)
        unparkSinkLocked(s, machine, targetFrame)
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

    // Feed held at H and sink read (hence written: a park follows a fully
    // written window) all H frames, transport PLAYING, sink RUNNING.
    private fun awaitQuiescenceLocked(
        f: VanguardRealtimePlaybackDecoderFeed,
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        holdFrame: Long,
    ) {
        val hold = holdFrame
        val waitStart = SystemClock.elapsedRealtime()
        val waitDeadline = waitStart + QUIESCE_WAIT_MS
        while (!(f.heldAtHoldFrame && f.anchorFrame == hold && s.framesRead == hold)) {
            pollSeekWait()
            if (!s.isAlive) throw FailClosed("sink_exited_before_quiesce:${s.currentExitReason}")
            if (!f.isAlive) throw FailClosed("feed_exited_before_quiesce:${f.exitReason}")
            if (s.framesRead > hold) throw FailClosed("sink_read_past_hold:${s.framesRead}:$hold")
            if (machine.currentState != TransportState.PLAYING) throw FailClosed("quiesce_state:${machine.currentState.name.lowercase()}")
            if (s.phase != VanguardRealtimeAudioPlaybackSinkBridge.Phase.RUNNING) throw FailClosed("quiesce_sink_phase:${s.phase.name.lowercase()}")
            if (SystemClock.elapsedRealtime() > waitDeadline) {
                throw FailClosed("quiesce_timeout:anchor=${f.anchorFrame}:held=${f.heldAtHoldFrame}:read=${s.framesRead}:hold=$hold")
            }
            sleepSlice()
        }
        seekQuiesceWaitMs = SystemClock.elapsedRealtime() - waitStart
        seekQuiesceFeedHeld = f.heldAtHoldFrame
        seekQuiesceSinkReadFrames = s.framesRead
    }

    // Seek park: AudioTrack paused on the sink thread, epoch closed at the
    // last published position, hold capped by maxSeekHoldMs.
    private fun parkForSeekLocked(s: VanguardRealtimeAudioPlaybackSinkBridge) {
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
        if (k.parkCount != 1 || k.seekParkCount != 1) throw FailClosed("sink_seek_park_count:${k.parkCount}:${k.seekParkCount}")
        seekQuiesceSinkWrittenFrames = s.framesWritten
    }

    // Pre-seek native snapshot: position == pushed == drained == H, discarded
    // 0, output ring empty, native PLAYING, sink PARKED, transport PLAYING.
    private fun verifyPreSeekQuiescenceLocked(
        f: VanguardRealtimePlaybackDecoderFeed,
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        holdFrame: Long,
    ) {
        val hold = holdFrame
        val window = config.maxFramesPerMix.toLong()
        val settleStart = SystemClock.elapsedRealtime()
        val settleDeadline = settleStart + SNAPSHOT_SETTLE_WAIT_MS
        var snap: Reply
        while (true) {
            snap = snapshotReplyLocked("pre_seek", machine)
            if (snap.pushedFrames == hold && snap.drainedFrames == hold && snap.positionFrame == hold) break
            pollSeekWait()
            if (SystemClock.elapsedRealtime() > settleDeadline) {
                throw FailClosed("pre_seek_snapshot_unsettled:pos=${snap.positionFrame}:pushed=${snap.pushedFrames}:drained=${snap.drainedFrames}:hold=$hold")
            }
            sleepSlice()
        }
        seekPreSeekSettleMs = SystemClock.elapsedRealtime() - settleStart
        seekPreSeekReply = snap
        val transportState = machine.currentState
        seekPreSeekTransportState = transportState
        val d = f.seekTelemetry()
        seekQuiesceAccountingOk = hold % window == 0L &&
            d.anchorFrame == hold && d.heldAtHoldFrame && d.acceptedFrames == hold &&
            snap.state == NativeState.PLAYING && transportState == TransportState.PLAYING &&
            snap.positionFrame == hold && snap.pushedFrames == hold && snap.drainedFrames == hold &&
            snap.discardedFrames == 0L && snap.outputAvailableReadFrames == 0L &&
            !snap.eosPushed && !snap.eosDrained &&
            s.framesRead == hold && s.framesWritten == hold &&
            s.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED
        if (!seekQuiesceAccountingOk) {
            throw FailClosed(
                "seek_quiesce_accounting:hold=$hold:anchor=${d.anchorFrame}:held=${d.heldAtHoldFrame}:accepted=${d.acceptedFrames}:" +
                    "native=${snap.stateToken}:transport=${transportState.name.lowercase()}:pos=${snap.positionFrame}:" +
                    "pushed=${snap.pushedFrames}:drained=${snap.drainedFrames}:discarded=${snap.discardedFrames}:" +
                    "avail=${snap.outputAvailableReadFrames}:read=${s.framesRead}:written=${s.framesWritten}:sink=${s.phase.name.lowercase()}",
            )
        }
    }

    // transport.pause after the sink park; PAUSED recheck with H accounting unchanged.
    private fun pauseForSeekLocked(machine: VanguardRealtimePlaybackTransportStateMachine, holdFrame: Long) {
        val hold = holdFrame
        val res = machine.pause()
        host.noteCommandIssued()
        seekPauseAccepted = res.accepted && res.state == TransportState.PAUSED
        seekPauseGeneration = machine.currentGeneration
        if (!seekPauseAccepted) throw FailClosed("seek_pause_rejected:${res.reason}")
        if (seekPauseGeneration != host.startGeneration) throw FailClosed("seek_pause_generation_moved:${host.startGeneration}:$seekPauseGeneration")
        val snap = snapshotReplyLocked("post_pause", machine)
        seekPostPauseReply = snap
        if (snap.state != NativeState.PAUSED || snap.pushedFrames != hold ||
            snap.drainedFrames != hold || snap.discardedFrames != 0L
        ) {
            throw FailClosed("post_pause_accounting:${snap.stateToken}:${snap.pushedFrames}:${snap.drainedFrames}:${snap.discardedFrames}")
        }
    }

    // AudioTrack.flush() once on the sink thread while sink PARKED/PAUSED and
    // transport PAUSED; read budget becomes H + (declared - T).
    private fun flushSinkLocked(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        declared: Long,
        holdFrame: Long,
        targetFrame: Long,
    ) {
        val hold = holdFrame
        val target = targetFrame
        if (machine.currentState != TransportState.PAUSED) throw FailClosed("flush_before_transport_pause:${machine.currentState.name.lowercase()}")
        if (s.phase != VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED) throw FailClosed("flush_before_sink_park:${s.phase.name.lowercase()}")
        seekFlushRequestedWhilePaused = true
        val flushAt = SystemClock.elapsedRealtime()
        if (!s.requestFlush(declared - target, target)) throw FailClosed("sink_flush_request_rejected:${s.phase.name.lowercase()}")
        val ackDeadline = flushAt + FLUSH_ACK_TIMEOUT_MS
        while (!s.awaitFlushed(WAIT_SLICE_MS)) {
            pollSeekWait()
            if (!s.isAlive) throw FailClosed("sink_exited_before_flush_ack:${s.currentExitReason}")
            if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_flush_ack_timeout:${s.currentFlushCount}")
        }
        seekFlushAckWaitMs = SystemClock.elapsedRealtime() - flushAt
        val k = s.telemetry()
        val ok = k.flushCount == 1 && k.flushRequestCount == 1 && k.flushExecutedOnSinkThread &&
            k.playStateBeforeFlush == AudioTrack.PLAYSTATE_PAUSED && k.playStateAfterFlush == AudioTrack.PLAYSTATE_PAUSED &&
            k.framesWrittenAtFlush == hold && k.framesReadAtFlush == hold &&
            k.postSeekExpectedFrames == declared - target && k.readBudgetFrames == hold + (declared - target) &&
            k.seekTargetFrame == target && k.timestampPollsDuringFlush == 0L &&
            s.phase == VanguardRealtimeAudioPlaybackSinkBridge.Phase.PARKED && machine.currentState == TransportState.PAUSED
        if (!ok) {
            throw FailClosed(
                "sink_flush_verification:count=${k.flushCount}:requests=${k.flushRequestCount}:before=${k.playStateBeforeFlush}:" +
                    "after=${k.playStateAfterFlush}:written=${k.framesWrittenAtFlush}:read=${k.framesReadAtFlush}:" +
                    "expected=${k.postSeekExpectedFrames}:budget=${k.readBudgetFrames}:sink=${s.phase.name.lowercase()}",
            )
        }
    }

    // transport.seek(T) while PAUSED into an empty output ring: stays PAUSED,
    // generation + 1, native cursor T, nothing discarded.
    private fun seekTransportLocked(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        holdFrame: Long,
        targetFrame: Long,
    ) {
        val hold = holdFrame
        val target = targetFrame
        if (machine.currentState != TransportState.PAUSED) throw FailClosed("seek_before_pause:${machine.currentState.name.lowercase()}")
        seekFlushAckedBeforeSeek = s.currentFlushCount == 1
        if (!seekFlushAckedBeforeSeek) throw FailClosed("seek_before_flush:${s.currentFlushCount}")
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
            snap.positionFrame == target && snap.pushedFrames == hold && snap.drainedFrames == hold &&
            snap.discardedFrames == 0L && !snap.eosPushed && !snap.eosDrained
        if (!ok) {
            throw FailClosed(
                "seek_command_accounting:transport=${transportState.name.lowercase()}:native=${snap.stateToken}:pos=${snap.positionFrame}:" +
                    "pushed=${snap.pushedFrames}:drained=${snap.drainedFrames}:discarded=${snap.discardedFrames}",
            )
        }
    }

    // Feed re-anchor on the decode thread (post-seek generation, stale probe
    // rejected before JNI), then >= one window post-seek pre-roll while PAUSED.
    private fun reanchorFeedLocked(
        f: VanguardRealtimePlaybackDecoderFeed,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        holdFrame: Long,
        targetFrame: Long,
    ) {
        val hold = holdFrame
        val target = targetFrame
        val reanchorAt = SystemClock.elapsedRealtime()
        val requested = f.requestSeekReanchor(
            VanguardRealtimePlaybackDecoderSeekRequest(
                targetFrame = target,
                preSeekAnchorFrame = hold,
                newGeneration = seekGeneration,
                staleGeneration = seekStaleGeneration,
            ),
        )
        if (!requested) throw FailClosed("feed_reanchor_request_rejected")
        val reanchorDeadline = reanchorAt + REANCHOR_WAIT_MS
        while (!f.awaitReanchor(WAIT_SLICE_MS)) {
            pollSeekWait()
            if (!f.isAlive) throw FailClosed("feed_exited_before_reanchor:${f.exitReason}")
            if (SystemClock.elapsedRealtime() > reanchorDeadline) throw FailClosed("feed_reanchor_timeout")
        }
        seekReanchorWaitMs = SystemClock.elapsedRealtime() - reanchorAt
        if (!(f.reanchorOk && f.seekReanchorCount == 1)) throw FailClosed("feed_reanchor_failed:${f.exitReason}")
        if (machine.currentState != TransportState.PAUSED) throw FailClosed("reanchor_state_moved:${machine.currentState.name.lowercase()}")

        val prerollAt = SystemClock.elapsedRealtime()
        val prerollDeadline = prerollAt + POST_SEEK_PREROLL_WAIT_MS
        while (!f.awaitPostSeekPreRoll(WAIT_SLICE_MS)) {
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
        if (snap.state != NativeState.PAUSED || snap.pushedFrames != hold || snap.positionFrame != target || snap.discardedFrames != 0L) {
            throw FailClosed("post_seek_preroll_accounting:${snap.stateToken}:${snap.pushedFrames}:${snap.positionFrame}:${snap.discardedFrames}")
        }
    }

    // Transport still PAUSED: the sink thread plays the flushed instance,
    // opens the seek epoch at T and publishes RUNNING before this returns.
    private fun unparkSinkLocked(
        s: VanguardRealtimeAudioPlaybackSinkBridge,
        machine: VanguardRealtimePlaybackTransportStateMachine,
        targetFrame: Long,
    ) {
        val target = targetFrame
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
        if (k.unparkCount != 1 || k.seekEpochOpenedAtUnpark == VanguardRealtimeAudioPlaybackSinkBridge.EPOCH_NONE ||
            k.seekEpochBaseFrame != target
        ) {
            throw FailClosed("seek_epoch_not_opened:${k.unparkCount}:${k.seekEpochOpenedAtUnpark}:${k.seekEpochBaseFrame}:$target")
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
