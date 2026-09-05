package com.connects.vanguard_media_engine.audio_playback_graph

import com.connects.vanguard_media_engine.bridge.VanguardRealtimePlaybackNativeBridge
import java.nio.ByteBuffer

// ── VanguardRealtimePlaybackNativeSession (P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE, Y1) ─
//
// Thin typed wrapper over one native realtime playback graph session
// handle. It owns exactly three things: the handle, defensive parsing of
// the native `key=value` replies into [Reply], and idempotent destruction.
// It carries NO transport policy: which command is legal in which state is
// decided by [VanguardRealtimePlaybackTransportStateMachine] (Kotlin
// authoritative) and re-validated natively.
//
// Owner-thread affinity: native pins the creating thread; construct and
// drive this object on that single thread (only [destroy] is any-thread).
//
// Y5a (EXTERNAL-INGEST-SEAM): [Config.externalIngestTrackMask] opts
// individual tracks into owner-thread PCM16 ingest through [ingest]; the
// default (0) keeps every track native-synthetic, so existing callers are
// unchanged. This wrapper still carries no policy: which ingest statuses
// are terminal is decided by the transport state machine.
//
// Y16 (CLOCK-DRIFT-SAMPLE-OWNERSHIP): [recordDriftSample] forwards one
// reported presentation position to the native worker-owned AudioClock;
// no Kotlin timebase is ever passed, and the Reply mirrors the native
// drift fields read-only.
class VanguardRealtimePlaybackNativeSession private constructor(
    val handle: Long,
    val config: Config,
) {
    data class Config(
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val trackCount: Int,
        val declaredFrameCount: Long,
        // Bit t set => track t is external-ingest (Kotlin producer). Must be
        // >= 0 with no bits at or above trackCount.
        val externalIngestTrackMask: Int = 0,
    ) {
        val bytesPerFrame: Int get() = 2 * channelCount

        fun isExternalTrack(trackIndex: Int): Boolean =
            trackIndex in 0 until trackCount && ((externalIngestTrackMask ushr trackIndex) and 1) != 0
    }

    enum class CreateFailure {
        INVALID_SAMPLE_RATE,
        INVALID_CHANNEL_COUNT,
        INVALID_MAX_FRAMES_PER_MIX,
        INVALID_TRACK_COUNT,
        INVALID_DECLARED_FRAME_COUNT,
        INVALID_EXTERNAL_INGEST_TRACK_MASK,
        // Native returned 0 for arguments that passed the mirrored
        // admission table above. The only remaining native causes are the
        // four-live-session cap and native resource exhaustion (thread or
        // allocation failure), which this API cannot distinguish.
        NATIVE_CAPACITY_EXHAUSTED,
    }

    sealed class CreateResult {
        data class Success(val session: VanguardRealtimePlaybackNativeSession) : CreateResult()
        data class Failure(val failure: CreateFailure) : CreateResult()
    }

    // Native-derived state token. COMPLETED is derived natively from
    // (playing|paused) + every pushed frame drained after the declared end.
    enum class NativeState(val token: String) {
        IDLE("idle"),
        PREPARED("prepared"),
        PLAYING("playing"),
        PAUSED("paused"),
        STOPPED("stopped"),
        COMPLETED("completed"),
        FAILED("failed"),
        DESTROYED("destroyed"),
        UNKNOWN("unknown");

        companion object {
            fun fromToken(token: String?): NativeState =
                entries.firstOrNull { it.token == token } ?: UNKNOWN
        }
    }

    data class Reply(
        val status: String,
        val state: NativeState,
        val stateToken: String,
        val handle: Long,
        val trackCount: Int,
        val declaredFrameCount: Long,
        val maxFramesPerMix: Long,
        val sampleRate: Int,
        val channelCount: Int,
        val renderedFrames: Long,
        val pushedFrames: Long,
        val drainedFrames: Long,
        val discardedFrames: Long,
        val positionFrame: Long,
        val eosPushed: Boolean,
        val eosDrained: Boolean,
        val commandSeq: Long,
        val commandResult: String,
        val lastError: String,
        val wrongOwnerThread: Boolean,
        val workerJoined: Boolean,
        val workerExited: Boolean,
        val dispatchCount: Long,
        val backpressureCount: Long,
        val outputAvailableReadFrames: Long,
        val pushedChecksumHex: String,
        val drainedChecksumHex: String,
        val framesRead: Long,
        val bytesRead: Long,
        // Y5a fields. externalIngestTrackMask/underrunCount are on every
        // full reply; ingestTrack/acceptedFrames/nextWriteFrame/freeFrames
        // are meaningful only on [ingest] replies (ingestTrack == -1 else).
        val externalIngestTrackMask: Int,
        val underrunCount: Long,
        val ingestTrack: Int,
        val acceptedFrames: Long,
        val nextWriteFrame: Long,
        val freeFrames: Long,
        // Y15a (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-CORRELATION-OBSERVATION):
        // read-only mirror of the native worker-owned AudioClock, refreshed
        // on every full reply. "none" state / 0 positions when no AudioClock
        // instance currently exists (parse-compatible default: an older
        // native build that predates these keys parses the same way).
        val nativeClockState: String,
        val nativeClockPositionUs: Long,
        val nativeClockPositionFrame: Long,
        val nativeClockAnchorMediaPtsUs: Long,
        val nativeClockAnchorSystemTimeNs: Long,
        val nativeClockSpeedNumerator: Int,
        val nativeClockSpeedDenominator: Int,
        val nativeClockDriftSampleCount: Long,
        val nativeClockLastDriftDeltaUs: Long,
        // Y16 (P4-AUDIO-REALTIME-PLAYBACK-CLOCK-DRIFT-SAMPLE-OWNERSHIP):
        // drift-sample ingestion mirror on every full reply. Expected /
        // reported are the native AudioClock's last recorded pair (expected
        // computed by the worker at record time); recorded/rejected are
        // worker-lifetime tallies; lastReportedFrame is -1 until one sample
        // was recorded. Parse-compatible defaults for older native builds.
        val nativeClockLastDriftExpectedPtsUs: Long,
        val nativeClockLastDriftReportedPtsUs: Long,
        val nativeDriftLastReportedFrame: Long,
        val nativeDriftSamplesRecorded: Long,
        val nativeDriftSamplesRejected: Long,
        val raw: String,
    ) {
        val ok: Boolean get() = status == STATUS_OK

        // Y5a: an ingest call that native fully processed without failing
        // the session; acceptedFrames may still be 0 (ring_full /
        // eos_reached) and nextWriteFrame is the post-call anchor.
        val ingestNonterminal: Boolean
            get() = status == STATUS_OK || status == STATUS_PARTIAL_WRITE ||
                status == STATUS_RING_FULL || status == STATUS_EOS_REACHED
    }

    companion object {
        const val STATUS_OK = "ok"
        const val STATUS_NOT_FOUND = "not_found"
        const val STATUS_WRONG_OWNER_THREAD = "wrong_owner_thread"
        const val STATUS_INVALID_STATE = "invalid_state"
        const val STATUS_INVALID_ARGS = "invalid_args"
        const val STATUS_COMMAND_TIMEOUT = "command_timeout"
        const val STATUS_SESSION_CLOSED = "session_closed"

        // Y5a ingest statuses (native tokens, see the ingest JNI comment).
        const val STATUS_PARTIAL_WRITE = "partial_write"
        const val STATUS_RING_FULL = "ring_full"
        const val STATUS_EOS_REACHED = "eos_reached"
        const val STATUS_EXPECTED_START_MISMATCH = "expected_start_mismatch"
        const val STATUS_AWAITING_SEEK_ACK = "awaiting_seek_ack"
        const val STATUS_COMMAND_IN_FLIGHT = "command_in_flight"
        const val STATUS_FORMAT_MISMATCH = "format_mismatch"
        const val STATUS_INVALID_TRACK = "invalid_track"
        const val STATUS_TRACK_NOT_EXTERNAL = "track_not_external"
        const val STATUS_WORKER_EXITED = "worker_exited"
        const val MAX_INGEST_FRAMES = 8_192

        // Y16 drift-sample rejection statuses (native tokens, nonterminal).
        const val STATUS_NO_CLOCK = "no_clock"
        const val STATUS_DRIFT_SAMPLE_REJECTED = "drift_sample_rejected"

        // Mirrors the native admission table exactly (AudioMixBusNode /
        // DecodedAudioPcmSourceNode / AudioDecoderRingWriter bounds).
        const val MIN_SAMPLE_RATE = 8_000
        const val MAX_SAMPLE_RATE = 192_000
        const val MAX_FRAMES_PER_MIX_CAP = 8_192
        const val MIN_TRACK_COUNT = 1
        const val MAX_TRACK_COUNT = 8
        const val MAX_DECLARED_SECONDS = 600L

        fun validate(config: Config): CreateFailure? = when {
            config.sampleRate < MIN_SAMPLE_RATE || config.sampleRate > MAX_SAMPLE_RATE ->
                CreateFailure.INVALID_SAMPLE_RATE
            config.channelCount != 1 && config.channelCount != 2 ->
                CreateFailure.INVALID_CHANNEL_COUNT
            config.maxFramesPerMix <= 0 || config.maxFramesPerMix > MAX_FRAMES_PER_MIX_CAP ->
                CreateFailure.INVALID_MAX_FRAMES_PER_MIX
            config.trackCount < MIN_TRACK_COUNT || config.trackCount > MAX_TRACK_COUNT ->
                CreateFailure.INVALID_TRACK_COUNT
            config.declaredFrameCount <= 0L ||
                config.declaredFrameCount > MAX_DECLARED_SECONDS * config.sampleRate ->
                CreateFailure.INVALID_DECLARED_FRAME_COUNT
            config.externalIngestTrackMask < 0 ||
                (config.externalIngestTrackMask and ((1 shl config.trackCount) - 1).inv()) != 0 ->
                CreateFailure.INVALID_EXTERNAL_INGEST_TRACK_MASK
            else -> null
        }

        // Must be called on the thread that will own the session.
        fun create(config: Config): CreateResult {
            validate(config)?.let { return CreateResult.Failure(it) }
            val handle = VanguardRealtimePlaybackNativeBridge.createRealtimePlaybackGraphSession(
                config.sampleRate,
                config.channelCount,
                config.maxFramesPerMix,
                config.trackCount,
                config.declaredFrameCount,
                config.externalIngestTrackMask,
            )
            if (handle <= 0L) return CreateResult.Failure(CreateFailure.NATIVE_CAPACITY_EXHAUSTED)
            return CreateResult.Success(VanguardRealtimePlaybackNativeSession(handle, config))
        }

        // Reference identity of the native synthetic generator, reproduced
        // bit-exactly for harness checks:
        //   sample(track, frame, channel) =
        //       (((frame * (2*track + 3) + channel * 97) mod 2001) - 1000) * 4
        fun referenceSample(track: Int, frame: Long, channel: Int): Short {
            val phase = frame * (2L * track + 3L) + channel.toLong() * 97L
            return (((phase % 2001L) - 1000L) * 4L).toInt().toShort()
        }

        // Unit-gain mix of all tracks at one frame/channel; never clips for
        // trackCount <= 8 (|sum| <= 32000).
        fun referenceMixedSample(trackCount: Int, frame: Long, channel: Int): Short {
            var sum = 0
            for (t in 0 until trackCount) sum += referenceSample(t, frame, channel).toInt()
            return sum.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }

        fun parseReply(raw: String): Reply {
            val kv = HashMap<String, String>()
            for (part in raw.split(';')) {
                val idx = part.indexOf('=')
                if (idx > 0) kv[part.substring(0, idx)] = part.substring(idx + 1)
            }
            fun str(key: String, default: String = "") = kv[key] ?: default
            fun long(key: String) = kv[key]?.toLongOrNull() ?: 0L
            fun int(key: String) = kv[key]?.toIntOrNull() ?: 0
            fun bool(key: String) = kv[key] == "true"
            val stateToken = str("state", NativeState.UNKNOWN.token)
            return Reply(
                status = str("status", "malformed_reply"),
                state = NativeState.fromToken(stateToken),
                stateToken = stateToken,
                handle = long("handle"),
                trackCount = int("trackCount"),
                declaredFrameCount = long("declaredFrameCount"),
                maxFramesPerMix = long("maxFramesPerMix"),
                sampleRate = int("sampleRate"),
                channelCount = int("channelCount"),
                renderedFrames = long("renderedFrames"),
                pushedFrames = long("pushedFrames"),
                drainedFrames = long("drainedFrames"),
                discardedFrames = long("discardedFrames"),
                positionFrame = long("positionFrame"),
                eosPushed = bool("eosPushed"),
                eosDrained = bool("eosDrained"),
                commandSeq = long("commandSeq"),
                commandResult = str("commandResult", "none"),
                lastError = str("lastError", "none"),
                wrongOwnerThread = bool("wrongOwnerThread"),
                workerJoined = bool("workerJoined"),
                workerExited = bool("workerExited"),
                dispatchCount = long("dispatchCount"),
                backpressureCount = long("backpressureCount"),
                outputAvailableReadFrames = long("outputAvailableReadFrames"),
                pushedChecksumHex = str("pushedChecksumHex"),
                drainedChecksumHex = str("drainedChecksumHex"),
                framesRead = long("framesRead"),
                bytesRead = long("bytesRead"),
                externalIngestTrackMask = int("externalIngestTrackMask"),
                underrunCount = long("underrunCount"),
                ingestTrack = kv["ingestTrack"]?.toIntOrNull() ?: -1,
                acceptedFrames = long("acceptedFrames"),
                nextWriteFrame = long("nextWriteFrame"),
                freeFrames = long("freeFrames"),
                nativeClockState = str("nativeClockState", "none"),
                nativeClockPositionUs = long("nativeClockPositionUs"),
                nativeClockPositionFrame = long("nativeClockPositionFrame"),
                nativeClockAnchorMediaPtsUs = long("nativeClockAnchorMediaPtsUs"),
                nativeClockAnchorSystemTimeNs = long("nativeClockAnchorSystemTimeNs"),
                nativeClockSpeedNumerator = kv["nativeClockSpeedNumerator"]?.toIntOrNull() ?: 1,
                nativeClockSpeedDenominator = kv["nativeClockSpeedDenominator"]?.toIntOrNull() ?: 1,
                nativeClockDriftSampleCount = long("nativeClockDriftSampleCount"),
                nativeClockLastDriftDeltaUs = long("nativeClockLastDriftDeltaUs"),
                nativeClockLastDriftExpectedPtsUs = long("nativeClockLastDriftExpectedPtsUs"),
                nativeClockLastDriftReportedPtsUs = long("nativeClockLastDriftReportedPtsUs"),
                nativeDriftLastReportedFrame = kv["nativeDriftLastReportedFrame"]?.toLongOrNull() ?: -1L,
                nativeDriftSamplesRecorded = long("nativeDriftSamplesRecorded"),
                nativeDriftSamplesRejected = long("nativeDriftSamplesRejected"),
                raw = raw,
            )
        }

        private fun syntheticReply(status: String, handle: Long): Reply =
            parseReply("status=$status;state=destroyed;handle=$handle;commandSeq=0;lastError=none")
    }

    @Volatile
    private var closed = false

    val isClosed: Boolean get() = closed

    fun prepare(): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.prepareRealtimePlaybackGraphSession(handle)
    }

    fun start(): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.startRealtimePlaybackGraphSession(handle)
    }

    fun pause(): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.pauseRealtimePlaybackGraphSession(handle)
    }

    fun resume(): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.resumeRealtimePlaybackGraphSession(handle)
    }

    fun seek(targetFrame: Long): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.seekRealtimePlaybackGraphSession(handle, targetFrame)
    }

    fun stop(): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.stopRealtimePlaybackGraphSession(handle)
    }

    // `dst` must be a direct buffer with capacity >= maxFrames * bytesPerFrame;
    // popped PCM16 lands at byte offset 0 (position/limit are not touched).
    fun drain(dst: ByteBuffer, maxFrames: Int): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.drainRealtimePlaybackGraphSessionOutputPcm16(
            handle, dst, maxFrames,
        )
    }

    // Y5a: owner-thread producer write into external track `trackIndex`.
    // `src` must be direct with capacity >= frameCount * bytesPerFrame; PCM16
    // is read from byte offset 0 (position/limit are not touched). The
    // session format is passed through so native can reject a mismatch.
    fun ingest(trackIndex: Int, src: ByteBuffer, frameCount: Int, expectedStartFrame: Long): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.ingestRealtimePlaybackGraphSessionExternalPcm16(
            handle, trackIndex, src, frameCount, config.sampleRate, config.channelCount, expectedStartFrame,
        )
    }

    // Y16: owner-thread drift-sample ingestion. Carries only the Kotlin
    // presentation clock's reported position (us + frame); the native
    // worker stamps its own steady clock and computes the expected position.
    // Which rejection statuses are terminal is decided by the transport
    // state machine (this wrapper still carries no policy).
    fun recordDriftSample(reportedPtsUs: Long, reportedFrame: Long): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.recordDriftSampleRealtimePlaybackGraphSession(
            handle, reportedPtsUs, reportedFrame,
        )
    }

    fun snapshot(): Reply = guarded {
        VanguardRealtimePlaybackNativeBridge.snapshotRealtimePlaybackGraphSession(handle)
    }

    // Any-thread, idempotent: the first call destroys (native joins the
    // worker); later calls return a synthesized session_closed reply.
    @Synchronized
    fun destroy(): Reply {
        if (closed) return syntheticReply(STATUS_SESSION_CLOSED, handle)
        closed = true
        return parseReply(
            VanguardRealtimePlaybackNativeBridge.destroyRealtimePlaybackGraphSession(handle),
        )
    }

    private inline fun guarded(call: () -> String): Reply =
        if (closed) syntheticReply(STATUS_SESSION_CLOSED, handle) else parseReply(call())
}
