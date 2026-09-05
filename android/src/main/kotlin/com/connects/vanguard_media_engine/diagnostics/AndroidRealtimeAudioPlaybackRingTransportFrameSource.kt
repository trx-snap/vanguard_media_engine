package com.connects.vanguard_media_engine.diagnostics

import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackFrameSource
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// ── AndroidRealtimeAudioPlaybackRingTransportFrameSource (P4-AUDIO-REALTIME-PLAYBACK-RING-FRAME-SOURCE-PROOF, Y18b) ─
//
// Diagnostics-owned implementation of the Y18a production seam
// [VanguardRealtimeAudioPlaybackFrameSource] that feeds the PRODUCTION
// [com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimeAudioPlaybackSinkBridge]
// from the existing async-runtime multi-source native OUTPUT RING
// (android_phase4_async_runtime_queue_multi_source_realtime_clock_jni.cpp,
// wrapped by [AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession])
// instead of the Y1 transport state machine. The production package never
// depends on this class: the sink sees only the seam.
//
// Ownership / threading (mirrors the production route 1:1):
//   - The native session is owner-thread-only for EVERY non-destroy JNI
//     entry point (read included), so this adapter owns ONE ring-owner
//     thread that creates the session, prefills BOTH node-owned source
//     rings with deterministic synthetic PCM (the reference identity
//     [VanguardRealtimePlaybackNativeSession.referenceSample]), enqueues
//     the single Start command, keeps both rings fed ahead of the native
//     realtime worker, sets the joint EOS exactly once after the exact
//     expected timeline completed (WITHOUT draining: the sink is the sole
//     output consumer), takes the final snapshot and destroys/joins.
//   - [drain] is called on the SINK thread only. Exactly like
//     [VanguardRealtimePlaybackTransportStateMachine.drain] marshals onto
//     its HandlerThread and blocks on a latch, this adapter hands the
//     sink's own direct buffer to the ring-owner thread, which performs
//     the destructive read through
//     [AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.readOutputInto],
//     and blocks the sink thread (deadline-bounded) until the reply is
//     back. The reply is translated into a
//     [VanguardRealtimePlaybackNativeSession.Reply] carrying framesRead /
//     bytesRead / eosDrained (eosDrained is the NATIVE read-reply verdict,
//     never synthesized here). A drain never issues a transport command.
//   - [postDriftSample] is called on the sink thread only and is
//     fire-and-forget. This ring transport has no owner entry point that
//     accepts a caller drift sample (the native worker alone records drift
//     on its AudioClock; adding a mutator route is out of scope), so every
//     sample is rejected inline with the typed reason
//     [REASON_DRIFT_RING_UNSUPPORTED] (or stale_generation when the pinned
//     generation is not [RING_GENERATION]). The sink counts rejections and
//     never acts on them; nothing feeds back.
//   - [isOwnerThread] is true only on the ring-owner thread; the sink fails
//     closed if its sink thread were that thread.
//
// Honest non-claims: diagnostic production-component proof only. No
// MediaExtractor/MediaCodec here (synthetic PCM on both tracks), no seek,
// no pause, no product/editor/app wiring, no streaming/cache, no iOS, no
// change to currentPosition authority, pacing, resampling, AudioClock
// mutators, the sink, the seam, or any X4..X15 entry point.
class AndroidRealtimeAudioPlaybackRingTransportFrameSource(
    private val config: Config,
) : VanguardRealtimeAudioPlaybackFrameSource {

    data class Config(
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        // Window-aligned frame count of the whole synthetic timeline.
        val expectedFrames: Long,
        val sourceRingCapacityFrames: Int = DEFAULT_SOURCE_RING_CAPACITY_FRAMES,
        val outputRingCapacityFrames: Int = DEFAULT_OUTPUT_RING_CAPACITY_FRAMES,
        // Absolute SystemClock.elapsedRealtime() deadline shared with the sink.
        val deadlineAtMs: Long,
        val threadName: String = "VanguardY18bRingOwner",
    )

    enum class Stage { CREATED, OPENING, READY, STARTED, EOS_SET, CLOSING, CLOSED, FAILED }

    class FailClosed(val reason: String) : Exception(reason)

    // Adapter-side facts (owner thread + sink thread counters).
    data class Telemetry(
        val stage: Stage,
        val failureReason: String,
        val ownerThreadId: Long,
        val sinkThreadIdObserved: Long,
        val drainCallsFromSink: Long,
        val drainCallsOnOwnerThread: Long,
        val drainCallsOnOtherThreads: Long,
        val drainOverlapRejects: Long,
        val drainsBeforeStartRejected: Long,
        val drainsServiced: Long,
        val drainsAfterCloseRejected: Long,
        val drainOwnerTimeouts: Long,
        val framesReadBySink: Long,
        val emptyReadsServiced: Long,
        val outputSinkAccountedFrames: Long,
        val outputSinkCallbacks: Long,
        val outputSinkCallbacksOffOwner: Long,
        val totalOutputFramesRead: Long,
        val nativeOutputReadChecksumHex: String,
        val kotlinReferenceMixChecksumHex: String,
        val kotlinTrack0ChecksumHex: String,
        val kotlinTrack1ChecksumHex: String,
        val nativeAcceptedChecksumHexTrack0: String,
        val nativeAcceptedChecksumHexTrack1: String,
        val framesIngestedTrack0: Long,
        val framesIngestedTrack1: Long,
        val ingestCallsTrack0: Long,
        val ingestCallsTrack1: Long,
        val ingestRingFullEventsTrack0: Long,
        val ingestRingFullEventsTrack1: Long,
        val preStartFillFrames: Long,
        val transportCommandsIssued: Long,
        val transportCommandsFromDrain: Long,
        val eosSetWithoutDrain: Boolean,
        val totalFramesPushedAtEos: Long,
        val eosDrainedObservedByRing: Boolean,
        val eosPollSnapshots: Long,
        val driftSamplesPosted: Long,
        val driftSamplesRejectedUnsupported: Long,
        val driftSamplesRejectedStale: Long,
        val destroyJoinOk: Boolean,
        val destroyIdempotentOk: Boolean,
        val openWallMs: Long,
        val startWallMs: Long,
        val ownerLoopWallMs: Long,
        val ownerLoopIterations: Long,
        val native: NativeTelemetry?,
    )

    // Facts folded from the owner thread's FINAL native snapshot (taken
    // right before destroy), null when no snapshot could be taken.
    data class NativeTelemetry(
        val commandsEnqueued: Long,
        val commandsProcessed: Long,
        val commandErrors: Long,
        val queueDepth: Long,
        val dispatchCount: Long,
        val okCount: Long,
        val silenceCount: Long,
        val backpressureCount: Long,
        val schedulerErrorCount: Long,
        val workerDispatchAnomalies: Long,
        val nonMonotonicTimeAnomalies: Long,
        val workerStarvedWaits: Long,
        val totalFramesRendered: Long,
        val totalFramesPushed: Long,
        val ownerDispatchCalls: Long,
        val workerThreadDistinct: Boolean,
        val noCallerSuppliedNativeTime: Boolean,
        val workerOwnsMonotonicClock: Boolean,
        val terminal: Boolean,
        val timelineComplete: Boolean,
        val eosTrack0: Boolean,
        val eosTrack1: Boolean,
        val providerFramesZeroFilledTrack0: Long,
        val providerFramesZeroFilledTrack1: Long,
        val providerUnderrunEventsTrack0: Long,
        val providerUnderrunEventsTrack1: Long,
        val writerSeekRequestsTrack0: Long,
        val writerSeekRequestsTrack1: Long,
        val totalFramesAcceptedTrack0: Long,
        val totalFramesAcceptedTrack1: Long,
        val outputAvailableReadFrames: Long,
        val totalOutputFramesRead: Long,
        val paused: Boolean,
        val pauseCommandsProcessed: Long,
        val resumeCommandsProcessed: Long,
        val envelopeProofEnabled: Boolean,
        val realtimeElapsedOk: Boolean,
        val nativeRealtimeElapsedMs: Long,
        val realtimeBacklogBoundOk: Boolean,
        val clockDriftSampleCount: Long,
        val proofBoundaryOk: Boolean,
    )

    companion object {
        // Fixed transport generation of this ring route (the sink pins it
        // onto drift samples; there is no start/seek generation bump here).
        const val RING_GENERATION = 1L
        const val REASON_OK = VanguardRealtimePlaybackTransportStateMachine.REASON_OK
        const val REASON_DRIFT_RING_UNSUPPORTED =
            VanguardRealtimePlaybackTransportStateMachine.REASON_DRIFT_PREFIX + "ring_transport_unsupported"
        const val DEFAULT_SOURCE_RING_CAPACITY_FRAMES = 8_192
        const val DEFAULT_OUTPUT_RING_CAPACITY_FRAMES = 4_096
        const val TRACK_COUNT = 2

        private const val INGEST_CHUNK_FRAMES = 2_048
        private const val OWNER_IDLE_WAIT_MS = 1L
        private const val EOS_POLL_INTERVAL_MS = 4L
        private const val JOIN_SLACK_MS = 2_000L

        private fun hex16(value: Long): String = String.format("%016x", value)
    }

    private class DrainRequest(val dst: ByteBuffer, val maxFrames: Int) {
        val latch = CountDownLatch(1)
        @Volatile var result: VanguardRealtimeAudioPlaybackFrameSource.DrainResult? = null
    }

    // ── Cross-thread control ───────────────────────────────────────────────

    private val opened = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private val startRequested = AtomicBoolean(false)
    private val readyLatch = CountDownLatch(1)
    private val startLatch = CountDownLatch(1)
    private val closedLatch = CountDownLatch(1)
    private val requestLock = ReentrantLock()
    private val requestCondition = requestLock.newCondition()
    // Guarded by requestLock. acceptingRequests flips false exactly once,
    // by the owner thread in its finally block, so no drain can be
    // enqueued after the owner's last pending-request rejection.
    private var pendingDrain: DrainRequest? = null
    private var acceptingRequests = true
    @Volatile private var ownerThread: Thread? = null
    @Volatile private var ownerThreadId = -1L
    @Volatile private var stage = Stage.CREATED
    @Volatile private var failureReason = ""
    @Volatile private var started = false

    // ── Sink-thread telemetry (atomics: written on the sink thread, read anywhere) ─

    @Volatile private var sinkThreadIdObserved = -1L
    private val drainCallsFromSink = AtomicLong(0L)
    private val drainCallsOnOwnerThread = AtomicLong(0L)
    private val drainCallsOnOtherThreads = AtomicLong(0L)
    private val drainOverlapRejects = AtomicLong(0L)
    private val drainsAfterCloseRejected = AtomicLong(0L)
    private val drainOwnerTimeouts = AtomicLong(0L)
    private val driftSamplesPosted = AtomicLong(0L)
    private val driftSamplesRejectedUnsupported = AtomicLong(0L)
    private val driftSamplesRejectedStale = AtomicLong(0L)

    // ── Owner-thread-confined state (published as volatile for telemetry) ──

    private var session: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession? = null
    private var readBuf: ByteBuffer? = null
    private val ingestChunk = arrayOfNulls<ByteBuffer>(TRACK_COUNT)
    private val ingestCursor = longArrayOf(0L, 0L)
    private val ingestCalls = longArrayOf(0L, 0L)
    private val ingestRingFullEvents = longArrayOf(0L, 0L)
    private val kotlinTrackChecksum = longArrayOf(0L, 0L)
    private var kotlinReferenceMixChecksum = 0L
    private var nextEosPollAtMs = 0L
    @Volatile private var drainsBeforeStartRejected = 0L
    @Volatile private var drainsServiced = 0L
    @Volatile private var framesReadBySink = 0L
    @Volatile private var emptyReadsServiced = 0L
    @Volatile private var outputSinkAccountedFrames = 0L
    @Volatile private var outputSinkCallbacks = 0L
    @Volatile private var outputSinkCallbacksOffOwner = 0L
    @Volatile private var preStartFillFrames = -1L
    @Volatile private var transportCommandsIssued = 0L
    @Volatile private var transportCommandsFromDrain = 0L
    @Volatile private var eosDrainedObservedByRing = false
    @Volatile private var eosPollSnapshots = 0L
    @Volatile private var destroyJoinOk = false
    @Volatile private var destroyIdempotentOk = false
    @Volatile private var openWallMs = -1L
    @Volatile private var startWallMs = -1L
    @Volatile private var ownerLoopWallMs = -1L
    @Volatile private var ownerLoopIterations = 0L
    @Volatile private var finalNative: NativeTelemetry? = null
    @Volatile private var finalTotalOutputFramesRead = 0L
    @Volatile private var finalNativeOutputReadChecksumHex = ""
    @Volatile private var finalNativeAcceptedChecksumHexTrack0 = ""
    @Volatile private var finalNativeAcceptedChecksumHexTrack1 = ""
    @Volatile private var finalEosSetWithoutDrain = false
    @Volatile private var finalTotalFramesPushedAtEos = -1L

    val currentStage: Stage get() = stage
    val currentFailureReason: String get() = failureReason
    val ringOwnerThreadId: Long get() = ownerThreadId

    // ── Seam (VanguardRealtimeAudioPlaybackFrameSource) ────────────────────

    override val isOwnerThread: Boolean
        get() = ownerThreadId > 0L && Thread.currentThread().id == ownerThreadId

    override val currentGeneration: Long get() = RING_GENERATION

    override val currentStateLabel: String get() = "ring_${stage.name.lowercase()}"

    // Sink thread only (class comment): marshals the read onto the
    // ring-owner thread and blocks (deadline-bounded) for the reply.
    override fun drain(dst: ByteBuffer, maxFrames: Int): VanguardRealtimeAudioPlaybackFrameSource.DrainResult {
        drainCallsFromSink.incrementAndGet()
        val callerId = Thread.currentThread().id
        if (sinkThreadIdObserved < 0L) sinkThreadIdObserved = callerId
        else if (sinkThreadIdObserved != callerId) drainCallsOnOtherThreads.incrementAndGet()
        if (ownerThreadId > 0L && callerId == ownerThreadId) {
            drainCallsOnOwnerThread.incrementAndGet()
            return reject("ring_drain_on_owner_thread")
        }
        if (maxFrames <= 0) return reject("ring_drain_invalid_max_frames")
        when (stage) {
            Stage.CLOSING, Stage.CLOSED -> {
                drainsAfterCloseRejected.incrementAndGet()
                return reject("ring_closed")
            }
            Stage.FAILED -> {
                drainsAfterCloseRejected.incrementAndGet()
                return reject("ring_owner_failed:$failureReason")
            }
            else -> {}
        }
        val request = DrainRequest(dst, maxFrames)
        requestLock.withLock {
            if (!acceptingRequests) {
                drainsAfterCloseRejected.incrementAndGet()
                return reject(if (stage == Stage.FAILED) "ring_owner_failed:$failureReason" else "ring_closed")
            }
            if (pendingDrain != null) {
                drainOverlapRejects.incrementAndGet()
                return reject("ring_drain_overlap")
            }
            pendingDrain = request
            requestCondition.signalAll()
        }
        val waitMs = (config.deadlineAtMs - SystemClock.elapsedRealtime()).coerceAtLeast(1L)
        val completed = try {
            request.latch.await(waitMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!completed) {
            requestLock.withLock { if (pendingDrain === request) pendingDrain = null }
            drainOwnerTimeouts.incrementAndGet()
            return reject("ring_owner_timeout")
        }
        return request.result ?: reject("ring_owner_failed:${failureReason.ifBlank { "unknown" }}")
    }

    // Sink thread only, fire-and-forget (class comment): always rejected
    // inline with a typed reason; never blocks, never reaches native.
    override fun postDriftSample(
        request: VanguardRealtimePlaybackTransportStateMachine.DriftSampleRequest,
        expectedGeneration: Long?,
        callback: ((VanguardRealtimeAudioPlaybackFrameSource.DriftResult) -> Unit)?,
    ): Boolean {
        driftSamplesPosted.incrementAndGet()
        val reason = if (expectedGeneration != null && expectedGeneration != RING_GENERATION) {
            driftSamplesRejectedStale.incrementAndGet()
            VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION
        } else {
            driftSamplesRejectedUnsupported.incrementAndGet()
            REASON_DRIFT_RING_UNSUPPORTED
        }
        callback?.invoke(VanguardRealtimeAudioPlaybackFrameSource.DriftResult(false, reason, null))
        return false
    }

    private fun reject(reason: String) =
        VanguardRealtimeAudioPlaybackFrameSource.DrainResult(false, reason, null)

    // ── Lifecycle (coordinator thread) ─────────────────────────────────────

    // Starts the ring-owner thread (create + prefill) and waits until the
    // ring is READY (both source rings prefilled, no Start enqueued yet).
    // Single use; false on timeout or any owner-thread failure.
    fun open(timeoutMs: Long): Boolean {
        if (!opened.compareAndSet(false, true)) return false
        stage = Stage.OPENING
        val t = Thread({ runOwnerThread() }, config.threadName)
        ownerThread = t
        t.start()
        val ok = try {
            readyLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        return ok && stage == Stage.READY
    }

    // Enqueues the ONE native Start command on the ring-owner thread and
    // waits for its execution plus the output-ring start ack. Must precede
    // the sink's allowDrain(). False on timeout or failure.
    fun startTransport(timeoutMs: Long): Boolean {
        if (stage != Stage.READY) return false
        if (!startRequested.compareAndSet(false, true)) return false
        requestLock.withLock { requestCondition.signalAll() }
        val ok = try {
            startLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        return ok && started && stage != Stage.FAILED
    }

    // Any thread: asks the owner loop to stop (pending drains are rejected).
    fun cancel() {
        stopRequested.set(true)
        requestLock.withLock { requestCondition.signalAll() }
    }

    // Stops the owner loop, lets it take the final snapshot and destroy /
    // join the native worker, then joins the owner thread. Idempotent;
    // true once the owner thread has exited.
    fun close(timeoutMs: Long): Boolean {
        cancel()
        val t = ownerThread ?: return true
        if (Thread.currentThread() === t) return false
        try {
            closedLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
            t.join(JOIN_SLACK_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return !t.isAlive
    }

    fun telemetry(): Telemetry = Telemetry(
        stage = stage,
        failureReason = failureReason,
        ownerThreadId = ownerThreadId,
        sinkThreadIdObserved = sinkThreadIdObserved,
        drainCallsFromSink = drainCallsFromSink.get(),
        drainCallsOnOwnerThread = drainCallsOnOwnerThread.get(),
        drainCallsOnOtherThreads = drainCallsOnOtherThreads.get(),
        drainOverlapRejects = drainOverlapRejects.get(),
        drainsBeforeStartRejected = drainsBeforeStartRejected,
        drainsServiced = drainsServiced,
        drainsAfterCloseRejected = drainsAfterCloseRejected.get(),
        drainOwnerTimeouts = drainOwnerTimeouts.get(),
        framesReadBySink = framesReadBySink,
        emptyReadsServiced = emptyReadsServiced,
        outputSinkAccountedFrames = outputSinkAccountedFrames,
        outputSinkCallbacks = outputSinkCallbacks,
        outputSinkCallbacksOffOwner = outputSinkCallbacksOffOwner,
        totalOutputFramesRead = finalTotalOutputFramesRead,
        nativeOutputReadChecksumHex = finalNativeOutputReadChecksumHex,
        kotlinReferenceMixChecksumHex = hex16(kotlinReferenceMixChecksum),
        kotlinTrack0ChecksumHex = hex16(kotlinTrackChecksum[0]),
        kotlinTrack1ChecksumHex = hex16(kotlinTrackChecksum[1]),
        nativeAcceptedChecksumHexTrack0 = finalNativeAcceptedChecksumHexTrack0,
        nativeAcceptedChecksumHexTrack1 = finalNativeAcceptedChecksumHexTrack1,
        framesIngestedTrack0 = ingestCursor[0],
        framesIngestedTrack1 = ingestCursor[1],
        ingestCallsTrack0 = ingestCalls[0],
        ingestCallsTrack1 = ingestCalls[1],
        ingestRingFullEventsTrack0 = ingestRingFullEvents[0],
        ingestRingFullEventsTrack1 = ingestRingFullEvents[1],
        preStartFillFrames = preStartFillFrames,
        transportCommandsIssued = transportCommandsIssued,
        transportCommandsFromDrain = transportCommandsFromDrain,
        eosSetWithoutDrain = finalEosSetWithoutDrain,
        totalFramesPushedAtEos = finalTotalFramesPushedAtEos,
        eosDrainedObservedByRing = eosDrainedObservedByRing,
        eosPollSnapshots = eosPollSnapshots,
        driftSamplesPosted = driftSamplesPosted.get(),
        driftSamplesRejectedUnsupported = driftSamplesRejectedUnsupported.get(),
        driftSamplesRejectedStale = driftSamplesRejectedStale.get(),
        destroyJoinOk = destroyJoinOk,
        destroyIdempotentOk = destroyIdempotentOk,
        openWallMs = openWallMs,
        startWallMs = startWallMs,
        ownerLoopWallMs = ownerLoopWallMs,
        ownerLoopIterations = ownerLoopIterations,
        native = finalNative,
    )

    // ── Ring-owner thread ──────────────────────────────────────────────────

    private fun runOwnerThread() {
        ownerThreadId = Thread.currentThread().id
        val openStart = SystemClock.elapsedRealtime()
        var loopStart = -1L
        try {
            validateConfig()
            establishSession()
            prefillBothRings()
            stage = Stage.READY
            openWallMs = SystemClock.elapsedRealtime() - openStart
            readyLatch.countDown()
            loopStart = SystemClock.elapsedRealtime()
            ownerLoop()
        } catch (f: FailClosed) {
            fail(f.reason)
        } catch (f: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.Failure) {
            fail("native_session:${f.reason}")
        } catch (t: Throwable) {
            fail("exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            if (loopStart >= 0L) ownerLoopWallMs = SystemClock.elapsedRealtime() - loopStart
            if (stage != Stage.FAILED) stage = Stage.CLOSING
            rejectPendingDrain()
            finalizeSession()
            if (stage != Stage.FAILED) stage = Stage.CLOSED
            // Waiters must never block on a dead owner; they re-check stage.
            readyLatch.countDown()
            startLatch.countDown()
            closedLatch.countDown()
        }
    }

    private fun fail(reason: String) {
        if (failureReason.isBlank()) failureReason = reason
        stage = Stage.FAILED
    }

    private fun validateConfig() {
        val c = config
        if (c.channelCount != 1 && c.channelCount != 2) throw FailClosed("ring_invalid_channel_count")
        if (c.sampleRate < VanguardRealtimePlaybackNativeSession.MIN_SAMPLE_RATE ||
            c.sampleRate > VanguardRealtimePlaybackNativeSession.MAX_SAMPLE_RATE
        ) {
            throw FailClosed("ring_invalid_sample_rate")
        }
        if (c.maxFramesPerMix <= 0 || c.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP) {
            throw FailClosed("ring_invalid_max_frames_per_mix")
        }
        if (c.expectedFrames <= 0L || c.expectedFrames % c.maxFramesPerMix != 0L) {
            throw FailClosed("ring_expected_frames_not_window_aligned")
        }
        if (c.outputRingCapacityFrames < c.maxFramesPerMix ||
            c.outputRingCapacityFrames % c.maxFramesPerMix != 0
        ) {
            throw FailClosed("ring_output_ring_not_window_aligned")
        }
        if (c.sourceRingCapacityFrames < c.outputRingCapacityFrames + 2 * c.maxFramesPerMix) {
            throw FailClosed("ring_source_ring_geometry")
        }
        if (c.maxFramesPerMix > INGEST_CHUNK_FRAMES) throw FailClosed("ring_window_exceeds_ingest_chunk")
    }

    // Creates the native session with the accounting-only output sink and
    // computes the three Kotlin reference checksums (per-track accepted
    // identity and the unit-gain reference mix, AudioMixBusNode parity:
    // integer sum clamped once at the int16 output stage) over the whole
    // timeline BEFORE any frame crosses JNI.
    private fun establishSession() {
        val bytesPerFrame = 2 * config.channelCount
        val s = AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession(
            deadlineElapsedRealtimeMs = config.deadlineAtMs,
            outputSink = { frames ->
                outputSinkCallbacks += 1L
                if (Thread.currentThread().id != ownerThreadId) outputSinkCallbacksOffOwner += 1L
                outputSinkAccountedFrames += frames
            },
        )
        val buf = ByteBuffer
            .allocateDirect(config.outputRingCapacityFrames * bytesPerFrame)
            .order(ByteOrder.LITTLE_ENDIAN)
        readBuf = buf
        for (track in 0 until TRACK_COUNT) {
            ingestChunk[track] = ByteBuffer
                .allocateDirect(INGEST_CHUNK_FRAMES * bytesPerFrame)
                .order(ByteOrder.LITTLE_ENDIAN)
        }
        var c0 = 0L
        var c1 = 0L
        var cm = 0L
        for (frame in 0L until config.expectedFrames) {
            for (ch in 0 until config.channelCount) {
                val s0 = VanguardRealtimePlaybackNativeSession.referenceSample(0, frame, ch).toInt()
                val s1 = VanguardRealtimePlaybackNativeSession.referenceSample(1, frame, ch).toInt()
                c0 = c0 * 31L + (s0.toLong() and 0xFFFFL)
                c1 = c1 * 31L + (s1.toLong() and 0xFFFFL)
                var acc = s0 + s1
                if (acc > 32767) acc = 32767 else if (acc < -32768) acc = -32768
                cm = cm * 31L + (acc.toLong() and 0xFFFFL)
            }
        }
        kotlinTrackChecksum[0] = c0
        kotlinTrackChecksum[1] = c1
        kotlinReferenceMixChecksum = cm
        s.create(
            sampleRateIn = config.sampleRate,
            channelCountIn = config.channelCount,
            expectedFramesIn = config.expectedFrames,
            sourceRingCapacityFrames = config.sourceRingCapacityFrames,
            outputRingCapacityFrames = config.outputRingCapacityFrames,
            maxFramesPerMix = config.maxFramesPerMix,
            readBuffer = buf,
        )
        session = s
    }

    // Fills BOTH node-owned source rings before Start (no drain exists
    // yet) until each is full or the whole timeline is ingested, so both
    // decodes stay ahead of the realtime clock from the first window.
    private fun prefillBothRings() {
        val s = requireSession()
        while (true) {
            var progressed = false
            for (track in 0 until TRACK_COUNT) progressed = ingestTrack(track) || progressed
            if (!progressed) break
        }
        preStartFillFrames = minOf(s.totalFramesAcceptedTrack0, s.totalFramesAcceptedTrack1)
        val quota = minOf(config.outputRingCapacityFrames.toLong(), config.expectedFrames)
        if (preStartFillFrames < quota) throw FailClosed("ring_prestart_fill_below_quota:$preStartFillFrames:$quota")
    }

    // One ingest of up to INGEST_CHUNK_FRAMES synthetic frames for [track]
    // at that track's own cursor (independent cursors: the native joint
    // gate renders only what BOTH rings can satisfy). Returns whether any
    // frame was accepted; ring_full / partial_write are reported outcomes.
    private fun ingestTrack(track: Int): Boolean {
        val s = requireSession()
        val cursor = ingestCursor[track]
        val remaining = config.expectedFrames - cursor
        if (remaining <= 0L) return false
        val n = minOf(INGEST_CHUNK_FRAMES.toLong(), remaining).toInt()
        val chunk = ingestChunk[track] ?: throw FailClosed("ring_ingest_chunk_missing")
        val channels = config.channelCount
        var idx = 0
        for (f in 0 until n) {
            val frame = cursor + f
            for (ch in 0 until channels) {
                chunk.putShort(idx * 2, VanguardRealtimePlaybackNativeSession.referenceSample(track, frame, ch))
                idx++
            }
        }
        val reply = s.ingestTrackOnce(track, chunk, n)
        ingestCalls[track] += 1L
        if (reply.framesAccepted > 0L) {
            ingestCursor[track] = cursor + reply.framesAccepted
            return true
        }
        ingestRingFullEvents[track] += 1L
        return false
    }

    // Services Start / drain requests with priority, keeps both rings fed,
    // then polls (snapshot-only, no ring read) for timeline completion to
    // set the joint EOS once; idles on the request condition otherwise.
    private fun ownerLoop() {
        val s = requireSession()
        while (!stopRequested.get()) {
            ownerLoopIterations += 1L
            if (SystemClock.elapsedRealtime() > config.deadlineAtMs) throw FailClosed("ring_owner_deadline_exceeded")
            var progressed = false
            if (!started && startRequested.get()) {
                val startAt = SystemClock.elapsedRealtime()
                transportCommandsIssued += 1L
                s.startAndConsumeAck()
                started = true
                stage = Stage.STARTED
                startWallMs = SystemClock.elapsedRealtime() - startAt
                nextEosPollAtMs = 0L
                startLatch.countDown()
                progressed = true
            }
            if (serviceDrainRequest()) progressed = true
            if (started) {
                if (ingestCursor[0] < config.expectedFrames || ingestCursor[1] < config.expectedFrames) {
                    for (track in 0 until TRACK_COUNT) progressed = ingestTrack(track) || progressed
                } else if (!s.eosSetWithoutDrain) {
                    val now = SystemClock.elapsedRealtime()
                    if (now >= nextEosPollAtMs) {
                        eosPollSnapshots += 1L
                        if (s.tryCompleteTimelineAndSetEosWithoutDrain()) {
                            stage = Stage.EOS_SET
                            progressed = true
                        }
                        nextEosPollAtMs = now + EOS_POLL_INTERVAL_MS
                    }
                }
            }
            if (!progressed) {
                requestLock.withLock {
                    if (pendingDrain == null && !stopRequested.get() && !(startRequested.get() && !started)) {
                        try {
                            requestCondition.await(OWNER_IDLE_WAIT_MS, TimeUnit.MILLISECONDS)
                        } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt()
                            throw FailClosed("ring_owner_interrupted")
                        }
                    }
                }
            }
        }
    }

    // One pending sink drain: destructive read straight into the sink's
    // buffer on THIS owner thread, reply translated to the seam type. A
    // read failure completes the request with a rejection and fails the
    // owner loop closed (the sink then exits with drain_rejected).
    private fun serviceDrainRequest(): Boolean {
        val request = requestLock.withLock {
            val r = pendingDrain
            pendingDrain = null
            r
        } ?: return false
        try {
            if (!started) {
                drainsBeforeStartRejected += 1L
                request.result = reject("ring_drain_before_start")
                return true
            }
            val s = requireSession()
            val r = s.readOutputInto(request.dst, request.maxFrames)
            drainsServiced += 1L
            if (r.framesRead > 0L) framesReadBySink += r.framesRead else emptyReadsServiced += 1L
            if (r.eosDrained) eosDrainedObservedByRing = true
            request.result = VanguardRealtimeAudioPlaybackFrameSource.DrainResult(true, REASON_OK, toReply(r))
            return true
        } catch (t: Throwable) {
            val reason = when (t) {
                is AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.Failure -> "native_session:${t.reason}"
                is FailClosed -> t.reason
                else -> "exception:${t.javaClass.simpleName}:${t.message}"
            }
            request.result = reject("ring_read_failed:$reason")
            throw FailClosed("ring_read_failed:$reason")
        } finally {
            request.latch.countDown()
        }
    }

    // Field-for-field translation of the native read reply into the seam's
    // production reply type through the production parser (no synthesized
    // EOS: eosDrained / eosPushed are the native verdicts).
    private fun toReply(r: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.SinkReadReply): VanguardRealtimePlaybackNativeSession.Reply {
        val stateToken = if (r.eosDrained) {
            VanguardRealtimePlaybackNativeSession.NativeState.COMPLETED.token
        } else {
            VanguardRealtimePlaybackNativeSession.NativeState.PLAYING.token
        }
        val raw = "status=${VanguardRealtimePlaybackNativeSession.STATUS_OK};state=$stateToken;handle=0;" +
            "trackCount=$TRACK_COUNT;declaredFrameCount=${config.expectedFrames};" +
            "maxFramesPerMix=${config.maxFramesPerMix};sampleRate=${config.sampleRate};channelCount=${config.channelCount};" +
            "renderedFrames=${r.totalFramesPushed};pushedFrames=${r.totalFramesPushed};drainedFrames=${r.totalOutputFramesRead};" +
            "discardedFrames=0;positionFrame=${r.totalOutputFramesRead};eosPushed=${r.eosPublished};eosDrained=${r.eosDrained};" +
            "commandSeq=0;commandResult=none;lastError=none;wrongOwnerThread=false;" +
            "outputAvailableReadFrames=${r.outputAvailableReadFrames};" +
            "drainedChecksumHex=${r.nativeOutputReadChecksumHex};" +
            "framesRead=${r.framesRead};bytesRead=${r.bytesRead};nativeClockState=none"
        return VanguardRealtimePlaybackNativeSession.parseReply(raw)
    }

    // Owner thread, finally block: closes the request gate under the lock
    // (no later drain can enqueue) and rejects the one request that may
    // still be pending.
    private fun rejectPendingDrain() {
        val request = requestLock.withLock {
            acceptingRequests = false
            val r = pendingDrain
            pendingDrain = null
            r
        } ?: return
        request.result = reject(
            if (stage == Stage.FAILED) "ring_owner_failed:${failureReason.ifBlank { "unknown" }}" else "ring_closed",
        )
        request.latch.countDown()
    }

    // Final snapshot (folded facts), destroy + join verdicts, finally-safe
    // cleanup; every step is best-effort so the native worker is always
    // joined even after a failure.
    private fun finalizeSession() {
        val s = session ?: return
        try {
            if (s.isCreated) {
                val snap = s.finalSnapshot()
                finalNative = foldNative(s, snap)
            }
        } catch (t: Throwable) {
            if (failureReason.isBlank()) {
                fail(
                    if (t is AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.Failure) "ring_final_snapshot:${t.reason}"
                    else "ring_final_snapshot:${t.javaClass.simpleName}",
                )
            }
        }
        finalTotalOutputFramesRead = s.totalOutputFramesRead
        finalNativeOutputReadChecksumHex = s.nativeOutputReadChecksumHex
        finalNativeAcceptedChecksumHexTrack0 = s.nativeAcceptedChecksumHexTrack0
        finalNativeAcceptedChecksumHexTrack1 = s.nativeAcceptedChecksumHexTrack1
        finalEosSetWithoutDrain = s.eosSetWithoutDrain
        finalTotalFramesPushedAtEos = s.totalFramesPushedAtEos
        try {
            if (s.isCreated) {
                val (joinOk, idempotentOk) = s.destroyAndVerifyLifecycle()
                destroyJoinOk = joinOk
                destroyIdempotentOk = idempotentOk
            }
        } catch (t: Throwable) {
            if (failureReason.isBlank()) fail("ring_destroy:${t.javaClass.simpleName}")
        } finally {
            s.cleanup()
        }
    }

    private fun foldNative(
        s: AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession,
        snap: Map<String, String>,
    ): NativeTelemetry {
        fun long(key: String): Long = snap[key]?.toLongOrNull() ?: -1L
        fun bool(key: String): Boolean = snap[key] == "true"
        return NativeTelemetry(
            commandsEnqueued = s.snapCommandsEnqueued,
            commandsProcessed = s.snapCommandsProcessed,
            commandErrors = s.snapCommandErrors,
            queueDepth = s.snapQueueDepth,
            dispatchCount = s.snapDispatchCount,
            okCount = s.snapOkCount,
            silenceCount = s.snapSilenceCount,
            backpressureCount = s.snapBackpressureCount,
            schedulerErrorCount = s.snapSchedulerErrorCount,
            workerDispatchAnomalies = s.snapWorkerDispatchAnomalies,
            nonMonotonicTimeAnomalies = s.snapNonMonotonicTimeAnomalies,
            workerStarvedWaits = s.snapWorkerStarvedWaits,
            totalFramesRendered = s.snapTotalFramesRendered,
            totalFramesPushed = s.snapTotalFramesPushed,
            ownerDispatchCalls = s.snapOwnerDispatchCalls,
            workerThreadDistinct = s.snapWorkerThreadDistinct,
            noCallerSuppliedNativeTime = s.snapNoCallerSuppliedNativeTime,
            workerOwnsMonotonicClock = s.snapWorkerOwnsMonotonicClock,
            terminal = s.snapTerminal,
            timelineComplete = bool("timelineComplete"),
            eosTrack0 = bool("writerEosTrack0"),
            eosTrack1 = bool("writerEosTrack1"),
            providerFramesZeroFilledTrack0 = s.snapProviderFramesZeroFilledTrack[0],
            providerFramesZeroFilledTrack1 = s.snapProviderFramesZeroFilledTrack[1],
            providerUnderrunEventsTrack0 = s.snapProviderUnderrunEventsTrack[0],
            providerUnderrunEventsTrack1 = s.snapProviderUnderrunEventsTrack[1],
            writerSeekRequestsTrack0 = long("writerSeekRequestsTrack0"),
            writerSeekRequestsTrack1 = long("writerSeekRequestsTrack1"),
            totalFramesAcceptedTrack0 = s.totalFramesAcceptedTrack0,
            totalFramesAcceptedTrack1 = s.totalFramesAcceptedTrack1,
            outputAvailableReadFrames = long("outputAvailableReadFrames"),
            totalOutputFramesRead = long("totalOutputFramesRead"),
            paused = s.snapPaused,
            pauseCommandsProcessed = s.snapPauseCommandsProcessed,
            resumeCommandsProcessed = s.snapResumeCommandsProcessed,
            envelopeProofEnabled = s.snapEnvelopeProofEnabled,
            realtimeElapsedOk = s.snapRealtimeElapsedOk,
            nativeRealtimeElapsedMs = s.snapNativeRealtimeElapsedMs,
            realtimeBacklogBoundOk = s.snapRealtimeBacklogBoundOk,
            clockDriftSampleCount = s.snapClockDriftSampleCount,
            proofBoundaryOk = s.snapProofBoundary ==
                AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession.NATIVE_PROOF_BOUNDARY,
        )
    }

    private fun requireSession(): AndroidAsyncRuntimeQueueMultiSourceRealtimeClockNativeSession =
        session ?: throw FailClosed("ring_session_missing")
}
