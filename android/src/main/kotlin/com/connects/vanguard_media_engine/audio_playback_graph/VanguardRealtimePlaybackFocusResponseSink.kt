package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackAudioFocusController.Event
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackAudioFocusController.Tag
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder

// -- VanguardRealtimePlaybackFocusResponseSink (P4-AUDIO-REALTIME-PLAYBACK-
// FOCUS-RESPONSE, Y4a) ---------------------------------------------------
//
// One reusable Kotlin adapter that proves the audio-focus / becoming-noisy
// response contract between a caller-supplied
// [VanguardRealtimePlaybackTransportStateMachine] (Y1), one NON-muted
// android.media.AudioTrack MODE_STREAM sink (Y2 shape, base gain 0.5) and
// one [VanguardRealtimePlaybackAudioFocusController]. Every focus / noisy
// event is popped from the controller's single bounded queue on THIS run
// thread at explicit drain points and applied here; OS callbacks and
// synthetic events only ever enqueue.
//
// Response table (applied on the run thread, in event seq order):
//   LOSS_TRANSIENT_CAN_DUCK : AudioTrack.setVolume(duckGain)           (telemetry only)
//   GAIN while ducked       : AudioTrack.setVolume(baseGain)           (telemetry only)
//   LOSS_TRANSIENT          : transport.pause() -> AudioTrack.pause();
//                             duplicate while already paused = recorded no-op
//   GAIN while focus-paused : AudioTrack.play() -> transport.resume()
//   BECOMING_NOISY          : terminal fail-closed pause: transport.pause() ->
//                             AudioTrack.pause(); autoResumeAllowed=false
//   LOSS (permanent)        : terminal stop: AudioTrack.pause() -> transport.stop();
//                             autoResumeAllowed=false
//   GAIN after terminal     : recorded + rejected; no play(), no resume()
//
// Scripted sequence of [run] (scenario-dependent tail):
//   1. admission, AudioTrack create + setVolume(baseGain)
//   2. controller.requestFocus() (must be granted) and
//      controller.registerNoisyReceiver() (must succeed); pre-start drain
//      point must be empty
//   3. transport load/prepare/start; drain+write >= phaseFrames
//   4. synthetic duck -> apply; drain >= 2*phaseFrames; synthetic gain ->
//      restore; drain >= 3*phaseFrames
//   5. synthetic transient loss -> pause (hold frozen pauseHoldMs);
//      duplicate transient loss -> recorded no-op; synthetic gain ->
//      resume; drain >= 4*phaseFrames
//   6a. EOS_COMPLETION: drain+write until native EOS, transport COMPLETED,
//       full checksum identity, exact declaredFrameCount accounting
//   6b. BECOMING_NOISY_TERMINAL: synthetic becoming-noisy while PLAYING ->
//       transport.pause() then AudioTrack.pause() (PAUSED,
//       autoResumeAllowed=false); hold frozen pauseHoldMs; prefix checksum
//       identity; no permanent loss is injected. The finally block stops
//       the still-PAUSED transport exactly once (never COMPLETED).
//   6c. PERMANENT_LOSS_TERMINAL: synthetic AUDIOFOCUS_LOSS while transport
//       and AudioTrack are PLAYING -> AudioTrack.pause() then
//       transport.stop() (STOPPED, autoResumeAllowed=false); prefix
//       checksum identity; synthetic AUDIOFOCUS_GAIN -> recorded/rejected
//       (no play(), no resume(), no transport command; still PAUSED sink,
//       still STOPPED transport). No becoming-noisy is injected (never
//       COMPLETED).
//   7. finally: AudioTrack stop+release once; controller.release()
//      (receiver unregistered once if registered, focus abandoned once if
//      requested); transport.stop() once if still live. The state machine
//      is never disposed here.
//
// setVolume is telemetry only: the Kotlin sink checksum and the frames
// handed to AudioTrack.write are unaffected by any focus volume control.
//
// [PROOF_BOUNDARY]: realtime playback focus/noisy response diagnostic
// only; nonzero-gain AudioTrack sink; Y1 transport; no MediaCodec, no
// MediaExtractor; no route-change handling; no dead-object recovery; no
// presentation clock; no A/V sync; no OS focus arbitration correctness
// claim; no audible-output claim; no product/editor/app wiring; no iOS;
// no native C++ changes.
class VanguardRealtimePlaybackFocusResponseSink {

    enum class Scenario { EOS_COMPLETION, BECOMING_NOISY_TERMINAL, PERMANENT_LOSS_TERMINAL }

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val focusController: VanguardRealtimePlaybackAudioFocusController,
        val scenario: Scenario,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        val phaseFrames: Long = 2048L,
        val pauseHoldMs: Long = 150L,
        val baseGain: Float = BASE_GAIN,
        val duckGain: Float = DUCK_GAIN,
        val eventAwaitMs: Long = 2_000L,
        val deadlineMs: Long = 30_000L,
        val cancelled: () -> Boolean = { false },
    )

    data class Result(
        val pass: Boolean,
        val status: String,
        val failureReason: String,
        val proofBoundary: String,
        val scenario: Scenario,
        val lanes: Map<String, Any?>,
        val metrics: Map<String, Any?>,
        val focusGrantedOk: Boolean,
        val noisyReceiverRegisteredOk: Boolean,
        val baseGainSetOk: Boolean,
        val duckAppliedOk: Boolean,
        val duckRestoreOk: Boolean,
        val transientPauseResumeOk: Boolean,
        val becomingNoisyPauseOk: Boolean,
        val permanentStopNoAutoResumeOk: Boolean,
        val transportCompletedOk: Boolean,
        val transportStoppedOk: Boolean,
        val autoResumeAllowed: Boolean,
        val checksumIdentityOk: Boolean,
        val sinkWriteAccountingOk: Boolean,
        val audioTrackReleasedOk: Boolean,
        val focusAbandonedOk: Boolean,
        val receiverUnregisteredOk: Boolean,
        val lifecycleOk: Boolean,
        val releaseCount: Int,
        val focusAbandonCount: Int,
        val receiverUnregisterCount: Int,
        val eventsEnqueued: Long,
        val eventsDrained: Long,
        val eventsDropped: Long,
        val framesReadFromTransport: Long,
        val framesWrittenToSink: Long,
        val kotlinSinkChecksumHex: String,
        val nativeChecksumHex: String,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    companion object {
        const val PROOF_BOUNDARY =
            "realtime_playback_focus_noisy_response_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_duck_gain_0_1_setvolume_telemetry_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_os_focus_arbitration_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes"

        const val BASE_GAIN = 0.5f
        const val DUCK_GAIN = 0.1f

        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val MAX_DRAIN_STALLS = 500
        private const val DRAIN_STALL_SLEEP_MS = 2L
        private const val DRAIN_ITERATION_MARGIN = 128L
        private const val PAUSE_HOLD_SLICE_MS = 10L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L
        private const val SCRIPT_PHASES_BEFORE_TAIL = 4L
        private const val TAIL_MARGIN_PHASES = 1L
    }

    fun run(config: Config): Result {
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        val stateMachine = config.stateMachine
        val controller = config.focusController

        var audioTrack: AudioTrack? = null
        var releaseCount = 0
        var played = false

        // -- Lanes --------------------------------------------------------
        var audioTrackInitOk = false
        var baseGainSetOk = false
        var focusGrantedOk = false
        var noisyReceiverRegisteredOk = false
        var preStartDrainEmptyOk = false
        var duckAppliedOk = false
        var duckRestoreOk = false
        var transientPauseOk = false
        var transientHoldFrozenOk = false
        var duplicateTransientNoOpOk = false
        var transientResumeOk = false
        var transientPauseResumeOk = false
        var becomingNoisyPauseOk = false
        var noisyHoldFrozenOk = false
        var permanentStopOk = false
        var gainAttemptRejectedOk = false
        var permanentStopNoAutoResumeOk = false
        var transportCompletedOk = false
        var transportStoppedOk = false
        var checksumIdentityOk = false
        var sinkWriteAccountingOk = false
        var transportStopCalled = false
        var transportStopAccepted = false

        // -- Focus response state (run-thread confined) -------------------
        var autoResumeAllowed = true
        var focusPaused = false
        var ducked = false
        var applyOrdinal = 0L
        var transportCommandAttempts = 0L
        var setVolumeCalls = 0L
        var currentGain = -1f

        var duckAppliedCount = 0L
        var restoreAppliedCount = 0L
        var transientPauseAppliedCount = 0L
        var duplicateTransientNoOpCount = 0L
        var focusGainResumeAppliedCount = 0L
        var focusGainNoOpCount = 0L
        var noisyPauseAppliedCount = 0L
        var noisyDuplicateNoOpCount = 0L
        var permanentStopAppliedCount = 0L
        var gainAttemptRejectedCount = 0L
        var unknownEventCount = 0L

        var duckApplySeq = -1L
        var restoreApplySeq = -1L
        var transientPauseApplySeq = -1L
        var duplicateTransientApplySeq = -1L
        var focusGainResumeApplySeq = -1L
        var noisyPauseApplySeq = -1L
        var permanentStopApplySeq = -1L
        var gainAttemptApplySeq = -1L

        var duckApplyOrder = -1L
        var restoreApplyOrder = -1L
        var transientPauseApplyOrder = -1L
        var duplicateTransientApplyOrder = -1L
        var focusGainResumeApplyOrder = -1L
        var noisyPauseApplyOrder = -1L
        var permanentStopApplyOrder = -1L
        var gainAttemptApplyOrder = -1L

        // -- Accounting ---------------------------------------------------
        var framesReadFromTransport = 0L
        var framesWrittenToSink = 0L
        var partialWriteCount = 0L
        var zeroWriteCount = 0L
        var kotlinSinkChecksum = 0L
        var nativeChecksumHex = ""
        var prefixNativeDrainedFrames = -1L
        var lastReply: Reply? = null
        var drainIterations = 0L
        var playbackHeadAtTransientPause = 0L
        var playbackHeadAtNoisyPause = 0L
        var playbackHeadAtPermanentStop = 0L
        var playbackHeadFinal = 0L
        var transportStateAtTailEnd = ""
        var nativeStateAtTailEnd = ""
        var sinkPlayStateAtTailEnd = -1
        var transientHoldDispatchDelta = -1L
        var transientHoldPushedDelta = -1L
        var noisyHoldDispatchDelta = -1L
        var noisyHoldPushedDelta = -1L
        var lateEventsAtTeardown = 0L
        var finalPlayState = -1

        var pass = false
        var failureReason = ""

        fun checkCancelled() {
            if (config.cancelled()) throw FailClosed("cancelled")
        }

        fun checkDeadline() {
            if (SystemClock.elapsedRealtime() > deadline) throw FailClosed("deadline_exceeded")
        }

        fun fail(reason: String): Nothing = throw FailClosed(reason)

        fun requireTrack(): AudioTrack = audioTrack ?: fail("audio_track_missing")

        fun rawHead(): Long {
            val track = audioTrack ?: return 0L
            return track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        }

        fun releaseAudioTrackOnce() {
            val track = audioTrack ?: return
            if (releaseCount > 0) return
            try { finalPlayState = track.playState } catch (_: Throwable) {}
            try { track.stop() } catch (_: Throwable) {}
            try { track.release() } catch (_: Throwable) {}
            releaseCount++
        }

        // Leaves no live transport behind: one stop() when the state
        // machine is still PREPARED/PLAYING/PAUSED. Never disposes.
        fun stopTransportIfLive() {
            if (transportStopCalled) return
            val state = stateMachine.currentState
            if (state != State.PREPARED && state != State.PLAYING && state != State.PAUSED) return
            transportStopCalled = true
            transportStopAccepted = try {
                stateMachine.stop().accepted
            } catch (_: Throwable) {
                false
            }
        }

        fun setGain(gain: Float, phase: String) {
            val track = requireTrack()
            setVolumeCalls++
            if (track.setVolume(gain) != AudioTrack.SUCCESS) fail("audio_track_set_volume_failed_$phase")
            currentGain = gain
        }

        // Mirrors the native drain checksum accumulation (c = c * 31 +
        // uint16(sample)) over exactly the frames about to be handed to
        // AudioTrack.write; any write failure aborts the run.
        fun accumulateChecksum(buf: ByteBuffer, frames: Int) {
            var c = kotlinSinkChecksum
            val sampleCount = frames * config.channelCount
            for (i in 0 until sampleCount) {
                c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
            }
            kotlinSinkChecksum = c
        }

        fun writeAllToAudioTrack(buf: ByteBuffer, bytes: Int, bytesPerFrame: Int): Long {
            val track = requireTrack()
            var framesThisCall = 0L
            buf.position(0)
            buf.limit(bytes)
            var consecutiveZero = 0
            while (buf.hasRemaining()) {
                checkCancelled()
                checkDeadline()
                val requested = buf.remaining()
                val wrote = track.write(buf, requested, AudioTrack.WRITE_NON_BLOCKING)
                when {
                    wrote > 0 -> {
                        consecutiveZero = 0
                        if (wrote % bytesPerFrame != 0) fail("audio_track_write_frame_misaligned:$wrote")
                        val frames = (wrote / bytesPerFrame).toLong()
                        framesThisCall += frames
                        framesWrittenToSink += frames
                        if (!played) {
                            track.play()
                            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("audio_track_initial_play_failed")
                            played = true
                        }
                        if (wrote < requested) {
                            partialWriteCount++
                            buf.compact()
                            buf.flip()
                        }
                    }
                    wrote == 0 -> {
                        zeroWriteCount++
                        if (++consecutiveZero > MAX_CONSECUTIVE_ZERO_WRITES) fail("audio_track_write_stalled")
                        SystemClock.sleep(ZERO_WRITE_SLEEP_MS)
                    }
                    wrote == AudioTrack.ERROR_INVALID_OPERATION -> fail("audio_track_invalid_operation")
                    wrote == AudioTrack.ERROR_BAD_VALUE -> fail("audio_track_bad_value")
                    wrote == AudioTrack.ERROR_DEAD_OBJECT -> fail("audio_track_dead_object")
                    else -> fail("audio_track_generic_error")
                }
            }
            buf.clear()
            return framesThisCall
        }

        fun snapshotReply(phase: String): Reply {
            val result = stateMachine.snapshot()
            if (!result.accepted) fail("snapshot_rejected_$phase:${result.reason}")
            return result.reply ?: fail("snapshot_null_reply_$phase")
        }

        // Two snapshots pauseHoldMs apart with no drain/write in between;
        // native dispatch and push must not move while paused and the sink
        // must stay PLAYSTATE_PAUSED. Returns (dispatchDelta, pushedDelta).
        fun holdFrozen(phase: String): Pair<Long, Long> {
            val track = requireTrack()
            val start = snapshotReply("${phase}_hold_start")
            if (start.state != NativeState.PAUSED) fail("native_not_paused_${phase}_hold_start:${start.stateToken}")
            val holdEnd = SystemClock.elapsedRealtime() + config.pauseHoldMs
            while (true) {
                checkCancelled()
                checkDeadline()
                val remaining = holdEnd - SystemClock.elapsedRealtime()
                if (remaining <= 0L) break
                SystemClock.sleep(minOf(remaining, PAUSE_HOLD_SLICE_MS))
            }
            val end = snapshotReply("${phase}_hold_end")
            if (end.state != NativeState.PAUSED) fail("native_not_paused_${phase}_hold_end:${end.stateToken}")
            if (stateMachine.currentState != State.PAUSED) {
                fail("transport_left_paused_${phase}_hold:${stateMachine.currentState}")
            }
            if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("audio_track_left_paused_${phase}_hold")
            val dispatchDelta = end.dispatchCount - start.dispatchCount
            val pushedDelta = end.pushedFrames - start.pushedFrames
            if (dispatchDelta != 0L || pushedDelta != 0L) {
                fail("${phase}_hold_not_frozen:dispatch=$dispatchDelta:pushed=$pushedDelta")
            }
            return dispatchDelta to pushedDelta
        }

        // -- Focus response applier (run thread only) ---------------------
        // Applies one popped event per the response table. Assertions about
        // the resulting transport / sink state live in the script so every
        // failure names its phase.
        fun applyEvent(event: Event) {
            val track = requireTrack()
            val order = applyOrdinal++
            when (event.tag) {
                Tag.FOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    setGain(config.duckGain, "duck")
                    ducked = true
                    duckAppliedCount++
                    duckApplySeq = event.seq
                    duckApplyOrder = order
                }
                Tag.FOCUS_LOSS_TRANSIENT -> {
                    if (focusPaused) {
                        // Already paused by focus: recorded no-op, no command attempt.
                        duplicateTransientNoOpCount++
                        duplicateTransientApplySeq = event.seq
                        duplicateTransientApplyOrder = order
                    } else {
                        transportCommandAttempts++
                        val pauseResult = stateMachine.pause()
                        if (!pauseResult.accepted) fail("transient_pause_rejected:${pauseResult.reason}")
                        if (pauseResult.state != State.PAUSED) fail("transient_pause_not_paused:${pauseResult.state}")
                        val reply = pauseResult.reply ?: fail("transient_pause_null_reply")
                        if (reply.state != NativeState.PAUSED) fail("transient_pause_native_not_paused:${reply.stateToken}")
                        track.pause()
                        if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("transient_pause_sink_not_paused:${track.playState}")
                        focusPaused = true
                        transientPauseAppliedCount++
                        transientPauseApplySeq = event.seq
                        transientPauseApplyOrder = order
                    }
                }
                Tag.FOCUS_GAIN -> {
                    if (!autoResumeAllowed) {
                        // Terminal state reached: recorded and rejected, no play/resume.
                        gainAttemptRejectedCount++
                        gainAttemptApplySeq = event.seq
                        gainAttemptApplyOrder = order
                    } else if (focusPaused) {
                        track.play()
                        if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("focus_gain_sink_not_playing:${track.playState}")
                        transportCommandAttempts++
                        val resumeResult = stateMachine.resume()
                        if (!resumeResult.accepted) fail("focus_gain_resume_rejected:${resumeResult.reason}")
                        if (resumeResult.state != State.PLAYING) fail("focus_gain_resume_not_playing:${resumeResult.state}")
                        val reply = resumeResult.reply ?: fail("focus_gain_resume_null_reply")
                        if (reply.state != NativeState.PLAYING) fail("focus_gain_resume_native_not_playing:${reply.stateToken}")
                        focusPaused = false
                        focusGainResumeAppliedCount++
                        focusGainResumeApplySeq = event.seq
                        focusGainResumeApplyOrder = order
                    } else if (ducked) {
                        setGain(config.baseGain, "restore")
                        ducked = false
                        restoreAppliedCount++
                        restoreApplySeq = event.seq
                        restoreApplyOrder = order
                    } else {
                        focusGainNoOpCount++
                    }
                }
                Tag.BECOMING_NOISY -> {
                    // Terminal fail-closed pause; never auto-resumed.
                    autoResumeAllowed = false
                    if (focusPaused) {
                        noisyDuplicateNoOpCount++
                    } else {
                        transportCommandAttempts++
                        val pauseResult = stateMachine.pause()
                        if (!pauseResult.accepted) fail("noisy_pause_rejected:${pauseResult.reason}")
                        if (pauseResult.state != State.PAUSED) fail("noisy_pause_not_paused:${pauseResult.state}")
                        val reply = pauseResult.reply ?: fail("noisy_pause_null_reply")
                        if (reply.state != NativeState.PAUSED) fail("noisy_pause_native_not_paused:${reply.stateToken}")
                        track.pause()
                        if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("noisy_pause_sink_not_paused:${track.playState}")
                        focusPaused = true
                        noisyPauseAppliedCount++
                        noisyPauseApplySeq = event.seq
                        noisyPauseApplyOrder = order
                    }
                }
                Tag.FOCUS_LOSS_PERMANENT -> {
                    // Terminal stop; never auto-resumed. Sink first, then transport.
                    autoResumeAllowed = false
                    track.pause()
                    if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("permanent_loss_sink_not_paused:${track.playState}")
                    focusPaused = true
                    val state = stateMachine.currentState
                    if (state == State.PREPARED || state == State.PLAYING || state == State.PAUSED) {
                        transportCommandAttempts++
                        transportStopCalled = true
                        val stopResult = stateMachine.stop()
                        transportStopAccepted = stopResult.accepted
                        if (!stopResult.accepted) fail("permanent_loss_stop_rejected:${stopResult.reason}")
                        if (stopResult.state != State.STOPPED) fail("permanent_loss_not_stopped:${stopResult.state}")
                        val reply = stopResult.reply ?: fail("permanent_loss_stop_null_reply")
                        if (reply.state != NativeState.STOPPED) fail("permanent_loss_native_not_stopped:${reply.stateToken}")
                    } else {
                        fail("permanent_loss_transport_not_live:$state")
                    }
                    permanentStopAppliedCount++
                    permanentStopApplySeq = event.seq
                    permanentStopApplyOrder = order
                }
                Tag.FOCUS_UNKNOWN -> {
                    unknownEventCount++
                    fail("unknown_focus_event:${event.rawFocusChange}")
                }
            }
        }

        // Bounded wait for the next event at an explicit drain point; the
        // oldest pending event must carry the expected tag.
        fun awaitExpected(expected: Tag, phase: String): Event {
            val event = controller.awaitEvent(config.eventAwaitMs) {
                !config.cancelled() && SystemClock.elapsedRealtime() <= deadline
            }
            checkCancelled()
            checkDeadline()
            if (event == null) fail("event_timeout_$phase:${expected.name.lowercase()}")
            if (event.tag != expected) {
                fail("unexpected_event_$phase:${event.tag.name.lowercase()}:${event.source.name.lowercase()}:seq=${event.seq}")
            }
            return event
        }

        fun postSyntheticFocus(focusChange: Int, phase: String) {
            checkCancelled()
            checkDeadline()
            if (!controller.postSyntheticFocusChange(focusChange)) fail("synthetic_post_rejected_$phase")
        }

        fun makeResult(): Result {
            val status = if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" }
            val audioTrackReleasedOk = releaseCount == 1
            val transportStateAtReturn = stateMachine.currentState
            val transportLeftLive = transportStateAtReturn == State.PREPARED ||
                transportStateAtReturn == State.PLAYING ||
                transportStateAtReturn == State.PAUSED
            val telemetry = controller.telemetry()
            val focusAbandonedOk = controller.isFocusRequested &&
                controller.focusAbandonCount == 1 &&
                (telemetry["focusAbandonError"] as? String).isNullOrEmpty()
            val receiverUnregisteredOk = controller.isReceiverRegistered &&
                controller.receiverUnregisterCount == 1 &&
                (telemetry["receiverUnregisterError"] as? String).isNullOrEmpty()
            val eventsDropped = controller.droppedCount
            val lifecycleOk = audioTrackReleasedOk &&
                focusAbandonedOk &&
                receiverUnregisteredOk &&
                !transportLeftLive &&
                eventsDropped == 0L &&
                controller.isReleased
            val kotlinSinkChecksumHex = String.format("%016x", kotlinSinkChecksum)
            val lanes = mapOf(
                "audioTrackInitOk" to audioTrackInitOk,
                "baseGainSetOk" to baseGainSetOk,
                "focusGrantedOk" to focusGrantedOk,
                "noisyReceiverRegisteredOk" to noisyReceiverRegisteredOk,
                "preStartDrainEmptyOk" to preStartDrainEmptyOk,
                "duckAppliedOk" to duckAppliedOk,
                "duckRestoreOk" to duckRestoreOk,
                "transientPauseOk" to transientPauseOk,
                "transientHoldFrozenOk" to transientHoldFrozenOk,
                "duplicateTransientNoOpOk" to duplicateTransientNoOpOk,
                "transientResumeOk" to transientResumeOk,
                "transientPauseResumeOk" to transientPauseResumeOk,
                "becomingNoisyPauseOk" to becomingNoisyPauseOk,
                "noisyHoldFrozenOk" to noisyHoldFrozenOk,
                "permanentStopOk" to permanentStopOk,
                "gainAttemptRejectedOk" to gainAttemptRejectedOk,
                "permanentStopNoAutoResumeOk" to permanentStopNoAutoResumeOk,
                "transportCompletedOk" to transportCompletedOk,
                "transportStoppedOk" to transportStoppedOk,
                "checksumIdentityOk" to checksumIdentityOk,
                "sinkWriteAccountingOk" to sinkWriteAccountingOk,
                "audioTrackReleasedOk" to audioTrackReleasedOk,
                "focusAbandonedOk" to focusAbandonedOk,
                "receiverUnregisteredOk" to receiverUnregisteredOk,
                "eventsDroppedZeroOk" to (eventsDropped == 0L),
                "lifecycleOk" to lifecycleOk,
            )
            val metrics = mapOf(
                "scenario" to config.scenario.name,
                "sampleRate" to config.sampleRate,
                "channelCount" to config.channelCount,
                "maxFramesPerMix" to config.maxFramesPerMix,
                "declaredFrameCount" to config.declaredFrameCount,
                "phaseFrames" to config.phaseFrames,
                "pauseHoldMs" to config.pauseHoldMs,
                "eventAwaitMs" to config.eventAwaitMs,
                "baseGain" to config.baseGain,
                "duckGain" to config.duckGain,
                "currentGainTelemetry" to currentGain,
                "setVolumeCalls" to setVolumeCalls,
                "autoResumeAllowed" to autoResumeAllowed,
                "focusPausedAtReturn" to focusPaused,
                "duckAppliedCount" to duckAppliedCount,
                "restoreAppliedCount" to restoreAppliedCount,
                "transientPauseAppliedCount" to transientPauseAppliedCount,
                "duplicateTransientNoOpCount" to duplicateTransientNoOpCount,
                "focusGainResumeAppliedCount" to focusGainResumeAppliedCount,
                "focusGainNoOpCount" to focusGainNoOpCount,
                "noisyPauseAppliedCount" to noisyPauseAppliedCount,
                "noisyDuplicateNoOpCount" to noisyDuplicateNoOpCount,
                "permanentStopAppliedCount" to permanentStopAppliedCount,
                "gainAttemptRejectedCount" to gainAttemptRejectedCount,
                "unknownEventCount" to unknownEventCount,
                "duckApplySeq" to duckApplySeq,
                "restoreApplySeq" to restoreApplySeq,
                "transientPauseApplySeq" to transientPauseApplySeq,
                "duplicateTransientApplySeq" to duplicateTransientApplySeq,
                "focusGainResumeApplySeq" to focusGainResumeApplySeq,
                "noisyPauseApplySeq" to noisyPauseApplySeq,
                "permanentStopApplySeq" to permanentStopApplySeq,
                "gainAttemptApplySeq" to gainAttemptApplySeq,
                "duckApplyOrder" to duckApplyOrder,
                "restoreApplyOrder" to restoreApplyOrder,
                "transientPauseApplyOrder" to transientPauseApplyOrder,
                "duplicateTransientApplyOrder" to duplicateTransientApplyOrder,
                "focusGainResumeApplyOrder" to focusGainResumeApplyOrder,
                "noisyPauseApplyOrder" to noisyPauseApplyOrder,
                "permanentStopApplyOrder" to permanentStopApplyOrder,
                "gainAttemptApplyOrder" to gainAttemptApplyOrder,
                "appliedEventCount" to applyOrdinal,
                "transportCommandAttempts" to transportCommandAttempts,
                "framesReadFromTransport" to framesReadFromTransport,
                "framesWrittenToSink" to framesWrittenToSink,
                "partialWriteCount" to partialWriteCount,
                "zeroWriteCount" to zeroWriteCount,
                "drainIterations" to drainIterations,
                "playbackHeadAtTransientPause" to playbackHeadAtTransientPause,
                "playbackHeadAtNoisyPause" to playbackHeadAtNoisyPause,
                "playbackHeadAtPermanentStop" to playbackHeadAtPermanentStop,
                "playbackHeadFinal" to playbackHeadFinal,
                "transportStateAtTailEnd" to transportStateAtTailEnd,
                "nativeStateAtTailEnd" to nativeStateAtTailEnd,
                "sinkPlayStateAtTailEnd" to sinkPlayStateAtTailEnd,
                "transientHoldDispatchDelta" to transientHoldDispatchDelta,
                "transientHoldPushedDelta" to transientHoldPushedDelta,
                "noisyHoldDispatchDelta" to noisyHoldDispatchDelta,
                "noisyHoldPushedDelta" to noisyHoldPushedDelta,
                "prefixNativeDrainedFrames" to prefixNativeDrainedFrames,
                "kotlinSinkChecksumHex" to kotlinSinkChecksumHex,
                "nativeChecksumHex" to nativeChecksumHex,
                "lateEventsAtTeardown" to lateEventsAtTeardown,
                "finalPlayState" to finalPlayState,
                "releaseCount" to releaseCount,
                "transportStopCalled" to transportStopCalled,
                "transportStopAccepted" to transportStopAccepted,
                "transportState" to transportStateAtReturn.name,
                "transportGeneration" to stateMachine.currentGeneration,
            ) + telemetry.mapKeys { "focus_${it.key}" }
            return Result(
                pass = pass,
                status = status,
                failureReason = failureReason,
                proofBoundary = PROOF_BOUNDARY,
                scenario = config.scenario,
                lanes = lanes,
                metrics = metrics,
                focusGrantedOk = focusGrantedOk,
                noisyReceiverRegisteredOk = noisyReceiverRegisteredOk,
                baseGainSetOk = baseGainSetOk,
                duckAppliedOk = duckAppliedOk,
                duckRestoreOk = duckRestoreOk,
                transientPauseResumeOk = transientPauseResumeOk,
                becomingNoisyPauseOk = becomingNoisyPauseOk,
                permanentStopNoAutoResumeOk = permanentStopNoAutoResumeOk,
                transportCompletedOk = transportCompletedOk,
                transportStoppedOk = transportStoppedOk,
                autoResumeAllowed = autoResumeAllowed,
                checksumIdentityOk = checksumIdentityOk,
                sinkWriteAccountingOk = sinkWriteAccountingOk,
                audioTrackReleasedOk = audioTrackReleasedOk,
                focusAbandonedOk = focusAbandonedOk,
                receiverUnregisteredOk = receiverUnregisteredOk,
                lifecycleOk = lifecycleOk,
                releaseCount = releaseCount,
                focusAbandonCount = controller.focusAbandonCount,
                receiverUnregisterCount = controller.receiverUnregisterCount,
                eventsEnqueued = controller.enqueuedCount,
                eventsDrained = controller.drainedCount,
                eventsDropped = eventsDropped,
                framesReadFromTransport = framesReadFromTransport,
                framesWrittenToSink = framesWrittenToSink,
                kotlinSinkChecksumHex = kotlinSinkChecksumHex,
                nativeChecksumHex = nativeChecksumHex,
            )
        }

        try {
            checkCancelled()
            // -- 1. Config admission ------------------------------------
            if (config.channelCount != 1 && config.channelCount != 2) fail("invalid_channel_count")
            if (config.maxFramesPerMix <= 0 ||
                config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP
            ) {
                fail("invalid_max_frames_per_mix")
            }
            if (config.sampleRate < VanguardRealtimePlaybackNativeSession.MIN_SAMPLE_RATE ||
                config.sampleRate > VanguardRealtimePlaybackNativeSession.MAX_SAMPLE_RATE
            ) {
                fail("invalid_sample_rate")
            }
            if (config.phaseFrames <= 0L) fail("invalid_phase_frames")
            val minimumDeclared = config.phaseFrames * (SCRIPT_PHASES_BEFORE_TAIL + TAIL_MARGIN_PHASES)
            if (config.declaredFrameCount <= minimumDeclared) fail("invalid_declared_frame_count")
            if (config.declaredFrameCount >
                VanguardRealtimePlaybackNativeSession.MAX_DECLARED_SECONDS * config.sampleRate
            ) {
                fail("invalid_declared_frame_count")
            }
            if (config.baseGain <= 0f || config.baseGain > 1f) fail("invalid_base_gain")
            if (config.duckGain <= 0f || config.duckGain >= config.baseGain) fail("invalid_duck_gain")
            if (config.pauseHoldMs < 0L) fail("invalid_pause_hold_ms")
            if (config.eventAwaitMs <= 0L) fail("invalid_event_await_ms")
            if (config.deadlineMs <= 0L) fail("invalid_deadline_ms")
            if (controller.isReleased) fail("focus_controller_released")
            if (controller.isFocusRequested || controller.isReceiverRegistered) fail("focus_controller_already_used")
            val initialState = stateMachine.currentState
            if (initialState != State.IDLE) fail("invalid_state_${initialState.name.lowercase()}")

            val bytesPerFrame = 2 * config.channelCount
            val channelMask = if (config.channelCount == 1) {
                AudioFormat.CHANNEL_OUT_MONO
            } else {
                AudioFormat.CHANNEL_OUT_STEREO
            }

            // -- 2. Nonzero-gain diagnostic AudioTrack ------------------
            val minBytes = AudioTrack.getMinBufferSize(
                config.sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBytes <= 0) fail("audio_track_min_buffer_invalid:$minBytes")
            val floorBytes = (TRACK_BUFFER_MARGIN_WINDOWS * config.maxFramesPerMix * bytesPerFrame).toInt()
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(config.sampleRate)
                        .setChannelMask(channelMask)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(maxOf(minBytes, floorBytes))
                .build()
            audioTrack = track
            if (track.state != AudioTrack.STATE_INITIALIZED) fail("audio_track_not_initialized")
            audioTrackInitOk = true
            setGain(config.baseGain, "base")
            baseGainSetOk = true

            // -- 3. Focus request + noisy receiver (fail closed) --------
            checkCancelled()
            focusGrantedOk = controller.requestFocus()
            if (!focusGrantedOk) {
                fail("focus_not_granted:${controller.telemetry()["focusRequestError"]}")
            }
            noisyReceiverRegisteredOk = controller.registerNoisyReceiver()
            if (!noisyReceiverRegisteredOk) {
                fail("noisy_receiver_register_failed:${controller.telemetry()["receiverRegisterError"]}")
            }
            // Pre-start drain point: nothing may be pending before the
            // script injects its first event.
            val preStart = controller.drainAll()
            if (preStart.isNotEmpty()) {
                val first = preStart.first()
                fail("unexpected_pre_start_event:${first.tag.name.lowercase()}:${first.source.name.lowercase()}")
            }
            preStartDrainEmptyOk = true

            // -- 4. Transport load/prepare/start ------------------------
            checkCancelled()
            val loadResult = stateMachine.load()
            if (!loadResult.accepted) fail("load_failed:${loadResult.reason}")
            checkCancelled()
            val prepareResult = stateMachine.prepare()
            if (!prepareResult.accepted) fail("prepare_failed:${prepareResult.reason}")
            checkCancelled()
            val startResult = stateMachine.start()
            if (!startResult.accepted) fail("start_failed:${startResult.reason}")
            if (stateMachine.currentState != State.PLAYING) {
                fail("transport_not_playing_after_start:${stateMachine.currentState}")
            }

            val drainBuffer = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame)
                .order(ByteOrder.LITTLE_ENDIAN)
            val maxDrainIterations =
                (config.declaredFrameCount / config.maxFramesPerMix) + DRAIN_ITERATION_MARGIN

            fun drainAndWriteOnce(phase: String): Reply {
                checkCancelled()
                checkDeadline()
                if (++drainIterations > maxDrainIterations) fail("drain_iteration_budget_exhausted_$phase")
                val drainResult = stateMachine.drain(drainBuffer, config.maxFramesPerMix)
                if (!drainResult.accepted) fail("drain_rejected_$phase:${drainResult.reason}")
                val reply = drainResult.reply ?: fail("drain_null_reply_$phase")
                lastReply = reply
                val framesRead = reply.framesRead.toInt()
                if (framesRead < 0 || framesRead > config.maxFramesPerMix) {
                    fail("drain_frames_read_out_of_range_$phase:$framesRead")
                }
                if (framesRead > 0) {
                    if (reply.bytesRead != framesRead.toLong() * bytesPerFrame) {
                        fail("drain_bytes_read_mismatch_$phase:${reply.bytesRead}")
                    }
                    accumulateChecksum(drainBuffer, framesRead)
                    framesReadFromTransport += framesRead
                    val written = writeAllToAudioTrack(drainBuffer, framesRead * bytesPerFrame, bytesPerFrame)
                    if (written != framesRead.toLong()) fail("sink_write_short_$phase:$written")
                }
                return reply
            }

            // Drains + writes until at least `targetFrames` have been read
            // in total; EOS before the target fails closed.
            fun drainAtLeast(phase: String, targetFrames: Long) {
                var stalls = 0
                while (framesReadFromTransport < targetFrames) {
                    val reply = drainAndWriteOnce(phase)
                    if (reply.eosDrained) fail("eos_before_$phase")
                    if (reply.framesRead > 0L) {
                        stalls = 0
                    } else {
                        if (++stalls > MAX_DRAIN_STALLS) fail("drain_stalled_$phase")
                        SystemClock.sleep(DRAIN_STALL_SLEEP_MS)
                    }
                }
                if (stateMachine.currentState != State.PLAYING) {
                    fail("transport_not_playing_after_$phase:${stateMachine.currentState}")
                }
            }

            drainAtLeast("pre_duck", config.phaseFrames)
            if (!played) fail("no_frames_written_to_sink_pre_duck")

            // -- 5. Duck / restore (setVolume telemetry only) -----------
            postSyntheticFocus(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK, "duck")
            applyEvent(awaitExpected(Tag.FOCUS_LOSS_TRANSIENT_CAN_DUCK, "duck"))
            if (duckAppliedCount != 1L || currentGain != config.duckGain) fail("duck_not_applied")
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("duck_changed_play_state:${track.playState}")
            if (stateMachine.currentState != State.PLAYING) fail("duck_changed_transport_state:${stateMachine.currentState}")
            duckAppliedOk = true
            drainAtLeast("ducked", config.phaseFrames * 2L)

            postSyntheticFocus(AudioManager.AUDIOFOCUS_GAIN, "restore")
            applyEvent(awaitExpected(Tag.FOCUS_GAIN, "restore"))
            if (restoreAppliedCount != 1L || currentGain != config.baseGain) fail("restore_not_applied")
            if (restoreApplySeq <= duckApplySeq || restoreApplyOrder <= duckApplyOrder) fail("restore_before_duck")
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("restore_changed_play_state:${track.playState}")
            duckRestoreOk = true
            drainAtLeast("restored", config.phaseFrames * 3L)

            // -- 6. Transient loss pause -> duplicate no-op -> gain resume -
            postSyntheticFocus(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, "transient_loss")
            val attemptsBeforeTransient = transportCommandAttempts
            applyEvent(awaitExpected(Tag.FOCUS_LOSS_TRANSIENT, "transient_loss"))
            if (transientPauseAppliedCount != 1L) fail("transient_pause_not_applied")
            if (transportCommandAttempts != attemptsBeforeTransient + 1L) fail("transient_pause_command_accounting")
            if (stateMachine.currentState != State.PAUSED) fail("transport_not_paused_after_transient:${stateMachine.currentState}")
            if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("sink_not_paused_after_transient:${track.playState}")
            playbackHeadAtTransientPause = rawHead()
            transientPauseOk = true

            val transientHold = holdFrozen("transient")
            transientHoldDispatchDelta = transientHold.first
            transientHoldPushedDelta = transientHold.second
            transientHoldFrozenOk = true

            postSyntheticFocus(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, "duplicate_transient_loss")
            val attemptsBeforeDuplicate = transportCommandAttempts
            applyEvent(awaitExpected(Tag.FOCUS_LOSS_TRANSIENT, "duplicate_transient_loss"))
            if (duplicateTransientNoOpCount != 1L) fail("duplicate_transient_not_recorded")
            if (transportCommandAttempts != attemptsBeforeDuplicate) fail("duplicate_transient_issued_command")
            if (stateMachine.currentState != State.PAUSED) fail("transport_changed_on_duplicate_transient:${stateMachine.currentState}")
            if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("sink_changed_on_duplicate_transient:${track.playState}")
            duplicateTransientNoOpOk = true

            postSyntheticFocus(AudioManager.AUDIOFOCUS_GAIN, "focus_gain_resume")
            applyEvent(awaitExpected(Tag.FOCUS_GAIN, "focus_gain_resume"))
            if (focusGainResumeAppliedCount != 1L) fail("focus_gain_resume_not_applied")
            if (gainAttemptRejectedCount != 0L) fail("focus_gain_rejected_before_terminal")
            if (stateMachine.currentState != State.PLAYING) fail("transport_not_playing_after_focus_gain:${stateMachine.currentState}")
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("sink_not_playing_after_focus_gain:${track.playState}")
            if (focusGainResumeApplySeq <= transientPauseApplySeq) fail("resume_before_transient_pause")
            transientResumeOk = true
            transientPauseResumeOk = transientPauseOk && transientHoldFrozenOk &&
                duplicateTransientNoOpOk && transientResumeOk
            drainAtLeast("resumed", config.phaseFrames * 4L)

            fun captureTailEndState(phase: String) {
                transportStateAtTailEnd = stateMachine.currentState.name
                sinkPlayStateAtTailEnd = track.playState
                nativeStateAtTailEnd = snapshotReply("${phase}_tail_end").stateToken
            }

            // Prefix checksum identity over every frame drained so far. The
            // last drain reply is an immutable snapshot, so it stays valid
            // even after a later stop() resets the native accumulators.
            fun verifyPrefixChecksum(phase: String) {
                val prefixReply = lastReply ?: fail("missing_prefix_reply_$phase")
                nativeChecksumHex = prefixReply.drainedChecksumHex
                prefixNativeDrainedFrames = prefixReply.drainedFrames
                val kotlinHex = String.format("%016x", kotlinSinkChecksum)
                checksumIdentityOk = nativeChecksumHex.isNotEmpty() &&
                    kotlinHex.equals(nativeChecksumHex, ignoreCase = true)
                if (!checksumIdentityOk) fail("prefix_checksum_identity_mismatch_$phase")
            }

            fun verifyPrefixWriteAccounting() {
                sinkWriteAccountingOk = framesReadFromTransport == framesWrittenToSink &&
                    framesReadFromTransport >= config.phaseFrames * SCRIPT_PHASES_BEFORE_TAIL &&
                    framesReadFromTransport < config.declaredFrameCount &&
                    prefixNativeDrainedFrames == framesReadFromTransport
                if (!sinkWriteAccountingOk) fail("sink_write_accounting_mismatch")
            }

            when (config.scenario) {
                Scenario.EOS_COMPLETION -> {
                    // -- 7a. Normal no-fault EOS: complete, then release once -
                    var stalls = 0
                    while (true) {
                        val reply = drainAndWriteOnce("to_eos")
                        if (reply.framesRead > 0L) stalls = 0
                        if (reply.eosDrained) break
                        if (reply.framesRead == 0L) {
                            if (++stalls > MAX_DRAIN_STALLS) fail("drain_stalled_to_eos")
                            SystemClock.sleep(DRAIN_STALL_SLEEP_MS)
                        }
                    }
                    val catchUpDeadline = SystemClock.elapsedRealtime() + HEAD_CATCHUP_MARGIN_MS
                    while (rawHead() < framesWrittenToSink) {
                        checkCancelled()
                        checkDeadline()
                        if (SystemClock.elapsedRealtime() > catchUpDeadline) break
                        SystemClock.sleep(HEAD_POLL_SLEEP_MS)
                    }
                    playbackHeadFinal = rawHead()

                    transportCompletedOk = stateMachine.currentState == State.COMPLETED
                    if (!transportCompletedOk) fail("transport_not_completed:${stateMachine.currentState}")
                    if (!autoResumeAllowed) fail("auto_resume_disallowed_without_terminal_event")

                    val finalReply = lastReply ?: fail("missing_final_reply")
                    nativeChecksumHex = finalReply.drainedChecksumHex
                    prefixNativeDrainedFrames = finalReply.drainedFrames
                    val kotlinHex = String.format("%016x", kotlinSinkChecksum)
                    checksumIdentityOk = nativeChecksumHex.isNotEmpty() &&
                        kotlinHex.equals(nativeChecksumHex, ignoreCase = true)
                    if (!checksumIdentityOk) fail("checksum_identity_mismatch")

                    sinkWriteAccountingOk = framesReadFromTransport == framesWrittenToSink &&
                        framesReadFromTransport == config.declaredFrameCount
                    if (!sinkWriteAccountingOk) fail("sink_write_accounting_mismatch")
                    captureTailEndState("eos")
                }
                Scenario.BECOMING_NOISY_TERMINAL -> {
                    // -- 7b. Becoming noisy while PLAYING: terminal fail-closed
                    // pause (transport.pause() -> AudioTrack.pause()). No
                    // permanent loss is injected in this scenario.
                    checkCancelled()
                    checkDeadline()
                    if (stateMachine.currentState != State.PLAYING) fail("transport_not_playing_before_noisy:${stateMachine.currentState}")
                    if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("sink_not_playing_before_noisy:${track.playState}")
                    if (!controller.postSyntheticBecomingNoisy()) fail("synthetic_post_rejected_becoming_noisy")
                    val attemptsBeforeNoisy = transportCommandAttempts
                    applyEvent(awaitExpected(Tag.BECOMING_NOISY, "becoming_noisy"))
                    if (noisyPauseAppliedCount != 1L) fail("noisy_pause_not_applied")
                    if (noisyDuplicateNoOpCount != 0L) fail("noisy_recorded_as_duplicate")
                    if (transportCommandAttempts != attemptsBeforeNoisy + 1L) fail("noisy_pause_command_accounting")
                    if (autoResumeAllowed) fail("auto_resume_still_allowed_after_noisy")
                    if (stateMachine.currentState != State.PAUSED) fail("transport_not_paused_after_noisy:${stateMachine.currentState}")
                    if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("sink_not_paused_after_noisy:${track.playState}")
                    if (noisyPauseApplySeq <= focusGainResumeApplySeq) fail("noisy_before_resume")
                    if (permanentStopAppliedCount != 0L || transportStopCalled) fail("permanent_stop_in_noisy_scenario")
                    playbackHeadAtNoisyPause = rawHead()
                    becomingNoisyPauseOk = true

                    // -- 8b. Hold frozen: no dispatch / push while paused --
                    val noisyHold = holdFrozen("noisy")
                    noisyHoldDispatchDelta = noisyHold.first
                    noisyHoldPushedDelta = noisyHold.second
                    noisyHoldFrozenOk = true
                    if (autoResumeAllowed) fail("auto_resume_allowed_after_noisy_hold")
                    if (stateMachine.currentState != State.PAUSED) fail("transport_left_paused_after_noisy_hold:${stateMachine.currentState}")
                    if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("sink_left_paused_after_noisy_hold:${track.playState}")

                    // -- 9b. Prefix checksum identity + accounting ---------
                    verifyPrefixChecksum("noisy")
                    verifyPrefixWriteAccounting()
                    playbackHeadFinal = rawHead()
                    captureTailEndState("noisy")
                    if (transportStateAtTailEnd != State.PAUSED.name) fail("transport_not_paused_at_noisy_tail_end:$transportStateAtTailEnd")
                    // Teardown (finally) releases the AudioTrack once, the
                    // controller once, and stops the still-PAUSED transport
                    // exactly once.
                }
                Scenario.PERMANENT_LOSS_TERMINAL -> {
                    // -- 7c. Permanent loss while transport + AudioTrack are
                    // PLAYING: AudioTrack.pause() -> transport.stop(). No
                    // becoming-noisy is injected in this scenario.
                    checkCancelled()
                    checkDeadline()
                    if (stateMachine.currentState != State.PLAYING) fail("transport_not_playing_before_permanent_loss:${stateMachine.currentState}")
                    if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("sink_not_playing_before_permanent_loss:${track.playState}")
                    if (focusPaused) fail("focus_paused_before_permanent_loss")
                    postSyntheticFocus(AudioManager.AUDIOFOCUS_LOSS, "permanent_loss")
                    val attemptsBeforePermanent = transportCommandAttempts
                    applyEvent(awaitExpected(Tag.FOCUS_LOSS_PERMANENT, "permanent_loss"))
                    if (permanentStopAppliedCount != 1L) fail("permanent_stop_not_applied")
                    if (transportCommandAttempts != attemptsBeforePermanent + 1L) fail("permanent_stop_command_accounting")
                    if (!transportStopCalled || !transportStopAccepted) fail("permanent_stop_not_accepted")
                    if (autoResumeAllowed) fail("auto_resume_still_allowed_after_permanent_loss")
                    transportStoppedOk = stateMachine.currentState == State.STOPPED
                    if (!transportStoppedOk) fail("transport_not_stopped_after_permanent_loss:${stateMachine.currentState}")
                    if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("sink_not_paused_after_permanent_loss:${track.playState}")
                    if (permanentStopApplySeq <= focusGainResumeApplySeq) fail("permanent_before_resume")
                    if (noisyPauseAppliedCount != 0L || noisyDuplicateNoOpCount != 0L) fail("noisy_applied_in_permanent_scenario")
                    playbackHeadAtPermanentStop = rawHead()
                    permanentStopOk = true

                    // -- 8c. Prefix checksum identity + accounting ---------
                    verifyPrefixChecksum("permanent")
                    verifyPrefixWriteAccounting()

                    // -- 9c. Focus gain after terminal stop: recorded and
                    // rejected; no play(), no resume(), no transport command.
                    postSyntheticFocus(AudioManager.AUDIOFOCUS_GAIN, "gain_attempt")
                    val attemptsBeforeGainAttempt = transportCommandAttempts
                    val resumesBeforeGainAttempt = focusGainResumeAppliedCount
                    val restoresBeforeGainAttempt = restoreAppliedCount
                    val setVolumeBeforeGainAttempt = setVolumeCalls
                    applyEvent(awaitExpected(Tag.FOCUS_GAIN, "gain_attempt"))
                    if (gainAttemptRejectedCount != 1L) fail("gain_attempt_not_rejected")
                    if (focusGainResumeAppliedCount != resumesBeforeGainAttempt) fail("gain_attempt_resumed_after_terminal")
                    if (restoreAppliedCount != restoresBeforeGainAttempt) fail("gain_attempt_restored_after_terminal")
                    if (setVolumeCalls != setVolumeBeforeGainAttempt) fail("gain_attempt_set_volume_after_terminal")
                    if (transportCommandAttempts != attemptsBeforeGainAttempt) fail("gain_attempt_issued_command")
                    if (autoResumeAllowed) fail("auto_resume_allowed_after_permanent_loss")
                    if (stateMachine.currentState != State.STOPPED) fail("transport_changed_on_gain_attempt:${stateMachine.currentState}")
                    if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("sink_changed_on_gain_attempt:${track.playState}")
                    if (gainAttemptApplySeq <= permanentStopApplySeq) fail("gain_attempt_before_permanent")
                    gainAttemptRejectedOk = true
                    permanentStopNoAutoResumeOk = permanentStopOk && gainAttemptRejectedOk &&
                        transportStoppedOk && !autoResumeAllowed
                    playbackHeadFinal = rawHead()
                    captureTailEndState("permanent")
                    if (transportStateAtTailEnd != State.STOPPED.name) fail("transport_not_stopped_at_permanent_tail_end:$transportStateAtTailEnd")
                }
            }

            // Final drain point: anything still pending is late telemetry.
            lateEventsAtTeardown = controller.drainAll().size.toLong()
            if (controller.droppedCount != 0L) fail("events_dropped:${controller.droppedCount}")

            pass = true
        } catch (f: FailClosed) {
            failureReason = f.reason
        } catch (e: Throwable) {
            failureReason = "exception:${e.javaClass.simpleName}:${e.message}"
        } finally {
            // AudioTrack once, receiver/focus once, then leave no live
            // transport behind. Never disposes the state machine.
            releaseAudioTrackOnce()
            try {
                controller.release()
            } catch (_: Throwable) {
            }
            try {
                stopTransportIfLive()
            } catch (_: Throwable) {
            }
        }

        return makeResult()
    }
}
