package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.CreateResult
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.Reply
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.IngestRequest
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import com.connects.vanguard_media_engine.bridge.VanguardRealtimePlaybackNativeBridge
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-EXTERNAL-INGEST-SEAM (Y5a):
 * verification smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route. A Kotlin SYNTHETIC producer
 * (the same `referenceSample` identity the native generator uses) feeds one
 * external-ingest track of the production realtime playback graph session
 * through [VanguardRealtimePlaybackTransportStateMachine.ingest] /
 * [VanguardRealtimePlaybackTransportStateMachine.postIngest] (owner
 * HandlerThread only, generation pinned), while the other track stays
 * native-synthetic. Because the external PCM is bit-identical to what the
 * native generator would have produced, the mixed output must equal the
 * all-synthetic reference mix, which is the identity proof.
 *
 * This is NOT the decoder slice: no MediaCodec, no MediaExtractor, no
 * decoder lifecycle, no presentation clock, no A/V sync, no AudioTrack.
 *
 * Assertion lanes:
 * 1. Identity: preroll + steady-state ingest of the external track, drain to
 *    completion; pushed == drained == Kotlin reference checksum and every
 *    drained sample equals `referenceMixedSample`.
 * 2. Seek re-anchor: after a PREPARED seek the stale producer anchor is
 *    rejected (expected_start_mismatch, nothing written, reply carries the
 *    new nextWriteFrame); ingest at the new anchor succeeds and playback
 *    from the seek target matches the reference over [target, declared).
 * 3. Backpressure: an oversize ingest is clamped (partial_write, freeFrames
 *    0), a follow-up is ring_full with acceptedFrames 0 and an unchanged
 *    anchor, and the writer accepts again once the worker consumed frames.
 * 4. Direct-native guards on a raw session: wrong-owner thread, format
 *    mismatch, synthetic-track target, and heap buffer are all rejected;
 *    a subsequent owner ingest at frame 0 proves none of them mutated.
 * 5. External underrun is nonterminal: a starved external track leaves the
 *    session PLAYING with underrunCount > 0 and the cursor parked at the
 *    last complete window; feeding it resumes to a clean completion.
 * 6. Stale generation: a postIngest pinned to a pre-seek generation is
 *    rejected before JNI; ingest at the same anchor afterwards succeeds
 *    (no mutation), and a correctly pinned postIngest runs on the owner
 *    thread.
 * 7. Lifecycle: dispose rejects later ingest as disposed; raw native
 *    destroy joins the worker and a second destroy is session_closed.
 *
 * The native command_in_flight gate cannot be driven deterministically from
 * the owner thread (it blocks on every command ack) without an unrelated
 * test hook, so that lane is reported as source/mechanical only.
 */
class AndroidRealtimePlaybackIngestSeamSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY5aIngestSeam"
        const val METHOD_NAME = "runRealtimePlaybackIngestSeamSmoke"

        const val START_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_SMOKE_START"
        const val JSON_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_JSON"
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_INGEST_SEAM_PHYSICAL_SMOKE_FAIL"

        const val PROOF_BOUNDARY =
            "realtime_playback_external_ingest_seam_diagnostic_only_kotlin_synthetic_pcm_to_" +
                "y_series_native_source_ring_owner_thread_ingest_generation_pinned_no_mediacodec_" +
                "no_mediaextractor_no_decoder_lifecycle_no_presentation_clock_no_av_sync_" +
                "no_audio_quality_claim_no_latency_claim_no_fleet_claim_no_product_editor_app_wiring_" +
                "no_ios_no_streaming_cache_no_src_audio_primitive_changes"

        private const val SAMPLE_RATE = 48_000
        private const val CHANNEL_COUNT = 2
        private const val MAX_FRAMES_PER_MIX = 256
        private const val TRACK_COUNT = 2
        private const val EXTERNAL_TRACK = 1
        private const val EXTERNAL_MASK = 1 shl EXTERNAL_TRACK
        private const val DECLARED_FRAMES = 12_000L
        private const val CHUNK_FRAMES = 1_024
        private const val OVERSIZE_FRAMES = VanguardRealtimePlaybackNativeSession.MAX_INGEST_FRAMES
        private const val COMPLETION_DEADLINE_MS = 8_000L

        private const val LANE_IDENTITY = "ingestIdentityOk"
        private const val LANE_SEEK = "seekReanchorOk"
        private const val LANE_BACKPRESSURE = "backpressureOk"
        private const val LANE_GUARDS = "directNativeGuardsOk"
        private const val LANE_UNDERRUN = "underrunNonterminalOk"
        private const val LANE_STALE = "staleGenerationOk"
        private const val LANE_LIFECYCLE = "lifecycleDisposeOk"
        private val LANE_NAMES = listOf(
            LANE_IDENTITY, LANE_SEEK, LANE_BACKPRESSURE, LANE_GUARDS,
            LANE_UNDERRUN, LANE_STALE, LANE_LIFECYCLE,
        )

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME

        private fun config() = VanguardRealtimePlaybackNativeSession.Config(
            sampleRate = SAMPLE_RATE,
            channelCount = CHANNEL_COUNT,
            maxFramesPerMix = MAX_FRAMES_PER_MIX,
            trackCount = TRACK_COUNT,
            declaredFrameCount = DECLARED_FRAMES,
            externalIngestTrackMask = EXTERNAL_MASK,
        )

        private fun directPcmBuffer(frames: Int): ByteBuffer =
            ByteBuffer.allocateDirect(frames * 2 * CHANNEL_COUNT).order(ByteOrder.nativeOrder())

        // Kotlin synthetic producer: the exact native reference identity for
        // the external track, written as native-order PCM16 at offset 0.
        private fun fillReference(dst: ByteBuffer, startFrame: Long, frames: Int) {
            var i = 0
            for (f in 0 until frames) {
                for (c in 0 until CHANNEL_COUNT) {
                    dst.putShort(
                        i,
                        VanguardRealtimePlaybackNativeSession.referenceSample(EXTERNAL_TRACK, startFrame + f, c),
                    )
                    i += 2
                }
            }
        }

        private fun referenceChecksumHex(fromFrame: Long, toFrameExclusive: Long): String {
            var checksum = 0L
            for (f in fromFrame until toFrameExclusive) {
                for (c in 0 until CHANNEL_COUNT) {
                    val s = VanguardRealtimePlaybackNativeSession.referenceMixedSample(TRACK_COUNT, f, c)
                    checksum = checksum * 31L + (s.toLong() and 0xFFFFL)
                }
            }
            return String.format("%016x", checksum)
        }
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    @Volatile
    private var activeStateMachine: VanguardRealtimePlaybackTransportStateMachine? = null

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(method: String, args: Map<*, *>?, result: MethodChannel.Result): Boolean {
        if (method != METHOD_NAME) return false
        if (disposed.get()) {
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }
        if (!active.compareAndSet(false, true)) {
            result.error("P4_REALTIME_PLAYBACK_INGEST_SEAM_SMOKE_BUSY", "$METHOD_NAME: diagnostic already running", null)
            return true
        }
        runSmoke(result)
        return true
    }

    fun disposeAll() {
        disposed.set(true)
        try {
            activeStateMachine?.dispose()
        } catch (_: Throwable) {}
        activeStateMachine = null
    }

    private fun runSmoke(result: MethodChannel.Result) {
        val replied = AtomicBoolean(false)
        Thread({
            try {
                Log.i(TAG, START_MARKER)
                val payload = executeSmoke()
                logOutcome(payload)
                postReply(replied, result, payload)
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME uncaught failure", t)
                val failPayload = buildFailurePayload("uncaught_exception:${t.javaClass.simpleName}:${t.message}")
                logOutcome(failPayload)
                postReply(replied, result, failPayload)
            } finally {
                active.set(false)
            }
        }, "Y5aIngestSeamSmoke").start()
    }

    private fun logOutcome(payload: Map<String, Any?>) {
        try {
            val lanes = payload["lanes"] as? Map<*, *>
            val laneText = lanes?.entries?.joinToString(",") { "\"${it.key}\":${it.value}" } ?: ""
            Log.i(
                TAG,
                "$JSON_MARKER {\"pass\":${payload["pass"]},\"status\":\"${payload["status"]}\"," +
                    "\"failureReason\":\"${payload["failureReason"]}\",\"lanes\":{$laneText}}",
            )
            Log.i(TAG, payload["marker"]?.toString() ?: FAIL_MARKER)
        } catch (_: Throwable) {}
    }

    private fun postReply(replied: AtomicBoolean, result: MethodChannel.Result, payload: Map<String, Any?>) {
        if (disposed.get() || !replied.compareAndSet(false, true)) return
        mainHandler.post {
            if (disposed.get()) return@post
            try {
                result.success(payload)
            } catch (t: Throwable) {
                Log.w(TAG, "$METHOD_NAME reply dropped: ${t.javaClass.simpleName}")
            }
        }
    }

    // ── Shared producer / drain helpers ────────────────────────────────────

    private class Producer(private val sm: VanguardRealtimePlaybackTransportStateMachine, startFrame: Long) {
        var next: Long = startFrame
        var calls = 0
        var acceptedTotal = 0L
        var lastReason = ""
        private val src = directPcmBuffer(CHUNK_FRAMES)

        // Ingests contiguous reference chunks until the declared end or the
        // first short accept (ring full). False on a rejected result.
        fun pump(): Boolean {
            while (next < DECLARED_FRAMES) {
                val frames = minOf(CHUNK_FRAMES.toLong(), DECLARED_FRAMES - next).toInt()
                fillReference(src, next, frames)
                val res = sm.ingest(IngestRequest(EXTERNAL_TRACK, src, frames, next))
                calls++
                if (!res.accepted) {
                    lastReason = res.reason
                    return false
                }
                val reply = res.reply ?: return false
                acceptedTotal += reply.acceptedFrames
                next = reply.nextWriteFrame
                if (reply.acceptedFrames < frames) break
            }
            return true
        }
    }

    private class DrainStats {
        var drainCalls = 0
        var sampleMismatches = 0L
        var framesChecked = 0L
        var lastReply: Reply? = null
    }

    // Drains one window and (when `verifyFromFrame` >= 0) checks every popped
    // sample against the Kotlin reference mix starting at that timeline frame.
    private fun drainOnce(
        sm: VanguardRealtimePlaybackTransportStateMachine,
        dst: ByteBuffer,
        stats: DrainStats,
        verifyFromFrame: Long,
    ): VanguardRealtimePlaybackTransportStateMachine.Result {
        val res = sm.drain(dst, MAX_FRAMES_PER_MIX)
        stats.drainCalls++
        val reply = res.reply
        if (res.accepted && reply != null) {
            stats.lastReply = reply
            val frames = reply.framesRead.toInt()
            if (verifyFromFrame >= 0 && frames > 0) {
                val base = verifyFromFrame + reply.drainedFrames - frames
                var i = 0
                for (f in 0 until frames) {
                    for (c in 0 until CHANNEL_COUNT) {
                        val expected = VanguardRealtimePlaybackNativeSession.referenceMixedSample(TRACK_COUNT, base + f, c)
                        if (dst.getShort(i) != expected) stats.sampleMismatches++
                        i += 2
                    }
                }
                stats.framesChecked += frames
            }
        }
        return res
    }

    // Pumps the producer and drains until completion / failure / deadline.
    private fun runToCompletion(
        sm: VanguardRealtimePlaybackTransportStateMachine,
        producer: Producer,
        dst: ByteBuffer,
        stats: DrainStats,
        verifyFromFrame: Long,
    ): Boolean {
        val deadline = System.currentTimeMillis() + COMPLETION_DEADLINE_MS
        while (sm.currentState != State.COMPLETED && sm.currentState != State.FAILED &&
            sm.currentState != State.DISPOSED && !disposed.get() && System.currentTimeMillis() < deadline
        ) {
            if (!producer.pump()) return false
            val res = drainOnce(sm, dst, stats, verifyFromFrame)
            if (!res.accepted) return false
            if (res.state == State.COMPLETED) break
            Thread.sleep(2)
        }
        return sm.currentState == State.COMPLETED
    }

    // ── Lanes ──────────────────────────────────────────────────────────────

    private fun executeSmoke(): Map<String, Any?> {
        val lanes = linkedMapOf<String, Any?>()
        val metrics = linkedMapOf<String, Any?>()
        var failureReason = ""
        fun failLane(reason: String) {
            if (failureReason.isEmpty()) failureReason = reason
        }

        // Lane 1: identity after ingest/drain.
        var identityOk = false
        run {
            val sm = VanguardRealtimePlaybackTransportStateMachine(config(), threadName = "Y5aIdentity")
            val dst = directPcmBuffer(MAX_FRAMES_PER_MIX)
            val producer = Producer(sm, 0L)
            val stats = DrainStats()
            try {
                activeStateMachine = sm
                val loadOk = sm.load().accepted
                val prepOk = loadOk && sm.prepare().accepted
                val prerollOk = prepOk && producer.pump()
                val prerollNext = producer.next
                val startOk = prerollOk && sm.start().accepted
                val completed = startOk && runToCompletion(sm, producer, dst, stats, 0L)
                val final = sm.snapshot().reply ?: stats.lastReply
                val refHex = referenceChecksumHex(0L, DECLARED_FRAMES)
                identityOk = completed && final != null &&
                    final.state == VanguardRealtimePlaybackNativeSession.NativeState.COMPLETED &&
                    final.renderedFrames == DECLARED_FRAMES && final.pushedFrames == DECLARED_FRAMES &&
                    final.drainedFrames == DECLARED_FRAMES && final.eosPushed && final.eosDrained &&
                    final.pushedChecksumHex == final.drainedChecksumHex && final.drainedChecksumHex == refHex &&
                    final.externalIngestTrackMask == EXTERNAL_MASK &&
                    producer.acceptedTotal == DECLARED_FRAMES && producer.next == DECLARED_FRAMES &&
                    stats.sampleMismatches == 0L && stats.framesChecked == DECLARED_FRAMES
                metrics["identityPrerollFrames"] = prerollNext
                metrics["identityIngestCalls"] = producer.calls
                metrics["identityAcceptedFrames"] = producer.acceptedTotal
                metrics["identityDrainCalls"] = stats.drainCalls
                metrics["identitySampleMismatches"] = stats.sampleMismatches
                metrics["identityUnderrunCount"] = final?.underrunCount ?: -1L
                metrics["identityPushedChecksumHex"] = final?.pushedChecksumHex ?: ""
                metrics["identityDrainedChecksumHex"] = final?.drainedChecksumHex ?: ""
                metrics["identityReferenceChecksumHex"] = refHex
                metrics["identityFinalState"] = sm.currentState.name
                metrics["identityProducerLastReason"] = producer.lastReason
                if (!identityOk) failLane("identity_failed:${sm.currentState.name.lowercase()}:${final?.lastError}")
            } catch (t: Throwable) {
                failLane("lane1_identity_exception:${t.message}")
            } finally {
                sm.dispose()
                activeStateMachine = null
            }
        }
        lanes[LANE_IDENTITY] = identityOk

        // Lane 2: seek re-anchor via expectedStartFrame.
        var seekOk = false
        run {
            val seekTarget = 6_000L
            val sm = VanguardRealtimePlaybackTransportStateMachine(config(), threadName = "Y5aSeek")
            val dst = directPcmBuffer(MAX_FRAMES_PER_MIX)
            val src = directPcmBuffer(CHUNK_FRAMES)
            try {
                activeStateMachine = sm
                val loadOk = sm.load().accepted
                val prepOk = loadOk && sm.prepare().accepted
                fillReference(src, 0L, CHUNK_FRAMES)
                val first = sm.ingest(IngestRequest(EXTERNAL_TRACK, src, CHUNK_FRAMES, 0L))
                val firstOk = prepOk && first.accepted && first.reply?.acceptedFrames == CHUNK_FRAMES.toLong()
                val seekRes = sm.seek(seekTarget)
                val seekAccepted = seekRes.accepted && seekRes.state == State.PREPARED
                fillReference(src, CHUNK_FRAMES.toLong(), CHUNK_FRAMES)
                val stale = sm.ingest(IngestRequest(EXTERNAL_TRACK, src, CHUNK_FRAMES, CHUNK_FRAMES.toLong()))
                val staleRejected = !stale.accepted &&
                    stale.reason == "ingest_expected_start_mismatch" &&
                    stale.reply?.status == VanguardRealtimePlaybackNativeSession.STATUS_EXPECTED_START_MISMATCH &&
                    stale.reply.acceptedFrames == 0L && stale.reply.nextWriteFrame == seekTarget &&
                    sm.currentState == State.PREPARED
                val producer = Producer(sm, seekTarget)
                val reanchorOk = producer.pump() && producer.next > seekTarget
                val startOk = reanchorOk && sm.start().accepted
                val stats = DrainStats()
                val completed = startOk && runToCompletion(sm, producer, dst, stats, seekTarget)
                val final = sm.snapshot().reply ?: stats.lastReply
                val refHex = referenceChecksumHex(seekTarget, DECLARED_FRAMES)
                val expectedFrames = DECLARED_FRAMES - seekTarget
                seekOk = firstOk && seekAccepted && staleRejected && completed && final != null &&
                    final.renderedFrames == expectedFrames && final.drainedFrames == expectedFrames &&
                    final.positionFrame == DECLARED_FRAMES && final.eosDrained &&
                    final.pushedChecksumHex == final.drainedChecksumHex && final.drainedChecksumHex == refHex &&
                    stats.sampleMismatches == 0L && stats.framesChecked == expectedFrames
                metrics["seekFirstIngestOk"] = firstOk
                metrics["seekAccepted"] = seekAccepted
                metrics["seekStaleAnchorRejected"] = staleRejected
                metrics["seekStaleStatus"] = stale.reply?.status ?: stale.reason
                metrics["seekStaleNextWriteFrame"] = stale.reply?.nextWriteFrame ?: -1L
                metrics["seekReanchorNext"] = producer.next
                metrics["seekDrainedFrames"] = final?.drainedFrames ?: -1L
                metrics["seekReferenceChecksumHex"] = refHex
                metrics["seekDrainedChecksumHex"] = final?.drainedChecksumHex ?: ""
                metrics["seekSampleMismatches"] = stats.sampleMismatches
                if (!seekOk) failLane("seek_reanchor_failed:${sm.currentState.name.lowercase()}:${producer.lastReason}")
            } catch (t: Throwable) {
                failLane("lane2_seek_exception:${t.message}")
            } finally {
                sm.dispose()
                activeStateMachine = null
            }
        }
        lanes[LANE_SEEK] = seekOk

        // Lane 3: ring-full / partial-write backpressure and recovery.
        var backpressureOk = false
        run {
            val sm = VanguardRealtimePlaybackTransportStateMachine(config(), threadName = "Y5aBackpressure")
            val big = directPcmBuffer(OVERSIZE_FRAMES)
            val small = directPcmBuffer(MAX_FRAMES_PER_MIX)
            val dst = directPcmBuffer(MAX_FRAMES_PER_MIX)
            try {
                activeStateMachine = sm
                val prepOk = sm.load().accepted && sm.prepare().accepted
                fillReference(big, 0L, OVERSIZE_FRAMES)
                val partial = sm.ingest(IngestRequest(EXTERNAL_TRACK, big, OVERSIZE_FRAMES, 0L))
                val pr = partial.reply
                val partialOk = prepOk && partial.accepted && pr != null &&
                    pr.status == VanguardRealtimePlaybackNativeSession.STATUS_PARTIAL_WRITE &&
                    pr.acceptedFrames in 1L until OVERSIZE_FRAMES.toLong() &&
                    pr.nextWriteFrame == pr.acceptedFrames && pr.freeFrames == 0L
                val anchor = pr?.nextWriteFrame ?: 0L
                fillReference(small, anchor, MAX_FRAMES_PER_MIX)
                val full = sm.ingest(IngestRequest(EXTERNAL_TRACK, small, MAX_FRAMES_PER_MIX, anchor))
                val fr = full.reply
                val fullOk = full.accepted && fr != null &&
                    fr.status == VanguardRealtimePlaybackNativeSession.STATUS_RING_FULL &&
                    fr.acceptedFrames == 0L && fr.nextWriteFrame == anchor && fr.freeFrames == 0L &&
                    sm.currentState == State.PREPARED
                // Recovery: once the worker consumed windows, the same anchor is accepted.
                val startOk = sm.start().accepted
                var recovered: Reply? = null
                if (startOk) {
                    val deadline = System.currentTimeMillis() + 2_000L
                    while (System.currentTimeMillis() < deadline && recovered == null) {
                        sm.drain(dst, MAX_FRAMES_PER_MIX)
                        val snap = sm.snapshot().reply
                        if (snap != null && snap.dispatchCount > 0L) {
                            val r = sm.ingest(IngestRequest(EXTERNAL_TRACK, small, MAX_FRAMES_PER_MIX, anchor))
                            if (r.accepted && r.reply != null && r.reply.acceptedFrames > 0L) recovered = r.reply
                            else if (!r.accepted) break
                        }
                        Thread.sleep(5)
                    }
                }
                val recoveryOk = recovered != null && sm.currentState == State.PLAYING
                backpressureOk = partialOk && fullOk && startOk && recoveryOk
                metrics["backpressurePartialStatus"] = pr?.status ?: partial.reason
                metrics["backpressurePartialAccepted"] = pr?.acceptedFrames ?: -1L
                metrics["backpressurePartialFreeFrames"] = pr?.freeFrames ?: -1L
                metrics["backpressureFullStatus"] = fr?.status ?: full.reason
                metrics["backpressureFullAccepted"] = fr?.acceptedFrames ?: -1L
                metrics["backpressureRecoveryAccepted"] = recovered?.acceptedFrames ?: -1L
                metrics["backpressureRecoveryStatus"] = recovered?.status ?: "none"
                if (!backpressureOk) failLane("backpressure_failed:${sm.currentState.name.lowercase()}")
            } catch (t: Throwable) {
                failLane("lane3_backpressure_exception:${t.message}")
            } finally {
                sm.dispose()
                activeStateMachine = null
            }
        }
        lanes[LANE_BACKPRESSURE] = backpressureOk

        // Lane 4 (+7 native half): direct-native guards on a raw owner session.
        var guardsOk = false
        var nativeDestroyOk = false
        run {
            var session: VanguardRealtimePlaybackNativeSession? = null
            try {
                when (val created = VanguardRealtimePlaybackNativeSession.create(config())) {
                    is CreateResult.Success -> {
                        val s = created.session
                        session = s
                        val prepOk = s.prepare().ok
                        val src = directPcmBuffer(MAX_FRAMES_PER_MIX)
                        fillReference(src, 0L, MAX_FRAMES_PER_MIX)

                        var wrongOwner: Reply? = null
                        val latch = CountDownLatch(1)
                        Thread({
                            try {
                                wrongOwner = s.ingest(EXTERNAL_TRACK, src, MAX_FRAMES_PER_MIX, 0L)
                            } finally {
                                latch.countDown()
                            }
                        }, "Y5aWrongOwnerProbe").start()
                        latch.await(3_000L, TimeUnit.MILLISECONDS)
                        val wrongOwnerOk = wrongOwner?.status == VanguardRealtimePlaybackNativeSession.STATUS_WRONG_OWNER_THREAD &&
                            wrongOwner?.wrongOwnerThread == true

                        val formatRaw = VanguardRealtimePlaybackNativeBridge.ingestRealtimePlaybackGraphSessionExternalPcm16(
                            s.handle, EXTERNAL_TRACK, src, MAX_FRAMES_PER_MIX, 44_100, CHANNEL_COUNT, 0L,
                        )
                        val format = VanguardRealtimePlaybackNativeSession.parseReply(formatRaw)
                        val formatOk = format.status == VanguardRealtimePlaybackNativeSession.STATUS_FORMAT_MISMATCH &&
                            format.acceptedFrames == 0L
                        val synthetic = s.ingest(0, src, MAX_FRAMES_PER_MIX, 0L)
                        val syntheticOk = synthetic.status == VanguardRealtimePlaybackNativeSession.STATUS_TRACK_NOT_EXTERNAL
                        val heap = s.ingest(EXTERNAL_TRACK, ByteBuffer.allocate(MAX_FRAMES_PER_MIX * 2 * CHANNEL_COUNT), MAX_FRAMES_PER_MIX, 0L)
                        val heapOk = heap.status == "non_direct_buffer"
                        // None of the rejections moved the writer: frame 0 is still the anchor.
                        val owner = s.ingest(EXTERNAL_TRACK, src, MAX_FRAMES_PER_MIX, 0L)
                        val noMutationOk = owner.ok && owner.acceptedFrames == MAX_FRAMES_PER_MIX.toLong() &&
                            owner.nextWriteFrame == MAX_FRAMES_PER_MIX.toLong() && owner.ingestTrack == EXTERNAL_TRACK
                        guardsOk = prepOk && wrongOwnerOk && formatOk && syntheticOk && heapOk && noMutationOk
                        metrics["guardWrongOwnerStatus"] = wrongOwner?.status ?: "none"
                        metrics["guardFormatMismatchStatus"] = format.status
                        metrics["guardSyntheticTrackStatus"] = synthetic.status
                        metrics["guardHeapBufferStatus"] = heap.status
                        metrics["guardOwnerIngestStatus"] = owner.status
                        metrics["guardOwnerNextWriteFrame"] = owner.nextWriteFrame

                        val firstDestroy = s.destroy()
                        val secondDestroy = s.destroy()
                        nativeDestroyOk = firstDestroy.status == VanguardRealtimePlaybackNativeSession.STATUS_OK &&
                            firstDestroy.workerJoined && firstDestroy.workerExited &&
                            secondDestroy.status == VanguardRealtimePlaybackNativeSession.STATUS_SESSION_CLOSED
                        metrics["nativeFirstDestroyStatus"] = firstDestroy.status
                        metrics["nativeFirstDestroyWorkerJoined"] = firstDestroy.workerJoined
                        metrics["nativeSecondDestroyStatus"] = secondDestroy.status
                    }
                    is CreateResult.Failure -> failLane("lane4_create_failed:${created.failure.name.lowercase()}")
                }
                if (!guardsOk) failLane("direct_native_guards_failed")
            } catch (t: Throwable) {
                failLane("lane4_guards_exception:${t.message}")
            } finally {
                session?.destroy()
            }
        }
        lanes[LANE_GUARDS] = guardsOk

        // Lane 5: external underrun is nonterminal and recovers.
        var underrunOk = false
        run {
            val prerollFrames = 512
            val sm = VanguardRealtimePlaybackTransportStateMachine(config(), threadName = "Y5aUnderrun")
            val dst = directPcmBuffer(MAX_FRAMES_PER_MIX)
            val src = directPcmBuffer(prerollFrames)
            try {
                activeStateMachine = sm
                val prepOk = sm.load().accepted && sm.prepare().accepted
                fillReference(src, 0L, prerollFrames)
                val preroll = sm.ingest(IngestRequest(EXTERNAL_TRACK, src, prerollFrames, 0L))
                val prerollOk = prepOk && preroll.accepted && preroll.reply?.acceptedFrames == prerollFrames.toLong()
                val startOk = prerollOk && sm.start().accepted
                val stats = DrainStats()
                val holdUntil = System.currentTimeMillis() + 150L
                while (startOk && System.currentTimeMillis() < holdUntil && sm.currentState == State.PLAYING) {
                    drainOnce(sm, dst, stats, 0L)
                    Thread.sleep(5)
                }
                val starved = sm.snapshot().reply
                val starvedOk = starved != null && sm.currentState == State.PLAYING &&
                    starved.state == VanguardRealtimePlaybackNativeSession.NativeState.PLAYING &&
                    starved.underrunCount > 0L && starved.positionFrame == prerollFrames.toLong() &&
                    starved.pushedFrames == prerollFrames.toLong() && starved.lastError == "none"
                val producer = Producer(sm, prerollFrames.toLong())
                val completed = starvedOk && runToCompletion(sm, producer, dst, stats, 0L)
                val final = sm.snapshot().reply ?: stats.lastReply
                val refHex = referenceChecksumHex(0L, DECLARED_FRAMES)
                underrunOk = completed && final != null && final.drainedFrames == DECLARED_FRAMES &&
                    final.pushedChecksumHex == final.drainedChecksumHex && final.drainedChecksumHex == refHex &&
                    stats.sampleMismatches == 0L && stats.framesChecked == DECLARED_FRAMES
                metrics["underrunPrerollOk"] = prerollOk
                metrics["underrunStarvedState"] = starved?.stateToken ?: "none"
                metrics["underrunStarvedUnderrunCount"] = starved?.underrunCount ?: -1L
                metrics["underrunStarvedPositionFrame"] = starved?.positionFrame ?: -1L
                metrics["underrunStarvedPushedFrames"] = starved?.pushedFrames ?: -1L
                metrics["underrunFinalUnderrunCount"] = final?.underrunCount ?: -1L
                metrics["underrunFinalDrainedChecksumHex"] = final?.drainedChecksumHex ?: ""
                metrics["underrunSampleMismatches"] = stats.sampleMismatches
                if (!underrunOk) failLane("underrun_nonterminal_failed:${sm.currentState.name.lowercase()}:${producer.lastReason}")
            } catch (t: Throwable) {
                failLane("lane5_underrun_exception:${t.message}")
            } finally {
                sm.dispose()
                activeStateMachine = null
            }
        }
        lanes[LANE_UNDERRUN] = underrunOk

        // Lane 6 + 7: stale generation before JNI, then lifecycle dispose.
        var staleOk = false
        var disposeOk = false
        run {
            val anchor = 1_000L
            val sm = VanguardRealtimePlaybackTransportStateMachine(config(), threadName = "Y5aStaleGen")
            val src = directPcmBuffer(MAX_FRAMES_PER_MIX)
            try {
                activeStateMachine = sm
                val prepOk = sm.load().accepted && sm.prepare().accepted
                val staleGeneration = sm.currentGeneration
                val seekOkLocal = prepOk && sm.seek(anchor).accepted && sm.currentGeneration != staleGeneration
                fillReference(src, anchor, MAX_FRAMES_PER_MIX)

                var staleResult: VanguardRealtimePlaybackTransportStateMachine.Result? = null
                val staleLatch = CountDownLatch(1)
                val posted = sm.postIngest(
                    IngestRequest(EXTERNAL_TRACK, src, MAX_FRAMES_PER_MIX, anchor),
                    expectedGeneration = staleGeneration,
                ) { r ->
                    staleResult = r
                    staleLatch.countDown()
                }
                staleLatch.await(3_000L, TimeUnit.MILLISECONDS)
                val staleRejected = posted && staleResult?.accepted == false &&
                    staleResult?.reason == VanguardRealtimePlaybackTransportStateMachine.REASON_STALE_GENERATION &&
                    staleResult?.reply == null

                // Same anchor accepted afterwards => the stale post never reached JNI.
                var pinnedResult: VanguardRealtimePlaybackTransportStateMachine.Result? = null
                var pinnedOnOwner = false
                val pinnedLatch = CountDownLatch(1)
                sm.postIngest(
                    IngestRequest(EXTERNAL_TRACK, src, MAX_FRAMES_PER_MIX, anchor),
                    expectedGeneration = sm.currentGeneration,
                ) { r ->
                    pinnedResult = r
                    pinnedOnOwner = sm.isOwnerThread
                    pinnedLatch.countDown()
                }
                pinnedLatch.await(3_000L, TimeUnit.MILLISECONDS)
                val pinnedOk = pinnedResult?.accepted == true && pinnedOnOwner &&
                    pinnedResult?.reply?.acceptedFrames == MAX_FRAMES_PER_MIX.toLong() &&
                    pinnedResult?.reply?.nextWriteFrame == anchor + MAX_FRAMES_PER_MIX
                staleOk = seekOkLocal && staleRejected && pinnedOk
                metrics["staleGenerationPinned"] = staleGeneration
                metrics["staleCurrentGeneration"] = sm.currentGeneration
                metrics["staleResultReason"] = staleResult?.reason ?: "none"
                metrics["stalePinnedIngestStatus"] = pinnedResult?.reply?.status ?: pinnedResult?.reason ?: "none"
                metrics["stalePinnedOnOwnerThread"] = pinnedOnOwner
                if (!staleOk) failLane("stale_generation_failed")

                // Lifecycle: dispose, then every later ingest is rejected as disposed.
                sm.dispose()
                val afterDispose = sm.ingest(IngestRequest(EXTERNAL_TRACK, src, MAX_FRAMES_PER_MIX, anchor))
                val postAfterDispose = sm.postIngest(IngestRequest(EXTERNAL_TRACK, src, MAX_FRAMES_PER_MIX, anchor))
                disposeOk = sm.currentState == State.DISPOSED && !afterDispose.accepted &&
                    afterDispose.reason == VanguardRealtimePlaybackTransportStateMachine.REASON_DISPOSED &&
                    !postAfterDispose && nativeDestroyOk
                metrics["disposeState"] = sm.currentState.name
                metrics["disposeIngestReason"] = afterDispose.reason
                metrics["disposePostIngestPosted"] = postAfterDispose
                if (!disposeOk) failLane("lifecycle_dispose_failed")
            } catch (t: Throwable) {
                failLane("lane6_stale_generation_exception:${t.message}")
            } finally {
                sm.dispose()
                activeStateMachine = null
            }
        }
        lanes[LANE_STALE] = staleOk
        lanes[LANE_LIFECYCLE] = disposeOk

        // The owner thread blocks for every command ack, so command_in_flight
        // cannot be provoked deterministically without a foreign test hook.
        metrics["commandInFlightGateProof"] = "source_mechanical_only"

        val pass = LANE_NAMES.all { lanes[it] == true }
        lanes["proofBoundaryOk"] = true
        lanes["canonical"] = pass
        val status = if (pass) "pass" else "fail"
        val marker = if (pass) PASS_MARKER else FAIL_MARKER
        return mapOf(
            "pass" to pass,
            "status" to status,
            "marker" to marker,
            "proofBoundary" to PROOF_BOUNDARY,
            "nativeProofBoundary" to PROOF_BOUNDARY,
            "failureReason" to if (pass) "" else failureReason.ifBlank { "smoke_failed" },
            "details" to "Y5a realtime playback external ingest seam harness pass=$pass",
            "lanes" to lanes,
            "metrics" to metrics,
            "lastError" to if (pass) null else failureReason.ifBlank { "smoke_failed" },
            "raw" to "pass=$pass;status=$status;marker=$marker",
        )
    }

    private fun buildFailurePayload(reason: String): Map<String, Any?> {
        val lanes = linkedMapOf<String, Any?>()
        for (name in LANE_NAMES) lanes[name] = false
        lanes["proofBoundaryOk"] = false
        lanes["canonical"] = false
        return mapOf(
            "pass" to false,
            "status" to "fail",
            "marker" to FAIL_MARKER,
            "proofBoundary" to PROOF_BOUNDARY,
            "nativeProofBoundary" to PROOF_BOUNDARY,
            "failureReason" to reason,
            "details" to reason,
            "lanes" to lanes,
            "metrics" to mapOf("failureReason" to reason),
            "lastError" to reason,
            "raw" to "pass=false;status=fail;marker=$FAIL_MARKER;reason=$reason",
        )
    }
}
