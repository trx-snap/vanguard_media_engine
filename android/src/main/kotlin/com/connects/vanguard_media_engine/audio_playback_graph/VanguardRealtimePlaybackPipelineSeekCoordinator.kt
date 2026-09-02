package com.connects.vanguard_media_engine.audio_playback_graph

import android.media.AudioTrack
import android.os.SystemClock
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.NativeState
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

// ── VanguardRealtimePlaybackPipelineSeekCoordinator (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-SEEK, Y6c) ─
//
// The ONLY transport command owner of the Y6c mid-stream seek proof over
// the committed Y6a/Y6b pipeline shape:
//
//   MediaExtractor/MediaCodec  ->  Y5a external ingest seam  ->  Y1 native
//   ([VanguardRealtimePlaybackPipelineSeekDecoderFeed], decode thread)
//   transport (owner HandlerThread inside the state machine)  ->
//   non-zero-gain AudioTrack MODE_STREAM
//   ([VanguardRealtimePlaybackPipelineSeekSinkBridge], sink thread)
//
// Thread model: the decoder feed thread only posts generation-pinned
// ingest (and performs the decoder re-seek on its own thread); the sink
// thread only drains and owns every AudioTrack call (pause / flush / play);
// the shared [VanguardRealtimePlaybackTransportStateMachine] is the only
// JNI caller; this coordinator (the caller's worker thread) issues exactly
// six transport commands (load, prepare, start, pause, seek, resume),
// drives the sink phase protocol, waits/joins and aggregates. It never
// calls an AudioTrack method.
//
// Fixed seek order (single track, one forward mid-stream seek):
//   pre-roll (PREPARED) -> hold frame H pinned on the feed (window-aligned,
//   H < target) -> start -> sink drains, first positive AudioTrack write ->
//   feed holds at H, the worker renders every ingested frame, the sink
//   drains it all: pushed == drained == H (quiescent) -> sink requestPark
//   -> sink ack PARKED (AudioTrack PAUSED on the sink thread) -> pre-seek
//   snapshot verified window-aligned and quiescent with discarded == 0 ->
//   transport.pause() -> sink AudioTrack.flush() exactly once on the sink
//   thread (opens the post-seek accounting epoch) -> transport.seek(target)
//   while PAUSED (state stays PAUSED, generation + 1) -> feed re-anchor on
//   the decode thread (pinned generation, staging cleared, extractor
//   previous-sync seek, codec flush, pre-target discard, bounded gap
//   silence padding, reopen-on-(-1)) -> deliberate stale pre-seek pinned
//   ingest rejected before JNI (reply == null) -> post-seek pre-roll of at
//   least one window while PAUSED -> sink unpark (AudioTrack.play on the
//   sink thread, epoch head base captured) -> transport.resume() -> drain
//   to EOS.
// The sink is intentionally PARKED before transport.pause(), the
// flush happens while both the AudioTrack and the transport are paused,
// and the seek is issued into a provably empty output ring.
//
// Two-epoch sink accounting: expected total transport reads / AudioTrack
// writes = H + (declared - target); the post-seek epoch is H..end. The
// playback-head proof is epoch-relative (post-seek head > 0 and <= post-
// seek written) because a flushed MODE_STREAM track restarts its head.
//
// Seek admission (fail closed, never pass late): H window-aligned,
// preRoll < H < target < declared - 2 * maxFramesPerMix.
//
// Terminal-state table:
// - start: feed opens/probes -> state machine (externalIngestTrackMask=1)
//   load, prepare -> feed attached, pre-rolls -> hold pinned -> start (+
//   feed generation update) -> sink starts -> first positive sink write.
// - seek: as above; a rejected command, a missing sink ack, a non-quiescent
//   pre-seek snapshot, a failed flush/re-anchor or an accepted stale probe
//   fails closed.
// - EOS: feed pads a <= 1 s shortfall; sink exits on eosDrained; the
//   transport observes COMPLETED on the owner thread.
// - failure / deadline / cancel: first failure wins (AtomicReference);
//   both threads are cancelled (a parked sink thread wakes on cancel),
//   MediaCodec/MediaExtractor and the AudioTrack are released exactly once
//   on their own threads, the state machine is disposed exactly once,
//   joins are bounded.
// - double run / dispose: AtomicBoolean guarded; [run] is single use.
//
// No presentation clock, A/V sync, latency/glitch/loudness/SNR claim,
// audio focus, becoming-noisy, route change, dead-object recovery,
// interactive UI, product/editor/app wiring, iOS, streaming/cache or C++
// change lives here.
class VanguardRealtimePlaybackPipelineSeekCoordinator {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val baseVolume: Float = VanguardRealtimePlaybackPipelineSeekSinkBridge.DEFAULT_BASE_VOLUME,
        val deadlineMs: Long = 30_000L,
        val seekTargetSec: Double = DEFAULT_SEEK_TARGET_SEC,
        // Windows fed after the pre-roll before the feed holds for the seek.
        val preSeekHoldWindows: Int = DEFAULT_PRE_SEEK_HOLD_WINDOWS,
    )

    data class Result(
        val pass: Boolean,
        val status: String,
        val failureReason: String,
        val proofBoundary: String,
        val lanes: Map<String, Boolean>,
        val metrics: Map<String, Any?>,
        val raw: String,
    )

    companion object {
        const val PROOF_BOUNDARY =
            "realtime_playback_pipeline_seek_diagnostic_only_real_mediaextractor_mediacodec_" +
                "to_y5a_external_ingest_to_y1_transport_to_nonzero_gain_audiotrack_base_gain_0_5_" +
                "single_track_one_forward_mid_stream_seek_while_paused_" +
                "feed_held_at_window_aligned_anchor_quiescent_pushed_eq_drained_eq_anchor_discarded_0_" +
                "sink_park_before_transport_pause_audiotrack_flush_once_on_sink_thread_before_transport_seek_" +
                "feed_reanchor_generation_pinned_stale_pre_seek_ingest_rejected_before_jni_" +
                "two_epoch_sink_accounting_epoch_relative_playback_head_" +
                "no_presentation_clock_no_av_sync_no_latency_no_glitch_no_loudness_no_snr_" +
                "no_audio_focus_no_becoming_noisy_no_route_change_no_dead_object_recovery_no_interactive_ui_" +
                "no_product_no_editor_no_app_wiring_no_ios_no_streaming_no_cache_no_cpp_changes"

        const val DEFAULT_SEEK_TARGET_SEC = 1.5
        const val DEFAULT_PRE_SEEK_HOLD_WINDOWS = 64
        const val MAX_PRE_SEEK_HOLD_WINDOWS = 1_024

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_PRE_ROLL = "preRollOk"
        const val LANE_INITIAL_DRAIN = "initialDrainOk"
        const val LANE_SEEK_QUIESCE_ACCOUNTING = "seekQuiesceAccountingOk"
        const val LANE_PAUSE_COMMAND = "pauseCommandOk"
        const val LANE_SINK_PAUSED = "sinkPausedOk"
        const val LANE_SEEK_COMMAND = "seekCommandOk"
        const val LANE_SINK_FLUSH_AT_SEEK = "sinkFlushAtSeekOk"
        const val LANE_REAL_DECODER_SEEK_REANCHOR = "realDecoderSeekReanchorOk"
        const val LANE_STALE_GENERATION_REJECTED = "staleGenerationRejectedOk"
        const val LANE_SINK_RESUMED = "sinkResumedOk"
        const val LANE_POST_SEEK_DRAIN = "postSeekDrainOk"
        const val LANE_SINK_WRITE_ACCOUNTING = "sinkWriteAccountingOk"
        const val LANE_CHECKSUM_IDENTITY = "checksumIdentityOk"
        const val LANE_POST_SEEK_PLAYBACK_HEAD_ADVANCED = "postSeekPlaybackHeadAdvancedOk"
        const val LANE_TRANSPORT_COMPLETED = "transportCompletedOk"
        const val LANE_THREAD_OWNERSHIP = "threadOwnershipOk"
        const val LANE_LIFECYCLE_DISPOSE = "lifecycleDisposeOk"
        const val LANE_PROOF_BOUNDARY = "proofBoundaryOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE,
            LANE_PRE_ROLL,
            LANE_INITIAL_DRAIN,
            LANE_SEEK_QUIESCE_ACCOUNTING,
            LANE_PAUSE_COMMAND,
            LANE_SINK_PAUSED,
            LANE_SEEK_COMMAND,
            LANE_SINK_FLUSH_AT_SEEK,
            LANE_REAL_DECODER_SEEK_REANCHOR,
            LANE_STALE_GENERATION_REJECTED,
            LANE_SINK_RESUMED,
            LANE_POST_SEEK_DRAIN,
            LANE_SINK_WRITE_ACCOUNTING,
            LANE_CHECKSUM_IDENTITY,
            LANE_POST_SEEK_PLAYBACK_HEAD_ADVANCED,
            LANE_TRANSPORT_COMPLETED,
            LANE_THREAD_OWNERSHIP,
            LANE_LIFECYCLE_DISPOSE,
        )

        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val INITIAL_WRITE_WAIT_MS = 2_000L
        private const val QUIESCE_WAIT_MS = 10_000L
        private const val SNAPSHOT_SETTLE_WAIT_MS = 2_000L
        private const val PARK_ACK_TIMEOUT_MS = 2_000L
        private const val FLUSH_ACK_TIMEOUT_MS = 2_000L
        private const val REANCHOR_WAIT_MS = 5_000L
        private const val POST_SEEK_PREROLL_WAIT_MS = 5_000L
        private const val UNPARK_ACK_TIMEOUT_MS = 2_000L
        // load, prepare, start, pause, seek, resume
        private const val COMMANDS_PER_SESSION = 6
    }

    private class FailClosed(val reason: String) : Exception(reason)

    private val started = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)

    @Volatile
    private var running = false

    @Volatile
    private var activeSession: Session? = null

    private val lanes = linkedMapOf<String, Boolean>()
    private val metrics = linkedMapOf<String, Any?>()

    // ── Public API ─────────────────────────────────────────────────────────

    // Requests cancellation from any thread; both pipeline threads observe
    // it at their next bounded wait (a parked sink wakes immediately) and
    // the run thread tears down.
    fun cancel() {
        cancelled.set(true)
        activeSession?.cancelThreads()
    }

    // Any-thread, idempotent. A running pipeline is cancelled (its own
    // threads release their resources); an idle one has nothing to free.
    fun dispose() {
        cancel()
        if (!running) activeSession?.disposeTransportOnce()
    }

    // Executes the whole proof on the calling thread. Single use.
    fun run(config: Config): Result {
        if (!started.compareAndSet(false, true)) return buildResult(false, "coordinator_already_used")
        running = true
        for (lane in REQUIRED_LANES) lanes[lane] = false
        return try {
            execute(config)
            val pass = REQUIRED_LANES.all { lanes[it] == true }
            buildResult(pass, if (pass) "" else "lane_failed:${firstFailedLane()}")
        } catch (f: FailClosed) {
            buildResult(false, f.reason)
        } catch (t: Throwable) {
            buildResult(false, "exception:${t.javaClass.simpleName}:${t.message}")
        } finally {
            activeSession?.disposeTransportOnce()
            activeSession = null
            running = false
        }
    }

    // ── Orchestration ──────────────────────────────────────────────────────

    private fun execute(config: Config) {
        if (config.sourcePath.isBlank()) throw FailClosed("source_path_required")
        if (config.maxDurationSec <= 0.0 ||
            config.maxDurationSec > VanguardRealtimePlaybackPipelineSeekDecoderFeed.HARD_MAX_DURATION_SEC
        ) {
            throw FailClosed("invalid_max_duration")
        }
        if (config.maxFramesPerMix <= 0 ||
            config.maxFramesPerMix > VanguardRealtimePlaybackNativeSession.MAX_FRAMES_PER_MIX_CAP
        ) {
            throw FailClosed("invalid_max_frames_per_mix")
        }
        if (!(config.baseVolume > 0f) || config.baseVolume > 1f) throw FailClosed("invalid_base_volume")
        if (config.deadlineMs <= 0L) throw FailClosed("invalid_deadline")
        if (!(config.seekTargetSec > 0.0) || config.seekTargetSec >= config.maxDurationSec) {
            throw FailClosed("invalid_seek_target")
        }
        if (config.preSeekHoldWindows <= 0 || config.preSeekHoldWindows > MAX_PRE_SEEK_HOLD_WINDOWS) {
            throw FailClosed("invalid_pre_seek_hold_windows")
        }
        if (cancelled.get()) throw FailClosed("cancelled")
        val deadlineAtMs = SystemClock.elapsedRealtime() + config.deadlineMs
        metrics["maxDurationSec"] = config.maxDurationSec
        metrics["maxFramesPerMix"] = config.maxFramesPerMix
        // Floats are not StandardMessageCodec values; publish as Double.
        metrics["baseVolume"] = config.baseVolume.toDouble()
        metrics["deadlineMs"] = config.deadlineMs
        metrics["seekTargetSec"] = config.seekTargetSec
        metrics["preSeekHoldWindows"] = config.preSeekHoldWindows
        metrics["coordinatorThreadId"] = Thread.currentThread().id

        val session = Session(config, deadlineAtMs)
        activeSession = session
        try {
            session.runPlaythrough()
        } finally {
            session.disposeTransportOnce()
            session.publishMetrics()
            activeSession = null
        }
        session.failure.get()?.let { throw FailClosed(it) }
    }

    private fun isCancelled(): Boolean = cancelled.get()

    // ── One pipeline session (feed + transport + sink) ─────────────────────

    private inner class Session(
        val config: Config,
        val deadlineAtMs: Long,
    ) {
        val failure = AtomicReference<String?>(null)
        val completedCount = AtomicInteger(0)
        val failedCount = AtomicInteger(0)
        val listenerOnOwner = AtomicLong(0L)
        val listenerOffOwner = AtomicLong(0L)
        private val transitions = StringBuilder()
        private val disposedOnce = AtomicBoolean(false)

        @Volatile
        var sm: VanguardRealtimePlaybackTransportStateMachine? = null

        @Volatile
        var feed: VanguardRealtimePlaybackPipelineSeekDecoderFeed? = null

        @Volatile
        var sink: VanguardRealtimePlaybackPipelineSeekSinkBridge? = null

        var format: VanguardRealtimePlaybackPipelineSeekDecoderFeed.Format? = null
        var commandsIssued = 0
        var prepareGeneration = -1L
        var startGeneration = -1L
        var pauseGeneration = -1L
        var seekStaleGeneration = -1L
        var seekGeneration = -1L
        var resumeGeneration = -1L
        var preRollFrames = 0L
        var preRollRingFull = false
        var preRollPartialWrite = false
        var preRollStatePrepared = false
        var startAcceptedPlaying = false
        var finalReply: Reply? = null
        var stateBeforeDispose = State.IDLE
        var stateAfterDispose = State.IDLE
        var stateAfterSecondDispose = State.IDLE
        var postIngestAfterDispose = true
        var feedJoined = false
        var sinkJoined = false
        var disposeCalls = 0
        var sessionWallMs = 0L

        // Seek admission.
        var seekTargetFrame = -1L
        var preSeekHoldFrame = -1L
        var seekAdmissionOk = false
        var holdPinned = false

        // Pre-seek / quiescence observations.
        var initialWriteWaitMs = -1L
        var framesWrittenBeforeHold = 0L
        var drainCallsBeforeHold = 0L
        var stateBeforeHold = State.IDLE
        var quiesceWaitMs = -1L
        var quiesceFeedHeld = false
        var quiesceSinkReadFrames = -1L
        var quiesceSinkWrittenFrames = -1L
        var parkRequested = false
        var parkAcked = false
        var parkAckWaitMs = -1L
        var preSeekSnapshot: Reply? = null
        var preSeekSnapshotState = State.IDLE
        var preSeekSnapshotSettleMs = -1L
        var quiesceAccountingOk = false

        // Pause / flush / seek observations.
        var pauseAccepted = false
        var pauseState = State.IDLE
        var pauseReason = ""
        var postPauseSnapshot: Reply? = null
        var flushRequested = false
        var flushAcked = false
        var flushAckWaitMs = -1L
        var seekAccepted = false
        var seekState = State.IDLE
        var seekReason = ""
        var postSeekSnapshot: Reply? = null
        var postSeekSnapshotState = State.IDLE
        var sinkPlayStateAtSeek = VanguardRealtimePlaybackPipelineSeekSinkBridge.PLAY_STATE_UNKNOWN
        var sinkPhaseAtSeek = ""
        var reanchorRequested = false
        var reanchorAcked = false
        var reanchorWaitMs = -1L
        var postSeekPreRollAcked = false
        var postSeekPreRollWaitMs = -1L
        var postSeekPreRollTransportState = State.IDLE
        var postSeekPreRollSnapshot: Reply? = null

        // Unpark / resume observations.
        var unparkRequested = false
        var unparkAcked = false
        var unparkAckWaitMs = -1L
        var framesWrittenAfterUnpark = 0L
        var drainCallsAfterUnpark = 0L
        var resumeAccepted = false
        var resumeState = State.IDLE
        var resumeReason = ""
        var framesWrittenAtResume = 0L
        var drainCallsAtResume = 0L

        private val listener = object : VanguardRealtimePlaybackTransportStateMachine.Listener {
            override fun onStateChanged(previous: State, current: State, generation: Long) {
                countListener()
                synchronized(transitions) {
                    if (transitions.isEmpty()) transitions.append(previous.name)
                    transitions.append('>').append(current.name)
                }
            }

            override fun onCompleted(generation: Long) {
                countListener()
                completedCount.incrementAndGet()
            }

            override fun onFailed(reason: String, generation: Long) {
                countListener()
                failedCount.incrementAndGet()
                recordFailure("transport:$reason")
            }

            private fun countListener() {
                val machine = sm
                if (machine != null && machine.isOwnerThread) listenerOnOwner.incrementAndGet() else listenerOffOwner.incrementAndGet()
            }
        }

        fun recordFailure(reason: String) {
            failure.compareAndSet(null, reason)
        }

        fun cancelThreads() {
            feed?.cancel()
            sink?.cancel()
        }

        // Exactly one coordinator-side dispose of the state machine; the
        // state machine itself is idempotent beyond that.
        fun disposeTransportOnce() {
            if (!disposedOnce.compareAndSet(false, true)) return
            val machine = sm ?: return
            stateBeforeDispose = machine.currentState
            machine.dispose()
            disposeCalls++
            stateAfterDispose = machine.currentState
        }

        private fun sessionCancelled(): Boolean = isCancelled()

        private fun checkDeadlineAndCancel() {
            if (sessionCancelled()) throw FailClosed("cancelled")
            if (SystemClock.elapsedRealtime() > deadlineAtMs) throw FailClosed("deadline_exceeded")
        }

        private fun remainingMs(): Long = maxOf(1L, deadlineAtMs - SystemClock.elapsedRealtime())

        private fun sleepSlice(ms: Long = WAIT_SLICE_MS) {
            try {
                Thread.sleep(ms)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                throw FailClosed("interrupted")
            }
        }

        private fun alignUp(frame: Long, window: Long): Long = ((frame + window - 1L) / window) * window

        // Feed open/probe -> transport load/prepare -> pre-roll -> seek
        // admission + hold pinned -> start -> sink start.
        private fun openAndStart() {
            checkDeadlineAndCancel()
            val f = VanguardRealtimePlaybackPipelineSeekDecoderFeed(
                VanguardRealtimePlaybackPipelineSeekDecoderFeed.Config(
                    sourcePath = config.sourcePath,
                    maxDurationSec = config.maxDurationSec,
                    maxFramesPerMix = config.maxFramesPerMix,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6cSeekDecoderFeed",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            feed = f
            if (!f.start()) throw FailClosed("feed_start_rejected")

            val fmt = f.awaitFormat(remainingMs()) ?: throw FailClosed("format_probe_failed:${f.exitReason}")
            format = fmt
            checkDeadlineAndCancel()

            val sessionConfig = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = fmt.sampleRate,
                channelCount = fmt.channelCount,
                maxFramesPerMix = config.maxFramesPerMix,
                trackCount = VanguardRealtimePlaybackPipelineSeekDecoderFeed.TRACK_COUNT,
                declaredFrameCount = fmt.declaredFrameCount,
                externalIngestTrackMask = VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXTERNAL_INGEST_TRACK_MASK,
            )
            VanguardRealtimePlaybackNativeSession.validate(sessionConfig)?.let {
                throw FailClosed("session_config_invalid:${it.name.lowercase()}")
            }
            val machine = VanguardRealtimePlaybackTransportStateMachine(
                sessionConfig, listener, threadName = "Y6cSeekTransport",
            )
            sm = machine
            if (sessionCancelled()) throw FailClosed("cancelled")

            val loadRes = machine.load()
            commandsIssued++
            if (!loadRes.accepted) throw FailClosed("load_rejected:${loadRes.reason}")
            val prepareRes = machine.prepare()
            commandsIssued++
            if (!prepareRes.accepted || prepareRes.state != State.PREPARED) {
                throw FailClosed("prepare_rejected:${prepareRes.reason}")
            }
            prepareGeneration = machine.currentGeneration
            f.attachTransport(machine, prepareGeneration)

            // Pre-roll while PREPARED until the source ring answers ring_full
            // (or the declared end fits entirely).
            while (!f.awaitPreRoll(WAIT_SLICE_MS)) {
                checkDeadlineAndCancel()
                failure.get()?.let { throw FailClosed(it) }
                if (!f.isAlive) throw FailClosed("feed_exited_during_preroll:${f.exitReason}")
            }
            preRollFrames = f.preRollFrames
            preRollRingFull = f.preRollRingFullObserved
            preRollPartialWrite = f.preRollPartialWriteObserved
            preRollStatePrepared = machine.currentState == State.PREPARED
            if (preRollFrames <= 0L) throw FailClosed("preroll_empty:${f.exitReason}")

            // Seek admission: the hold frame H is the first window-aligned
            // frame at least preSeekHoldWindows past the pre-roll; the feed
            // cannot move while PREPARED, so pinning H here is race-free.
            val window = config.maxFramesPerMix.toLong()
            val declared = fmt.declaredFrameCount
            seekTargetFrame = (config.seekTargetSec * fmt.sampleRate).toLong()
            preSeekHoldFrame = alignUp(preRollFrames + config.preSeekHoldWindows * window, window)
            seekAdmissionOk = preSeekHoldFrame % window == 0L &&
                preSeekHoldFrame > preRollFrames &&
                preSeekHoldFrame < seekTargetFrame &&
                seekTargetFrame < declared - 2L * window
            if (!seekAdmissionOk) {
                throw FailClosed("seek_admission:preroll=$preRollFrames:hold=$preSeekHoldFrame:target=$seekTargetFrame:declared=$declared")
            }
            holdPinned = f.setPreSeekHoldFrame(preSeekHoldFrame)
            if (!holdPinned) throw FailClosed("hold_pin_rejected:$preSeekHoldFrame")

            val startRes = machine.start()
            commandsIssued++
            startAcceptedPlaying = startRes.accepted && startRes.state == State.PLAYING
            if (!startAcceptedPlaying) throw FailClosed("start_rejected:${startRes.reason}")
            startGeneration = machine.currentGeneration
            f.updateGeneration(startGeneration)
            f.markTransportStarted()

            val s = VanguardRealtimePlaybackPipelineSeekSinkBridge(
                VanguardRealtimePlaybackPipelineSeekSinkBridge.Config(
                    stateMachine = machine,
                    sampleRate = fmt.sampleRate,
                    channelCount = fmt.channelCount,
                    maxFramesPerMix = config.maxFramesPerMix,
                    declaredFrameCount = fmt.declaredFrameCount,
                    baseVolume = config.baseVolume,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6cSeekSinkBridge",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            sink = s
            if (!s.start()) throw FailClosed("sink_start_rejected")
        }

        // Polls the failure sources once; returns the first failure if any.
        private fun pollFailure(): String? {
            failure.get()?.let { return it }
            val machine = sm
            if (machine != null && machine.currentState == State.FAILED) recordFailure("transport_failed")
            val f = feed
            if (f != null && !f.isAlive) {
                val reason = f.exitReason
                if (reason != VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXIT_EOS &&
                    reason != VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXIT_RUNNING &&
                    reason != VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXIT_CANCELLED
                ) {
                    recordFailure("decoder:$reason")
                }
            }
            val s = sink
            if (s != null && !s.isAlive && s.exitReason != VanguardRealtimePlaybackPipelineSeekSinkBridge.EXIT_RUNNING &&
                s.exitReason != VanguardRealtimePlaybackPipelineSeekSinkBridge.EXIT_EOS &&
                s.exitReason != VanguardRealtimePlaybackPipelineSeekSinkBridge.EXIT_NOT_STARTED
            ) {
                recordFailure("sink:${s.exitReason}")
            }
            if (sessionCancelled()) recordFailure("cancelled")
            if (SystemClock.elapsedRealtime() > deadlineAtMs) recordFailure("deadline_exceeded")
            return failure.get()
        }

        private fun joinBoth() {
            val f = feed
            val s = sink
            feedJoined = f?.join(JOIN_TIMEOUT_MS) ?: true
            sinkJoined = s?.join(JOIN_TIMEOUT_MS) ?: true
        }

        private fun snapshotReply(phase: String, machine: VanguardRealtimePlaybackTransportStateMachine): Reply {
            val res = machine.snapshot()
            if (!res.accepted) throw FailClosed("snapshot_rejected_$phase:${res.reason}")
            return res.reply ?: throw FailClosed("snapshot_null_reply_$phase")
        }

        // ── Pre-seek: initial writes, quiescence, park ──────────────────────

        // Waits for the first positive AudioTrack write so the seek lands
        // on a really playing sink.
        private fun awaitInitialWrites(
            s: VanguardRealtimePlaybackPipelineSeekSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            val waitStart = SystemClock.elapsedRealtime()
            val waitDeadline = waitStart + INITIAL_WRITE_WAIT_MS
            while (s.framesWrittenToSink <= 0L || !s.played) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_first_write:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > waitDeadline) throw FailClosed("no_initial_sink_write")
                sleepSlice()
            }
            initialWriteWaitMs = SystemClock.elapsedRealtime() - waitStart
            framesWrittenBeforeHold = s.framesWrittenToSink
            drainCallsBeforeHold = s.drainCalls
            stateBeforeHold = machine.currentState
            lanes[LANE_INITIAL_DRAIN] = framesWrittenBeforeHold > 0L && drainCallsBeforeHold > 0L && s.played &&
                stateBeforeHold == State.PLAYING
            if (stateBeforeHold != State.PLAYING) throw FailClosed("seek_precondition_state:${stateBeforeHold.name.lowercase()}")
        }

        // Waits until the feed holds at H and the sink has read (and hence
        // written, see park ordering) every one of the H frames.
        private fun awaitQuiescence(
            f: VanguardRealtimePlaybackPipelineSeekDecoderFeed,
            s: VanguardRealtimePlaybackPipelineSeekSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            val waitStart = SystemClock.elapsedRealtime()
            val waitDeadline = waitStart + QUIESCE_WAIT_MS
            while (!(f.heldAtHoldFrame && f.anchorFrame == preSeekHoldFrame && s.framesReadFromTransport == preSeekHoldFrame)) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_quiesce:${s.exitReason}")
                if (!f.isAlive) throw FailClosed("feed_exited_before_quiesce:${f.exitReason}")
                if (s.framesReadFromTransport > preSeekHoldFrame) {
                    throw FailClosed("sink_read_past_hold:${s.framesReadFromTransport}:$preSeekHoldFrame")
                }
                if (machine.currentState != State.PLAYING) throw FailClosed("quiesce_state:${machine.currentState.name.lowercase()}")
                if (SystemClock.elapsedRealtime() > waitDeadline) {
                    throw FailClosed("quiesce_timeout:anchor=${f.anchorFrame}:held=${f.heldAtHoldFrame}:read=${s.framesReadFromTransport}:hold=$preSeekHoldFrame")
                }
                sleepSlice()
            }
            quiesceWaitMs = SystemClock.elapsedRealtime() - waitStart
            quiesceFeedHeld = f.heldAtHoldFrame
            quiesceSinkReadFrames = s.framesReadFromTransport
        }

        private fun parkSink(s: VanguardRealtimePlaybackPipelineSeekSinkBridge) {
            val parkAt = SystemClock.elapsedRealtime()
            parkRequested = s.requestPark()
            if (!parkRequested) throw FailClosed("sink_park_request_rejected:${s.phase.name.lowercase()}")
            val ackDeadline = parkAt + PARK_ACK_TIMEOUT_MS
            while (!s.awaitParked(WAIT_SLICE_MS)) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_park_ack:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_park_ack_timeout:${s.phase.name.lowercase()}")
            }
            parkAckWaitMs = SystemClock.elapsedRealtime() - parkAt
            parkAcked = s.phase == VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.PARKED && s.parkCount == 1
            if (!parkAcked) throw FailClosed("sink_park_not_acked:${s.phase.name.lowercase()}")
            if (s.playStateAtPark != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("sink_not_paused_at_park:${s.playStateAtPark}")
            quiesceSinkWrittenFrames = s.framesWrittenToSink
        }

        // Pre-seek native snapshot: window-aligned, positionFrame == pushed
        // == drained == H (the feed anchor), discarded == 0, PLAYING. The
        // sink is parked, so nothing can move once the worker published the
        // last render; a short settle wait covers that publication.
        private fun verifyPreSeekQuiescence(
            f: VanguardRealtimePlaybackPipelineSeekDecoderFeed,
            s: VanguardRealtimePlaybackPipelineSeekSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            val window = config.maxFramesPerMix.toLong()
            val settleStart = SystemClock.elapsedRealtime()
            val settleDeadline = settleStart + SNAPSHOT_SETTLE_WAIT_MS
            var snap: Reply
            while (true) {
                pollFailure()?.let { throw FailClosed(it) }
                snap = snapshotReply("pre_seek", machine)
                val settled = snap.pushedFrames == preSeekHoldFrame && snap.drainedFrames == preSeekHoldFrame &&
                    snap.positionFrame == preSeekHoldFrame
                if (settled || SystemClock.elapsedRealtime() > settleDeadline) break
                sleepSlice()
            }
            preSeekSnapshotSettleMs = SystemClock.elapsedRealtime() - settleStart
            preSeekSnapshot = snap
            preSeekSnapshotState = machine.currentState
            quiesceAccountingOk = preSeekHoldFrame % window == 0L &&
                f.anchorFrame == preSeekHoldFrame && f.heldAtHoldFrame && f.acceptedFrames == preSeekHoldFrame &&
                snap.state == NativeState.PLAYING && preSeekSnapshotState == State.PLAYING &&
                snap.positionFrame == preSeekHoldFrame &&
                snap.pushedFrames == preSeekHoldFrame && snap.drainedFrames == preSeekHoldFrame &&
                snap.discardedFrames == 0L && snap.outputAvailableReadFrames == 0L &&
                !snap.eosPushed && !snap.eosDrained &&
                s.framesReadFromTransport == preSeekHoldFrame && s.framesWrittenToSink == preSeekHoldFrame &&
                s.framesWrittenAtPark == preSeekHoldFrame && s.phase == VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.PARKED
            lanes[LANE_SEEK_QUIESCE_ACCOUNTING] = quiesceAccountingOk
            if (!quiesceAccountingOk) {
                throw FailClosed(
                    "seek_quiesce_accounting:hold=$preSeekHoldFrame:anchor=${f.anchorFrame}:pos=${snap.positionFrame}:" +
                        "pushed=${snap.pushedFrames}:drained=${snap.drainedFrames}:discarded=${snap.discardedFrames}:" +
                        "read=${s.framesReadFromTransport}:written=${s.framesWrittenToSink}:native=${snap.stateToken}",
                )
            }
        }

        // ── Pause, flush, seek ──────────────────────────────────────────────

        private fun pauseTransport(machine: VanguardRealtimePlaybackTransportStateMachine) {
            val res = machine.pause()
            commandsIssued++
            pauseAccepted = res.accepted
            pauseState = res.state
            pauseReason = res.reason
            pauseGeneration = machine.currentGeneration
            lanes[LANE_PAUSE_COMMAND] = pauseAccepted && pauseState == State.PAUSED &&
                machine.currentState == State.PAUSED && pauseGeneration == startGeneration
            if (!pauseAccepted || pauseState != State.PAUSED) throw FailClosed("pause_rejected:${res.reason}")
            val snap = snapshotReply("post_pause", machine)
            postPauseSnapshot = snap
            if (snap.state != NativeState.PAUSED || snap.pushedFrames != preSeekHoldFrame ||
                snap.drainedFrames != preSeekHoldFrame || snap.discardedFrames != 0L
            ) {
                throw FailClosed("post_pause_accounting:${snap.stateToken}:${snap.pushedFrames}:${snap.drainedFrames}:${snap.discardedFrames}")
            }
        }

        // AudioTrack.flush() exactly once on the sink thread while both the
        // sink (PARKED, PAUSED) and the transport (PAUSED) are paused. Opens
        // the post-seek accounting epoch of declared - target frames.
        private fun flushSink(s: VanguardRealtimePlaybackPipelineSeekSinkBridge, machine: VanguardRealtimePlaybackTransportStateMachine) {
            val declared = format?.declaredFrameCount ?: throw FailClosed("format_missing")
            if (machine.currentState != State.PAUSED) throw FailClosed("flush_before_transport_pause:${machine.currentState.name.lowercase()}")
            if (s.phase != VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.PARKED) throw FailClosed("flush_before_sink_park:${s.phase.name.lowercase()}")
            val flushAt = SystemClock.elapsedRealtime()
            flushRequested = s.requestFlush(declared - seekTargetFrame)
            if (!flushRequested) throw FailClosed("sink_flush_request_rejected:${s.phase.name.lowercase()}:${s.flushRequestCount}")
            val ackDeadline = flushAt + FLUSH_ACK_TIMEOUT_MS
            while (!s.awaitFlushed(WAIT_SLICE_MS)) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_flush_ack:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_flush_ack_timeout:${s.flushCount}")
            }
            flushAckWaitMs = SystemClock.elapsedRealtime() - flushAt
            flushAcked = s.flushCount == 1
            lanes[LANE_SINK_FLUSH_AT_SEEK] = flushAcked && s.flushRequestCount == 1 && s.flushExecutedOnSinkThread &&
                s.playStateBeforeFlush == AudioTrack.PLAYSTATE_PAUSED && s.playStateAfterFlush == AudioTrack.PLAYSTATE_PAUSED &&
                s.framesWrittenAtFlush == preSeekHoldFrame && s.framesReadAtFlush == preSeekHoldFrame &&
                s.postSeekExpectedFrames == declared - seekTargetFrame &&
                s.readBudgetFrames == preSeekHoldFrame + (declared - seekTargetFrame) &&
                s.phase == VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.PARKED &&
                machine.currentState == State.PAUSED
            if (!flushAcked) throw FailClosed("sink_flush_not_acked:${s.flushCount}")
            if (s.playStateAfterFlush != AudioTrack.PLAYSTATE_PAUSED) throw FailClosed("sink_not_paused_after_flush:${s.playStateAfterFlush}")
        }

        // transport.seek(target) while PAUSED into a provably empty output
        // ring: state stays PAUSED, generation advances by exactly one, the
        // native cursor moves to the target with nothing discarded.
        private fun seekTransport(s: VanguardRealtimePlaybackPipelineSeekSinkBridge, machine: VanguardRealtimePlaybackTransportStateMachine) {
            if (machine.currentState != State.PAUSED) throw FailClosed("seek_before_pause:${machine.currentState.name.lowercase()}")
            if (s.flushCount != 1) throw FailClosed("seek_before_flush:${s.flushCount}")
            sinkPlayStateAtSeek = s.observedPlayState
            sinkPhaseAtSeek = s.phase.name
            seekStaleGeneration = machine.currentGeneration
            val res = machine.seek(seekTargetFrame)
            commandsIssued++
            seekAccepted = res.accepted
            seekState = res.state
            seekReason = res.reason
            seekGeneration = machine.currentGeneration
            if (!seekAccepted || seekState != State.PAUSED) throw FailClosed("seek_rejected:${res.reason}:${res.state.name.lowercase()}")
            val snap = snapshotReply("post_seek", machine)
            postSeekSnapshot = snap
            postSeekSnapshotState = machine.currentState
            lanes[LANE_SEEK_COMMAND] = seekAccepted && seekState == State.PAUSED && postSeekSnapshotState == State.PAUSED &&
                seekGeneration == seekStaleGeneration + 1L && seekStaleGeneration == startGeneration &&
                snap.state == NativeState.PAUSED && snap.positionFrame == seekTargetFrame &&
                snap.pushedFrames == preSeekHoldFrame && snap.drainedFrames == preSeekHoldFrame &&
                snap.discardedFrames == 0L && !snap.eosPushed && !snap.eosDrained &&
                sinkPhaseAtSeek == VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.PARKED.name &&
                sinkPlayStateAtSeek == AudioTrack.PLAYSTATE_PAUSED
            if (lanes[LANE_SEEK_COMMAND] != true) {
                throw FailClosed(
                    "seek_command:state=${seekState.name.lowercase()}:gen=$seekStaleGeneration>$seekGeneration:" +
                        "pos=${snap.positionFrame}:pushed=${snap.pushedFrames}:drained=${snap.drainedFrames}:discarded=${snap.discardedFrames}",
                )
            }
        }

        // Feed re-anchor on the decode thread (pinned to the post-seek
        // generation) including the deliberate stale pre-seek probe, then
        // the post-seek pre-roll of at least one window while PAUSED.
        private fun reanchorFeed(
            f: VanguardRealtimePlaybackPipelineSeekDecoderFeed,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            val reanchorAt = SystemClock.elapsedRealtime()
            reanchorRequested = f.requestSeekReanchor(
                VanguardRealtimePlaybackPipelineSeekDecoderFeed.SeekRequest(
                    targetFrame = seekTargetFrame,
                    preSeekAnchorFrame = preSeekHoldFrame,
                    newGeneration = seekGeneration,
                    staleGeneration = seekStaleGeneration,
                ),
            )
            if (!reanchorRequested) throw FailClosed("feed_reanchor_request_rejected")
            val reanchorDeadline = reanchorAt + REANCHOR_WAIT_MS
            while (!f.awaitReanchor(WAIT_SLICE_MS)) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!f.isAlive) throw FailClosed("feed_exited_before_reanchor:${f.exitReason}")
                if (SystemClock.elapsedRealtime() > reanchorDeadline) throw FailClosed("feed_reanchor_timeout")
            }
            reanchorWaitMs = SystemClock.elapsedRealtime() - reanchorAt
            reanchorAcked = f.reanchorOk && f.seekReanchorCount == 1
            if (!reanchorAcked) throw FailClosed("feed_reanchor_failed:${f.exitReason}")
            if (machine.currentState != State.PAUSED) throw FailClosed("reanchor_state_moved:${machine.currentState.name.lowercase()}")

            val prerollAt = SystemClock.elapsedRealtime()
            val prerollDeadline = prerollAt + POST_SEEK_PREROLL_WAIT_MS
            while (!f.awaitPostSeekPreRoll(WAIT_SLICE_MS)) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!f.isAlive) throw FailClosed("feed_exited_before_post_seek_preroll:${f.exitReason}")
                if (SystemClock.elapsedRealtime() > prerollDeadline) throw FailClosed("post_seek_preroll_timeout:${f.postSeekAcceptedFrames}")
            }
            postSeekPreRollWaitMs = SystemClock.elapsedRealtime() - prerollAt
            postSeekPreRollTransportState = machine.currentState
            postSeekPreRollAcked = f.postSeekPreRollFrames >= config.maxFramesPerMix && f.postSeekPreRollStatePaused &&
                postSeekPreRollTransportState == State.PAUSED
            if (!postSeekPreRollAcked) {
                throw FailClosed("post_seek_preroll_short:${f.postSeekPreRollFrames}:${postSeekPreRollTransportState.name.lowercase()}")
            }
            // Still PAUSED: the worker rendered nothing since the seek.
            val snap = snapshotReply("post_seek_preroll", machine)
            postSeekPreRollSnapshot = snap
            if (snap.state != NativeState.PAUSED || snap.pushedFrames != preSeekHoldFrame || snap.positionFrame != seekTargetFrame) {
                throw FailClosed("post_seek_preroll_accounting:${snap.stateToken}:${snap.pushedFrames}:${snap.positionFrame}")
            }
        }

        // ── Unpark, resume ──────────────────────────────────────────────────

        // Runs while the transport is still PAUSED: the sink thread calls
        // AudioTrack.play (post-flush), captures the epoch head base,
        // confirms PLAYSTATE_PLAYING and publishes RUNNING before this
        // returns.
        private fun unparkSink(s: VanguardRealtimePlaybackPipelineSeekSinkBridge) {
            val unparkAt = SystemClock.elapsedRealtime()
            unparkRequested = s.unpark()
            if (!unparkRequested) throw FailClosed("sink_unpark_request_rejected:${s.phase.name.lowercase()}")
            val ackDeadline = unparkAt + UNPARK_ACK_TIMEOUT_MS
            while (!s.awaitRunning(WAIT_SLICE_MS)) {
                pollFailure()?.let { throw FailClosed(it) }
                if (!s.isAlive) throw FailClosed("sink_exited_before_unpark_ack:${s.exitReason}")
                if (SystemClock.elapsedRealtime() > ackDeadline) throw FailClosed("sink_unpark_ack_timeout:${s.phase.name.lowercase()}")
            }
            unparkAckWaitMs = SystemClock.elapsedRealtime() - unparkAt
            unparkAcked = s.phase == VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.RUNNING && s.unparkCount == 1
            framesWrittenAfterUnpark = s.framesWrittenToSink
            drainCallsAfterUnpark = s.drainCalls
            lanes[LANE_SINK_RESUMED] = unparkAcked && s.unparkExecutedOnSinkThread &&
                s.playStateAfterUnpark == AudioTrack.PLAYSTATE_PLAYING && s.parkedHoldMs >= 0L &&
                s.flushCount == 1 && s.epochBaseCaptured && s.playbackHeadEpochBase >= 0L
            if (!unparkAcked) throw FailClosed("sink_unpark_not_acked:${s.phase.name.lowercase()}")
            if (s.playStateAfterUnpark != AudioTrack.PLAYSTATE_PLAYING) {
                throw FailClosed("sink_not_playing_after_unpark:${s.playStateAfterUnpark}")
            }
        }

        // Issued only after [unparkSink] confirmed the sink RUNNING with the
        // AudioTrack PLAYSTATE_PLAYING. The generation must stay at the
        // post-seek value.
        private fun resumeTransport(
            s: VanguardRealtimePlaybackPipelineSeekSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
        ) {
            if (s.phase != VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.RUNNING || !unparkAcked) {
                throw FailClosed("resume_before_sink_unpark:${s.phase.name.lowercase()}")
            }
            val res = machine.resume()
            commandsIssued++
            resumeAccepted = res.accepted
            resumeState = res.state
            resumeReason = res.reason
            resumeGeneration = machine.currentGeneration
            framesWrittenAtResume = s.framesWrittenToSink
            drainCallsAtResume = s.drainCalls
            if (!resumeAccepted || resumeState != State.PLAYING) throw FailClosed("resume_rejected:${res.reason}")
            if (resumeGeneration != seekGeneration) throw FailClosed("resume_generation_moved:$seekGeneration:$resumeGeneration")
        }

        // ── Playthrough ────────────────────────────────────────────────────

        fun runPlaythrough() {
            val wallStart = SystemClock.elapsedRealtime()
            try {
                openAndStart()
                val f = feed ?: throw FailClosed("feed_missing")
                val s = sink ?: throw FailClosed("sink_missing")
                val machine = sm ?: throw FailClosed("transport_missing")

                // Fixed order: initial writes -> quiescence at H -> park ->
                // pre-seek snapshot -> pause -> flush -> seek -> feed
                // re-anchor + stale probe + post-seek pre-roll -> unpark ->
                // resume -> drain to EOS.
                awaitInitialWrites(s, machine)
                awaitQuiescence(f, s, machine)
                parkSink(s)
                verifyPreSeekQuiescence(f, s, machine)
                pauseTransport(machine)
                flushSink(s, machine)
                seekTransport(s, machine)
                reanchorFeed(f, machine)
                unparkSink(s)
                resumeTransport(s, machine)

                // Wait for the sink to exit (EOS) or the first failure.
                while (!s.awaitExit(WAIT_SLICE_MS)) {
                    val first = pollFailure()
                    if (first != null) {
                        cancelThreads()
                        break
                    }
                }
                if (failure.get() == null && s.exitReason != VanguardRealtimePlaybackPipelineSeekSinkBridge.EXIT_EOS) {
                    recordFailure("sink:${s.exitReason}")
                }
                if (failure.get() == null && !f.awaitExit(JOIN_TIMEOUT_MS)) {
                    recordFailure("decoder_did_not_exit")
                }
                if (failure.get() == null && f.exitReason != VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXIT_EOS) {
                    recordFailure("decoder:${f.exitReason}")
                }
                if (failure.get() != null) cancelThreads()
                joinBoth()

                val snapRes = machine.snapshot()
                finalReply = snapRes.reply ?: s.lastReply
                val final = finalReply
                if (failure.get() == null && (!snapRes.accepted || final == null)) {
                    recordFailure("final_snapshot_rejected:${snapRes.reason}")
                }

                // Lifecycle: explicit dispose, later postIngest rejected
                // (never posted), second dispose is a no-op.
                val stateAtCompletion = machine.currentState
                disposeTransportOnce()
                val probe = ByteBuffer.allocateDirect(config.maxFramesPerMix * 2 * (format?.channelCount ?: 2))
                    .order(ByteOrder.nativeOrder())
                postIngestAfterDispose = machine.postIngest(
                    IngestRequest(VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXTERNAL_TRACK_INDEX, probe, config.maxFramesPerMix, f.anchorFrame),
                    expectedGeneration = seekGeneration,
                )
                machine.dispose()
                stateAfterSecondDispose = machine.currentState

                if (failure.get() == null && final != null) evaluatePlaythrough(f, s, machine, final, stateAtCompletion)
            } finally {
                cancelThreads()
                joinBoth()
                sessionWallMs = SystemClock.elapsedRealtime() - wallStart
            }
        }

        private fun evaluatePlaythrough(
            f: VanguardRealtimePlaybackPipelineSeekDecoderFeed,
            s: VanguardRealtimePlaybackPipelineSeekSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            final: Reply,
            stateAtCompletion: State,
        ) {
            val fmt = format ?: return
            val declared = fmt.declaredFrameCount
            val window = config.maxFramesPerMix.toLong()
            val coordinatorThreadId = Thread.currentThread().id
            val decoderHex = f.checksumHex
            val sinkHex = s.checksumHex
            val postSeekExpected = declared - seekTargetFrame
            val expectedTotal = preSeekHoldFrame + postSeekExpected

            val transportCompleted = stateAtCompletion == State.COMPLETED &&
                final.state == NativeState.COMPLETED && completedCount.get() == 1 && failedCount.get() == 0 &&
                final.positionFrame == declared && final.eosPushed && final.eosDrained

            lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
            lanes[LANE_PRE_ROLL] = preRollFrames > 0L && (preRollRingFull || preRollFrames == declared) &&
                preRollStatePrepared && startAcceptedPlaying && preRollFrames <= declared &&
                seekAdmissionOk && holdPinned && preRollFrames < preSeekHoldFrame
            lanes[LANE_SINK_PAUSED] = s.playStateAtPark == AudioTrack.PLAYSTATE_PAUSED &&
                s.parkedPlayStateViolations == 0L && s.parkedPlayStateObservations > 0L &&
                s.playStateBeforeFlush == AudioTrack.PLAYSTATE_PAUSED && s.playStateAfterFlush == AudioTrack.PLAYSTATE_PAUSED &&
                sinkPlayStateAtSeek == AudioTrack.PLAYSTATE_PAUSED && sinkPhaseAtSeek == VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.PARKED.name &&
                parkAcked && s.parkExecutedOnSinkThread && s.parkCount == 1
            // Y5b gap policy: every observed gap frame was padded, the total
            // stays inside the bound, and a padded gap ends exactly at the
            // decoder-reported first post-seek frame.
            val gapPolicyOk = f.gapPaddedFrames == f.gapObservedFrames &&
                f.gapPaddedFrames <= f.maxSeekGapFrames &&
                (f.gapPaddedFrames == 0L || f.firstPostSeekFrame == seekTargetFrame + f.gapPaddedFrames)
            lanes[LANE_REAL_DECODER_SEEK_REANCHOR] = reanchorAcked && f.reanchorOk && f.seekReanchorCount == 1 &&
                f.reanchorExecutedOnDecodeThread && f.reanchorTransportStatePaused &&
                f.seekTargetFrame == seekTargetFrame && f.seekLandedUs >= 0L && f.seekLandedUs <= f.seekTargetUs &&
                f.preSeekAcceptedFrames == preSeekHoldFrame && f.codecChunks > f.codecChunksAtSeek &&
                f.postSeekAcceptedFrames == postSeekExpected && f.postSeekDecodedAcceptedFrames > 0L &&
                f.anchorFrame == declared && f.acceptedFrames == expectedTotal && gapPolicyOk &&
                f.paddedFrames <= (VanguardRealtimePlaybackPipelineSeekDecoderFeed.MAX_EOS_DRIFT_SEC * fmt.sampleRate).toLong() &&
                f.exitReason == VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXIT_EOS && transportCompleted
            lanes[LANE_STALE_GENERATION_REJECTED] = f.staleProbeCalls == 1 && f.staleProbeRejected &&
                f.staleProbeReplyNull && f.staleProbeAnchorUntouched &&
                f.staleProbeReason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION &&
                postSeekPreRollAcked && f.postSeekPreRollFrames >= window && transportCompleted
            lanes[LANE_POST_SEEK_DRAIN] = s.exitReason == VanguardRealtimePlaybackPipelineSeekSinkBridge.EXIT_EOS &&
                s.eosDrainedObserved && resumeAccepted &&
                framesWrittenAtResume >= framesWrittenAfterUnpark && drainCallsAtResume >= drainCallsAfterUnpark &&
                s.framesWrittenToSink > framesWrittenAtResume && s.drainCalls > drainCallsAtResume &&
                f.exitReason == VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXIT_EOS &&
                s.parkCount == 1 && s.unparkCount == 1 && s.flushCount == 1 &&
                s.phase == VanguardRealtimePlaybackPipelineSeekSinkBridge.Phase.RUNNING
            lanes[LANE_SINK_WRITE_ACCOUNTING] = s.exitReason == VanguardRealtimePlaybackPipelineSeekSinkBridge.EXIT_EOS &&
                s.framesReadFromTransport == expectedTotal && s.framesWrittenToSink == expectedTotal &&
                s.framesWrittenAtFlush == preSeekHoldFrame && s.framesReadAtFlush == preSeekHoldFrame &&
                s.postSeekFramesWritten == postSeekExpected && s.readBudgetFrames == expectedTotal &&
                final.pushedFrames == expectedTotal && final.drainedFrames == expectedTotal && final.discardedFrames == 0L
            lanes[LANE_CHECKSUM_IDENTITY] = decoderHex.isNotBlank() &&
                decoderHex.equals(final.pushedChecksumHex, ignoreCase = true) &&
                decoderHex.equals(final.drainedChecksumHex, ignoreCase = true) &&
                decoderHex.equals(sinkHex, ignoreCase = true)
            lanes[LANE_POST_SEEK_PLAYBACK_HEAD_ADVANCED] = s.played && s.flushCount == 1 && s.epochBaseCaptured &&
                s.postSeekPlaybackHeadFrames > 0L && s.postSeekPlaybackHeadFrames <= s.postSeekFramesWritten
            lanes[LANE_TRANSPORT_COMPLETED] = transportCompleted && final.lastError == "none"
            lanes[LANE_THREAD_OWNERSHIP] = f.ingestCallbacksOnOwner.get() > 0L && f.ingestCallbacksOffOwner.get() == 0L &&
                !f.threadIsTransportOwner && !s.threadIsTransportOwner &&
                f.threadId > 0L && s.threadId > 0L && f.threadId != s.threadId &&
                f.threadId != coordinatorThreadId && s.threadId != coordinatorThreadId &&
                s.parkExecutedOnSinkThread && s.flushExecutedOnSinkThread && s.unparkExecutedOnSinkThread &&
                f.reanchorExecutedOnDecodeThread &&
                listenerOnOwner.get() > 0L && listenerOffOwner.get() == 0L &&
                commandsIssued == COMMANDS_PER_SESSION && startGeneration == prepareGeneration + 1L &&
                pauseGeneration == startGeneration && seekStaleGeneration == startGeneration &&
                seekGeneration == startGeneration + 1L && resumeGeneration == seekGeneration &&
                machine.currentGeneration == seekGeneration && final.wrongOwnerThread.not()
            lanes[LANE_LIFECYCLE_DISPOSE] = feedJoined && sinkJoined &&
                f.mediaReleaseCount.get() == 1L && f.mediaReleaseClean &&
                s.releaseCount.get() == 1 && disposeCalls == 1 &&
                stateAfterDispose == State.DISPOSED && stateAfterSecondDispose == State.DISPOSED &&
                !postIngestAfterDispose && machine.currentState == State.DISPOSED
        }

        // ── Metrics ────────────────────────────────────────────────────────

        fun publishMetrics() {
            val fmt = format
            val f = feed
            val s = sink
            val machine = sm
            val final = finalReply
            val pre = preSeekSnapshot
            val post = postSeekSnapshot
            val postPause = postPauseSnapshot
            val postPreroll = postSeekPreRollSnapshot
            metrics["sourceMime"] = fmt?.sourceMime ?: ""
            metrics["sourceTrackIndex"] = fmt?.sourceTrackIndex ?: -1
            metrics["sourceDurationUs"] = fmt?.sourceDurationUs ?: -1L
            metrics["declaredWindowUs"] = fmt?.declaredWindowUs ?: -1L
            metrics["sampleRate"] = fmt?.sampleRate ?: 0
            metrics["channelCount"] = fmt?.channelCount ?: 0
            metrics["pcmEncoding"] = fmt?.pcmEncoding ?: 0
            metrics["declaredFrameCount"] = fmt?.declaredFrameCount ?: 0L
            metrics["preRollFrames"] = preRollFrames
            metrics["preRollRingFullObserved"] = preRollRingFull
            metrics["preRollPartialWriteObserved"] = preRollPartialWrite
            metrics["preRollStatePrepared"] = preRollStatePrepared
            metrics["ingestRingFullCount"] = f?.ingestRingFullCount ?: 0L
            metrics["ingestPartialWriteCount"] = f?.ingestPartialWriteCount ?: 0L
            metrics["ingestCalls"] = f?.ingestCalls ?: 0L
            metrics["staleGenerationRetries"] = f?.staleGenerationRetries ?: 0L
            metrics["transientRejects"] = f?.transientRejects ?: 0L
            metrics["nativeBackpressureCount"] = final?.backpressureCount ?: -1L
            metrics["nativeUnderrunCount"] = final?.underrunCount ?: -1L
            metrics["nativeDispatchCount"] = final?.dispatchCount ?: -1L
            metrics["eosPaddedFrames"] = f?.paddedFrames ?: 0L
            metrics["eosTruncatedFrames"] = f?.truncatedFrames ?: 0L
            metrics["decoderDiscardedFrames"] = f?.discardedFrames ?: 0L
            metrics["decoderAcceptedFrames"] = f?.acceptedFrames ?: 0L
            metrics["decoderAnchorFrame"] = f?.anchorFrame ?: -1L
            metrics["codecChunks"] = f?.codecChunks ?: 0L
            metrics["decodedFramesTotal"] = f?.decodedFramesTotal ?: 0L
            metrics["framesReadFromTransport"] = s?.framesReadFromTransport ?: 0L
            metrics["framesWrittenToSink"] = s?.framesWrittenToSink ?: 0L
            metrics["partialWriteCount"] = s?.partialWriteCount ?: 0L
            metrics["zeroWriteCount"] = s?.zeroWriteCount ?: 0L
            metrics["drainCalls"] = s?.drainCalls ?: 0L
            metrics["emptyDrainCount"] = s?.emptyDrainCount ?: 0L
            metrics["playbackHeadFinal"] = s?.playbackHeadFinal ?: 0L
            metrics["playbackHeadCaughtUp"] = s?.playbackHeadCaughtUp ?: false
            metrics["audioTrackInitOk"] = s?.audioTrackInitOk ?: false
            metrics["gainSetOk"] = s?.gainSetOk ?: false
            metrics["gainValue"] = (s?.gainValue ?: 0f).toDouble()
            metrics["audioTrackBufferBytes"] = s?.audioTrackBufferBytes ?: 0
            metrics["decodeThreadWallMs"] = f?.decodeThreadWallMs ?: 0L
            metrics["sinkThreadWallMs"] = s?.sinkThreadWallMs ?: 0L
            metrics["sessionWallMs"] = sessionWallMs
            metrics["kotlinDecoderChecksumHex"] = f?.checksumHex ?: ""
            metrics["kotlinSinkChecksumHex"] = s?.checksumHex ?: ""
            metrics["nativePushedChecksumHex"] = final?.pushedChecksumHex ?: ""
            metrics["nativeDrainedChecksumHex"] = final?.drainedChecksumHex ?: ""
            metrics["mediaReleaseCount"] = f?.mediaReleaseCount?.get() ?: 0L
            metrics["mediaReleaseClean"] = f?.mediaReleaseClean ?: false
            metrics["mediaReopens"] = f?.mediaReopens ?: 0
            metrics["audioTrackReleaseCount"] = s?.releaseCount?.get() ?: 0
            metrics["transportDisposeCalls"] = disposeCalls
            metrics["decoderThreadJoined"] = feedJoined
            metrics["sinkThreadJoined"] = sinkJoined
            metrics["decoderExitReason"] = f?.exitReason ?: VanguardRealtimePlaybackPipelineSeekDecoderFeed.EXIT_NOT_STARTED
            metrics["sinkExitReason"] = s?.exitReason ?: VanguardRealtimePlaybackPipelineSeekSinkBridge.EXIT_NOT_STARTED
            metrics["decoderThreadId"] = f?.threadId ?: -1L
            metrics["sinkThreadId"] = s?.threadId ?: -1L
            metrics["ingestCallbacksOnOwner"] = f?.ingestCallbacksOnOwner?.get() ?: 0L
            metrics["ingestCallbacksOffOwner"] = f?.ingestCallbacksOffOwner?.get() ?: 0L
            metrics["listenerCallbacksOnOwner"] = listenerOnOwner.get()
            metrics["listenerCallbacksOffOwner"] = listenerOffOwner.get()
            metrics["transportCommandsIssued"] = commandsIssued
            metrics["transportPrepareGeneration"] = prepareGeneration
            metrics["transportStartGeneration"] = startGeneration
            metrics["transportPauseGeneration"] = pauseGeneration
            metrics["transportSeekStaleGeneration"] = seekStaleGeneration
            metrics["transportSeekGeneration"] = seekGeneration
            metrics["transportResumeGeneration"] = resumeGeneration
            metrics["transportGenerationFinal"] = machine?.currentGeneration ?: -1L
            metrics["transportStateBeforeDispose"] = stateBeforeDispose.name
            metrics["transportStateFinal"] = machine?.currentState?.name ?: "none"
            metrics["transportStateTransitions"] = synchronized(transitions) { transitions.toString() }
            metrics["transportCompletedCallbacks"] = completedCount.get()
            metrics["transportFailedCallbacks"] = failedCount.get()
            metrics["postIngestAfterDisposePosted"] = postIngestAfterDispose
            metrics["nativeStateFinal"] = final?.stateToken ?: "none"
            metrics["nativeWorkerExited"] = final?.workerExited ?: false
            metrics["nativeWorkerJoined"] = final?.workerJoined ?: false
            metrics["positionFrame"] = final?.positionFrame ?: -1L
            metrics["pushedFrames"] = final?.pushedFrames ?: -1L
            metrics["drainedFrames"] = final?.drainedFrames ?: -1L
            metrics["discardedFrames"] = final?.discardedFrames ?: -1L
            metrics["eosPushed"] = final?.eosPushed ?: false
            metrics["eosDrained"] = final?.eosDrained ?: false
            metrics["lastError"] = final?.lastError ?: "none"
            // Seek admission / quiescence.
            metrics["seekTargetFrame"] = seekTargetFrame
            metrics["preSeekHoldFrame"] = preSeekHoldFrame
            metrics["seekAdmissionOk"] = seekAdmissionOk
            metrics["holdPinned"] = holdPinned
            metrics["expectedTotalSinkFrames"] = if (preSeekHoldFrame >= 0L && seekTargetFrame >= 0L && fmt != null) {
                preSeekHoldFrame + (fmt.declaredFrameCount - seekTargetFrame)
            } else {
                -1L
            }
            metrics["initialWriteWaitMs"] = initialWriteWaitMs
            metrics["framesWrittenBeforeHold"] = framesWrittenBeforeHold
            metrics["drainCallsBeforeHold"] = drainCallsBeforeHold
            metrics["transportStateBeforeHold"] = stateBeforeHold.name
            metrics["quiesceWaitMs"] = quiesceWaitMs
            metrics["quiesceFeedHeld"] = quiesceFeedHeld
            metrics["quiesceSinkReadFrames"] = quiesceSinkReadFrames
            metrics["quiesceSinkWrittenFrames"] = quiesceSinkWrittenFrames
            metrics["quiesceAccountingOk"] = quiesceAccountingOk
            metrics["preSeekSnapshotSettleMs"] = preSeekSnapshotSettleMs
            metrics["preSeekNativeState"] = pre?.stateToken ?: "none"
            metrics["preSeekTransportState"] = preSeekSnapshotState.name
            metrics["preSeekPositionFrame"] = pre?.positionFrame ?: -1L
            metrics["preSeekPushedFrames"] = pre?.pushedFrames ?: -1L
            metrics["preSeekDrainedFrames"] = pre?.drainedFrames ?: -1L
            metrics["preSeekDiscardedFrames"] = pre?.discardedFrames ?: -1L
            metrics["preSeekUnderrunCount"] = pre?.underrunCount ?: -1L
            metrics["preSeekOutputAvailableReadFrames"] = pre?.outputAvailableReadFrames ?: -1L
            metrics["decoderPreSeekAcceptedFrames"] = f?.preSeekAcceptedFrames ?: -1L
            metrics["decoderStagedFramesClearedAtSeek"] = f?.stagedFramesClearedAtSeek ?: -1L
            // Park / pause / flush.
            metrics["sinkParkRequested"] = parkRequested
            metrics["sinkParkAcked"] = parkAcked
            metrics["sinkParkAckWaitMs"] = parkAckWaitMs
            metrics["sinkParkAckLatencyMs"] = s?.parkAckLatencyMs ?: -1L
            metrics["sinkParkCount"] = s?.parkCount ?: 0
            metrics["sinkUnparkCount"] = s?.unparkCount ?: 0
            metrics["sinkParkRequestCount"] = s?.parkRequestCount ?: 0
            metrics["sinkPhaseFinal"] = s?.phase?.name ?: "none"
            metrics["sinkPlayStateAtPark"] = s?.playStateAtPark ?: -1
            metrics["sinkPlayStateAfterUnpark"] = s?.playStateAfterUnpark ?: -1
            metrics["sinkParkedPlayStateObservations"] = s?.parkedPlayStateObservations ?: 0L
            metrics["sinkParkedPlayStateViolations"] = s?.parkedPlayStateViolations ?: 0L
            metrics["sinkParkExecutedOnSinkThread"] = s?.parkExecutedOnSinkThread ?: false
            metrics["sinkUnparkExecutedOnSinkThread"] = s?.unparkExecutedOnSinkThread ?: false
            metrics["sinkFramesWrittenAtPark"] = s?.framesWrittenAtPark ?: 0L
            metrics["sinkDrainCallsAtPark"] = s?.drainCallsAtPark ?: 0L
            metrics["sinkPlaybackHeadAtPark"] = s?.playbackHeadAtPark ?: 0L
            metrics["sinkPlaybackHeadAtUnpark"] = s?.playbackHeadAtUnpark ?: 0L
            metrics["sinkParkedHoldMs"] = s?.parkedHoldMs ?: -1L
            metrics["pauseAccepted"] = pauseAccepted
            metrics["pauseState"] = pauseState.name
            metrics["pauseReason"] = pauseReason
            metrics["postPauseNativeState"] = postPause?.stateToken ?: "none"
            metrics["postPausePushedFrames"] = postPause?.pushedFrames ?: -1L
            metrics["postPauseDrainedFrames"] = postPause?.drainedFrames ?: -1L
            metrics["sinkFlushRequested"] = flushRequested
            metrics["sinkFlushAcked"] = flushAcked
            metrics["sinkFlushAckWaitMs"] = flushAckWaitMs
            metrics["sinkFlushAckLatencyMs"] = s?.flushAckLatencyMs ?: -1L
            metrics["sinkFlushRequestCount"] = s?.flushRequestCount ?: 0
            metrics["sinkFlushCount"] = s?.flushCount ?: 0
            metrics["sinkFlushExecutedOnSinkThread"] = s?.flushExecutedOnSinkThread ?: false
            metrics["sinkPlayStateBeforeFlush"] = s?.playStateBeforeFlush ?: -1
            metrics["sinkPlayStateAfterFlush"] = s?.playStateAfterFlush ?: -1
            metrics["sinkPlaybackHeadBeforeFlush"] = s?.playbackHeadBeforeFlush ?: -1L
            metrics["sinkPlaybackHeadAfterFlush"] = s?.playbackHeadAfterFlush ?: -1L
            metrics["sinkFramesWrittenAtFlush"] = s?.framesWrittenAtFlush ?: -1L
            metrics["sinkFramesReadAtFlush"] = s?.framesReadAtFlush ?: -1L
            metrics["sinkDrainCallsAtFlush"] = s?.drainCallsAtFlush ?: -1L
            metrics["sinkPostSeekExpectedFrames"] = s?.postSeekExpectedFrames ?: -1L
            metrics["sinkReadBudgetFrames"] = s?.readBudgetFrames ?: -1L
            // Seek command / re-anchor.
            metrics["seekAccepted"] = seekAccepted
            metrics["seekState"] = seekState.name
            metrics["seekReason"] = seekReason
            metrics["sinkPlayStateAtSeek"] = sinkPlayStateAtSeek
            metrics["sinkPhaseAtSeek"] = sinkPhaseAtSeek
            metrics["postSeekNativeState"] = post?.stateToken ?: "none"
            metrics["postSeekTransportState"] = postSeekSnapshotState.name
            metrics["postSeekPositionFrame"] = post?.positionFrame ?: -1L
            metrics["postSeekPushedFrames"] = post?.pushedFrames ?: -1L
            metrics["postSeekDrainedFrames"] = post?.drainedFrames ?: -1L
            metrics["postSeekDiscardedFrames"] = post?.discardedFrames ?: -1L
            metrics["feedReanchorRequested"] = reanchorRequested
            metrics["feedReanchorAcked"] = reanchorAcked
            metrics["feedReanchorWaitMs"] = reanchorWaitMs
            metrics["feedReanchorWallMs"] = f?.seekReanchorWallMs ?: -1L
            metrics["feedReanchorCount"] = f?.seekReanchorCount ?: 0
            metrics["feedReanchorExecutedOnDecodeThread"] = f?.reanchorExecutedOnDecodeThread ?: false
            metrics["feedReanchorTransportStatePaused"] = f?.reanchorTransportStatePaused ?: false
            metrics["seekTargetUs"] = f?.seekTargetUs ?: -1L
            metrics["seekLandedUs"] = f?.seekLandedUs ?: -1L
            metrics["seekStaleProbeCalls"] = f?.staleProbeCalls ?: 0
            metrics["seekStaleReason"] = f?.staleProbeReason ?: ""
            metrics["seekStaleReplyNull"] = f?.staleProbeReplyNull ?: false
            metrics["seekStaleRejected"] = f?.staleProbeRejected ?: false
            metrics["seekStaleAnchorUntouched"] = f?.staleProbeAnchorUntouched ?: false
            metrics["seekDiscardedPreTargetFrames"] = f?.discardedPreTargetFrames ?: 0L
            metrics["seekGapObservedFrames"] = f?.gapObservedFrames ?: 0L
            metrics["seekGapPaddedFrames"] = f?.gapPaddedFrames ?: 0L
            metrics["seekMaxGapFrames"] = f?.maxSeekGapFrames ?: 0L
            metrics["seekFirstDecodedPtsUs"] = f?.firstPostSeekPtsUs ?: -1L
            metrics["seekFirstDecodedFrame"] = f?.firstPostSeekFrame ?: -1L
            metrics["postSeekAcceptedFrames"] = f?.postSeekAcceptedFrames ?: 0L
            metrics["postSeekDecodedAcceptedFrames"] = f?.postSeekDecodedAcceptedFrames ?: 0L
            metrics["postSeekPaddedFrames"] = f?.postSeekPaddedFrames ?: 0L
            metrics["postSeekPreRollAcked"] = postSeekPreRollAcked
            metrics["postSeekPreRollWaitMs"] = postSeekPreRollWaitMs
            metrics["postSeekPreRollFrames"] = f?.postSeekPreRollFrames ?: 0L
            metrics["postSeekPreRollStatePaused"] = f?.postSeekPreRollStatePaused ?: false
            metrics["postSeekPreRollTransportState"] = postSeekPreRollTransportState.name
            metrics["postSeekPreRollNativeState"] = postPreroll?.stateToken ?: "none"
            metrics["postSeekPreRollPushedFrames"] = postPreroll?.pushedFrames ?: -1L
            // Unpark / resume / post-seek epoch.
            metrics["sinkUnparkRequested"] = unparkRequested
            metrics["sinkUnparkAcked"] = unparkAcked
            metrics["sinkUnparkAckWaitMs"] = unparkAckWaitMs
            metrics["framesWrittenAfterUnpark"] = framesWrittenAfterUnpark
            metrics["drainCallsAfterUnpark"] = drainCallsAfterUnpark
            metrics["resumeAccepted"] = resumeAccepted
            metrics["resumeState"] = resumeState.name
            metrics["resumeReason"] = resumeReason
            metrics["framesWrittenAtResume"] = framesWrittenAtResume
            metrics["drainCallsAtResume"] = drainCallsAtResume
            metrics["sinkPlaybackHeadEpochBase"] = s?.playbackHeadEpochBase ?: -1L
            metrics["sinkEpochBaseCaptured"] = s?.epochBaseCaptured ?: false
            metrics["postSeekPlaybackHeadFrames"] = s?.postSeekPlaybackHeadFrames ?: -1L
            metrics["postSeekFramesWritten"] = s?.postSeekFramesWritten ?: 0L
            metrics["failureReason"] = failure.get() ?: ""
        }
    }

    // ── Result assembly ────────────────────────────────────────────────────

    private fun firstFailedLane(): String = REQUIRED_LANES.firstOrNull { lanes[it] != true } ?: "none"

    private fun buildResult(pass: Boolean, failureReason: String): Result {
        val laneMap = linkedMapOf<String, Boolean>()
        for (lane in REQUIRED_LANES) laneMap[lane] = pass || (lanes[lane] == true)
        laneMap[LANE_PROOF_BOUNDARY] = true
        laneMap[LANE_CANONICAL] = pass
        val status = if (pass) "pass" else "fail"
        val metricMap = LinkedHashMap<String, Any?>(metrics)
        metricMap["failureReason"] = failureReason
        metricMap["cancelled"] = cancelled.get()
        return Result(
            pass = pass,
            status = status,
            failureReason = failureReason,
            proofBoundary = PROOF_BOUNDARY,
            lanes = laneMap,
            metrics = metricMap,
            raw = "pass=$pass;status=$status;failureReason=$failureReason",
        )
    }
}
