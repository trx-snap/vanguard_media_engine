package com.connects.vanguard_media_engine.audio_playback_graph

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

// ── VanguardRealtimePlaybackTransportStateMachine (P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE, Y1) ─
//
// Authoritative Kotlin transport state machine over one
// [VanguardRealtimePlaybackNativeSession]. Owns exactly one HandlerThread
// (the native owner thread) and serializes EVERY native call on it; the
// native worker's derived state is compared against the Kotlin state after
// each call and any divergence fails closed into [State.FAILED].
//
// - Commands are synchronous from any thread ([prepare], [start], ...) or
//   callback-friendly ([post]); both run on the owner thread in order.
// - A generation counter advances on every transport epoch (load, start,
//   seek, stop); [post] callers may pin an expected generation so stale
//   work is rejected without touching native.
// - Completion is observed exactly once (native `completed` seen from
//   PLAYING/PAUSED after a drain or snapshot) and failure has exactly one
//   path ([fail]); both are reported to the [Listener] on the owner thread.
// - [dispose] is any-state, idempotent: destroys native (joined), then
//   quits the HandlerThread safely.
//
// No OS media APIs live here: no AudioTrack, MediaCodec, MediaExtractor,
// AudioManager, BroadcastReceiver, or route listeners. Draining the mixed
// PCM16 into a sink is a later coordinator's job through [drain].
//
// Y5a (EXTERNAL-INGEST-SEAM): [ingest] / [postIngest] are the ONLY sanctioned
// way to feed an external-ingest track. Both execute on the owner
// HandlerThread (the native owner thread), so a decoder or background
// producer never touches JNI directly; [postIngest] additionally pins an
// expected generation and is rejected as stale, before any native call,
// once start/seek/stop advanced the epoch. Ingest statuses that mean
// "producer must re-anchor / retry" ([IngestRequest] anchor mismatch,
// ring full, command in flight, format/argument errors) are rejected
// results that do NOT fail the machine; only native session faults do.
class VanguardRealtimePlaybackTransportStateMachine(
    private val config: VanguardRealtimePlaybackNativeSession.Config,
    private val listener: Listener? = null,
    threadName: String = "VanguardRealtimePlaybackTransport",
) {
    enum class State { IDLE, PREPARED, PLAYING, PAUSED, STOPPED, COMPLETED, FAILED, DISPOSED }

    enum class Op { LOAD, PREPARE, START, PAUSE, RESUME, SEEK, STOP, SNAPSHOT, DRAIN, INGEST }

    // Y5a typed ingest request. `src` is a direct buffer holding frameCount
    // interleaved PCM16 frames at byte offset 0 in the session format;
    // expectedStartFrame must equal the track's native writer cursor.
    data class IngestRequest(
        val trackIndex: Int,
        val src: ByteBuffer,
        val frameCount: Int,
        val expectedStartFrame: Long,
    )

    // All callbacks run on the owner thread.
    interface Listener {
        fun onStateChanged(previous: State, current: State, generation: Long) {}
        fun onCompleted(generation: Long) {}
        fun onFailed(reason: String, generation: Long) {}
    }

    data class Result(
        val accepted: Boolean,
        val state: State,
        val generation: Long,
        val reason: String,
        val reply: Reply?,
    )

    companion object {
        const val REASON_OK = "ok"
        const val REASON_STALE_GENERATION = "stale_generation"
        const val REASON_DISPOSED = "disposed"
        const val REASON_OWNER_THREAD_TIMEOUT = "owner_thread_timeout"
        const val REASON_INGEST_PREFIX = "ingest_"
        private const val OWNER_WAIT_TIMEOUT_MS = 10_000L
        private const val DISPOSE_JOIN_TIMEOUT_MS = 5_000L
    }

    private val thread = HandlerThread(threadName).apply { start() }
    private val handler = Handler(thread.looper)
    private val disposed = AtomicBoolean(false)

    // Owner-thread-confined mutable state.
    @Volatile
    private var session: VanguardRealtimePlaybackNativeSession? = null
    private var state = State.IDLE
    private var generation = 0L
    private var failureReason: String? = null

    // Cheap off-thread mirrors of the owner-confined state.
    @Volatile
    private var publishedState = State.IDLE

    @Volatile
    private var publishedGeneration = 0L

    val currentState: State get() = publishedState
    val currentGeneration: Long get() = publishedGeneration
    val isOwnerThread: Boolean get() = Looper.myLooper() == thread.looper

    // ── Synchronous API (any thread; runs inline when already on the owner thread) ─

    fun load(): Result = runOnOwner { execute(Op.LOAD, 0L) }
    fun prepare(): Result = runOnOwner { execute(Op.PREPARE, 0L) }
    fun start(): Result = runOnOwner { execute(Op.START, 0L) }
    fun pause(): Result = runOnOwner { execute(Op.PAUSE, 0L) }
    fun resume(): Result = runOnOwner { execute(Op.RESUME, 0L) }
    fun seek(targetFrame: Long): Result = runOnOwner { execute(Op.SEEK, targetFrame) }
    fun stop(): Result = runOnOwner { execute(Op.STOP, 0L) }
    fun snapshot(): Result = runOnOwner { execute(Op.SNAPSHOT, 0L) }

    // Pops up to maxFrames of mixed PCM16 into the direct buffer `dst` at
    // byte offset 0; the returned reply carries framesRead/bytesRead and
    // the completion observation happens here when the last frame drains.
    fun drain(dst: ByteBuffer, maxFrames: Int): Result =
        runOnOwner { executeDrain(dst, maxFrames) }

    // Y5a: synchronous owner-thread ingest. On success the reply carries
    // acceptedFrames (may be 0 on ring_full/eos_reached) and the post-call
    // nextWriteFrame anchor. Re-anchor/retry conditions come back as
    // rejected results whose reason starts with [REASON_INGEST_PREFIX] and
    // whose reply (when present) holds the real nextWriteFrame.
    fun ingest(request: IngestRequest): Result = runOnOwner { executeIngest(request) }

    // Y5a: callback-friendly ingest through the same generation-pinned
    // [post] path; the producer thread never reaches JNI itself.
    fun postIngest(
        request: IngestRequest,
        expectedGeneration: Long? = null,
        callback: ((Result) -> Unit)? = null,
    ): Boolean = post(Op.INGEST, 0L, expectedGeneration, null, request, callback)

    // ── Callback-friendly API ──────────────────────────────────────────────

    // Enqueues `op` on the owner thread. When `expectedGeneration` is set
    // and no longer current at execution time, the op is rejected as stale
    // without touching native. `callback` runs on the owner thread.
    //
    // Once [dispose] is visible the op is rejected quietly on the caller's
    // thread (callback invoked inline, returns false) WITHOUT touching the
    // Handler: posting to a quit Looper logs an Android MessageQueue
    // "dead thread" warning, and post-dispose rejection is a normal,
    // expected path for late producers, not a defect worth a warning.
    fun post(
        op: Op,
        arg: Long = 0L,
        expectedGeneration: Long? = null,
        drainBuffer: ByteBuffer? = null,
        ingestRequest: IngestRequest? = null,
        callback: ((Result) -> Unit)? = null,
    ): Boolean {
        if (disposed.get()) {
            callback?.invoke(disposedResult())
            return false
        }
        val posted = handler.post {
            val result = if (expectedGeneration != null && expectedGeneration != generation) {
                Result(false, state, generation, REASON_STALE_GENERATION, null)
            } else if (op == Op.DRAIN) {
                if (drainBuffer == null) {
                    Result(false, state, generation, "null_drain_buffer", null)
                } else {
                    executeDrain(drainBuffer, arg.toInt())
                }
            } else if (op == Op.INGEST) {
                if (ingestRequest == null) {
                    Result(false, state, generation, "null_ingest_request", null)
                } else {
                    executeIngest(ingestRequest)
                }
            } else {
                execute(op, arg)
            }
            callback?.invoke(result)
        }
        // Narrow race: dispose became visible between the gate above and
        // the enqueue. Same rejection shape either way.
        if (!posted) callback?.invoke(disposedResult())
        return posted
    }

    private fun disposedResult(): Result =
        Result(false, State.DISPOSED, publishedGeneration, REASON_DISPOSED, null)

    // ── Dispose ────────────────────────────────────────────────────────────

    // Any state, any thread, idempotent. Native destroy joins the worker;
    // the HandlerThread is quit safely afterwards (and joined when called
    // from another thread).
    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        if (isOwnerThread) {
            disposeOnOwner()
            thread.quitSafely()
            return
        }
        val latch = CountDownLatch(1)
        val posted = handler.post {
            try {
                disposeOnOwner()
            } finally {
                latch.countDown()
            }
        }
        if (posted) {
            latch.await(OWNER_WAIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } else {
            // Looper already gone: destroy is any-thread and idempotent.
            session?.destroy()
            session = null
            publishedState = State.DISPOSED
        }
        thread.quitSafely()
        try {
            thread.join(DISPOSE_JOIN_TIMEOUT_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun disposeOnOwner() {
        session?.destroy()
        session = null
        transition(State.DISPOSED)
    }

    // ── Owner-thread execution ─────────────────────────────────────────────

    // Off-owner callers after [dispose] is visible get null without touching
    // the Handler (see [post] for why); the owner thread still runs inline so
    // listener callbacks issued during dispose observe the same rejections.
    private fun <T> runOnOwnerOrNull(block: () -> T): T? {
        if (isOwnerThread) return block()
        if (disposed.get()) return null
        val latch = CountDownLatch(1)
        var result: T? = null
        val posted = handler.post {
            try {
                result = block()
            } finally {
                latch.countDown()
            }
        }
        if (!posted) return null
        if (!latch.await(OWNER_WAIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) return null
        return result
    }

    private fun runOnOwner(block: () -> Result): Result =
        runOnOwnerOrNull(block)
            ?: if (disposed.get()) {
                disposedResult()
            } else {
                Result(false, publishedState, publishedGeneration, REASON_OWNER_THREAD_TIMEOUT, null)
            }

    private fun reject(reason: String, reply: Reply? = null): Result =
        Result(false, state, generation, reason, reply)

    private fun accept(reply: Reply?): Result = Result(true, state, generation, REASON_OK, reply)

    private fun execute(op: Op, arg: Long): Result {
        if (state == State.DISPOSED) return reject(REASON_DISPOSED)
        if (op == Op.LOAD) return executeLoad()
        val s = session ?: return reject("not_loaded")
        if (state == State.FAILED) {
            // Read-only observation stays available after failure; every
            // command is rejected.
            return if (op == Op.SNAPSHOT) reject("failed:${failureReason ?: "unknown"}", s.snapshot())
            else reject("failed:${failureReason ?: "unknown"}")
        }

        if (!commandAllowed(op, state)) return reject("invalid_state_${state.name.lowercase()}")
        if (op == Op.SEEK && (arg < 0L || arg >= config.declaredFrameCount)) {
            return reject("invalid_seek_target")
        }

        val reply = when (op) {
            Op.PREPARE -> s.prepare()
            Op.START -> s.start()
            Op.PAUSE -> s.pause()
            Op.RESUME -> s.resume()
            Op.SEEK -> s.seek(arg)
            Op.STOP -> s.stop()
            Op.SNAPSHOT -> s.snapshot()
            Op.LOAD, Op.DRAIN, Op.INGEST -> return reject("unreachable")
        }
        if (!reply.ok) return failClosedOnReply(op, reply)

        when (op) {
            Op.PREPARE -> transition(State.PREPARED)
            Op.START -> { generation++; transition(State.PLAYING) }
            Op.PAUSE -> transition(State.PAUSED)
            Op.RESUME -> transition(State.PLAYING)
            Op.SEEK -> generation++ // paused stays PAUSED, playing stays PLAYING
            Op.STOP -> { generation++; transition(State.STOPPED) }
            Op.SNAPSHOT -> Unit
            Op.LOAD, Op.DRAIN, Op.INGEST -> Unit
        }
        publishedGeneration = generation
        return verifyAndObserve(reply)
    }

    private fun executeLoad(): Result {
        if (state != State.IDLE || session != null) return reject("invalid_state_${state.name.lowercase()}")
        return when (val created = VanguardRealtimePlaybackNativeSession.create(config)) {
            is VanguardRealtimePlaybackNativeSession.CreateResult.Success -> {
                session = created.session
                generation++
                publishedGeneration = generation
                accept(null)
            }
            is VanguardRealtimePlaybackNativeSession.CreateResult.Failure ->
                fail("create_failed:${created.failure.name.lowercase()}")
        }
    }

    private fun executeDrain(dst: ByteBuffer, maxFrames: Int): Result {
        if (state == State.DISPOSED) return reject(REASON_DISPOSED)
        val s = session ?: return reject("not_loaded")
        if (state == State.FAILED) return reject("failed:${failureReason ?: "unknown"}")
        if (state == State.IDLE) return reject("invalid_state_idle")
        if (maxFrames < 0) return reject("invalid_max_frames")
        if (!dst.isDirect) return reject("non_direct_buffer")
        if (dst.capacity() < maxFrames.toLong() * config.bytesPerFrame) return reject("insufficient_buffer_capacity")
        val reply = s.drain(dst, maxFrames)
        if (!reply.ok) return failClosedOnReply(Op.DRAIN, reply)
        return verifyAndObserve(reply)
    }

    // Y5a owner-thread ingest. Argument/mode errors are caught here before
    // JNI; native re-validates everything and the writer is only touched
    // when its command gate is quiescent.
    private fun executeIngest(request: IngestRequest): Result {
        if (state == State.DISPOSED) return reject(REASON_DISPOSED)
        val s = session ?: return reject("not_loaded")
        if (state == State.FAILED) return reject("failed:${failureReason ?: "unknown"}")
        if (!commandAllowed(Op.INGEST, state)) return reject("invalid_state_${state.name.lowercase()}")
        if (request.trackIndex < 0 || request.trackIndex >= config.trackCount) {
            return reject("${REASON_INGEST_PREFIX}invalid_track")
        }
        if (!config.isExternalTrack(request.trackIndex)) {
            return reject("${REASON_INGEST_PREFIX}track_not_external")
        }
        if (request.frameCount <= 0 || request.expectedStartFrame < 0L) {
            return reject("${REASON_INGEST_PREFIX}invalid_args")
        }
        if (!request.src.isDirect) return reject("${REASON_INGEST_PREFIX}non_direct_buffer")
        if (request.src.capacity() < request.frameCount.toLong() * config.bytesPerFrame) {
            return reject("${REASON_INGEST_PREFIX}insufficient_buffer_capacity")
        }
        val reply = s.ingest(
            request.trackIndex, request.src, request.frameCount, request.expectedStartFrame,
        )
        if (reply.ingestNonterminal) return verifyAndObserve(reply)
        return when (reply.status) {
            // Producer must re-anchor (reply.nextWriteFrame) or retry later;
            // the session itself is intact and nothing was written.
            VanguardRealtimePlaybackNativeSession.STATUS_EXPECTED_START_MISMATCH,
            VanguardRealtimePlaybackNativeSession.STATUS_AWAITING_SEEK_ACK,
            VanguardRealtimePlaybackNativeSession.STATUS_COMMAND_IN_FLIGHT,
            VanguardRealtimePlaybackNativeSession.STATUS_FORMAT_MISMATCH,
            VanguardRealtimePlaybackNativeSession.STATUS_INVALID_TRACK,
            VanguardRealtimePlaybackNativeSession.STATUS_TRACK_NOT_EXTERNAL,
            VanguardRealtimePlaybackNativeSession.STATUS_INVALID_ARGS,
            "null_pcm_buffer", "non_direct_buffer", "direct_buffer_address_unavailable",
            "insufficient_buffer_capacity",
            -> reject("$REASON_INGEST_PREFIX${reply.status}", reply)
            else -> failClosedOnReply(Op.INGEST, reply)
        }
    }

    // Native rejected the call. Kotlin is authoritative, so a native
    // invalid_state for a command Kotlin allowed is a divergence; every
    // other non-ok status is a native failure. Both fail closed.
    private fun failClosedOnReply(op: Op, reply: Reply): Result {
        val reason = when (reply.status) {
            VanguardRealtimePlaybackNativeSession.STATUS_INVALID_STATE ->
                "native_state_divergence:${op.name.lowercase()}:${reply.stateToken}"
            VanguardRealtimePlaybackNativeSession.STATUS_WRONG_OWNER_THREAD -> "wrong_owner_thread"
            VanguardRealtimePlaybackNativeSession.STATUS_COMMAND_TIMEOUT -> "native_command_timeout"
            else -> "native_${reply.status}:${reply.lastError}"
        }
        return fail(reason, reply)
    }

    // After every successful native call: the derived native state must be
    // consistent with the authoritative Kotlin state, and a native
    // `completed` seen from PLAYING/PAUSED is the single completion path.
    private fun verifyAndObserve(reply: Reply): Result {
        if (reply.state == NativeState.FAILED) return fail("native_failed:${reply.lastError}", reply)
        val consistent = when (state) {
            State.IDLE -> reply.state == NativeState.IDLE
            State.PREPARED -> reply.state == NativeState.PREPARED
            State.PLAYING, State.PAUSED -> {
                val expected = if (state == State.PLAYING) NativeState.PLAYING else NativeState.PAUSED
                reply.state == expected || reply.state == NativeState.COMPLETED
            }
            State.STOPPED -> reply.state == NativeState.STOPPED
            State.COMPLETED -> reply.state == NativeState.COMPLETED
            State.FAILED, State.DISPOSED -> false
        }
        if (!consistent) {
            return fail("native_state_divergence:${state.name.lowercase()}:${reply.stateToken}", reply)
        }
        if (reply.state == NativeState.COMPLETED && (state == State.PLAYING || state == State.PAUSED)) {
            // The cursor (not the cumulative pushed total, which seeks skew)
            // must sit exactly on the declared end.
            if (reply.positionFrame != config.declaredFrameCount || !reply.eosDrained) {
                return fail("completion_cursor_divergence:${reply.positionFrame}", reply)
            }
            transition(State.COMPLETED)
            listener?.onCompleted(generation)
        }
        return accept(reply)
    }

    // Exactly one failure path: first failure wins, later ones are no-ops
    // beyond returning a rejected result.
    private fun fail(reason: String, reply: Reply? = null): Result {
        if (state == State.FAILED || state == State.DISPOSED) return reject(reason, reply)
        failureReason = reason
        transition(State.FAILED)
        listener?.onFailed(reason, generation)
        return Result(false, state, generation, reason, reply)
    }

    private fun transition(to: State) {
        val from = state
        if (from == to) return
        state = to
        publishedState = to
        listener?.onStateChanged(from, to, generation)
    }

    private fun commandAllowed(op: Op, current: State): Boolean = when (op) {
        Op.LOAD -> current == State.IDLE
        Op.PREPARE -> current == State.IDLE || current == State.PREPARED || current == State.STOPPED
        Op.START -> current == State.PREPARED || current == State.STOPPED
        Op.PAUSE -> current == State.PLAYING
        Op.RESUME -> current == State.PAUSED
        Op.SEEK -> current == State.PREPARED || current == State.PLAYING ||
            current == State.PAUSED || current == State.STOPPED
        Op.STOP -> current == State.PREPARED || current == State.PLAYING ||
            current == State.PAUSED || current == State.STOPPED || current == State.COMPLETED
        Op.SNAPSHOT -> current != State.DISPOSED
        Op.DRAIN -> current != State.IDLE && current != State.FAILED && current != State.DISPOSED
        // Pre-roll while PREPARED/STOPPED, steady-state while PLAYING/PAUSED;
        // COMPLETED answers eos_reached natively (harmless, no mutation).
        Op.INGEST -> current != State.IDLE && current != State.FAILED && current != State.DISPOSED
    }
}
