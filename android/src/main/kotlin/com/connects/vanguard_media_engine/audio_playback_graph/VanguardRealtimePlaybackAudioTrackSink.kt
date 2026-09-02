package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── VanguardRealtimePlaybackAudioTrackSink (P4-AUDIO-REALTIME-PLAYBACK-
// AUDIOTRACK-SINK, Y2 work package A) ───────────────────────────────────
//
// One reusable Kotlin muted android.media.AudioTrack sink adapter driven
// entirely over the public API of a caller-supplied
// [VanguardRealtimePlaybackTransportStateMachine] (Y1). It owns exactly
// the AudioTrack lifecycle and the non-blocking PCM16 write accounting on
// the caller's thread; the state machine itself serializes every native
// call internally on its own owner thread. [run] never calls the state
// machine's `stop` or `dispose` — both stay the caller's responsibility
// across the state machine's lifetime. The AudioTrack, in contrast, is
// stopped and released exactly once, always, regardless of the outcome.
//
// Shape of [run]: validate config -> create a muted MODE_STREAM AudioTrack
// -> load/prepare/start the supplied state machine -> repeatedly drain
// mixed PCM16 into one reused direct buffer and write exactly those bytes
// to the AudioTrack with WRITE_NON_BLOCKING (partial writes retried in
// place, zero writes parked and retried under a bounded budget) until
// native reports the drain as EOS -> a bounded playback-head catch-up
// wait -> stop + release the AudioTrack. The Kotlin sink checksum
// accumulates only over samples this adapter has fully handed to
// AudioTrack.write, and must equal the native drainedChecksumHex from the
// final drain reply.
//
// [PROOF_BOUNDARY]: muted diagnostic AudioTrack sink only; synthetic PCM
// input is expected to come from the Y1 transport (no MediaCodec, no
// MediaExtractor here); no audio focus, no route-change handling, no
// dead-object recovery, no presentation-clock or A/V-sync claim, no
// audible-output claim; no product/editor/app wiring, no iOS, no native/
// C++ changes.
class VanguardRealtimePlaybackAudioTrackSink {

    data class Config(
        val stateMachine: VanguardRealtimePlaybackTransportStateMachine,
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
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
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val declaredFrameCount: Long,
        val framesReadFromTransport: Long,
        val framesWrittenToSink: Long,
        val partialWriteCount: Long,
        val zeroWriteCount: Long,
        val playbackHeadFinal: Long,
        val audioTrackReleasedOk: Boolean,
        val releaseCount: Int,
        val transportCompletedOk: Boolean,
        val checksumIdentityOk: Boolean,
        val sinkWriteAccountingOk: Boolean,
        val playbackHeadAdvancedOk: Boolean,
        val mutedOutputOk: Boolean,
        val lifecycleOk: Boolean,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    companion object {
        const val PROOF_BOUNDARY =
            "muted_diagnostic_audiotrack_sink_only_synthetic_pcm_input_expected_from_y1_transport_no_mediacodec_no_mediaextractor_no_audio_focus_no_route_change_no_dead_object_recovery_no_presentation_clock_no_av_sync_no_audible_output_claim_no_product_editor_app_wiring_no_ios_no_native_cpp_changes"

        private const val MUTED_VOLUME = 0.0f
        private const val TRACK_BUFFER_MARGIN_WINDOWS = 4L
        private const val MAX_CONSECUTIVE_ZERO_WRITES = 500
        private const val ZERO_WRITE_SLEEP_MS = 2L
        private const val MAX_DRAIN_STALLS = 200
        private const val DRAIN_STALL_SLEEP_MS = 2L
        private const val DRAIN_ITERATION_MARGIN = 64L
        private const val HEAD_POLL_SLEEP_MS = 5L
        private const val HEAD_CATCHUP_MARGIN_MS = 3_000L
    }

    fun run(config: Config): Result {
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs

        var audioTrack: AudioTrack? = null
        var releaseCount = 0
        var audioTrackInitOk = false
        var mutedOutputOk = false
        var played = false

        var framesReadFromTransport = 0L
        var framesWrittenToSink = 0L
        var partialWriteCount = 0L
        var zeroWriteCount = 0L
        var kotlinSinkChecksum = 0L
        var nativeDrainedChecksumHex = ""
        var lastReply: Reply? = null

        var playbackHeadFinal = 0L
        var playbackHeadAdvancedOk = false
        var transportCompletedOk = false
        var checksumIdentityOk = false
        var sinkWriteAccountingOk = false

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

        fun rawHead(): Long {
            val track = audioTrack ?: return 0L
            return track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        }

        fun writeAllToAudioTrack(buf: ByteBuffer, bytes: Int, bytesPerFrame: Int) {
            val track = audioTrack ?: fail("audio_track_missing")
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
                        framesWrittenToSink += (wrote / bytesPerFrame).toLong()
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
        }

        // Mirrors the native drain checksum accumulation (c = c * 31 +
        // uint16(sample)) over exactly the frames this call is about to
        // hand to AudioTrack.write; a failure anywhere in that write
        // aborts the whole run, so a checksum counted here is always one
        // this adapter fully accepted.
        fun accumulateChecksum(buf: ByteBuffer, frames: Int, channelCount: Int) {
            var c = kotlinSinkChecksum
            val sampleCount = frames * channelCount
            for (i in 0 until sampleCount) {
                c = c * 31L + (buf.getShort(i * 2).toLong() and 0xFFFFL)
            }
            kotlinSinkChecksum = c
        }

        fun makeResult(): Result {
            val status = if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" }
            val audioTrackReleasedOk = releaseCount == 1
            val lifecycleOk = audioTrackReleasedOk
            val lanes = mapOf(
                "audioTrackInitOk" to audioTrackInitOk,
                "mutedOutputOk" to mutedOutputOk,
                "transportCompletedOk" to transportCompletedOk,
                "checksumIdentityOk" to checksumIdentityOk,
                "sinkWriteAccountingOk" to sinkWriteAccountingOk,
                "playbackHeadAdvancedOk" to playbackHeadAdvancedOk,
                "audioTrackReleasedOk" to audioTrackReleasedOk,
                "lifecycleOk" to lifecycleOk,
            )
            val metrics = mapOf(
                "sampleRate" to config.sampleRate,
                "channelCount" to config.channelCount,
                "maxFramesPerMix" to config.maxFramesPerMix,
                "declaredFrameCount" to config.declaredFrameCount,
                "framesReadFromTransport" to framesReadFromTransport,
                "framesWrittenToSink" to framesWrittenToSink,
                "partialWriteCount" to partialWriteCount,
                "zeroWriteCount" to zeroWriteCount,
                "playbackHeadFinal" to playbackHeadFinal,
                "releaseCount" to releaseCount,
                "kotlinSinkChecksumHex" to String.format("%016x", kotlinSinkChecksum),
                "nativeDrainedChecksumHex" to nativeDrainedChecksumHex,
                "transportState" to config.stateMachine.currentState.name,
            )
            return Result(
                pass = pass,
                status = status,
                failureReason = failureReason,
                proofBoundary = PROOF_BOUNDARY,
                lanes = lanes,
                metrics = metrics,
                sampleRate = config.sampleRate,
                channelCount = config.channelCount,
                maxFramesPerMix = config.maxFramesPerMix,
                declaredFrameCount = config.declaredFrameCount,
                framesReadFromTransport = framesReadFromTransport,
                framesWrittenToSink = framesWrittenToSink,
                partialWriteCount = partialWriteCount,
                zeroWriteCount = zeroWriteCount,
                playbackHeadFinal = playbackHeadFinal,
                audioTrackReleasedOk = audioTrackReleasedOk,
                releaseCount = releaseCount,
                transportCompletedOk = transportCompletedOk,
                checksumIdentityOk = checksumIdentityOk,
                sinkWriteAccountingOk = sinkWriteAccountingOk,
                playbackHeadAdvancedOk = playbackHeadAdvancedOk,
                mutedOutputOk = mutedOutputOk,
                lifecycleOk = lifecycleOk,
            )
        }

        try {
            checkCancelled()
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
            if (config.declaredFrameCount <= 0L) fail("invalid_declared_frame_count")

            val bytesPerFrame = 2 * config.channelCount
            val channelMask = if (config.channelCount == 1) {
                AudioFormat.CHANNEL_OUT_MONO
            } else {
                AudioFormat.CHANNEL_OUT_STEREO
            }
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

            checkCancelled()
            val loadResult = config.stateMachine.load()
            if (!loadResult.accepted) fail("load_failed:${loadResult.reason}")
            checkCancelled()
            val prepareResult = config.stateMachine.prepare()
            if (!prepareResult.accepted) fail("prepare_failed:${prepareResult.reason}")
            checkCancelled()
            val startResult = config.stateMachine.start()
            if (!startResult.accepted) fail("start_failed:${startResult.reason}")

            val drainBuffer = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame)
                .order(ByteOrder.LITTLE_ENDIAN)
            val maxIterations = config.declaredFrameCount / config.maxFramesPerMix + DRAIN_ITERATION_MARGIN
            var iterations = 0L
            var stalls = 0
            while (true) {
                checkCancelled()
                checkDeadline()
                if (++iterations > maxIterations) fail("drain_iteration_budget_exhausted")
                val drainResult = config.stateMachine.drain(drainBuffer, config.maxFramesPerMix)
                if (!drainResult.accepted) fail("drain_rejected:${drainResult.reason}")
                val reply = drainResult.reply ?: fail("drain_null_reply")
                lastReply = reply
                val framesRead = reply.framesRead.toInt()
                if (framesRead > 0) {
                    accumulateChecksum(drainBuffer, framesRead, config.channelCount)
                    framesReadFromTransport += framesRead
                    writeAllToAudioTrack(drainBuffer, framesRead * bytesPerFrame, bytesPerFrame)
                    if (!played) {
                        track.play()
                        played = true
                    }
                    stalls = 0
                } else {
                    if (reply.eosDrained) break
                    if (++stalls > MAX_DRAIN_STALLS) fail("drain_stalled")
                    SystemClock.sleep(DRAIN_STALL_SLEEP_MS)
                    continue
                }
                if (reply.eosDrained) break
            }
            if (!played) fail("no_frames_written_to_sink")

            val catchUpDeadline = SystemClock.elapsedRealtime() + HEAD_CATCHUP_MARGIN_MS
            while (rawHead() < framesWrittenToSink) {
                checkCancelled()
                checkDeadline()
                if (SystemClock.elapsedRealtime() > catchUpDeadline) break
                SystemClock.sleep(HEAD_POLL_SLEEP_MS)
            }
            playbackHeadFinal = rawHead()
            playbackHeadAdvancedOk = playbackHeadFinal > 0L
            if (!playbackHeadAdvancedOk) fail("playback_head_not_advanced")

            transportCompletedOk = config.stateMachine.currentState == State.COMPLETED
            if (!transportCompletedOk) fail("transport_not_completed:${config.stateMachine.currentState}")

            val finalReply = lastReply ?: fail("missing_final_reply")
            nativeDrainedChecksumHex = finalReply.drainedChecksumHex
            val kotlinChecksumHex = String.format("%016x", kotlinSinkChecksum)
            checksumIdentityOk = kotlinChecksumHex.equals(nativeDrainedChecksumHex, ignoreCase = true)
            if (!checksumIdentityOk) fail("checksum_identity_mismatch")

            sinkWriteAccountingOk = framesReadFromTransport == framesWrittenToSink &&
                framesReadFromTransport == config.declaredFrameCount
            if (!sinkWriteAccountingOk) fail("sink_write_accounting_mismatch")

            pass = true
        } catch (f: FailClosed) {
            failureReason = f.reason
        } catch (e: Throwable) {
            failureReason = "exception:${e.javaClass.simpleName}:${e.message}"
        } finally {
            releaseAudioTrackOnce()
        }

        return makeResult()
    }
}
