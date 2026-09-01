package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-RUNTIME-QUEUE-SCHEDULER (under
 * P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): diagnostic async
 * runtime queue/backpressure scheduler integration smoke coordinator.
 *
 * Owns [METHOD_NAME]. The Kotlin owner thread generates deterministic PCM16
 * in memory, ingests through the node-owned source-ring writer, drains the
 * output ring, and posts start/pause/resume/seek commands into the native
 * bounded command queue -- while the NATIVE WORKER thread advances the
 * clock/coordinator independently on a caller-derived synthetic frame-axis
 * timebase. The owner observes the worker only through the mutex-published
 * snapshot mirror.
 *
 * Honest non-claims (Proof Boundary): diagnostic async runtime queue
 * scheduler integration proof only. No MediaExtractor/MediaCodec, no
 * AudioTrack/AAudio/OpenSL/Oboe, no audible output, no realtime claim, no
 * product/editor/app wiring, no streaming/cache, no iOS, no export route
 * changes. Zero-fill probing runs in a separate bounded session whose zero
 * frames are counted honestly and never mixed into the main checksum
 * identity verdict.
 *
 * The coordinator dispatches to one background [Thread] per accepted run;
 * runs are serialized by an active flag. Detach-safe: after [disposeAll] no
 * MethodChannel reply is ever delivered; an in-flight run finishes on its
 * own thread and destroys its native sessions in its finally block.
 */
class AndroidAsyncRuntimeQueueSchedulerSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AsyncRtQueue"
        private const val METHOD_NAME = "runAsyncRuntimeQueueSchedulerSmoke"

        const val PASS_MARKER = "ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "diagnostic_async_runtime_queue_scheduler_integration_proof_only_worker_owned_clock_and_coordinator_command_serialized_source_ring_spsc_output_ring_spsc_caller_derived_systime_ticks_only_steady_clock_pacing_only_no_native_media_timebase_no_audible_output_no_audiotrack_no_aaudio_no_opensl_no_oboe_no_product_editor_app_wiring_no_streaming_cache_no_ios_no_export_route_changes"

        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        private const val POLL_SLEEP_MS = 2L

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        if (disposed.get()) {
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }
        val config = RunConfig(
            sampleRate = (args?.get("sampleRate") as? Number)?.toInt() ?: 48_000,
            channelCount = (args?.get("channelCount") as? Number)?.toInt() ?: 2,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 4_096,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 1_024,
            mainWindows = (args?.get("mainWindows") as? Number)?.toInt() ?: 64,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_ASYNC_RUNTIME_QUEUE_SCHEDULER_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        val replied = AtomicBoolean(false)
        try {
            Thread {
                try {
                    postReply(replied, result, runDriver(config))
                } catch (t: Throwable) {
                    Log.e(TAG, "$METHOD_NAME failed", t)
                    postReply(
                        replied,
                        result,
                        makePayload(
                            Telemetry(),
                            pass = false,
                            failureReason = "exception:${t.javaClass.simpleName}:${t.message}",
                        ),
                    )
                } finally {
                    active.set(false)
                }
            }.start()
        } catch (t: Throwable) {
            // Fail closed if the diagnostic thread cannot be created or
            // started: release the run slot and reply exactly once.
            Log.e(TAG, "$METHOD_NAME thread startup failed", t)
            active.set(false)
            postReply(
                replied,
                result,
                makePayload(
                    Telemetry(),
                    pass = false,
                    failureReason = "thread_startup_failed:${t.javaClass.simpleName}:${t.message}",
                ),
            )
        }
        return true
    }

    /** Marks the coordinator disposed; an in-flight run finishes naturally. */
    fun disposeAll() {
        disposed.set(true)
    }

    private fun postReply(
        replied: AtomicBoolean,
        result: MethodChannel.Result,
        payload: Map<String, Any?>,
    ) {
        if (disposed.get() || !replied.compareAndSet(false, true)) {
            return
        }
        mainHandler.post {
            if (disposed.get()) {
                return@post
            }
            result.success(payload)
        }
    }

    // ── Embedded deterministic PCM16 owner-thread driver ────────────────────

    private data class RunConfig(
        val sampleRate: Int,
        val channelCount: Int,
        val maxFramesPerMix: Int,
        val sourceRingCapacityFrames: Int,
        val outputRingCapacityFrames: Int,
        val mainWindows: Int,
        val deadlineMs: Long,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    // Mutable telemetry threaded through the run so fail-closed paths still
    // report everything observed up to the failure point.
    private class Telemetry {
        var asyncThreadDecouplingOk = false
        var controlCommandSerializationOk = false
        var sourceBackpressureOk = false
        var outputBackpressureOk = false
        var providerZeroFillAccountingOk = false
        var seekEpochCoordinationOk = false
        var checksumAccountingOk = false
        var workerJoinOnDestroyOk = false
        var idempotentDestroyOk = false
        var noOwnerThreadDispatchOk = false
        var proofBoundaryOk = false

        var workerThreadDistinct = false
        var ownerDispatchCalls = -1L
        var commandsEnqueued = -1L
        var commandsProcessed = -1L
        var commandErrors = -1L
        var dispatchCount = -1L
        var okCount = -1L
        var silenceCount = -1L
        var backpressureCount = -1L
        var schedulerErrorCount = -1L
        var writerBackpressureRejects = -1L
        var providerUnderrunEvents = -1L
        var providerFramesZeroFilled = -1L
        var providerForwardSkipFrames = -1L
        var providerRewindRejects = -1L
        var totalFramesAccepted = -1L
        var totalFramesRendered = -1L
        var totalFramesPushed = -1L
        var totalOutputFramesRead = -1L
        var kotlinAcceptedChecksumHex = ""
        var nativeAcceptedChecksumHex = ""
        var nativeOutputReadChecksumHex = ""
        var probeZeroFillWindows = -1L
        var probeFramesZeroFilled = -1L
        var probeUnderrunEvents = -1L
        var probeSilenceCount = -1L
        var probeFramesPushed = -1L
        var probeFramesRead = -1L
        val detailParts = mutableListOf<String>()
    }

    private fun runDriver(config: RunConfig): Map<String, Any?> {
        val t = Telemetry()
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        var handle = 0L
        var probeHandle = 0L
        try {
            val sr = config.sampleRate
            val ch = config.channelCount
            val mfpm = config.maxFramesPerMix
            // Power-of-two mfpm keeps the derived probe ring capacities
            // (8 * mfpm) inside the native power-of-two admission bound.
            if (mfpm < 4 || (mfpm and (mfpm - 1)) != 0) {
                throw FailClosed("invalid_driver_config_mfpm")
            }
            if (config.outputRingCapacityFrames < 2 * mfpm ||
                config.sourceRingCapacityFrames < 4 * mfpm
            ) {
                throw FailClosed("invalid_driver_config_ring_capacities")
            }
            if (config.outputRingCapacityFrames % mfpm != 0 ||
                config.sourceRingCapacityFrames % mfpm != 0
            ) {
                throw FailClosed("invalid_driver_config_ring_alignment")
            }
            val phaseAWindows = 2 * (config.outputRingCapacityFrames / mfpm)
            val phaseBWindows = config.sourceRingCapacityFrames / mfpm
            if (config.mainWindows <= phaseAWindows + phaseBWindows) {
                throw FailClosed("invalid_driver_config_main_windows")
            }
            val expectedFrames = config.mainWindows.toLong() * mfpm

            fun checkDeadline() {
                if (SystemClock.elapsedRealtime() > deadline) throw FailClosed("deadline_exceeded")
            }

            fun ceilDiv(a: Long, b: Long): Long = (a + b - 1) / b
            fun ceilPtsUs(frame: Long): Long = ceilDiv(frame * 1_000_000L, sr.toLong())

            // Caller-derived synthetic tick axis, mirroring the worker's
            // deterministic anchor rules exactly (re-based on pause/seek).
            var anchorPtsUs = 0L
            var anchorSysNs = ANCHOR_SYS_TIME_NS
            fun tickForFrame(frame: Long): Long =
                anchorSysNs + (ceilPtsUs(frame) - anchorPtsUs) * 1_000L

            val bytesPerFrame = 2 * ch
            val writeBuf = ByteBuffer.allocateDirect(mfpm * bytesPerFrame)
                .order(ByteOrder.LITTLE_ENDIAN)
            val readChunkFrames = 2 * mfpm
            val readBuf = ByteBuffer.allocateDirect(readChunkFrames * bytesPerFrame)
                .order(ByteOrder.LITTLE_ENDIAN)
            var patternCounter = 0L
            var kotlinChecksum = 0L
            var kotlinFramesAccepted = 0L

            // ── Per-session helpers (bound to the active handle) ────────────
            var activeHandle = 0L

            fun snapshot(): Map<String, String> {
                val kv = parseStatus(
                    VanguardNativeBridge.snapshotAsyncRuntimeQueueScheduler(activeHandle)
                )
                if (kv["status"] != "ok") throw FailClosed("snapshot_status_${kv["status"]}")
                return kv
            }

            fun awaitSnapshot(
                what: String,
                pred: (Map<String, String>) -> Boolean,
            ): Map<String, String> {
                while (true) {
                    val kv = snapshot()
                    if (pred(kv)) return kv
                    if (SystemClock.elapsedRealtime() > deadline) {
                        throw FailClosed("await_timeout_$what")
                    }
                    Thread.sleep(POLL_SLEEP_MS)
                }
            }

            fun awaitCommandProcessed(seq: Long): Map<String, String> {
                val kv = awaitSnapshot("command_$seq") {
                    longField(it, "commandsProcessed") >= seq
                }
                if (longField(kv, "lastCommandSeq") != seq ||
                    kv["lastCommandResult"] != "ok" ||
                    longField(kv, "commandErrors") != 0L
                ) {
                    throw FailClosed(
                        "command_${seq}_failed_${kv["lastCommandResult"]}"
                    )
                }
                return kv
            }

            // Generates `frames` deterministic pattern frames into writeBuf
            // from a stable local base cursor and ingests them; mirrors the
            // native accepted-side checksum over exactly the accepted leading
            // samples. The generator cursor advances only by the accepted
            // leading samples (never on a rejected window), so a retry
            // preserves and regenerates the same rejected logical window
            // instead of skipping it with fresh data. Returns the reply.
            fun ingestOnce(frames: Int, checksummed: Boolean): Map<String, String> {
                checkDeadline()
                val base = patternCounter
                for (i in 0 until frames * ch) {
                    val v = (((base + i) * 31L + 7L) % 24_001L - 12_000L).toInt().toShort()
                    writeBuf.putShort(i * 2, v)
                }
                val kv = parseStatus(
                    VanguardNativeBridge.ingestAsyncRuntimeQueueSchedulerPcm16(
                        activeHandle, writeBuf, frames,
                    )
                )
                if (kv["status"] != "ok") throw FailClosed("ingest_status_${kv["status"]}")
                val accepted = longField(kv, "framesAccepted")
                if (accepted > 0) {
                    if (checksummed) {
                        var c = kotlinChecksum
                        for (i in 0 until (accepted * ch).toInt()) {
                            c = c * 31L + (writeBuf.getShort(i * 2).toLong() and 0xFFFFL)
                        }
                        kotlinChecksum = c
                        kotlinFramesAccepted += accepted
                    }
                    patternCounter = base + accepted * ch
                }
                return kv
            }

            fun readOnce(maxFrames: Int): Map<String, String> {
                checkDeadline()
                val kv = parseStatus(
                    VanguardNativeBridge.readAsyncRuntimeQueueSchedulerOutputPcm16(
                        activeHandle, readBuf, maxFrames,
                    )
                )
                if (kv["status"] != "ok") throw FailClosed("read_status_${kv["status"]}")
                return kv
            }

            // Ingests until `targetTotal` frames have been accepted by the
            // writer for the active session, tolerating transient writer
            // backpressure by retrying the same rejected logical window
            // regenerated from the preserved generator cursor.
            fun ingestUntilAccepted(targetTotal: Long, checksummed: Boolean) {
                var acceptedTotal = -1L
                while (true) {
                    val want = if (acceptedTotal < 0) mfpm.toLong()
                    else minOf(mfpm.toLong(), targetTotal - acceptedTotal)
                    if (want <= 0L) break
                    val kv = ingestOnce(want.toInt(), checksummed)
                    acceptedTotal = longField(kv, "totalFramesAccepted")
                    if (acceptedTotal >= targetTotal) break
                    if (longField(kv, "framesAccepted") == 0L) {
                        Thread.sleep(POLL_SLEEP_MS)
                    }
                    checkDeadline()
                }
            }

            fun drainUntilRead(targetTotal: Long) {
                while (true) {
                    val kv = readOnce(readChunkFrames)
                    if (longField(kv, "totalOutputFramesRead") >= targetTotal) break
                    if (longField(kv, "framesRead") == 0L) {
                        Thread.sleep(POLL_SLEEP_MS)
                    }
                    checkDeadline()
                }
            }

            // ── Main session: create + worker identity ──────────────────────
            handle = VanguardNativeBridge.createAsyncRuntimeQueueSchedulerSession(
                sr, ch, expectedFrames,
                config.sourceRingCapacityFrames, config.outputRingCapacityFrames, mfpm,
            )
            if (handle == 0L) throw FailClosed("native_session_create_failed")
            activeHandle = handle

            val snapBoot = awaitSnapshot("worker_started") { it["workerStarted"] == "true" }
            if (snapBoot["workerThreadDistinct"] != "true") {
                throw FailClosed("worker_thread_not_distinct")
            }
            if (longField(snapBoot, "ownerDispatchCalls") != 0L) {
                throw FailClosed("owner_dispatch_calls_nonzero_at_boot")
            }

            // ── Start: enqueue -> worker executes -> owner acks via read ────
            val startKv = parseStatus(
                VanguardNativeBridge.startAsyncRuntimeQueueScheduler(
                    handle, 0L, ANCHOR_SYS_TIME_NS,
                )
            )
            if (startKv["status"] != "enqueued") {
                throw FailClosed("start_not_enqueued_${startKv["status"]}")
            }
            val snapStarted = awaitCommandProcessed(1L)
            if (snapStarted["started"] != "true" ||
                longField(snapStarted, "totalFramesRendered") != 0L
            ) {
                throw FailClosed("start_state_mismatch")
            }
            val startAck = readOnce(0)
            if (startAck["seekAckConsumed"] != "true" ||
                longField(startAck, "newStartFrame") != 0L ||
                longField(startAck, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("start_ack_not_consumed_cleanly")
            }

            // ── Phase A: async decoupling + output backpressure ─────────────
            // Feed 2x the output ring without reading: the worker advances
            // on its own thread, fills the output ring, then records
            // kBackpressure -- with zero owner dispatch calls.
            val phaseAFrames = phaseAWindows.toLong() * mfpm
            ingestUntilAccepted(phaseAFrames, checksummed = true)
            val snapBp = awaitSnapshot("output_backpressure") {
                longField(it, "backpressureCount") >= 1L &&
                    longField(it, "totalFramesPushed") >=
                    config.outputRingCapacityFrames.toLong()
            }
            t.outputBackpressureOk =
                longField(snapBp, "totalFramesPushed") ==
                config.outputRingCapacityFrames.toLong()
            if (!t.outputBackpressureOk) throw FailClosed("output_backpressure_overrun")
            t.asyncThreadDecouplingOk = snapBp["workerThreadDistinct"] == "true" &&
                longField(snapBp, "dispatchCount") >= 1L &&
                longField(snapBp, "totalFramesRendered") >= 1L &&
                longField(snapBp, "ownerDispatchCalls") == 0L
            if (!t.asyncThreadDecouplingOk) throw FailClosed("async_decoupling_not_observed")
            drainUntilRead(phaseAFrames)
            awaitSnapshot("phase_a_settled") {
                longField(it, "totalFramesPushed") == phaseAFrames &&
                    longField(it, "sourceAvailableReadFrames") == 0L
            }

            // ── Phase B: pause, source backpressure, resume ─────────────────
            var frameCursor = phaseAFrames
            val pauseTick = tickForFrame(frameCursor)
            val pauseKv = parseStatus(
                VanguardNativeBridge.pauseAsyncRuntimeQueueScheduler(handle, pauseTick)
            )
            if (pauseKv["status"] != "enqueued") {
                throw FailClosed("pause_not_enqueued_${pauseKv["status"]}")
            }
            val snapPaused = awaitCommandProcessed(2L)
            if (snapPaused["paused"] != "true") throw FailClosed("pause_state_mismatch")
            // Mirror the worker's pause re-anchor on the kotlin tick axis.
            anchorPtsUs = ceilPtsUs(frameCursor)
            anchorSysNs = pauseTick

            // Fill the paused source ring completely, then prove the writer
            // rejects the next full window (fail-closed source SPSC
            // backpressure; no frame is silently dropped mid-stream). The
            // rejected window does not advance the generator cursor, so the
            // exact same logical window is regenerated and accepted later --
            // the final checksum identity therefore covers it.
            val phaseBFrames = frameCursor + config.sourceRingCapacityFrames.toLong()
            ingestUntilAccepted(phaseBFrames, checksummed = true)
            val rejectKv = ingestOnce(mfpm, checksummed = true)
            if (longField(rejectKv, "framesAccepted") != 0L ||
                rejectKv["writerStatus"] != "ring_full" ||
                longField(rejectKv, "writerBackpressureRejects") < 1L
            ) {
                throw FailClosed("source_backpressure_not_observed_${rejectKv["writerStatus"]}")
            }
            t.sourceBackpressureOk = true
            frameCursor = phaseBFrames

            val resumeKv = parseStatus(
                VanguardNativeBridge.resumeAsyncRuntimeQueueScheduler(handle, pauseTick)
            )
            if (resumeKv["status"] != "enqueued") {
                throw FailClosed("resume_not_enqueued_${resumeKv["status"]}")
            }
            val snapResumed = awaitCommandProcessed(3L)
            if (snapResumed["paused"] != "false") throw FailClosed("resume_state_mismatch")
            drainUntilRead(frameCursor)
            awaitSnapshot("phase_b_settled") {
                longField(it, "totalFramesPushed") == frameCursor &&
                    longField(it, "sourceAvailableReadFrames") == 0L &&
                    longField(it, "outputAvailableReadFrames") == 0L &&
                    longField(it, "nextDispatchFrame") == frameCursor
            }

            // ── Phase C: forward-only seek over quiescent rings ─────────────
            val seekTargetFrame = frameCursor
            val seekPtsUs = ceilPtsUs(seekTargetFrame)
            val seekTick = tickForFrame(seekTargetFrame)
            val seekKv = parseStatus(
                VanguardNativeBridge.seekAsyncRuntimeQueueScheduler(
                    handle, seekPtsUs, seekTick,
                )
            )
            if (seekKv["status"] != "enqueued" ||
                longField(seekKv, "targetFrame") != seekTargetFrame
            ) {
                throw FailClosed("seek_not_enqueued_${seekKv["status"]}")
            }
            awaitCommandProcessed(4L)
            val seekAck = readOnce(0)
            if (seekAck["seekAckConsumed"] != "true" ||
                longField(seekAck, "newStartFrame") != seekTargetFrame ||
                longField(seekAck, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("seek_ack_not_consumed_cleanly")
            }
            t.seekEpochCoordinationOk = true
            anchorPtsUs = seekPtsUs
            anchorSysNs = seekTick

            // ── Phase D: feed the remaining timeline with interleaved reads ─
            while (kotlinFramesAccepted < expectedFrames) {
                val want = minOf(mfpm.toLong(), expectedFrames - kotlinFramesAccepted)
                val kv = ingestOnce(want.toInt(), checksummed = true)
                if (longField(kv, "framesAccepted") == 0L) {
                    Thread.sleep(POLL_SLEEP_MS)
                }
                readOnce(readChunkFrames)
                checkDeadline()
            }
            drainUntilRead(expectedFrames)

            // ── Final verdicts on the main session ──────────────────────────
            val snapFinal = awaitSnapshot("timeline_complete") {
                it["timelineComplete"] == "true" &&
                    longField(it, "totalFramesPushed") == expectedFrames &&
                    longField(it, "outputAvailableReadFrames") == 0L
            }
            t.workerThreadDistinct = snapFinal["workerThreadDistinct"] == "true"
            t.ownerDispatchCalls = longField(snapFinal, "ownerDispatchCalls")
            t.commandsEnqueued = longField(snapFinal, "commandsEnqueued")
            t.commandsProcessed = longField(snapFinal, "commandsProcessed")
            t.commandErrors = longField(snapFinal, "commandErrors")
            t.dispatchCount = longField(snapFinal, "dispatchCount")
            t.okCount = longField(snapFinal, "okCount")
            t.silenceCount = longField(snapFinal, "silenceCount")
            t.backpressureCount = longField(snapFinal, "backpressureCount")
            t.schedulerErrorCount = longField(snapFinal, "schedulerErrorCount")
            t.writerBackpressureRejects = longField(snapFinal, "writerBackpressureRejects")
            t.providerUnderrunEvents = longField(snapFinal, "providerUnderrunEvents")
            t.providerFramesZeroFilled = longField(snapFinal, "providerFramesZeroFilled")
            t.providerForwardSkipFrames = longField(snapFinal, "providerForwardSkipFrames")
            t.providerRewindRejects = longField(snapFinal, "providerRewindRejects")
            t.totalFramesAccepted = longField(snapFinal, "totalFramesAccepted")
            t.totalFramesRendered = longField(snapFinal, "totalFramesRendered")
            t.totalFramesPushed = longField(snapFinal, "totalFramesPushed")
            t.totalOutputFramesRead = longField(snapFinal, "totalOutputFramesRead")
            t.nativeAcceptedChecksumHex = snapFinal["nativeAcceptedChecksumHex"] ?: ""
            t.nativeOutputReadChecksumHex = snapFinal["nativeOutputReadChecksumHex"] ?: ""
            t.kotlinAcceptedChecksumHex = String.format("%016x", kotlinChecksum)

            if (snapFinal["terminal"] == "true") throw FailClosed("terminal_coordinator_state")
            if (t.schedulerErrorCount != 0L ||
                longField(snapFinal, "workerDispatchAnomalies") != 0L
            ) {
                throw FailClosed("worker_dispatch_anomalies_observed")
            }

            t.controlCommandSerializationOk = t.commandsEnqueued == 4L &&
                t.commandsProcessed == 4L &&
                t.commandErrors == 0L &&
                longField(snapFinal, "lastCommandSeq") == 4L &&
                longField(snapFinal, "queueDepth") == 0L
            if (!t.controlCommandSerializationOk) {
                throw FailClosed("command_serialization_mismatch")
            }

            t.checksumAccountingOk =
                t.kotlinAcceptedChecksumHex == t.nativeAcceptedChecksumHex &&
                t.kotlinAcceptedChecksumHex == t.nativeOutputReadChecksumHex &&
                t.totalFramesAccepted == expectedFrames &&
                t.totalFramesRendered == expectedFrames &&
                t.totalFramesPushed == expectedFrames &&
                t.totalOutputFramesRead == expectedFrames &&
                kotlinFramesAccepted == expectedFrames &&
                t.silenceCount == 0L &&
                t.providerFramesZeroFilled == 0L &&
                t.providerUnderrunEvents == 0L &&
                t.providerRewindRejects == 0L
            if (!t.checksumAccountingOk) throw FailClosed("checksum_accounting_mismatch")

            t.proofBoundaryOk = snapFinal["proofBoundary"] == PROOF_BOUNDARY
            if (!t.proofBoundaryOk) throw FailClosed("proof_boundary_mismatch")

            t.noOwnerThreadDispatchOk =
                t.ownerDispatchCalls == 0L && t.workerThreadDistinct
            if (!t.noOwnerThreadDispatchOk) throw FailClosed("owner_thread_dispatch_observed")

            // ── Destroy: join-on-destroy + idempotence ──────────────────────
            val destroyKv = parseStatus(
                VanguardNativeBridge.destroyAsyncRuntimeQueueSchedulerSession(handle)
            )
            t.workerJoinOnDestroyOk = destroyKv["status"] == "ok" &&
                destroyKv["workerJoined"] == "true" &&
                destroyKv["workerExited"] == "true" &&
                longField(destroyKv, "joinCount") == 1L
            if (!t.workerJoinOnDestroyOk) {
                throw FailClosed("worker_join_on_destroy_failed_${destroyKv["status"]}")
            }
            val destroyAgainKv = parseStatus(
                VanguardNativeBridge.destroyAsyncRuntimeQueueSchedulerSession(handle)
            )
            val postDestroySnapshotKv = parseStatus(
                VanguardNativeBridge.snapshotAsyncRuntimeQueueScheduler(handle)
            )
            handle = 0L
            t.idempotentDestroyOk = destroyAgainKv["status"] == "not_found" &&
                postDestroySnapshotKv["status"] == "not_found"
            if (!t.idempotentDestroyOk) throw FailClosed("destroy_not_idempotent")

            // ── Bounded zero-fill probe session (separate from identity) ────
            val probeExpected = 4L * mfpm
            val probeIngest = 2L * mfpm + mfpm / 2L
            val probeMissing = probeExpected - probeIngest
            probeHandle = VanguardNativeBridge.createAsyncRuntimeQueueSchedulerSession(
                sr, ch, probeExpected, 8 * mfpm, 8 * mfpm, mfpm,
            )
            if (probeHandle == 0L) throw FailClosed("probe_session_create_failed")
            activeHandle = probeHandle
            awaitSnapshot("probe_worker_started") { it["workerStarted"] == "true" }
            val probeStartKv = parseStatus(
                VanguardNativeBridge.startAsyncRuntimeQueueScheduler(
                    probeHandle, 0L, ANCHOR_SYS_TIME_NS,
                )
            )
            if (probeStartKv["status"] != "enqueued") {
                throw FailClosed("probe_start_not_enqueued")
            }
            awaitCommandProcessed(1L)
            val probeAck = readOnce(0)
            if (probeAck["seekAckConsumed"] != "true") {
                throw FailClosed("probe_start_ack_not_consumed")
            }
            ingestUntilAccepted(probeIngest, checksummed = false)
            val eosKv = parseStatus(
                VanguardNativeBridge.setAsyncRuntimeQueueSchedulerEos(probeHandle)
            )
            if (eosKv["status"] != "ok" || eosKv["eos"] != "true") {
                throw FailClosed("probe_eos_set_failed")
            }
            awaitSnapshot("probe_timeline_complete") {
                it["timelineComplete"] == "true" &&
                    longField(it, "totalFramesPushed") == probeExpected
            }
            drainUntilRead(probeExpected)
            val snapProbe = snapshot()
            t.probeZeroFillWindows = longField(snapProbe, "workerZeroFillProbeWindows")
            t.probeFramesZeroFilled = longField(snapProbe, "providerFramesZeroFilled")
            t.probeUnderrunEvents = longField(snapProbe, "providerUnderrunEvents")
            t.probeSilenceCount = longField(snapProbe, "silenceCount")
            t.probeFramesPushed = longField(snapProbe, "totalFramesPushed")
            t.probeFramesRead = longField(snapProbe, "totalOutputFramesRead")
            t.providerZeroFillAccountingOk =
                t.probeFramesZeroFilled == probeMissing &&
                t.probeUnderrunEvents == 2L &&
                t.probeSilenceCount == 1L &&
                t.probeZeroFillWindows == 2L &&
                t.probeFramesPushed == probeExpected &&
                t.probeFramesRead == probeExpected
            if (!t.providerZeroFillAccountingOk) {
                throw FailClosed("provider_zero_fill_accounting_mismatch")
            }
            val probeDestroyKv = parseStatus(
                VanguardNativeBridge.destroyAsyncRuntimeQueueSchedulerSession(probeHandle)
            )
            probeHandle = 0L
            if (probeDestroyKv["status"] != "ok" ||
                probeDestroyKv["workerJoined"] != "true"
            ) {
                throw FailClosed("probe_destroy_failed")
            }

            t.detailParts.add("mainWindows=${config.mainWindows}")
            t.detailParts.add("expectedFrames=$expectedFrames")
            t.detailParts.add("probeExpected=$probeExpected")
            t.detailParts.add("probeMissing=$probeMissing")

            return makePayload(t, pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makePayload(t, pass = false, failureReason = f.reason)
        } finally {
            if (handle != 0L) {
                try {
                    VanguardNativeBridge.destroyAsyncRuntimeQueueSchedulerSession(handle)
                } catch (_: Throwable) {}
            }
            if (probeHandle != 0L) {
                try {
                    VanguardNativeBridge.destroyAsyncRuntimeQueueSchedulerSession(probeHandle)
                } catch (_: Throwable) {}
            }
        }
    }

    private fun makePayload(
        t: Telemetry,
        pass: Boolean,
        failureReason: String,
    ): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "asyncThreadDecouplingOk" to t.asyncThreadDecouplingOk,
            "controlCommandSerializationOk" to t.controlCommandSerializationOk,
            "sourceBackpressureOk" to t.sourceBackpressureOk,
            "outputBackpressureOk" to t.outputBackpressureOk,
            "providerZeroFillAccountingOk" to t.providerZeroFillAccountingOk,
            "seekEpochCoordinationOk" to t.seekEpochCoordinationOk,
            "checksumAccountingOk" to t.checksumAccountingOk,
            "workerJoinOnDestroyOk" to t.workerJoinOnDestroyOk,
            "idempotentDestroyOk" to t.idempotentDestroyOk,
            "noOwnerThreadDispatchOk" to t.noOwnerThreadDispatchOk,
            "proofBoundaryOk" to t.proofBoundaryOk,
        )
        val metrics = mapOf<String, Any?>(
            "workerThreadDistinct" to t.workerThreadDistinct,
            "ownerDispatchCalls" to t.ownerDispatchCalls,
            "commandsEnqueued" to t.commandsEnqueued,
            "commandsProcessed" to t.commandsProcessed,
            "commandErrors" to t.commandErrors,
            "dispatchCount" to t.dispatchCount,
            "okCount" to t.okCount,
            "silenceCount" to t.silenceCount,
            "backpressureCount" to t.backpressureCount,
            "schedulerErrorCount" to t.schedulerErrorCount,
            "writerBackpressureRejects" to t.writerBackpressureRejects,
            "providerUnderrunEvents" to t.providerUnderrunEvents,
            "providerFramesZeroFilled" to t.providerFramesZeroFilled,
            "providerForwardSkipFrames" to t.providerForwardSkipFrames,
            "providerRewindRejects" to t.providerRewindRejects,
            "totalFramesAccepted" to t.totalFramesAccepted,
            "totalFramesRendered" to t.totalFramesRendered,
            "totalFramesPushed" to t.totalFramesPushed,
            "totalOutputFramesRead" to t.totalOutputFramesRead,
            "kotlinAcceptedChecksumHex" to t.kotlinAcceptedChecksumHex,
            "nativeAcceptedChecksumHex" to t.nativeAcceptedChecksumHex,
            "nativeOutputReadChecksumHex" to t.nativeOutputReadChecksumHex,
            "probeZeroFillWindows" to t.probeZeroFillWindows,
            "probeFramesZeroFilled" to t.probeFramesZeroFilled,
            "probeUnderrunEvents" to t.probeUnderrunEvents,
            "probeSilenceCount" to t.probeSilenceCount,
            "probeFramesPushed" to t.probeFramesPushed,
            "probeFramesRead" to t.probeFramesRead,
        )
        return mapOf(
            "pass" to pass,
            "status" to if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" },
            "marker" to if (pass) PASS_MARKER else FAIL_MARKER,
            "proofBoundary" to PROOF_BOUNDARY,
            "failureReason" to failureReason,
            "details" to t.detailParts.joinToString("|"),
            "lanes" to lanes,
            "metrics" to metrics,
            "lastError" to if (pass) null else failureReason.ifBlank { "fail" },
        )
    }

    private fun parseStatus(raw: String): Map<String, String> =
        raw.split(';').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx <= 0) null else part.substring(0, idx) to part.substring(idx + 1)
        }.toMap()

    private fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw FailClosed("missing_status_field_$key")
}
