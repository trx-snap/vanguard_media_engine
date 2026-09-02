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
    ) {
        val bytesPerFrame: Int get() = 2 * channelCount
    }

    enum class CreateFailure {
        INVALID_SAMPLE_RATE,
        INVALID_CHANNEL_COUNT,
        INVALID_MAX_FRAMES_PER_MIX,
        INVALID_TRACK_COUNT,
        INVALID_DECLARED_FRAME_COUNT,
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
        val raw: String,
    ) {
        val ok: Boolean get() = status == STATUS_OK
    }

    companion object {
        const val STATUS_OK = "ok"
        const val STATUS_NOT_FOUND = "not_found"
        const val STATUS_WRONG_OWNER_THREAD = "wrong_owner_thread"
        const val STATUS_INVALID_STATE = "invalid_state"
        const val STATUS_INVALID_ARGS = "invalid_args"
        const val STATUS_COMMAND_TIMEOUT = "command_timeout"
        const val STATUS_SESSION_CLOSED = "session_closed"

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
