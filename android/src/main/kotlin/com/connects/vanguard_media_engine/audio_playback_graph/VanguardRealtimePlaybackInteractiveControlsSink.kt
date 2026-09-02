package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── VanguardRealtimePlaybackInteractiveControlsSink (P4-AUDIO-REALTIME-
// PLAYBACK-INTERACTIVE-CONTROLS, Y3) ─────────────────────────────────────
//
// One reusable Kotlin adapter that proves the interactive control
// contract between a caller-supplied
// [VanguardRealtimePlaybackTransportStateMachine] (Y1) and one muted
// android.media.AudioTrack sink (the Y2 shape): pause, resume and seek
// are applied to BOTH sides in a fixed order and each side is verified
// after every step. The adapter owns exactly the AudioTrack lifecycle
// (created here, stopped + released exactly once in `finally`) and the
// non-blocking PCM16 write accounting on the caller's thread. The state
// machine is never disposed here; it stays the caller's responsibility.
// The only transport command issued outside the scripted sequence is one
// `stop()` on the way out when the transport is still live (PREPARED/
// PLAYING/PAUSED), so no caller inherits a running native worker.
//
// Scripted sequence of [run]:
//   1. validate config, create the muted MODE_STREAM AudioTrack
//   2. load/prepare/start the transport, drain + write >= preControlFrames
//      through one reused direct little-endian buffer (AudioTrack.play()
//      after the first positive write)
//   3. pause: transport.pause() -> AudioTrack.pause(); two snapshots
//      pauseHoldMs apart with no drain/write must show dispatchCount and
//      pushedFrames frozen
//   4. resume: AudioTrack.play() -> transport.resume()
//   5. active-before-seek: transport must be PLAYING (not completed/failed)
//      and native must have advanced (dispatch or pushed) since the pause
//      snapshot, or hold readable output
//   6. seek: sample playback head, AudioTrack.pause() + flush() exactly
//      once, transport.seek(seekTargetFrame) while PLAYING (stays PLAYING,
//      generation advances), AudioTrack.play()
//   7. drain + write until native EOS; frames handed to the sink must be
//      exactly framesWrittenPreSeek + (declaredFrameCount - seekTargetFrame)
//      and the cumulative Kotlin sink checksum (pre + post seek) must equal
//      the native drainedChecksumHex of the final drain reply
//
// [PROOF_BOUNDARY]: muted diagnostic AudioTrack interactive controls only;
// synthetic PCM from the Y1 transport; no MediaCodec, no MediaExtractor,
// no audio focus, no route change, no dead-object recovery, no production
// presentation clock, no A/V sync, no audible output, no product/editor/
// app wiring, no iOS, no streaming/cache, no native C++ changes.
class VanguardRealtimePlaybackInteractiveControlsSink {

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        val pauseHoldMs: Long = 150L,
        val preControlFrames: Long = 4096L,
        val seekTargetFrame: Long = 6000L,
        val deadlineMs: Long = 30_000L,
        val cancelled: () -> Boolean = { false },
    )

    data class Result(
        val pass: Boolean,
        val status: String,
        val failureReason: String,
        val proofBoundary: String,
        val lanes: Map<String, Any?>,
        val metrics: Map<String, Any?>,
        val audioTrackInitOk: Boolean,
        val mutedOutputOk: Boolean,
        val initialDrainOk: Boolean,
        val pauseCommandOk: Boolean,
        val sinkPausedOk: Boolean,
        val pauseHoldFrozenOk: Boolean,
        val resumeCommandOk: Boolean,
        val sinkResumedOk: Boolean,
        val activeBeforeSeekOk: Boolean,
        val seekCommandOk: Boolean,
        val sinkFlushAtSeekOk: Boolean,
        val postSeekDrainOk: Boolean,
        val transportCompletedOk: Boolean,
        val checksumIdentityOk: Boolean,
        val sinkWriteAccountingOk: Boolean,
        val lifecycleOk: Boolean,
        val audioTrackReleasedOk: Boolean,
        val releaseCount: Int,
        val framesWrittenPreSeek: Long,
        val sinkFramesDiscardedAtSeek: Long,
        val framesWrittenPostSeek: Long,
        val totalFramesWrittenToSink: Long,
        val expectedFramesWrittenToSink: Long,
        val playbackHeadAtSeek: Long,
        val playbackHeadFinal: Long,
        val zeroWriteCount: Long,
        val partialWriteCount: Long,
        val kotlinSinkChecksumHex: String,
        val nativeDrainedChecksumHex: String,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    companion object {
        const val PROOF_BOUNDARY =
            "muted_diagnostic_audiotrack_interactive_controls_only_synthetic_pcm_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_production_presentation_clock_no_av_sync_no_audible_output_no_product_editor_app_wiring_no_ios_no_streaming_cache_no_native_cpp_changes"

        private const val MUTED_VOLUME = 0.0f
        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val MAX_DRAIN_STALLS = 500
        private const val DRAIN_STALL_SLEEP_MS = 2L
        private const val DRAIN_ITERATION_MARGIN = 128L
        private const val PAUSE_HOLD_SLICE_MS = 10L
        private const val MAX_ACTIVE_PROBE_ATTEMPTS = 250
        private const val ACTIVE_PROBE_SLEEP_MS = 2L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L
    }

    fun run(config: Config): Result {
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        val stateMachine = config.stateMachine

        var audioTrack: AudioTrack? = null
        var releaseCount = 0
        var flushCount = 0
        var played = false

        var audioTrackInitOk = false
        var mutedOutputOk = false
        var initialDrainOk = false
        var pauseCommandOk = false
        var sinkPausedOk = false
        var pauseHoldFrozenOk = false
        var resumeCommandOk = false
        var sinkResumedOk = false
        var activeBeforeSeekOk = false
        var seekCommandOk = false
        var sinkFlushAtSeekOk = false
        var postSeekDrainOk = false
        var transportCompletedOk = false
        var checksumIdentityOk = false
        var sinkWriteAccountingOk = false
        var transportStopCalled = false
        var transportStopAccepted = false

        var framesReadFromTransport = 0L
        var totalFramesWrittenToSink = 0L
        var framesWrittenPreSeek = 0L
        var framesWrittenPostSeek = 0L
        var sinkFramesDiscardedAtSeek = 0L
        var expectedFramesWrittenToSink = 0L
        var partialWriteCount = 0L
        var zeroWriteCount = 0L
        var kotlinSinkChecksum = 0L
        var nativeDrainedChecksumHex = ""
        var lastReply: Reply? = null
        var drainIterations = 0L

        var playbackHeadAtPause = 0L
        var playbackHeadAtSeek = 0L
        var playbackHeadFinal = 0L
        var pauseSnapshotDispatch = 0L
        var pauseSnapshotPushed = 0L
        var pauseHoldDispatchDelta = 0L
        var pauseHoldPushedDelta = 0L
        var activeProbeAttempts = 0
        var activeProbeDrainedFrames = 0L
        var seekGenerationBefore = 0L
        var seekGenerationAfter = 0L
        var seekReplyPositionFrame = -1L
        var seekReplyDiscardedFrames = -1L
        var finalReplyDiscardedFrames = -1L
        var finalReplyPositionFrame = -1L

        var pass = false
        var failureReason = ""

        fun checkCancelled() {
            if (config.cancelled()) throw FailClosed("cancelled")
        }

        fun checkDeadline() {
            if (SystemClock.elapsedRealtime() > deadline) throw FailClosed("deadline_exceeded")
        }

        fun fail(reason: String): Nothing = throw FailClosed(reason)

        fun releaseAudioTrackOnce() {
            val track = audioTrack ?: return
            if (releaseCount > 0) return
            try { track.stop() } catch (_: Throwable) {}
            try { track.release() } catch (_: Throwable) {}
            releaseCount++
        }

        // Leaves no live transport behind: one stop() when the state
        // machine is still PREPARED/PLAYING/PAUSED. Terminal states
        // (COMPLETED/STOPPED/FAILED/DISPOSED) and IDLE are left untouched.
        // Never disposes; the caller owns the state machine.
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

        fun rawHead(): Long {
            val track = audioTrack ?: return 0L
            return track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        }

        fun requireTrack(): AudioTrack = audioTrack ?: fail("audio_track_missing")

        // Mirrors the native drain checksum accumulation (c = c * 31 +
        // uint16(sample)) over exactly the frames about to be handed to
        // AudioTrack.write; any write failure aborts the run, so every
        // sample counted here was fully accepted by the sink.
        fun accumulateChecksum(buf: ByteBuffer, frames: Int) {
            var c = kotlinSinkChecksum
            val sampleCount = frames * config.channelCount
            for (i in 0 until sampleCount) {
                c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
            }
            kotlinSinkChecksum = c
        }

        // Writes exactly `bytes` from offset 0 of `buf` with
        // WRITE_NON_BLOCKING; partial writes are retried in place, zero
        // writes are parked under a bounded budget. AudioTrack.play() is
        // issued right after the first positive write of the run.
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
                        totalFramesWrittenToSink += frames
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

        fun makeResult(): Result {
            val status = if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" }
            val audioTrackReleasedOk = releaseCount == 1
            val transportStateAtReturn = stateMachine.currentState
            val transportLeftLive = transportStateAtReturn == State.PREPARED ||
                transportStateAtReturn == State.PLAYING ||
                transportStateAtReturn == State.PAUSED
            val lifecycleOk = audioTrackReleasedOk && flushCount <= 1 && !transportLeftLive
            val kotlinSinkChecksumHex = String.format("%016x", kotlinSinkChecksum)
            val lanes = mapOf(
                "audioTrackInitOk" to audioTrackInitOk,
                "mutedOutputOk" to mutedOutputOk,
                "initialDrainOk" to initialDrainOk,
                "pauseCommandOk" to pauseCommandOk,
                "sinkPausedOk" to sinkPausedOk,
                "pauseHoldFrozenOk" to pauseHoldFrozenOk,
                "resumeCommandOk" to resumeCommandOk,
                "sinkResumedOk" to sinkResumedOk,
                "activeBeforeSeekOk" to activeBeforeSeekOk,
                "seekCommandOk" to seekCommandOk,
                "sinkFlushAtSeekOk" to sinkFlushAtSeekOk,
                "postSeekDrainOk" to postSeekDrainOk,
                "transportCompletedOk" to transportCompletedOk,
                "checksumIdentityOk" to checksumIdentityOk,
                "sinkWriteAccountingOk" to sinkWriteAccountingOk,
                "audioTrackReleasedOk" to audioTrackReleasedOk,
                "lifecycleOk" to lifecycleOk,
            )
            val metrics = mapOf(
                "sampleRate" to config.sampleRate,
                "channelCount" to config.channelCount,
                "maxFramesPerMix" to config.maxFramesPerMix,
                "declaredFrameCount" to config.declaredFrameCount,
                "pauseHoldMs" to config.pauseHoldMs,
                "preControlFrames" to config.preControlFrames,
                "seekTargetFrame" to config.seekTargetFrame,
                "framesReadFromTransport" to framesReadFromTransport,
                "framesWrittenPreSeek" to framesWrittenPreSeek,
                "sinkFramesDiscardedAtSeek" to sinkFramesDiscardedAtSeek,
                "framesWrittenPostSeek" to framesWrittenPostSeek,
                "totalFramesWrittenToSink" to totalFramesWrittenToSink,
                "expectedFramesWrittenToSink" to expectedFramesWrittenToSink,
                "playbackHeadAtPause" to playbackHeadAtPause,
                "playbackHeadAtSeek" to playbackHeadAtSeek,
                "playbackHeadFinal" to playbackHeadFinal,
                "pauseSnapshotDispatchCount" to pauseSnapshotDispatch,
                "pauseSnapshotPushedFrames" to pauseSnapshotPushed,
                "pauseHoldDispatchDelta" to pauseHoldDispatchDelta,
                "pauseHoldPushedDelta" to pauseHoldPushedDelta,
                "activeProbeAttempts" to activeProbeAttempts,
                "activeProbeDrainedFrames" to activeProbeDrainedFrames,
                "seekGenerationBefore" to seekGenerationBefore,
                "seekGenerationAfter" to seekGenerationAfter,
                "seekReplyPositionFrame" to seekReplyPositionFrame,
                "seekReplyDiscardedFrames" to seekReplyDiscardedFrames,
                "finalReplyPositionFrame" to finalReplyPositionFrame,
                "finalReplyDiscardedFrames" to finalReplyDiscardedFrames,
                "drainIterations" to drainIterations,
                "partialWriteCount" to partialWriteCount,
                "zeroWriteCount" to zeroWriteCount,
                "flushCount" to flushCount,
                "releaseCount" to releaseCount,
                "kotlinSinkChecksumHex" to kotlinSinkChecksumHex,
                "nativeDrainedChecksumHex" to nativeDrainedChecksumHex,
                "transportStopCalled" to transportStopCalled,
                "transportStopAccepted" to transportStopAccepted,
                "transportState" to transportStateAtReturn.name,
            )
            return Result(
                pass = pass,
                status = status,
                failureReason = failureReason,
                proofBoundary = PROOF_BOUNDARY,
                lanes = lanes,
                metrics = metrics,
                audioTrackInitOk = audioTrackInitOk,
                mutedOutputOk = mutedOutputOk,
                initialDrainOk = initialDrainOk,
                pauseCommandOk = pauseCommandOk,
                sinkPausedOk = sinkPausedOk,
                pauseHoldFrozenOk = pauseHoldFrozenOk,
                resumeCommandOk = resumeCommandOk,
                sinkResumedOk = sinkResumedOk,
                activeBeforeSeekOk = activeBeforeSeekOk,
                seekCommandOk = seekCommandOk,
                sinkFlushAtSeekOk = sinkFlushAtSeekOk,
                postSeekDrainOk = postSeekDrainOk,
                transportCompletedOk = transportCompletedOk,
                checksumIdentityOk = checksumIdentityOk,
                sinkWriteAccountingOk = sinkWriteAccountingOk,
                lifecycleOk = lifecycleOk,
                audioTrackReleasedOk = audioTrackReleasedOk,
                releaseCount = releaseCount,
                framesWrittenPreSeek = framesWrittenPreSeek,
                sinkFramesDiscardedAtSeek = sinkFramesDiscardedAtSeek,
                framesWrittenPostSeek = framesWrittenPostSeek,
                totalFramesWrittenToSink = totalFramesWrittenToSink,
                expectedFramesWrittenToSink = expectedFramesWrittenToSink,
                playbackHeadAtSeek = playbackHeadAtSeek,
                playbackHeadFinal = playbackHeadFinal,
                zeroWriteCount = zeroWriteCount,
                partialWriteCount = partialWriteCount,
                kotlinSinkChecksumHex = kotlinSinkChecksumHex,
                nativeDrainedChecksumHex = nativeDrainedChecksumHex,
            )
        }

        try {
            checkCancelled()
            // ── 1. Config admission ────────────────────────────────────
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
            if (config.preControlFrames <= 0L) fail("invalid_pre_control_frames")
            if (config.seekTargetFrame <= config.preControlFrames) fail("invalid_seek_target_frame")
            if (config.declaredFrameCount <= config.seekTargetFrame) fail("invalid_declared_frame_count")
            if (config.declaredFrameCount >
                VanguardRealtimePlaybackNativeSession.MAX_DECLARED_SECONDS * config.sampleRate
            ) {
                fail("invalid_declared_frame_count")
            }
            if (config.pauseHoldMs < 0L) fail("invalid_pause_hold_ms")
            if (config.deadlineMs <= 0L) fail("invalid_deadline_ms")
            val initialState = stateMachine.currentState
            if (initialState != State.IDLE) fail("invalid_state_${initialState.name.lowercase()}")

            val bytesPerFrame = 2 * config.channelCount
            val channelMask = if (config.channelCount == 1) {
                AudioFormat.CHANNEL_OUT_MONO
            } else {
                AudioFormat.CHANNEL_OUT_STEREO
            }

            // ── 2. Muted diagnostic AudioTrack ─────────────────────────
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
            if (track.setVolume(MUTED_VOLUME) != AudioTrack.SUCCESS) fail("audio_track_set_volume_failed")
            mutedOutputOk = true

            // ── 3. Transport load/prepare/start + pre-control drain ────
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
            // Pre-seek reads are bounded by the declared length and
            // post-seek reads by (declared - seekTarget), so twice the
            // declared window plus a margin covers every phase.
            val maxDrainIterations =
                (config.declaredFrameCount / config.maxFramesPerMix) * 2L + DRAIN_ITERATION_MARGIN

            // One drain + write of up to maxFramesPerMix. Returns the reply;
            // frames read are accounted, checksummed and fully handed to the
            // sink before this returns.
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

            var stalls = 0
            while (framesReadFromTransport < config.preControlFrames) {
                val reply = drainAndWriteOnce("pre_control")
                if (reply.eosDrained) fail("eos_before_pre_control_frames")
                if (reply.framesRead > 0L) {
                    stalls = 0
                } else {
                    if (++stalls > MAX_DRAIN_STALLS) fail("drain_stalled_pre_control")
                    SystemClock.sleep(DRAIN_STALL_SLEEP_MS)
                }
            }
            if (!played) fail("no_frames_written_to_sink_pre_control")
            if (stateMachine.currentState != State.PLAYING) {
                fail("transport_not_playing_after_pre_control:${stateMachine.currentState}")
            }
            initialDrainOk = true

            // ── 4. Pause sync: transport first, then sink ──────────────
            checkCancelled()
            checkDeadline()
            val pauseResult = stateMachine.pause()
            if (!pauseResult.accepted) fail("pause_rejected:${pauseResult.reason}")
            if (pauseResult.state != State.PAUSED || stateMachine.currentState != State.PAUSED) {
                fail("transport_not_paused:${stateMachine.currentState}")
            }
            val pauseReply = pauseResult.reply ?: fail("pause_null_reply")
            if (pauseReply.state != NativeState.PAUSED) fail("native_not_paused:${pauseReply.stateToken}")
            pauseCommandOk = true

            track.pause()
            if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("audio_track_not_paused:${track.playState}")
            playbackHeadAtPause = rawHead()
            sinkPausedOk = true

            // Frozen-hold check: two snapshots pauseHoldMs apart with no
            // drain or write in between; native dispatch and push must not
            // move while paused.
            val holdStart = snapshotReply("hold_start")
            if (holdStart.state != NativeState.PAUSED) fail("native_not_paused_hold_start:${holdStart.stateToken}")
            pauseSnapshotDispatch = holdStart.dispatchCount
            pauseSnapshotPushed = holdStart.pushedFrames
            val holdEnd = SystemClock.elapsedRealtime() + config.pauseHoldMs
            while (true) {
                checkCancelled()
                checkDeadline()
                val remaining = holdEnd - SystemClock.elapsedRealtime()
                if (remaining <= 0L) break
                SystemClock.sleep(minOf(remaining, PAUSE_HOLD_SLICE_MS))
            }
            val holdStop = snapshotReply("hold_end")
            if (holdStop.state != NativeState.PAUSED) fail("native_not_paused_hold_end:${holdStop.stateToken}")
            if (stateMachine.currentState != State.PAUSED) {
                fail("transport_left_paused_during_hold:${stateMachine.currentState}")
            }
            pauseHoldDispatchDelta = holdStop.dispatchCount - holdStart.dispatchCount
            pauseHoldPushedDelta = holdStop.pushedFrames - holdStart.pushedFrames
            if (pauseHoldDispatchDelta != 0L || pauseHoldPushedDelta != 0L) {
                fail("pause_hold_not_frozen:dispatch=$pauseHoldDispatchDelta:pushed=$pauseHoldPushedDelta")
            }
            if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("audio_track_left_paused_during_hold")
            pauseHoldFrozenOk = true

            // ── 5. Resume sync: sink first, then transport ─────────────
            checkCancelled()
            checkDeadline()
            track.play()
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("audio_track_not_playing_after_resume:${track.playState}")
            sinkResumedOk = true
            val resumeResult = stateMachine.resume()
            if (!resumeResult.accepted) fail("resume_rejected:${resumeResult.reason}")
            if (resumeResult.state != State.PLAYING || stateMachine.currentState != State.PLAYING) {
                fail("transport_not_playing_after_resume:${stateMachine.currentState}")
            }
            val resumeReply = resumeResult.reply ?: fail("resume_null_reply")
            if (resumeReply.state != NativeState.PLAYING) fail("native_not_playing_after_resume:${resumeReply.stateToken}")
            resumeCommandOk = true

            // ── 6. Active-before-seek ──────────────────────────────────
            // Bounded probe: transport must still be PLAYING and native
            // must show forward progress since the pause snapshot (dispatch
            // or pushed advanced) or hold readable output. A drain attempt
            // is used to relieve output backpressure only while a single
            // window cannot reach the declared end.
            while (true) {
                checkCancelled()
                checkDeadline()
                if (++activeProbeAttempts > MAX_ACTIVE_PROBE_ATTEMPTS) fail("transport_inactive_after_resume")
                val probe = snapshotReply("active_probe")
                val transportState = stateMachine.currentState
                if (transportState == State.COMPLETED || transportState == State.FAILED) {
                    fail("transport_terminal_before_seek:${transportState.name.lowercase()}")
                }
                if (transportState != State.PLAYING) fail("transport_not_playing_before_seek:$transportState")
                if (probe.state == NativeState.COMPLETED || probe.state == NativeState.FAILED) {
                    fail("native_terminal_before_seek:${probe.stateToken}")
                }
                if (probe.state != NativeState.PLAYING) fail("native_not_playing_before_seek:${probe.stateToken}")
                val advanced = probe.dispatchCount > pauseSnapshotDispatch ||
                    probe.pushedFrames > pauseSnapshotPushed ||
                    probe.outputAvailableReadFrames > 0L
                if (advanced) break
                if (framesReadFromTransport + config.maxFramesPerMix < config.declaredFrameCount) {
                    val reply = drainAndWriteOnce("active_probe")
                    if (reply.eosDrained) fail("eos_before_seek")
                    activeProbeDrainedFrames += reply.framesRead
                }
                SystemClock.sleep(ACTIVE_PROBE_SLEEP_MS)
            }
            if (stateMachine.currentState != State.PLAYING) {
                fail("transport_not_playing_before_seek:${stateMachine.currentState}")
            }
            activeBeforeSeekOk = true

            // ── 7. Seek sync: sink pause+flush once, transport seek while
            //      PLAYING, sink play ─────────────────────────────────────
            checkCancelled()
            checkDeadline()
            framesWrittenPreSeek = totalFramesWrittenToSink
            playbackHeadAtSeek = rawHead()
            sinkFramesDiscardedAtSeek = maxOf(0L, framesWrittenPreSeek - playbackHeadAtSeek)
            track.pause()
            if (track.playState != AudioTrack.PLAYSTATE_PAUSED) fail("audio_track_not_paused_at_seek:${track.playState}")
            if (flushCount != 0) fail("audio_track_flush_count_divergence:$flushCount")
            track.flush()
            flushCount++
            sinkFlushAtSeekOk = true

            if (stateMachine.currentState != State.PLAYING) {
                fail("transport_not_playing_at_seek:${stateMachine.currentState}")
            }
            seekGenerationBefore = stateMachine.currentGeneration
            val seekResult = stateMachine.seek(config.seekTargetFrame)
            if (!seekResult.accepted) fail("seek_rejected:${seekResult.reason}")
            seekGenerationAfter = seekResult.generation
            if (seekResult.state != State.PLAYING || stateMachine.currentState != State.PLAYING) {
                fail("transport_not_playing_after_seek:${stateMachine.currentState}")
            }
            if (seekGenerationAfter != seekGenerationBefore + 1L) {
                fail("seek_generation_not_advanced:$seekGenerationBefore:$seekGenerationAfter")
            }
            val seekReply = seekResult.reply ?: fail("seek_null_reply")
            if (seekReply.state != NativeState.PLAYING) fail("native_not_playing_after_seek:${seekReply.stateToken}")
            seekReplyPositionFrame = seekReply.positionFrame
            seekReplyDiscardedFrames = seekReply.discardedFrames
            seekCommandOk = true
            expectedFramesWrittenToSink =
                framesWrittenPreSeek + (config.declaredFrameCount - config.seekTargetFrame)

            track.play()
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) fail("audio_track_not_playing_after_seek:${track.playState}")

            // ── 8. Post-seek drain/write until native EOS ──────────────
            val writtenBeforePostSeek = totalFramesWrittenToSink
            val readBeforePostSeek = framesReadFromTransport
            stalls = 0
            while (true) {
                val reply = drainAndWriteOnce("post_seek")
                if (reply.framesRead > 0L) stalls = 0
                if (reply.eosDrained) break
                if (reply.framesRead == 0L) {
                    if (++stalls > MAX_DRAIN_STALLS) fail("drain_stalled_post_seek")
                    SystemClock.sleep(DRAIN_STALL_SLEEP_MS)
                }
            }
            framesWrittenPostSeek = totalFramesWrittenToSink - writtenBeforePostSeek
            val framesReadPostSeek = framesReadFromTransport - readBeforePostSeek
            val expectedPostSeek = config.declaredFrameCount - config.seekTargetFrame
            if (framesWrittenPostSeek != expectedPostSeek || framesReadPostSeek != expectedPostSeek) {
                fail("post_seek_frame_mismatch:written=$framesWrittenPostSeek:read=$framesReadPostSeek:expected=$expectedPostSeek")
            }
            postSeekDrainOk = true

            // Bounded catch-up so playbackHeadFinal is meaningful (the head
            // restarted at zero on flush); not a gate.
            val catchUpDeadline = SystemClock.elapsedRealtime() + HEAD_CATCHUP_MARGIN_MS
            while (rawHead() < framesWrittenPostSeek) {
                checkCancelled()
                checkDeadline()
                if (SystemClock.elapsedRealtime() > catchUpDeadline) break
                SystemClock.sleep(HEAD_POLL_SLEEP_MS)
            }
            playbackHeadFinal = rawHead()

            // ── 9. Completion, checksum identity, accounting ───────────
            transportCompletedOk = stateMachine.currentState == State.COMPLETED
            if (!transportCompletedOk) fail("transport_not_completed:${stateMachine.currentState}")

            val finalReply = lastReply ?: fail("missing_final_reply")
            finalReplyPositionFrame = finalReply.positionFrame
            finalReplyDiscardedFrames = finalReply.discardedFrames
            nativeDrainedChecksumHex = finalReply.drainedChecksumHex
            val kotlinChecksumHex = String.format("%016x", kotlinSinkChecksum)
            checksumIdentityOk = nativeDrainedChecksumHex.isNotEmpty() &&
                kotlinChecksumHex.equals(nativeDrainedChecksumHex, ignoreCase = true)
            if (!checksumIdentityOk) fail("checksum_identity_mismatch")

            sinkWriteAccountingOk = totalFramesWrittenToSink == expectedFramesWrittenToSink &&
                framesReadFromTransport == expectedFramesWrittenToSink &&
                framesWrittenPreSeek + framesWrittenPostSeek == totalFramesWrittenToSink
            if (!sinkWriteAccountingOk) fail("sink_write_accounting_mismatch")

            pass = true
        } catch (f: FailClosed) {
            failureReason = f.reason
        } catch (e: Throwable) {
            failureReason = "exception:${e.javaClass.simpleName}:${e.message}"
        } finally {
            // Sink first (owned here), then leave no live transport behind.
            releaseAudioTrackOnce()
            try {
                stopTransportIfLive()
            } catch (_: Throwable) {
            }
        }

        return makeResult()
    }
}
