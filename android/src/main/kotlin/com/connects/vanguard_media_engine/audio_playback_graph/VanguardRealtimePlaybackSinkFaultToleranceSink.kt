package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController.Event
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController.Source
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackRoutingController.Tag
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder

// -- VanguardRealtimePlaybackSinkFaultToleranceSink (P4-AUDIO-REALTIME-
// PLAYBACK-SINK-FAULT-TOLERANCE, Y4b) -------------------------------------
//
// One reusable Kotlin adapter that proves the AudioTrack sink fault-
// tolerance contract between a caller-supplied
// [VanguardRealtimePlaybackTransportStateMachine] (Y1), one NON-muted
// android.media.AudioTrack MODE_STREAM sink (Y2 shape, base gain 0.5) and
// one [VanguardRealtimePlaybackRoutingController]. Every routing event is
// popped from the controller's single bounded queue on THIS run thread at
// explicit drain points and applied here; OS callbacks and synthetic
// events only ever enqueue.
//
// Response table (applied on the run thread, in event seq order):
//   ROUTE_CHANGED            : AudioTrack.getRoutedDevice() sampled (telemetry
//                              only; no recreation, no play-state change).
//                              After the terminal disconnect: recorded no-op.
//   ROUTE_DISCONNECT         : terminal fail-closed pause: transport.pause() ->
//                              AudioTrack.pause(); autoResumeAllowed=false.
//                              Requires PLAYING, applied exactly once, never
//                              at a non-terminal drain point.
//   ERROR_DEAD_OBJECT (write): EOS scenario only, exactly once, synthetic:
//                              detach listener -> release old track once ->
//                              create same-parameter track -> STATE_INITIALIZED
//                              -> setVolume(baseGain) -> attach listener ->
//                              play() (PLAYSTATE_PLAYING) -> resume writing the
//                              SAME ByteBuffer remainder. A second dead
//                              object, or a real (un-armed) one, fails closed.
//
// Scripted sequence of [run] (scenario-dependent tail):
//   1. admission, AudioTrack create + setVolume(baseGain), routing listener
//      attached; pre-start drain point must be empty
//   2. transport load/prepare/start; drain+write >= phaseFrames
//   3. synthetic ROUTE_CHANGED -> observed on the run thread (any real
//      ROUTE_CHANGED before it is observed too); drain >= 2*phaseFrames
//   4a. EOS_WITH_DEAD_OBJECT_RECOVERY: the ONE synthetic ERROR_DEAD_OBJECT is
//       substituted for an in-flight AudioTrack.write result (no bytes
//       consumed) once >= 2*phaseFrames were written; recovery per the table
//       above; drain+write until native EOS, transport COMPLETED, full
//       checksum identity, exact declaredFrameCount accounting, no
//       double-count/drop across the recreate.
//   4b. ROUTE_DISCONNECT_TERMINAL: synthetic ROUTE_DISCONNECT enqueued on
//       this thread while PLAYING -> transport.pause() then AudioTrack.pause()
//       (PAUSED, autoResumeAllowed=false); hold frozen pauseHoldMs (native
//       dispatch/pushed unchanged); prefix checksum identity; partial write
//       accounting. The finally block stops the still-PAUSED transport
//       exactly once (never COMPLETED). No dead object is injected.
//   5. finally: controller.release() (listener detached once, BEFORE the
//      track release); AudioTrack stop+release once; transport.stop() once
//      if still live. The state machine is never disposed here.
//
// setVolume is telemetry only: the Kotlin sink checksum and the frames
// handed to AudioTrack.write are unaffected by any volume control.
//
// [PROOF_BOUNDARY]: realtime playback sink fault tolerance diagnostic only;
// nonzero-gain AudioTrack sink; Y1 transport; synthetic dead-object recovery
// only; route-change listener handoff and fail-closed pause only; no
// MediaCodec, no MediaExtractor; no presentation clock; no A/V sync; no OS
// route arbitration claim; no real OS dead-object forcing claim; no seamless
// hot-swap claim; no audible-output claim; no product/editor/app wiring; no
// iOS; no native C++ changes.
class VanguardRealtimePlaybackSinkFaultToleranceSink {

    enum class Scenario { EOS_WITH_DEAD_OBJECT_RECOVERY, ROUTE_DISCONNECT_TERMINAL }

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val routingController: VanguardRealtimePlaybackRoutingController,
        val scenario: Scenario,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        val phaseFrames: Long = 2048L,
        val pauseHoldMs: Long = 150L,
        val baseGain: Float = BASE_GAIN,
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
        val audioTrackInitOk: Boolean,
        val baseGainSetOk: Boolean,
        val routingListenerRegisteredOk: Boolean,
        val routingListenerUnregisteredOk: Boolean,
        val routeChangeObservationOk: Boolean,
        val routeDisconnectFailClosedPauseOk: Boolean,
        val deadObjectInjectedOnceOk: Boolean,
        val deadObjectOldTrackReleasedOk: Boolean,
        val deadObjectNewTrackStateInitializedOk: Boolean,
        val deadObjectNewTrackVolumeSetOk: Boolean,
        val deadObjectNewTrackPlayOk: Boolean,
        val deadObjectRemainderResumedOk: Boolean,
        val deadObjectNoDoubleCountOk: Boolean,
        val transportCompletedOk: Boolean,
        val transportStoppedOk: Boolean,
        val autoResumeAllowed: Boolean,
        val checksumIdentityOk: Boolean,
        val sinkWriteAccountingOk: Boolean,
        val audioTrackReleasedOk: Boolean,
        val lifecycleOk: Boolean,
        val audioTracksCreated: Int,
        val audioTracksReleased: Int,
        val finalReleaseCount: Int,
        val listenerAttachCount: Int,
        val listenerDetachCount: Int,
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
            "realtime_playback_sink_fault_tolerance_diagnostic_only_nonzero_gain_audiotrack_sink_base_gain_0_5_synthetic_pcm_from_y1_transport_synthetic_dead_object_recovery_only_route_change_listener_handoff_and_fail_closed_pause_only_no_mediacodec_no_mediaextractor_no_presentation_clock_no_av_sync_no_os_route_arbitration_claim_no_real_os_dead_object_forcing_claim_no_seamless_hot_swap_claim_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes"

        const val BASE_GAIN = 0.5f

        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val MAX_DRAIN_STALLS = 500
        private const val DRAIN_STALL_SLEEP_MS = 2L
        private const val DRAIN_ITERATION_MARGIN = 128L
        private const val PAUSE_HOLD_SLICE_MS = 10L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L
        private const val MAX_EVENTS_PER_DRAIN_POINT = 64
        // Script phases before the scenario tail: pre-route-changed
        // (1 phase) and post-observation (1 phase). The dead object arms
        // once DEAD_OBJECT_INJECT_AFTER_PHASES phases were written.
        private const val SCRIPT_PHASES_BEFORE_TAIL = 2L
        private const val DEAD_OBJECT_INJECT_AFTER_PHASES = 2L
        private const val TAIL_MARGIN_PHASES = 1L
    }

    fun run(config: Config): Result {
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        val stateMachine = config.stateMachine
        val controller = config.routingController

        var audioTrack: AudioTrack? = null
        var audioTracksCreated = 0
        var audioTracksReleased = 0
        var finalReleaseCount = 0
        var played = false
        var frozenBufferSizeInBytes = 0
        var frozenBufferSizeInFrames = -1L
        var frozenChannelMask = AudioFormat.CHANNEL_OUT_STEREO
        val bytesPerFrame = 2 * config.channelCount

        // -- Lanes --------------------------------------------------------
        var audioTrackInitOk = false
        var baseGainSetOk = false
        var routingListenerRegisteredOk = false
        var preStartDrainEmptyOk = false
        var routeChangeObservationOk = false
        var syntheticRouteChangedObservedOk = false
        var routeDisconnectFailClosedPauseOk = false
        var routeDisconnectHoldFrozenOk = false
        var deadObjectInjectedOnceOk = false
        var deadObjectOldTrackReleasedOk = false
        var deadObjectNewTrackStateInitializedOk = false
        var deadObjectNewTrackVolumeSetOk = false
        var deadObjectListenerHandoffOk = false
        var deadObjectNewTrackPlayOk = false
        var deadObjectRemainderResumedOk = false
        var deadObjectNoDoubleCountOk = false
        var transportCompletedOk = false
        var checksumIdentityOk = false
        var sinkWriteAccountingOk = false
        var transportStopCalled = false
        var transportStopAccepted = false

        // -- Response state (run-thread confined) -------------------------
        var autoResumeAllowed = true
        var terminalDrainPoint = false
        var applyOrdinal = 0L
        var transportCommandAttempts = 0L
        var setVolumeCalls = 0L
        var currentGain = -1f

        var routeChangedAppliedCount = 0L
        var syntheticRouteChangedAppliedCount = 0L
        var routeChangedAfterDisconnectCount = 0L
        var routeDisconnectAppliedCount = 0L
        var routeChangedApplySeq = -1L
        var routeChangedApplyOrder = -1L
        var routeDisconnectApplySeq = -1L
        var routeDisconnectApplyOrder = -1L
        var routedDeviceTypeAtRouteChanged = -1
        var routedDeviceSampleOk = false

        // -- Dead-object recovery state (run-thread confined) -------------
        var syntheticDeadObjectInjectedCount = 0L
        var deadObjectObservedCount = 0L
        var deadObjectOldTrackReleaseCount = 0L
        var deadObjectOldTrackListenerDetachOk = false
        var deadObjectSliceBytesAtRecovery = -1L
        var deadObjectUnwrittenBytesAtRecovery = -1L
        var deadObjectBufferPositionAtRecovery = -1L
        var deadObjectSinkFramesWrittenBeforeRecovery = -1L
        var deadObjectSinkFramesWrittenAfterRecoveryCall = -1L
        var deadObjectRemainderFramesWrittenOnNewTrack = -1L
        var deadObjectFramesReadAtRecovery = -1L
        var deadObjectResumePending = false
        var playStateAfterRecreatePlay = -1
        var newTrackBufferSizeInFrames = -1L
        val deadObjectInjectAfterFrames = config.phaseFrames * DEAD_OBJECT_INJECT_AFTER_PHASES

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
        var playbackHeadAtRouteDisconnect = 0L
        var playbackHeadFinal = 0L
        var transportStateAtTailEnd = ""
        var nativeStateAtTailEnd = ""
        var sinkPlayStateAtTailEnd = -1
        var disconnectHoldDispatchDelta = -1L
        var disconnectHoldPushedDelta = -1L
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
            return try {
                track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            } catch (_: Throwable) {
                0L
            }
        }

        // Final release of whichever instance is current: exactly once.
        // Instances released by the dead-object recovery are counted in
        // audioTracksReleased separately, so every created instance is
        // accounted for.
        fun releaseAudioTrackOnce() {
            val track = audioTrack ?: return
            if (finalReleaseCount > 0) return
            try { finalPlayState = track.playState } catch (_: Throwable) {}
            try { track.stop() } catch (_: Throwable) {}
            try { track.release() } catch (_: Throwable) {}
            finalReleaseCount++
            audioTracksReleased++
            audioTrack = null
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

        // Builds the diagnostic sink with the parameters frozen at the first
        // build (format, channel mask, buffer bytes, MODE_STREAM), so the
        // recreated instance is a same-parameter instance by construction.
        fun buildDiagnosticAudioTrack(): AudioTrack {
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
                        .setChannelMask(frozenChannelMask)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(frozenBufferSizeInBytes)
                .build()
            audioTracksCreated++
            return track
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

        // Arms the ONE synthetic dead object: EOS scenario only, never
        // injected before, sink playing, route-changed already observed and
        // at least deadObjectInjectAfterFrames written. Returns true exactly
        // once per run; the caller then substitutes ERROR_DEAD_OBJECT for the
        // write result WITHOUT calling AudioTrack.write(). Synthetic and
        // deterministic by construction; this is not a forced OS dead object.
        fun armSyntheticDeadObject(sliceBytes: Int, unwrittenBytes: Int): Boolean {
            if (config.scenario != Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY) return false
            if (syntheticDeadObjectInjectedCount != 0L) return false
            if (!played || !routeChangeObservationOk) return false
            if (framesWrittenToSink < deadObjectInjectAfterFrames) return false
            if (sliceBytes <= 0 || unwrittenBytes <= 0) return false
            syntheticDeadObjectInjectedCount = 1L
            return true
        }

        // Recovery after ERROR_DEAD_OBJECT was observed on [oldTrack], all on
        // this run thread: listener handoff off the dead instance, release()
        // it exactly once (no pause/flush: a dead object accepts no further
        // control calls), build ONE same-parameter instance, assert
        // STATE_INITIALIZED and identical buffer geometry, reapply the base
        // gain, hand the listener over, play() and assert PLAYSTATE_PLAYING.
        // The native worker is never involved: it keeps rendering into the
        // output ring and at most sees normal ring backpressure.
        fun recreateAudioTrackAfterDeadObject(oldTrack: AudioTrack): AudioTrack {
            if (deadObjectOldTrackReleaseCount != 0L) fail("dead_object_old_track_already_released")
            if (finalReleaseCount > 0) fail("dead_object_after_final_release")

            // Handoff step 1: the listener leaves the dead instance before
            // its release (same order as the final teardown).
            deadObjectOldTrackListenerDetachOk = controller.detach()

            // Step 2: release the old instance exactly once.
            audioTrack = null
            try {
                oldTrack.release()
            } catch (t: Throwable) {
                fail("dead_object_old_track_release_failed:${t.javaClass.simpleName}")
            }
            audioTracksReleased++
            deadObjectOldTrackReleaseCount = 1L
            deadObjectOldTrackReleasedOk = true

            // Step 3: same-parameter recreate.
            val newTrack = try {
                buildDiagnosticAudioTrack()
            } catch (t: Throwable) {
                fail("recreated_audio_track_build_failed:${t.javaClass.simpleName}")
            }
            audioTrack = newTrack

            // Step 4: the recreated instance must be initialized with the
            // frozen buffer geometry.
            if (newTrack.state != AudioTrack.STATE_INITIALIZED) fail("recreated_audio_track_not_initialized")
            deadObjectNewTrackStateInitializedOk = true
            newTrackBufferSizeInFrames = newTrack.bufferSizeInFrames.toLong()
            if (newTrackBufferSizeInFrames != frozenBufferSizeInFrames) {
                fail("recreated_audio_track_buffer_geometry_mismatch:$newTrackBufferSizeInFrames:$frozenBufferSizeInFrames")
            }

            // Step 5: reapply the base gain (telemetry only).
            setGain(config.baseGain, "dead_object_reapply")
            deadObjectNewTrackVolumeSetOk = true

            // Handoff step 2: the same listener joins the new instance.
            if (!controller.attach(newTrack)) {
                fail("recreated_audio_track_listener_attach_failed:${controller.lastAttachError}")
            }
            deadObjectListenerHandoffOk = deadObjectOldTrackListenerDetachOk && controller.isAttached

            // Step 6: start the recreated instance; MODE_STREAM consumes once
            // the resumed writes land.
            newTrack.play()
            playStateAfterRecreatePlay = newTrack.playState
            if (playStateAfterRecreatePlay != AudioTrack.PLAYSTATE_PLAYING) {
                fail("recreated_audio_track_not_playing_after_play:$playStateAfterRecreatePlay")
            }
            deadObjectNewTrackPlayOk = true
            played = true
            return newTrack
        }

        fun writeAllToAudioTrack(buf: ByteBuffer, bytes: Int): Long {
            var track = requireTrack()
            var framesThisCall = 0L
            buf.position(0)
            buf.limit(bytes)
            var consecutiveZero = 0
            while (buf.hasRemaining()) {
                checkCancelled()
                checkDeadline()
                val requested = buf.remaining()
                val positionBefore = buf.position()
                val wrote = if (armSyntheticDeadObject(bytes, requested)) {
                    AudioTrack.ERROR_DEAD_OBJECT
                } else {
                    track.write(buf, requested, AudioTrack.WRITE_NON_BLOCKING)
                }
                val errorPrefix = if (deadObjectObservedCount > 0L) "recreated_audio_track" else "audio_track"
                when {
                    wrote > 0 -> {
                        consecutiveZero = 0
                        if (wrote % bytesPerFrame != 0) fail("${errorPrefix}_write_frame_misaligned:$wrote")
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
                        if (++consecutiveZero > MAX_CONSECUTIVE_ZERO_WRITES) fail("${errorPrefix}_write_stalled")
                        SystemClock.sleep(ZERO_WRITE_SLEEP_MS)
                    }
                    wrote == AudioTrack.ERROR_INVALID_OPERATION -> fail("${errorPrefix}_invalid_operation")
                    wrote == AudioTrack.ERROR_BAD_VALUE -> fail("${errorPrefix}_bad_value")
                    wrote == AudioTrack.ERROR_DEAD_OBJECT -> {
                        deadObjectObservedCount++
                        if (deadObjectObservedCount != 1L) {
                            fail("audio_track_dead_object_repeated:$deadObjectObservedCount")
                        }
                        // Only the armed synthetic dead object is recovered;
                        // a real OS dead object is outside this proof and
                        // fails closed exactly like Y4a.
                        if (syntheticDeadObjectInjectedCount != 1L) fail("audio_track_dead_object")
                        if (buf.position() != positionBefore || buf.remaining() != requested) {
                            fail("dead_object_consumed_bytes")
                        }
                        deadObjectSliceBytesAtRecovery = bytes.toLong()
                        deadObjectUnwrittenBytesAtRecovery = requested.toLong()
                        deadObjectBufferPositionAtRecovery = positionBefore.toLong()
                        deadObjectSinkFramesWrittenBeforeRecovery = framesWrittenToSink
                        deadObjectFramesReadAtRecovery = framesReadFromTransport
                        deadObjectInjectedOnceOk = true
                        // Recovery on this thread; the buffer position/limit
                        // are untouched, so the loop resumes on the same
                        // unwritten remainder.
                        track = recreateAudioTrackAfterDeadObject(track)
                        deadObjectResumePending = true
                        consecutiveZero = 0
                    }
                    else -> fail("${errorPrefix}_generic_error:$wrote")
                }
            }
            if (deadObjectResumePending) {
                // The remainder present at injection was written by the new
                // instance: exactly those frames, no more, no less, and the
                // slice total is intact.
                deadObjectResumePending = false
                deadObjectSinkFramesWrittenAfterRecoveryCall = framesWrittenToSink
                deadObjectRemainderFramesWrittenOnNewTrack =
                    framesWrittenToSink - deadObjectSinkFramesWrittenBeforeRecovery
                val remainderFrames = deadObjectUnwrittenBytesAtRecovery / bytesPerFrame
                deadObjectRemainderResumedOk =
                    deadObjectRemainderFramesWrittenOnNewTrack == remainderFrames &&
                    framesThisCall == (bytes / bytesPerFrame).toLong()
                if (!deadObjectRemainderResumedOk) {
                    fail("dead_object_remainder_accounting:$deadObjectRemainderFramesWrittenOnNewTrack:$remainderFrames")
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

        // -- Routing event applier (run thread only) ----------------------
        fun applyEvent(event: Event) {
            val track = requireTrack()
            val order = applyOrdinal++
            when (event.tag) {
                Tag.ROUTE_CHANGED -> {
                    if (routeDisconnectAppliedCount > 0L) {
                        // Terminal pause already applied: recorded no-op.
                        routeChangedAfterDisconnectCount++
                        return
                    }
                    val device = try {
                        track.routedDevice
                    } catch (t: Throwable) {
                        fail("routed_device_sample_failed:${t.javaClass.simpleName}")
                    }
                    if (routeChangedAppliedCount == 0L) {
                        routeChangedApplySeq = event.seq
                        routeChangedApplyOrder = order
                        routedDeviceTypeAtRouteChanged = device?.type ?: -1
                        routedDeviceSampleOk = true
                        routeChangeObservationOk = true
                    }
                    routeChangedAppliedCount++
                    if (event.source == Source.SYNTHETIC) syntheticRouteChangedAppliedCount++
                }
                Tag.ROUTE_DISCONNECT -> {
                    if (!terminalDrainPoint) fail("route_disconnect_at_non_terminal_point")
                    if (routeDisconnectAppliedCount > 0L) fail("duplicate_route_disconnect")
                    if (routeChangedAppliedCount == 0L) fail("route_disconnect_before_route_changed")
                    if (stateMachine.currentState != State.PLAYING) {
                        fail("route_disconnect_transport_not_playing:${stateMachine.currentState}")
                    }
                    if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                        fail("route_disconnect_from_non_playing_state:${track.playState}")
                    }
                    // Terminal fail-closed pause; never auto-resumed. Transport
                    // first, then sink: no flush/stop, no recreate, no play().
                    autoResumeAllowed = false
                    transportCommandAttempts++
                    val pauseResult = stateMachine.pause()
                    if (!pauseResult.accepted) fail("route_disconnect_pause_rejected:${pauseResult.reason}")
                    if (pauseResult.state != State.PAUSED) fail("route_disconnect_pause_not_paused:${pauseResult.state}")
                    val reply = pauseResult.reply ?: fail("route_disconnect_pause_null_reply")
                    if (reply.state != NativeState.PAUSED) fail("route_disconnect_native_not_paused:${reply.stateToken}")
                    track.pause()
                    if (track.playState != AudioTrack.PLAYSTATE_PAUSED) {
                        fail("route_disconnect_sink_not_paused:${track.playState}")
                    }
                    routeDisconnectAppliedCount = 1L
                    routeDisconnectApplySeq = event.seq
                    routeDisconnectApplyOrder = order
                    routeDisconnectFailClosedPauseOk = true
                }
            }
        }

        // Non-blocking drain point: applies everything pending, in seq order.
        fun drainRoutingEvents(phase: String): Int {
            var applied = 0
            while (true) {
                val event = controller.pollEvent() ?: break
                applyEvent(event)
                if (++applied > MAX_EVENTS_PER_DRAIN_POINT) fail("routing_drain_unbounded_$phase")
            }
            return applied
        }

        // Bounded wait until the synthetic ROUTE_CHANGED has been applied;
        // any real ROUTE_CHANGED ahead of it is applied (observed) too.
        fun awaitSyntheticRouteChanged(phase: String) {
            val waitDeadline = SystemClock.elapsedRealtime() + config.eventAwaitMs
            var applied = 0
            while (syntheticRouteChangedAppliedCount == 0L) {
                val remaining = waitDeadline - SystemClock.elapsedRealtime()
                if (remaining <= 0L) fail("event_timeout_$phase:route_changed")
                val event = controller.awaitEvent(remaining) {
                    !config.cancelled() && SystemClock.elapsedRealtime() <= deadline
                }
                checkCancelled()
                checkDeadline()
                if (event == null) continue
                if (event.tag != Tag.ROUTE_CHANGED) {
                    fail("unexpected_event_$phase:${event.tag.name.lowercase()}:${event.source.name.lowercase()}:seq=${event.seq}")
                }
                applyEvent(event)
                if (++applied > MAX_EVENTS_PER_DRAIN_POINT) fail("routing_drain_unbounded_$phase")
            }
        }

        fun makeResult(): Result {
            val status = if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" }
            val audioTrackReleasedOk = audioTracksCreated >= 1 &&
                audioTracksReleased == audioTracksCreated &&
                finalReleaseCount == 1 &&
                audioTrack == null
            val transportStateAtReturn = stateMachine.currentState
            val transportLeftLive = transportStateAtReturn == State.PREPARED ||
                transportStateAtReturn == State.PLAYING ||
                transportStateAtReturn == State.PAUSED
            val telemetry = controller.telemetry()
            val routingListenerUnregisteredOk = controller.isReleased &&
                !controller.isAttached &&
                controller.attachCount >= 1 &&
                controller.detachCount == controller.attachCount &&
                controller.lastDetachError.isEmpty()
            val eventsDropped = controller.droppedCount
            val lifecycleOk = audioTrackReleasedOk &&
                routingListenerUnregisteredOk &&
                !transportLeftLive &&
                eventsDropped == 0L &&
                controller.isReleased
            val transportStoppedOk = routeDisconnectFailClosedPauseOk &&
                transportStopCalled &&
                transportStopAccepted &&
                transportStateAtReturn == State.STOPPED
            val kotlinSinkChecksumHex = String.format("%016x", kotlinSinkChecksum)
            val lanes = mapOf(
                "audioTrackInitOk" to audioTrackInitOk,
                "baseGainSetOk" to baseGainSetOk,
                "routingListenerRegisteredOk" to routingListenerRegisteredOk,
                "routingListenerUnregisteredOk" to routingListenerUnregisteredOk,
                "preStartDrainEmptyOk" to preStartDrainEmptyOk,
                "routeChangeObservationOk" to routeChangeObservationOk,
                "syntheticRouteChangedObservedOk" to syntheticRouteChangedObservedOk,
                "routeDisconnectFailClosedPauseOk" to routeDisconnectFailClosedPauseOk,
                "routeDisconnectHoldFrozenOk" to routeDisconnectHoldFrozenOk,
                "deadObjectInjectedOnceOk" to deadObjectInjectedOnceOk,
                "deadObjectOldTrackReleasedOk" to deadObjectOldTrackReleasedOk,
                "deadObjectNewTrackStateInitializedOk" to deadObjectNewTrackStateInitializedOk,
                "deadObjectNewTrackVolumeSetOk" to deadObjectNewTrackVolumeSetOk,
                "deadObjectListenerHandoffOk" to deadObjectListenerHandoffOk,
                "deadObjectNewTrackPlayOk" to deadObjectNewTrackPlayOk,
                "deadObjectRemainderResumedOk" to deadObjectRemainderResumedOk,
                "deadObjectNoDoubleCountOk" to deadObjectNoDoubleCountOk,
                "transportCompletedOk" to transportCompletedOk,
                "transportStoppedOk" to transportStoppedOk,
                "checksumIdentityOk" to checksumIdentityOk,
                "sinkWriteAccountingOk" to sinkWriteAccountingOk,
                "audioTrackReleasedOk" to audioTrackReleasedOk,
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
                "currentGainTelemetry" to currentGain,
                "setVolumeCalls" to setVolumeCalls,
                "autoResumeAllowed" to autoResumeAllowed,
                "frozenBufferSizeInBytes" to frozenBufferSizeInBytes,
                "frozenBufferSizeInFrames" to frozenBufferSizeInFrames,
                "routeChangedAppliedCount" to routeChangedAppliedCount,
                "syntheticRouteChangedAppliedCount" to syntheticRouteChangedAppliedCount,
                "routeChangedAfterDisconnectCount" to routeChangedAfterDisconnectCount,
                "routeDisconnectAppliedCount" to routeDisconnectAppliedCount,
                "routeChangedApplySeq" to routeChangedApplySeq,
                "routeChangedApplyOrder" to routeChangedApplyOrder,
                "routeDisconnectApplySeq" to routeDisconnectApplySeq,
                "routeDisconnectApplyOrder" to routeDisconnectApplyOrder,
                "routedDeviceSampleOk" to routedDeviceSampleOk,
                "routedDeviceTypeAtRouteChanged" to routedDeviceTypeAtRouteChanged,
                "appliedEventCount" to applyOrdinal,
                "transportCommandAttempts" to transportCommandAttempts,
                "syntheticDeadObjectInjectedCount" to syntheticDeadObjectInjectedCount,
                "deadObjectObservedCount" to deadObjectObservedCount,
                "deadObjectInjectAfterFrames" to deadObjectInjectAfterFrames,
                "deadObjectOldTrackReleaseCount" to deadObjectOldTrackReleaseCount,
                "deadObjectOldTrackListenerDetachOk" to deadObjectOldTrackListenerDetachOk,
                "deadObjectSliceBytesAtRecovery" to deadObjectSliceBytesAtRecovery,
                "deadObjectUnwrittenBytesAtRecovery" to deadObjectUnwrittenBytesAtRecovery,
                "deadObjectBufferPositionAtRecovery" to deadObjectBufferPositionAtRecovery,
                "deadObjectSinkFramesWrittenBeforeRecovery" to deadObjectSinkFramesWrittenBeforeRecovery,
                "deadObjectSinkFramesWrittenAfterRecoveryCall" to deadObjectSinkFramesWrittenAfterRecoveryCall,
                "deadObjectRemainderFramesWrittenOnNewTrack" to deadObjectRemainderFramesWrittenOnNewTrack,
                "deadObjectFramesReadAtRecovery" to deadObjectFramesReadAtRecovery,
                "playStateAfterRecreatePlay" to playStateAfterRecreatePlay,
                "newTrackBufferSizeInFrames" to newTrackBufferSizeInFrames,
                "audioTracksCreated" to audioTracksCreated,
                "audioTracksReleased" to audioTracksReleased,
                "finalReleaseCount" to finalReleaseCount,
                "framesReadFromTransport" to framesReadFromTransport,
                "framesWrittenToSink" to framesWrittenToSink,
                "partialWriteCount" to partialWriteCount,
                "zeroWriteCount" to zeroWriteCount,
                "drainIterations" to drainIterations,
                "playbackHeadAtRouteDisconnect" to playbackHeadAtRouteDisconnect,
                "playbackHeadFinal" to playbackHeadFinal,
                "transportStateAtTailEnd" to transportStateAtTailEnd,
                "nativeStateAtTailEnd" to nativeStateAtTailEnd,
                "sinkPlayStateAtTailEnd" to sinkPlayStateAtTailEnd,
                "disconnectHoldDispatchDelta" to disconnectHoldDispatchDelta,
                "disconnectHoldPushedDelta" to disconnectHoldPushedDelta,
                "prefixNativeDrainedFrames" to prefixNativeDrainedFrames,
                "kotlinSinkChecksumHex" to kotlinSinkChecksumHex,
                "nativeChecksumHex" to nativeChecksumHex,
                "lateEventsAtTeardown" to lateEventsAtTeardown,
                "finalPlayState" to finalPlayState,
                "transportStopCalled" to transportStopCalled,
                "transportStopAccepted" to transportStopAccepted,
                "transportState" to transportStateAtReturn.name,
                "transportGeneration" to stateMachine.currentGeneration,
            ) + telemetry.mapKeys { "routing_${it.key}" }
            return Result(
                pass = pass,
                status = status,
                failureReason = failureReason,
                proofBoundary = PROOF_BOUNDARY,
                scenario = config.scenario,
                lanes = lanes,
                metrics = metrics,
                audioTrackInitOk = audioTrackInitOk,
                baseGainSetOk = baseGainSetOk,
                routingListenerRegisteredOk = routingListenerRegisteredOk,
                routingListenerUnregisteredOk = routingListenerUnregisteredOk,
                routeChangeObservationOk = routeChangeObservationOk,
                routeDisconnectFailClosedPauseOk = routeDisconnectFailClosedPauseOk,
                deadObjectInjectedOnceOk = deadObjectInjectedOnceOk,
                deadObjectOldTrackReleasedOk = deadObjectOldTrackReleasedOk,
                deadObjectNewTrackStateInitializedOk = deadObjectNewTrackStateInitializedOk,
                deadObjectNewTrackVolumeSetOk = deadObjectNewTrackVolumeSetOk,
                deadObjectNewTrackPlayOk = deadObjectNewTrackPlayOk,
                deadObjectRemainderResumedOk = deadObjectRemainderResumedOk,
                deadObjectNoDoubleCountOk = deadObjectNoDoubleCountOk,
                transportCompletedOk = transportCompletedOk,
                transportStoppedOk = transportStoppedOk,
                autoResumeAllowed = autoResumeAllowed,
                checksumIdentityOk = checksumIdentityOk,
                sinkWriteAccountingOk = sinkWriteAccountingOk,
                audioTrackReleasedOk = audioTrackReleasedOk,
                lifecycleOk = lifecycleOk,
                audioTracksCreated = audioTracksCreated,
                audioTracksReleased = audioTracksReleased,
                finalReleaseCount = finalReleaseCount,
                listenerAttachCount = controller.attachCount,
                listenerDetachCount = controller.detachCount,
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
            val minimumDeclared = config.phaseFrames *
                (maxOf(SCRIPT_PHASES_BEFORE_TAIL, DEAD_OBJECT_INJECT_AFTER_PHASES) + TAIL_MARGIN_PHASES)
            if (config.declaredFrameCount <= minimumDeclared) fail("invalid_declared_frame_count")
            if (config.declaredFrameCount >
                VanguardRealtimePlaybackNativeSession.MAX_DECLARED_SECONDS * config.sampleRate
            ) {
                fail("invalid_declared_frame_count")
            }
            if (config.baseGain <= 0f || config.baseGain > 1f) fail("invalid_base_gain")
            if (config.pauseHoldMs < 0L) fail("invalid_pause_hold_ms")
            if (config.eventAwaitMs <= 0L) fail("invalid_event_await_ms")
            if (config.deadlineMs <= 0L) fail("invalid_deadline_ms")
            if (controller.isReleased) fail("routing_controller_released")
            if (controller.isAttached || controller.attachCount != 0) fail("routing_controller_already_used")
            val initialState = stateMachine.currentState
            if (initialState != State.IDLE) fail("invalid_state_${initialState.name.lowercase()}")

            frozenChannelMask = if (config.channelCount == 1) {
                AudioFormat.CHANNEL_OUT_MONO
            } else {
                AudioFormat.CHANNEL_OUT_STEREO
            }

            // -- 2. Nonzero-gain diagnostic AudioTrack + listener ---------
            val minBytes = AudioTrack.getMinBufferSize(
                config.sampleRate, frozenChannelMask, AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBytes <= 0) fail("audio_track_min_buffer_invalid:$minBytes")
            val floorBytes = (TRACK_BUFFER_MARGIN_WINDOWS * config.maxFramesPerMix * bytesPerFrame).toInt()
            frozenBufferSizeInBytes = maxOf(minBytes, floorBytes)
            val firstTrack = buildDiagnosticAudioTrack()
            audioTrack = firstTrack
            if (firstTrack.state != AudioTrack.STATE_INITIALIZED) fail("audio_track_not_initialized")
            frozenBufferSizeInFrames = firstTrack.bufferSizeInFrames.toLong()
            audioTrackInitOk = true
            setGain(config.baseGain, "base")
            baseGainSetOk = true

            checkCancelled()
            if (!controller.attach(firstTrack)) {
                fail("routing_listener_register_failed:${controller.lastAttachError}")
            }
            routingListenerRegisteredOk = true
            // Pre-start drain point: nothing may be pending before the
            // script injects its first event. (A real OS routing callback
            // fires only after play(), so the queue must still be empty.)
            val preStart = controller.drainAll()
            if (preStart.isNotEmpty()) {
                val first = preStart.first()
                fail("unexpected_pre_start_event:${first.tag.name.lowercase()}:${first.source.name.lowercase()}")
            }
            preStartDrainEmptyOk = true

            // -- 3. Transport load/prepare/start ------------------------
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

            // Every drain iteration is a routing drain point first: real
            // ROUTE_CHANGED callbacks are observed as they arrive.
            fun drainAndWriteOnce(phase: String): Reply {
                checkCancelled()
                checkDeadline()
                drainRoutingEvents(phase)
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
                    val written = writeAllToAudioTrack(drainBuffer, framesRead * bytesPerFrame)
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

            drainAtLeast("pre_route_changed", config.phaseFrames)
            if (!played) fail("no_frames_written_to_sink_pre_route_changed")

            // -- 4. Synthetic route-changed observation (telemetry only) -
            if (!controller.postSyntheticRouteChanged()) fail("synthetic_post_rejected_route_changed")
            awaitSyntheticRouteChanged("route_changed")
            if (routeChangedAppliedCount < 1L || !routeChangeObservationOk) fail("route_changed_not_observed")
            if (syntheticRouteChangedAppliedCount != 1L) fail("synthetic_route_changed_count:$syntheticRouteChangedAppliedCount")
            if (requireTrack().playState != AudioTrack.PLAYSTATE_PLAYING) fail("route_changed_changed_play_state")
            if (stateMachine.currentState != State.PLAYING) fail("route_changed_changed_transport_state:${stateMachine.currentState}")
            if (audioTracksCreated != 1) fail("route_changed_recreated_track")
            syntheticRouteChangedObservedOk = true
            drainAtLeast("post_route_changed", config.phaseFrames * SCRIPT_PHASES_BEFORE_TAIL)

            fun captureTailEndState(phase: String) {
                transportStateAtTailEnd = stateMachine.currentState.name
                sinkPlayStateAtTailEnd = requireTrack().playState
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

            when (config.scenario) {
                Scenario.EOS_WITH_DEAD_OBJECT_RECOVERY -> {
                    // -- 5a. Drain to EOS; the ONE synthetic dead object arms
                    // inside the write loop once the injection threshold is
                    // reached and recovery happens inline. --------------
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
                    if (syntheticDeadObjectInjectedCount != 1L || deadObjectObservedCount != 1L) {
                        fail("dead_object_never_injected:$syntheticDeadObjectInjectedCount:$deadObjectObservedCount")
                    }
                    if (!deadObjectRemainderResumedOk) fail("dead_object_remainder_not_resumed")
                    if (audioTracksCreated != 2 || deadObjectOldTrackReleaseCount != 1L) {
                        fail("dead_object_instance_accounting:$audioTracksCreated:$deadObjectOldTrackReleaseCount")
                    }
                    if (routeDisconnectAppliedCount != 0L) fail("route_disconnect_in_eos_scenario")

                    // Final drain point before the head catch-up.
                    drainRoutingEvents("post_eos")
                    val catchUpDeadline = SystemClock.elapsedRealtime() + HEAD_CATCHUP_MARGIN_MS
                    val newTrackFrames = framesWrittenToSink - deadObjectSinkFramesWrittenBeforeRecovery
                    while (rawHead() < newTrackFrames) {
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
                        framesReadFromTransport == config.declaredFrameCount &&
                        prefixNativeDrainedFrames == config.declaredFrameCount
                    if (!sinkWriteAccountingOk) fail("sink_write_accounting_mismatch")

                    // No frame was counted twice or dropped across the
                    // recreate: the frames written before the injection plus
                    // the remainder written on the new instance equal the
                    // total at the end of that write call, and the run total
                    // equals what the transport handed out.
                    val remainderFrames = deadObjectUnwrittenBytesAtRecovery / bytesPerFrame
                    deadObjectNoDoubleCountOk = deadObjectRemainderResumedOk &&
                        deadObjectSinkFramesWrittenBeforeRecovery + remainderFrames ==
                        deadObjectSinkFramesWrittenAfterRecoveryCall &&
                        deadObjectSinkFramesWrittenBeforeRecovery >= deadObjectInjectAfterFrames &&
                        deadObjectSinkFramesWrittenBeforeRecovery < config.declaredFrameCount &&
                        framesWrittenToSink == framesReadFromTransport
                    if (!deadObjectNoDoubleCountOk) fail("dead_object_double_count_or_drop")
                    captureTailEndState("eos")
                }
                Scenario.ROUTE_DISCONNECT_TERMINAL -> {
                    // -- 5b. Route disconnect while PLAYING: terminal fail-
                    // closed pause (transport.pause() -> AudioTrack.pause()).
                    // No dead object is injected in this scenario. ---------
                    checkCancelled()
                    checkDeadline()
                    if (stateMachine.currentState != State.PLAYING) fail("transport_not_playing_before_disconnect:${stateMachine.currentState}")
                    if (requireTrack().playState != AudioTrack.PLAYSTATE_PLAYING) fail("sink_not_playing_before_disconnect")
                    // Any real route-changed pending now is observed strictly
                    // BEFORE the disconnect is enqueued on this thread.
                    drainRoutingEvents("pre_disconnect")
                    terminalDrainPoint = true
                    if (!controller.postSyntheticRouteDisconnect()) fail("synthetic_post_rejected_route_disconnect")
                    val attemptsBeforeDisconnect = transportCommandAttempts
                    drainRoutingEvents("disconnect")
                    if (routeDisconnectAppliedCount != 1L) fail("route_disconnect_not_applied")
                    if (transportCommandAttempts != attemptsBeforeDisconnect + 1L) fail("route_disconnect_command_accounting")
                    if (autoResumeAllowed) fail("auto_resume_still_allowed_after_disconnect")
                    if (stateMachine.currentState != State.PAUSED) fail("transport_not_paused_after_disconnect:${stateMachine.currentState}")
                    if (requireTrack().playState != AudioTrack.PLAYSTATE_PAUSED) fail("sink_not_paused_after_disconnect")
                    if (routeDisconnectApplySeq <= routeChangedApplySeq) fail("disconnect_before_route_changed")
                    if (deadObjectObservedCount != 0L || syntheticDeadObjectInjectedCount != 0L) fail("dead_object_in_disconnect_scenario")
                    if (audioTracksCreated != 1) fail("disconnect_recreated_track")
                    if (transportStopCalled) fail("transport_stopped_in_disconnect_apply")
                    playbackHeadAtRouteDisconnect = rawHead()

                    // -- 6b. Hold frozen: no dispatch / push while paused --
                    val hold = holdFrozen("disconnect")
                    disconnectHoldDispatchDelta = hold.first
                    disconnectHoldPushedDelta = hold.second
                    routeDisconnectHoldFrozenOk = true
                    if (autoResumeAllowed) fail("auto_resume_allowed_after_disconnect_hold")
                    if (stateMachine.currentState != State.PAUSED) fail("transport_left_paused_after_disconnect_hold:${stateMachine.currentState}")
                    if (requireTrack().playState != AudioTrack.PLAYSTATE_PAUSED) fail("sink_left_paused_after_disconnect_hold")

                    // -- 7b. Prefix checksum identity + partial accounting -
                    verifyPrefixChecksum("disconnect")
                    sinkWriteAccountingOk = framesReadFromTransport == framesWrittenToSink &&
                        framesReadFromTransport >= config.phaseFrames * SCRIPT_PHASES_BEFORE_TAIL &&
                        framesReadFromTransport < config.declaredFrameCount &&
                        prefixNativeDrainedFrames == framesReadFromTransport
                    if (!sinkWriteAccountingOk) fail("sink_write_accounting_mismatch")
                    playbackHeadFinal = rawHead()
                    captureTailEndState("disconnect")
                    if (transportStateAtTailEnd != State.PAUSED.name) fail("transport_not_paused_at_disconnect_tail_end:$transportStateAtTailEnd")
                    // Teardown (finally) detaches the listener once, releases
                    // the AudioTrack once, and stops the still-PAUSED
                    // transport exactly once.
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
            // Listener off the track first, then the AudioTrack once, then
            // leave no live transport behind. Never disposes the state
            // machine.
            try {
                controller.release()
            } catch (_: Throwable) {
            }
            releaseAudioTrackOnce()
            try {
                stopTransportIfLive()
            } catch (_: Throwable) {
            }
        }

        return makeResult()
    }
}
