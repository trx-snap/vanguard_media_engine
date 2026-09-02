package com.connects.vanguard_media_engine.audio_playback_graph

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

// ── VanguardRealtimePlaybackPipelineCoordinator (P4-AUDIO-REALTIME-PLAYBACK-PIPELINE-INTEGRATION-A, Y6a) ─
//
// The ONLY transport command owner of the Y6a realtime playback pipeline:
//
//   MediaExtractor/MediaCodec  ->  Y5a external ingest seam  ->  Y1 native
//   ([VanguardRealtimePlaybackDecoderFeed], decode thread)     transport
//   (owner HandlerThread inside the state machine)  ->  non-zero-gain
//   AudioTrack MODE_STREAM ([VanguardRealtimePlaybackAudioTrackSinkBridge],
//   sink thread)
//
// Thread model: the decoder feed thread only posts generation-pinned
// ingest; the sink thread only drains/snapshots; the shared
// [VanguardRealtimePlaybackTransportStateMachine] is the only JNI caller
// and owns its HandlerThread; this coordinator (the caller's worker
// thread) issues load -> prepare -> start, waits/joins and aggregates.
//
// Terminal-state table (single track, one forward playthrough to EOS):
// - start: feed opens/probes -> coordinator creates the state machine with
//   externalIngestTrackMask=1, load, prepare -> feed attached, pre-rolls
//   until ring_full (or the declared end) -> coordinator start (+ feed
//   generation update) -> sink bridge starts.
// - active: feed fills and retries backpressure; sink drains/writes; native
//   backpressure and underrun counters are recorded, never fatal.
// - EOS: feed pads a <= 1 s shortfall through ingest; sink exits on
//   eosDrained; the transport observes COMPLETED on the owner thread.
// - failure / deadline / cancel: first failure wins (AtomicReference);
//   both threads are cancelled, MediaCodec/MediaExtractor and the
//   AudioTrack are released exactly once on their own threads, the state
//   machine is disposed exactly once, joins are bounded.
// - double run / dispose: AtomicBoolean guarded; [run] is single use.
//
// After the playthrough a short bounded cancel probe (same source, same
// pipeline shape, cancelled after the first sink write) proves the cancel
// path with real threads; it is a second, separately accounted session.
//
// No seek, pause/resume, interactive controls, audio focus, becoming-
// noisy, route change, dead-object recovery, presentation clock, A/V
// sync, resample or downmix live here.
class VanguardRealtimePlaybackPipelineCoordinator {

    data class Config(
        val sourcePath: String,
        val maxDurationSec: Double = 3.0,
        val maxFramesPerMix: Int = 256,
        val baseVolume: Float = VanguardRealtimePlaybackAudioTrackSinkBridge.DEFAULT_BASE_VOLUME,
        val deadlineMs: Long = 30_000L,
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
            "realtime_playback_pipeline_integration_a_diagnostic_only_real_mediacodec_mediaextractor_" +
                "streaming_pcm16_to_y5a_external_ingest_seam_native_dag_transport_to_nonzero_gain_" +
                "audiotrack_sink_base_gain_0_5_single_track_forward_playthrough_no_seek_no_pause_resume_" +
                "no_interactive_controls_no_audio_focus_no_becoming_noisy_no_route_change_" +
                "no_dead_object_recovery_no_presentation_clock_no_av_sync_no_latency_drift_loudness_" +
                "snr_claim_no_resample_no_downmix_no_product_editor_app_wiring_no_ios_no_streaming_cache_" +
                "no_native_cpp_changes"

        const val LANE_FORMAT_PROBE = "formatProbeOk"
        const val LANE_PRE_ROLL = "preRollOk"
        const val LANE_REAL_DECODER_INGEST = "realDecoderIngestOk"
        const val LANE_NON_ZERO_GAIN_SET = "nonZeroGainSetOk"
        const val LANE_AUDIO_TRACK_INIT = "audioTrackInitOk"
        const val LANE_SINK_WRITE_ACCOUNTING = "sinkWriteAccountingOk"
        const val LANE_CHECKSUM_IDENTITY = "checksumIdentityOk"
        const val LANE_BACKPRESSURE_OBSERVED = "backpressureObservedOk"
        const val LANE_UNDERRUN_NONTERMINAL = "underrunNonterminalOk"
        const val LANE_EOS_ACCOUNTING = "eosAccountingOk"
        const val LANE_PLAYBACK_HEAD_ADVANCED = "playbackHeadAdvancedOk"
        const val LANE_TRANSPORT_COMPLETED = "transportCompletedOk"
        const val LANE_THREAD_OWNERSHIP = "threadOwnershipOk"
        const val LANE_CANCELLATION = "cancellationOk"
        const val LANE_LIFECYCLE_DISPOSE = "lifecycleDisposeOk"
        const val LANE_PROOF_BOUNDARY = "proofBoundaryOk"
        const val LANE_CANONICAL = "canonical"

        val REQUIRED_LANES: List<String> = listOf(
            LANE_FORMAT_PROBE,
            LANE_PRE_ROLL,
            LANE_REAL_DECODER_INGEST,
            LANE_NON_ZERO_GAIN_SET,
            LANE_AUDIO_TRACK_INIT,
            LANE_SINK_WRITE_ACCOUNTING,
            LANE_CHECKSUM_IDENTITY,
            LANE_BACKPRESSURE_OBSERVED,
            LANE_UNDERRUN_NONTERMINAL,
            LANE_EOS_ACCOUNTING,
            LANE_PLAYBACK_HEAD_ADVANCED,
            LANE_TRANSPORT_COMPLETED,
            LANE_THREAD_OWNERSHIP,
            LANE_CANCELLATION,
            LANE_LIFECYCLE_DISPOSE,
        )

        private const val MAX_EOS_DRIFT_SEC = 1.0
        private const val WAIT_SLICE_MS = 5L
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val CANCEL_PROBE_FIRST_WRITE_WAIT_MS = 2_000L
        private const val COMMANDS_PER_SESSION = 3 // load, prepare, start
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
    // it at their next bounded wait and the run thread tears down.
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
            config.maxDurationSec > VanguardRealtimePlaybackDecoderFeed.HARD_MAX_DURATION_SEC
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
        if (cancelled.get()) throw FailClosed("cancelled")
        val deadlineAtMs = SystemClock.elapsedRealtime() + config.deadlineMs
        metrics["maxDurationSec"] = config.maxDurationSec
        metrics["maxFramesPerMix"] = config.maxFramesPerMix
        // Floats are not StandardMessageCodec values; publish as Double.
        metrics["baseVolume"] = config.baseVolume.toDouble()
        metrics["deadlineMs"] = config.deadlineMs
        metrics["coordinatorThreadId"] = Thread.currentThread().id

        val playthrough = Session("play", config, deadlineAtMs)
        activeSession = playthrough
        try {
            playthrough.runPlaythrough()
        } finally {
            playthrough.disposeTransportOnce()
            playthrough.publishMetrics("")
            activeSession = null
        }
        playthrough.failure.get()?.let { throw FailClosed(it) }

        val probe = Session("cancelProbe", config, deadlineAtMs)
        activeSession = probe
        try {
            probe.runCancelProbe()
        } finally {
            probe.disposeTransportOnce()
            probe.publishMetrics("cancelProbe")
            activeSession = null
        }
        lanes[LANE_CANCELLATION] = probe.cancellationOk
        probe.failure.get()?.let { throw FailClosed("cancel_probe:$it") }
    }

    private fun isCancelled(): Boolean = cancelled.get()

    // ── One pipeline session (feed + transport + sink) ─────────────────────

    private inner class Session(
        val name: String,
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
        var feed: VanguardRealtimePlaybackDecoderFeed? = null

        @Volatile
        var sink: VanguardRealtimePlaybackAudioTrackSinkBridge? = null

        var format: VanguardRealtimePlaybackDecoderFeed.Format? = null
        var commandsIssued = 0
        var prepareGeneration = -1L
        var startGeneration = -1L
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
        var cancelProbeStateAtCancel = State.IDLE
        var cancelProbeFramesWrittenAtCancel = 0L
        var cancelProbeJoinMs = -1L
        var cancellationOk = false

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

        private fun sleepSlice() {
            try {
                Thread.sleep(WAIT_SLICE_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                throw FailClosed("interrupted")
            }
        }

        // Feed open/probe -> transport load/prepare -> pre-roll -> start ->
        // sink start. Shared by the playthrough and the cancel probe.
        private fun openAndStart() {
            checkDeadlineAndCancel()
            val f = VanguardRealtimePlaybackDecoderFeed(
                VanguardRealtimePlaybackDecoderFeed.Config(
                    sourcePath = config.sourcePath,
                    maxDurationSec = config.maxDurationSec,
                    maxFramesPerMix = config.maxFramesPerMix,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6a${name}DecoderFeed",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            feed = f
            if (!f.start()) throw FailClosed("${name}_feed_start_rejected")

            val fmt = f.awaitFormat(remainingMs()) ?: throw FailClosed("${name}_format_probe_failed:${f.exitReason}")
            format = fmt
            checkDeadlineAndCancel()

            val sessionConfig = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = fmt.sampleRate,
                channelCount = fmt.channelCount,
                maxFramesPerMix = config.maxFramesPerMix,
                trackCount = VanguardRealtimePlaybackDecoderFeed.TRACK_COUNT,
                declaredFrameCount = fmt.declaredFrameCount,
                externalIngestTrackMask = VanguardRealtimePlaybackDecoderFeed.EXTERNAL_INGEST_TRACK_MASK,
            )
            VanguardRealtimePlaybackNativeSession.validate(sessionConfig)?.let {
                throw FailClosed("${name}_session_config_invalid:${it.name.lowercase()}")
            }
            val machine = VanguardRealtimePlaybackTransportStateMachine(
                sessionConfig, listener, threadName = "Y6a${name}Transport",
            )
            sm = machine
            if (sessionCancelled()) throw FailClosed("cancelled")

            val loadRes = machine.load()
            commandsIssued++
            if (!loadRes.accepted) throw FailClosed("${name}_load_rejected:${loadRes.reason}")
            val prepareRes = machine.prepare()
            commandsIssued++
            if (!prepareRes.accepted || prepareRes.state != State.PREPARED) {
                throw FailClosed("${name}_prepare_rejected:${prepareRes.reason}")
            }
            prepareGeneration = machine.currentGeneration
            f.attachTransport(machine, prepareGeneration)

            // Pre-roll while PREPARED until the source ring answers ring_full
            // (or the declared end fits entirely).
            while (!f.awaitPreRoll(WAIT_SLICE_MS)) {
                checkDeadlineAndCancel()
                failure.get()?.let { throw FailClosed(it) }
                if (!f.isAlive) throw FailClosed("${name}_feed_exited_during_preroll:${f.exitReason}")
            }
            preRollFrames = f.preRollFrames
            preRollRingFull = f.preRollRingFullObserved
            preRollPartialWrite = f.preRollPartialWriteObserved
            preRollStatePrepared = machine.currentState == State.PREPARED
            if (preRollFrames <= 0L) throw FailClosed("${name}_preroll_empty:${f.exitReason}")

            val startRes = machine.start()
            commandsIssued++
            startAcceptedPlaying = startRes.accepted && startRes.state == State.PLAYING
            if (!startAcceptedPlaying) throw FailClosed("${name}_start_rejected:${startRes.reason}")
            startGeneration = machine.currentGeneration
            f.updateGeneration(startGeneration)
            f.markTransportStarted()

            val s = VanguardRealtimePlaybackAudioTrackSinkBridge(
                VanguardRealtimePlaybackAudioTrackSinkBridge.Config(
                    stateMachine = machine,
                    sampleRate = fmt.sampleRate,
                    channelCount = fmt.channelCount,
                    maxFramesPerMix = config.maxFramesPerMix,
                    declaredFrameCount = fmt.declaredFrameCount,
                    baseVolume = config.baseVolume,
                    deadlineAtMs = deadlineAtMs,
                    threadName = "Y6a${name}SinkBridge",
                    externallyCancelled = { sessionCancelled() },
                ),
            )
            sink = s
            if (!s.start()) throw FailClosed("${name}_sink_start_rejected")
        }

        // Polls the failure sources once; returns the first failure if any.
        private fun pollFailure(): String? {
            failure.get()?.let { return it }
            val machine = sm
            if (machine != null && machine.currentState == State.FAILED) recordFailure("${name}_transport_failed")
            val f = feed
            if (f != null && !f.isAlive) {
                val reason = f.exitReason
                if (reason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS &&
                    reason != VanguardRealtimePlaybackDecoderFeed.EXIT_RUNNING &&
                    reason != VanguardRealtimePlaybackDecoderFeed.EXIT_CANCELLED
                ) {
                    recordFailure("${name}_decoder:$reason")
                }
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

        // ── Playthrough ────────────────────────────────────────────────────

        fun runPlaythrough() {
            val wallStart = SystemClock.elapsedRealtime()
            try {
                openAndStart()
                val f = feed ?: throw FailClosed("feed_missing")
                val s = sink ?: throw FailClosed("sink_missing")
                val machine = sm ?: throw FailClosed("transport_missing")

                // Wait for the sink to exit (EOS) or the first failure.
                while (!s.awaitExit(WAIT_SLICE_MS)) {
                    val first = pollFailure()
                    if (first != null) {
                        cancelThreads()
                        break
                    }
                }
                if (failure.get() == null && s.exitReason != VanguardRealtimePlaybackAudioTrackSinkBridge.EXIT_EOS) {
                    recordFailure("${name}_sink:${s.exitReason}")
                }
                if (failure.get() == null && !f.awaitExit(JOIN_TIMEOUT_MS)) {
                    recordFailure("${name}_decoder_did_not_exit")
                }
                if (failure.get() == null && f.exitReason != VanguardRealtimePlaybackDecoderFeed.EXIT_EOS) {
                    recordFailure("${name}_decoder:${f.exitReason}")
                }
                if (failure.get() != null) cancelThreads()
                joinBoth()

                val snapRes = machine.snapshot()
                finalReply = snapRes.reply ?: s.lastReply
                val final = finalReply
                if (failure.get() == null && (!snapRes.accepted || final == null)) {
                    recordFailure("${name}_final_snapshot_rejected:${snapRes.reason}")
                }

                // Lifecycle: explicit dispose, later postIngest rejected
                // (never posted), second dispose is a no-op.
                val stateAtCompletion = machine.currentState
                disposeTransportOnce()
                val probe = ByteBuffer.allocateDirect(config.maxFramesPerMix * 2 * (format?.channelCount ?: 2))
                    .order(ByteOrder.nativeOrder())
                postIngestAfterDispose = machine.postIngest(
                    IngestRequest(VanguardRealtimePlaybackDecoderFeed.EXTERNAL_TRACK_INDEX, probe, config.maxFramesPerMix, f.acceptedFrames),
                    expectedGeneration = startGeneration,
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
            f: VanguardRealtimePlaybackDecoderFeed,
            s: VanguardRealtimePlaybackAudioTrackSinkBridge,
            machine: VanguardRealtimePlaybackTransportStateMachine,
            final: Reply,
            stateAtCompletion: State,
        ) {
            val fmt = format ?: return
            val declared = fmt.declaredFrameCount
            val coordinatorThreadId = Thread.currentThread().id
            val maxPadFrames = (MAX_EOS_DRIFT_SEC * fmt.sampleRate).toLong()
            val decoderHex = f.checksumHex
            val sinkHex = s.checksumHex

            val transportCompleted = stateAtCompletion == State.COMPLETED &&
                final.state == NativeState.COMPLETED && completedCount.get() == 1 && failedCount.get() == 0

            lanes[LANE_FORMAT_PROBE] = fmt.sampleRate > 0 && fmt.channelCount in 1..2 && declared > 0L && fmt.sourceMime.isNotBlank()
            lanes[LANE_PRE_ROLL] = preRollFrames > 0L && (preRollRingFull || preRollFrames == declared) &&
                preRollStatePrepared && startAcceptedPlaying && preRollFrames <= declared
            lanes[LANE_REAL_DECODER_INGEST] = f.exitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS &&
                f.codecChunks > 0L && f.ingestCalls > 0L && f.acceptedFrames == declared &&
                f.acceptedFrames - f.paddedFrames > 0L
            lanes[LANE_NON_ZERO_GAIN_SET] = s.gainSetOk && s.gainValue > 0f && s.gainValue == config.baseVolume
            lanes[LANE_AUDIO_TRACK_INIT] = s.audioTrackInitOk
            lanes[LANE_SINK_WRITE_ACCOUNTING] = s.exitReason == VanguardRealtimePlaybackAudioTrackSinkBridge.EXIT_EOS &&
                s.framesReadFromTransport == declared && s.framesWrittenToSink == declared
            lanes[LANE_CHECKSUM_IDENTITY] = decoderHex.equals(final.pushedChecksumHex, ignoreCase = true) &&
                decoderHex.equals(final.drainedChecksumHex, ignoreCase = true) &&
                decoderHex.equals(sinkHex, ignoreCase = true)
            lanes[LANE_BACKPRESSURE_OBSERVED] = f.ingestRingFullCount > 0L || f.ingestPartialWriteCount > 0L ||
                final.backpressureCount > 0L
            // Underruns (if any) and backpressure were recorded, never fatal:
            // the run still reached a clean completion with no native error.
            lanes[LANE_UNDERRUN_NONTERMINAL] = transportCompleted && final.lastError == "none" &&
                final.underrunCount >= 0L && f.exitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS
            lanes[LANE_EOS_ACCOUNTING] = final.positionFrame == declared && final.eosPushed && final.eosDrained &&
                final.pushedFrames == declared && final.drainedFrames == declared && final.discardedFrames == 0L &&
                f.paddedFrames <= maxPadFrames && f.discardedFrames == 0L && s.eosDrainedObserved
            lanes[LANE_PLAYBACK_HEAD_ADVANCED] = s.played && s.playbackHeadFinal > 0L
            lanes[LANE_TRANSPORT_COMPLETED] = transportCompleted
            lanes[LANE_THREAD_OWNERSHIP] = f.ingestCallbacksOnOwner.get() > 0L && f.ingestCallbacksOffOwner.get() == 0L &&
                !f.threadIsTransportOwner && !s.threadIsTransportOwner &&
                f.threadId > 0L && s.threadId > 0L && f.threadId != s.threadId &&
                f.threadId != coordinatorThreadId && s.threadId != coordinatorThreadId &&
                listenerOnOwner.get() > 0L && listenerOffOwner.get() == 0L &&
                commandsIssued == COMMANDS_PER_SESSION && startGeneration == prepareGeneration + 1L &&
                machine.currentGeneration == startGeneration && final.wrongOwnerThread.not()
            lanes[LANE_LIFECYCLE_DISPOSE] = feedJoined && sinkJoined &&
                f.mediaReleaseCount.get() == 1L && f.mediaReleaseClean &&
                s.releaseCount.get() == 1 && disposeCalls == 1 &&
                stateAfterDispose == State.DISPOSED && stateAfterSecondDispose == State.DISPOSED &&
                !postIngestAfterDispose && machine.currentState == State.DISPOSED
        }

        // ── Cancel probe ───────────────────────────────────────────────────

        fun runCancelProbe() {
            val wallStart = SystemClock.elapsedRealtime()
            try {
                openAndStart()
                val f = feed ?: throw FailClosed("feed_missing")
                val s = sink ?: throw FailClosed("sink_missing")
                val machine = sm ?: throw FailClosed("transport_missing")

                // Let the pipeline reach real output, then cancel mid-flight.
                val firstWriteDeadline = SystemClock.elapsedRealtime() + CANCEL_PROBE_FIRST_WRITE_WAIT_MS
                while (s.framesWrittenToSink <= 0L) {
                    pollFailure()?.let { throw FailClosed(it) }
                    if (!s.isAlive) throw FailClosed("${name}_sink_exited_early:${s.exitReason}")
                    if (SystemClock.elapsedRealtime() > firstWriteDeadline) throw FailClosed("${name}_no_sink_write")
                    sleepSlice()
                }
                cancelProbeStateAtCancel = machine.currentState
                cancelProbeFramesWrittenAtCancel = s.framesWrittenToSink
                val cancelAt = SystemClock.elapsedRealtime()
                cancelThreads()
                joinBoth()
                cancelProbeJoinMs = SystemClock.elapsedRealtime() - cancelAt

                val snapRes = machine.snapshot()
                finalReply = snapRes.reply ?: s.lastReply
                val stateAfterCancel = machine.currentState
                disposeTransportOnce()
                val probe = ByteBuffer.allocateDirect(config.maxFramesPerMix * 2 * (format?.channelCount ?: 2))
                    .order(ByteOrder.nativeOrder())
                postIngestAfterDispose = machine.postIngest(
                    IngestRequest(VanguardRealtimePlaybackDecoderFeed.EXTERNAL_TRACK_INDEX, probe, config.maxFramesPerMix, f.acceptedFrames),
                    expectedGeneration = startGeneration,
                )
                machine.dispose()
                stateAfterSecondDispose = machine.currentState

                val feedExitOk = f.exitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_CANCELLED ||
                    f.exitReason == VanguardRealtimePlaybackDecoderFeed.EXIT_EOS
                cancellationOk = cancelProbeStateAtCancel == State.PLAYING && cancelProbeFramesWrittenAtCancel > 0L &&
                    feedJoined && sinkJoined && feedExitOk &&
                    s.exitReason == VanguardRealtimePlaybackAudioTrackSinkBridge.EXIT_CANCELLED &&
                    f.mediaReleaseCount.get() == 1L && f.mediaReleaseClean && s.releaseCount.get() == 1 &&
                    stateAfterCancel == State.PLAYING && failedCount.get() == 0 && failure.get() == null &&
                    disposeCalls == 1 && stateAfterDispose == State.DISPOSED &&
                    stateAfterSecondDispose == State.DISPOSED && !postIngestAfterDispose
            } finally {
                cancelThreads()
                joinBoth()
                sessionWallMs = SystemClock.elapsedRealtime() - wallStart
            }
        }

        // ── Metrics ────────────────────────────────────────────────────────

        fun publishMetrics(prefix: String) {
            fun key(k: String): String = if (prefix.isEmpty()) k else prefix + k.replaceFirstChar { it.uppercaseChar() }
            val fmt = format
            val f = feed
            val s = sink
            val machine = sm
            val final = finalReply
            metrics[key("sourceMime")] = fmt?.sourceMime ?: ""
            metrics[key("sourceTrackIndex")] = fmt?.sourceTrackIndex ?: -1
            metrics[key("sourceDurationUs")] = fmt?.sourceDurationUs ?: -1L
            metrics[key("declaredWindowUs")] = fmt?.declaredWindowUs ?: -1L
            metrics[key("sampleRate")] = fmt?.sampleRate ?: 0
            metrics[key("channelCount")] = fmt?.channelCount ?: 0
            metrics[key("pcmEncoding")] = fmt?.pcmEncoding ?: 0
            metrics[key("declaredFrameCount")] = fmt?.declaredFrameCount ?: 0L
            metrics[key("preRollFrames")] = preRollFrames
            metrics[key("preRollRingFullObserved")] = preRollRingFull
            metrics[key("preRollPartialWriteObserved")] = preRollPartialWrite
            metrics[key("preRollStatePrepared")] = preRollStatePrepared
            metrics[key("ingestRingFullCount")] = f?.ingestRingFullCount ?: 0L
            metrics[key("ingestPartialWriteCount")] = f?.ingestPartialWriteCount ?: 0L
            metrics[key("ingestCalls")] = f?.ingestCalls ?: 0L
            metrics[key("staleGenerationRetries")] = f?.staleGenerationRetries ?: 0L
            metrics[key("transientRejects")] = f?.transientRejects ?: 0L
            metrics[key("nativeBackpressureCount")] = final?.backpressureCount ?: -1L
            metrics[key("nativeUnderrunCount")] = final?.underrunCount ?: -1L
            metrics[key("nativeDispatchCount")] = final?.dispatchCount ?: -1L
            metrics[key("eosPaddedFrames")] = f?.paddedFrames ?: 0L
            metrics[key("eosTruncatedFrames")] = f?.truncatedFrames ?: 0L
            metrics[key("decoderDiscardedFrames")] = f?.discardedFrames ?: 0L
            metrics[key("decoderAcceptedFrames")] = f?.acceptedFrames ?: 0L
            metrics[key("decoderDecodedFramesAccepted")] = (f?.acceptedFrames ?: 0L) - (f?.paddedFrames ?: 0L)
            metrics[key("codecChunks")] = f?.codecChunks ?: 0L
            metrics[key("decodedFramesTotal")] = f?.decodedFramesTotal ?: 0L
            metrics[key("framesReadFromTransport")] = s?.framesReadFromTransport ?: 0L
            metrics[key("framesWrittenToSink")] = s?.framesWrittenToSink ?: 0L
            metrics[key("partialWriteCount")] = s?.partialWriteCount ?: 0L
            metrics[key("zeroWriteCount")] = s?.zeroWriteCount ?: 0L
            metrics[key("drainCalls")] = s?.drainCalls ?: 0L
            metrics[key("emptyDrainCount")] = s?.emptyDrainCount ?: 0L
            metrics[key("playbackHeadFinal")] = s?.playbackHeadFinal ?: 0L
            metrics[key("playbackHeadCaughtUp")] = s?.playbackHeadCaughtUp ?: false
            metrics[key("audioTrackInitOk")] = s?.audioTrackInitOk ?: false
            metrics[key("gainSetOk")] = s?.gainSetOk ?: false
            metrics[key("gainValue")] = (s?.gainValue ?: 0f).toDouble()
            metrics[key("audioTrackBufferBytes")] = s?.audioTrackBufferBytes ?: 0
            metrics[key("decodeThreadWallMs")] = f?.decodeThreadWallMs ?: 0L
            metrics[key("sinkThreadWallMs")] = s?.sinkThreadWallMs ?: 0L
            metrics[key("sessionWallMs")] = sessionWallMs
            metrics[key("kotlinDecoderChecksumHex")] = f?.checksumHex ?: ""
            metrics[key("kotlinSinkChecksumHex")] = s?.checksumHex ?: ""
            metrics[key("nativePushedChecksumHex")] = final?.pushedChecksumHex ?: ""
            metrics[key("nativeDrainedChecksumHex")] = final?.drainedChecksumHex ?: ""
            metrics[key("mediaReleaseCount")] = f?.mediaReleaseCount?.get() ?: 0L
            metrics[key("mediaReleaseClean")] = f?.mediaReleaseClean ?: false
            metrics[key("audioTrackReleaseCount")] = s?.releaseCount?.get() ?: 0
            metrics[key("transportDisposeCalls")] = disposeCalls
            metrics[key("decoderThreadJoined")] = feedJoined
            metrics[key("sinkThreadJoined")] = sinkJoined
            metrics[key("decoderExitReason")] = f?.exitReason ?: VanguardRealtimePlaybackDecoderFeed.EXIT_NOT_STARTED
            metrics[key("sinkExitReason")] = s?.exitReason ?: VanguardRealtimePlaybackAudioTrackSinkBridge.EXIT_NOT_STARTED
            metrics[key("decoderThreadId")] = f?.threadId ?: -1L
            metrics[key("sinkThreadId")] = s?.threadId ?: -1L
            metrics[key("ingestCallbacksOnOwner")] = f?.ingestCallbacksOnOwner?.get() ?: 0L
            metrics[key("ingestCallbacksOffOwner")] = f?.ingestCallbacksOffOwner?.get() ?: 0L
            metrics[key("listenerCallbacksOnOwner")] = listenerOnOwner.get()
            metrics[key("listenerCallbacksOffOwner")] = listenerOffOwner.get()
            metrics[key("transportCommandsIssued")] = commandsIssued
            metrics[key("transportPrepareGeneration")] = prepareGeneration
            metrics[key("transportStartGeneration")] = startGeneration
            metrics[key("transportGenerationFinal")] = machine?.currentGeneration ?: -1L
            metrics[key("transportStateBeforeDispose")] = stateBeforeDispose.name
            metrics[key("transportStateFinal")] = machine?.currentState?.name ?: "none"
            metrics[key("transportStateTransitions")] = synchronized(transitions) { transitions.toString() }
            metrics[key("transportCompletedCallbacks")] = completedCount.get()
            metrics[key("transportFailedCallbacks")] = failedCount.get()
            metrics[key("postIngestAfterDisposePosted")] = postIngestAfterDispose
            metrics[key("nativeStateFinal")] = final?.stateToken ?: "none"
            metrics[key("nativeWorkerExited")] = final?.workerExited ?: false
            metrics[key("nativeWorkerJoined")] = final?.workerJoined ?: false
            metrics[key("positionFrame")] = final?.positionFrame ?: -1L
            metrics[key("pushedFrames")] = final?.pushedFrames ?: -1L
            metrics[key("drainedFrames")] = final?.drainedFrames ?: -1L
            metrics[key("discardedFrames")] = final?.discardedFrames ?: -1L
            metrics[key("eosPushed")] = final?.eosPushed ?: false
            metrics[key("eosDrained")] = final?.eosDrained ?: false
            metrics[key("lastError")] = final?.lastError ?: "none"
            metrics[key("failureReason")] = failure.get() ?: ""
            if (prefix.isNotEmpty()) {
                metrics[key("stateAtCancel")] = cancelProbeStateAtCancel.name
                metrics[key("framesWrittenAtCancel")] = cancelProbeFramesWrittenAtCancel
                metrics[key("joinMs")] = cancelProbeJoinMs
                metrics[key("cancellationOk")] = cancellationOk
            }
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
