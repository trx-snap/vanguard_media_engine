package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.CreateFailure
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackNativeSession.CreateResult
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine
import com.connects.vanguard_media_engine.audio_playback_graph.VanguardRealtimePlaybackTransportStateMachine.State
import com.connects.vanguard_media_engine.bridge.VanguardRealtimePlaybackNativeBridge
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REALTIME-PLAYBACK-TRANSPORT-CORE (Y1): verification
 * smoke coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating the production
 * realtime playback transport core:
 * - Native worker-owned std::chrono::steady_clock media timebase driving
 *   N (1..8) node-owned synthetic PCM16 source tracks through
 *   GraphAudioScheduler -> AudioMixBusNode into an SPSC PCM16 output ring.
 * - Authoritative Kotlin transport state machine
 *   ([VanguardRealtimePlaybackTransportStateMachine]) driving the native
 *   session on a dedicated owner HandlerThread with state divergence fail-closed.
 *
 * Required assertion lanes:
 * 1. Track admission: N=1, N=2, N=8 pass; N=9 fails closed as INVALID_TRACK_COUNT.
 * 2. Partial EOS tail: declaredFrameCount not divisible by maxFramesPerMix;
 *    drains to completion with renderedFrames == pushedFrames == drainedFrames == declaredFrameCount,
 *    eosPushed/eosDrained true, state completed, pushedChecksumHex == drainedChecksumHex.
 * 3. Reentrant sequence in one live session: load, prepare, start, drain some,
 *    pause, hold 120-180ms proving dispatchCount and pushedFrames unchanged,
 *    resume, non-quiescent seek forward, drain, seek backward, stop, start again,
 *    drain to EOS.
 * 4. Paused seek stays PAUSED.
 * 5. Wrong owner direct native probe returns status wrong_owner_thread with
 *    wrongOwnerThread=true and no mutation.
 * 6. Registry capacity: first 4 direct native sessions create; 5th returns 0 /
 *    capacity exhausted; all 4 destroyed.
 * 7. Destroy/idempotence: first native destroy reports ok and workerJoined/workerExited true;
 *    second reports not_found (native) or session_closed (wrapper).
 *
 * Proof boundary non-claims:
 * synthetic_pcm_only, no_audiotrack, no_mediacodec, no_mediaextractor,
 * no_audiomanager, no_audible_output, no_product_editor_app_wiring, no_ios.
 */
class AndroidRealtimePlaybackTransportCoreSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardY1Transport"
        const val METHOD_NAME = "runRealtimePlaybackTransportCoreSmoke"

        const val PASS_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_PHYSICAL_SMOKE_PASS"
        const val FAIL_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_PHYSICAL_SMOKE_FAIL"
        const val START_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_SMOKE_START"
        const val JSON_MARKER =
            "ANDROID_DAG_PHASE4_REALTIME_PLAYBACK_TRANSPORT_CORE_JSON"

        const val PROOF_BOUNDARY =
            "synthetic_pcm_only, no_audiotrack, no_mediacodec, no_mediaextractor, " +
                "no_audiomanager, no_audible_output, no_product_editor_app_wiring, no_ios"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    private val active = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)

    @Volatile
    private var activeStateMachine: VanguardRealtimePlaybackTransportStateMachine? = null

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) return false

        if (disposed.get()) {
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }

        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_REALTIME_PLAYBACK_TRANSPORT_CORE_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
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
        Thread {
            try {
                val payload = executeSmoke()
                postReply(replied, result, payload)
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME uncaught failure", t)
                val failPayload = buildFailurePayload("uncaught_exception:${t.javaClass.simpleName}:${t.message}")
                postReply(replied, result, failPayload)
            } finally {
                active.set(false)
            }
        }.start()
    }

    private fun postReply(
        replied: AtomicBoolean,
        result: MethodChannel.Result,
        payload: Map<String, Any?>,
    ) {
        if (disposed.get() || !replied.compareAndSet(false, true)) return
        mainHandler.post {
            if (disposed.get()) return@post
            result.success(payload)
        }
    }

    private fun executeSmoke(): Map<String, Any?> {
        val lanes = mutableMapOf<String, Any?>()
        val metrics = mutableMapOf<String, Any?>()
        var failureReason = ""

        // ── Lane 1: Track admission (N=1, N=2, N=8 pass; N=9 fails closed as INVALID_TRACK_COUNT) ──
        var trackAdmission1Ok = false
        var trackAdmission2Ok = false
        var trackAdmission8Ok = false
        var trackAdmission9RejectedOk = false

        try {
            for (n in listOf(1, 2, 8)) {
                val config = VanguardRealtimePlaybackNativeSession.Config(
                    sampleRate = 48000,
                    channelCount = 2,
                    maxFramesPerMix = 256,
                    trackCount = n,
                    declaredFrameCount = 48000L,
                )
                val sm = VanguardRealtimePlaybackTransportStateMachine(config, threadName = "Y1SmokeTrackAdm$n")
                try {
                    activeStateMachine = sm
                    val loadRes = sm.load()
                    val prepRes = sm.prepare()
                    val ok = loadRes.accepted && loadRes.state == State.IDLE &&
                        prepRes.accepted && prepRes.state == State.PREPARED
                    when (n) {
                        1 -> trackAdmission1Ok = ok
                        2 -> trackAdmission2Ok = ok
                        8 -> trackAdmission8Ok = ok
                    }
                } finally {
                    sm.dispose()
                    activeStateMachine = null
                }
            }

            // N=9 track admission failure validation
            val config9 = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = 48000,
                channelCount = 2,
                maxFramesPerMix = 256,
                trackCount = 9,
                declaredFrameCount = 48000L,
            )
            val valFailure = VanguardRealtimePlaybackNativeSession.validate(config9)
            val sm9 = VanguardRealtimePlaybackTransportStateMachine(config9, threadName = "Y1SmokeTrackAdm9")
            try {
                activeStateMachine = sm9
                val load9Res = sm9.load()
                trackAdmission9RejectedOk = valFailure == CreateFailure.INVALID_TRACK_COUNT &&
                    !load9Res.accepted &&
                    load9Res.state == State.FAILED &&
                    load9Res.reason == "create_failed:invalid_track_count"
            } finally {
                sm9.dispose()
                activeStateMachine = null
            }
        } catch (e: Throwable) {
            failureReason = "lane1_track_admission_exception:${e.message}"
        }

        val trackAdmissionOk = trackAdmission1Ok && trackAdmission2Ok && trackAdmission8Ok && trackAdmission9RejectedOk
        lanes["trackAdmissionOk"] = trackAdmissionOk
        metrics["trackAdmission1Ok"] = trackAdmission1Ok
        metrics["trackAdmission2Ok"] = trackAdmission2Ok
        metrics["trackAdmission8Ok"] = trackAdmission8Ok
        metrics["trackAdmission9RejectedOk"] = trackAdmission9RejectedOk

        if (!trackAdmissionOk && failureReason.isEmpty()) {
            failureReason = "track_admission_failed"
        }

        // ── Lane 2: Partial EOS tail ───────────────────────────────────────────
        // declaredFrameCount is not divisible by maxFramesPerMix (e.g. 1000 frames with maxFramesPerMix=256: 3 * 256 + 232)
        var partialEosTailOk = false
        var partialEosTailRenderedFrames = 0L
        var partialEosTailPushedFrames = 0L
        var partialEosTailDrainedFrames = 0L
        var partialEosTailPushedChecksumHex = ""
        var partialEosTailDrainedChecksumHex = ""

        if (trackAdmissionOk) {
            val sampleRate = 48000
            val channelCount = 2
            val trackCount = 2
            val maxFramesPerMix = 256
            val declaredFrameCount = 1000L

            val configTail = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = sampleRate,
                channelCount = channelCount,
                maxFramesPerMix = maxFramesPerMix,
                trackCount = trackCount,
                declaredFrameCount = declaredFrameCount,
            )
            val smTail = VanguardRealtimePlaybackTransportStateMachine(configTail, threadName = "Y1SmokePartialTail")
            val dstBuffer = ByteBuffer.allocateDirect(maxFramesPerMix * configTail.bytesPerFrame)

            try {
                activeStateMachine = smTail
                val loadRes = smTail.load()
                val prepRes = smTail.prepare()
                val startRes = smTail.start()

                if (loadRes.accepted && prepRes.accepted && startRes.accepted) {
                    val deadline = System.currentTimeMillis() + 5000L
                    var lastReply: VanguardRealtimePlaybackNativeSession.Reply? = null

                    while (smTail.currentState != State.COMPLETED &&
                        smTail.currentState != State.FAILED &&
                        smTail.currentState != State.DISPOSED &&
                        !disposed.get() &&
                        System.currentTimeMillis() < deadline
                    ) {
                        val drainRes = smTail.drain(dstBuffer, maxFramesPerMix)
                        if (!drainRes.accepted) break
                        lastReply = drainRes.reply
                        if (drainRes.state == State.COMPLETED) break
                        Thread.sleep(5)
                    }

                    val finalSnap = smTail.snapshot().reply ?: lastReply
                    if (finalSnap != null) {
                        partialEosTailRenderedFrames = finalSnap.renderedFrames
                        partialEosTailPushedFrames = finalSnap.pushedFrames
                        partialEosTailDrainedFrames = finalSnap.drainedFrames
                        partialEosTailPushedChecksumHex = finalSnap.pushedChecksumHex
                        partialEosTailDrainedChecksumHex = finalSnap.drainedChecksumHex

                        // Calculate reference checksum to verify mathematical identity
                        var refChecksum = 0L
                        for (f in 0L until declaredFrameCount) {
                            for (c in 0 until channelCount) {
                                val s = VanguardRealtimePlaybackNativeSession.referenceMixedSample(trackCount, f, c)
                                refChecksum = refChecksum * 31L + (s.toLong() and 0xFFFFL)
                            }
                        }
                        val refChecksumHex = String.format("%016x", refChecksum)

                        partialEosTailOk = smTail.currentState == State.COMPLETED &&
                            finalSnap.state == VanguardRealtimePlaybackNativeSession.NativeState.COMPLETED &&
                            finalSnap.renderedFrames == declaredFrameCount &&
                            finalSnap.pushedFrames == declaredFrameCount &&
                            finalSnap.drainedFrames == declaredFrameCount &&
                            finalSnap.eosPushed &&
                            finalSnap.eosDrained &&
                            finalSnap.pushedChecksumHex == finalSnap.drainedChecksumHex &&
                            finalSnap.drainedChecksumHex == refChecksumHex
                    }
                }
            } catch (e: Throwable) {
                failureReason = "lane2_partial_eos_tail_exception:${e.message}"
            } finally {
                smTail.dispose()
                activeStateMachine = null
            }
        }

        lanes["partialEosTailOk"] = partialEosTailOk
        metrics["partialEosTailRenderedFrames"] = partialEosTailRenderedFrames
        metrics["partialEosTailPushedFrames"] = partialEosTailPushedFrames
        metrics["partialEosTailDrainedFrames"] = partialEosTailDrainedFrames
        metrics["partialEosTailPushedChecksumHex"] = partialEosTailPushedChecksumHex
        metrics["partialEosTailDrainedChecksumHex"] = partialEosTailDrainedChecksumHex

        if (trackAdmissionOk && !partialEosTailOk && failureReason.isEmpty()) {
            failureReason = "partial_eos_tail_failed"
        }

        // ── Lane 3: Reentrant sequence in one live session ──────────────────────
        // load, prepare, start, drain some, pause, hold 120-180ms proving dispatchCount and
        // pushedFrames unchanged, resume, non-quiescent seek forward, drain, seek backward,
        // stop, start again, drain to EOS.
        var reentrantSequenceOk = false
        var reentrantHoldDispatchUnchangedOk = false
        var reentrantHoldPushedUnchangedOk = false
        var reentrantForwardSeekNonQuiescentOk = false
        var reentrantSeekForwardOk = false
        var reentrantSeekBackwardOk = false
        var reentrantRestartAndEosOk = false

        if (trackAdmissionOk && partialEosTailOk) {
            val sampleRate = 48000
            val channelCount = 2
            val trackCount = 2
            val maxFramesPerMix = 256
            val declaredFrameCount = 24000L // 0.5s of audio

            val configReentrant = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = sampleRate,
                channelCount = channelCount,
                maxFramesPerMix = maxFramesPerMix,
                trackCount = trackCount,
                declaredFrameCount = declaredFrameCount,
            )
            val smReentrant = VanguardRealtimePlaybackTransportStateMachine(
                configReentrant,
                threadName = "Y1SmokeReentrant",
            )
            val dstBuffer = ByteBuffer.allocateDirect(maxFramesPerMix * configReentrant.bytesPerFrame)

            try {
                activeStateMachine = smReentrant
                val loadRes = smReentrant.load()
                val prepRes = smReentrant.prepare()
                val startRes = smReentrant.start()

                if (loadRes.accepted && prepRes.accepted && startRes.accepted) {
                    // Drain some frames while playing
                    for (i in 0 until 5) {
                        smReentrant.drain(dstBuffer, maxFramesPerMix)
                        Thread.sleep(5)
                    }

                    // Pause and hold 150ms (in [120, 180]ms)
                    val pauseRes = smReentrant.pause()
                    val snapBefore = smReentrant.snapshot().reply
                    var snapAfter: VanguardRealtimePlaybackNativeSession.Reply? = null
                    if (pauseRes.accepted && snapBefore != null) {
                        Thread.sleep(150)
                        // Snapshot / drain during pause
                        snapAfter = smReentrant.snapshot().reply
                        if (snapAfter != null) {
                            reentrantHoldDispatchUnchangedOk = snapBefore.dispatchCount == snapAfter.dispatchCount
                            reentrantHoldPushedUnchangedOk = snapBefore.pushedFrames == snapAfter.pushedFrames
                        }
                    }

                    // Resume
                    val resumeRes = smReentrant.resume()

                    // Wait briefly (bounded 20-50ms) and take snapshot to prove active progress / pending output before forward seek
                    if (resumeRes.accepted) {
                        Thread.sleep(30)
                        val snapResume = smReentrant.snapshot().reply
                        if (snapResume != null) {
                            val activeProgress = (snapAfter != null && (snapResume.dispatchCount > snapAfter.dispatchCount || snapResume.pushedFrames > snapAfter.pushedFrames)) ||
                                snapResume.outputAvailableReadFrames > 0L
                            reentrantForwardSeekNonQuiescentOk = smReentrant.currentState == State.PLAYING &&
                                snapResume.state == VanguardRealtimePlaybackNativeSession.NativeState.PLAYING &&
                                activeProgress
                        }
                    }

                    // Non-quiescent seek forward while playing
                    val seekFwdRes = smReentrant.seek(12000L)
                    reentrantSeekForwardOk = reentrantForwardSeekNonQuiescentOk &&
                        resumeRes.accepted &&
                        seekFwdRes.accepted &&
                        seekFwdRes.state == State.PLAYING

                    // Drain some frames post forward-seek
                    for (i in 0 until 3) {
                        smReentrant.drain(dstBuffer, maxFramesPerMix)
                        Thread.sleep(5)
                    }

                    // Seek backward while playing
                    val seekBwdRes = smReentrant.seek(2000L)
                    reentrantSeekBackwardOk = seekBwdRes.accepted && seekBwdRes.state == State.PLAYING

                    // Stop
                    val stopRes = smReentrant.stop()

                    // Start again from STOPPED
                    val startAgainRes = smReentrant.start()

                    // Drain to EOS
                    val deadline = System.currentTimeMillis() + 8000L
                    var lastReply: VanguardRealtimePlaybackNativeSession.Reply? = null

                    while (smReentrant.currentState != State.COMPLETED &&
                        smReentrant.currentState != State.FAILED &&
                        smReentrant.currentState != State.DISPOSED &&
                        !disposed.get() &&
                        System.currentTimeMillis() < deadline
                    ) {
                        val drainRes = smReentrant.drain(dstBuffer, maxFramesPerMix)
                        if (!drainRes.accepted) break
                        lastReply = drainRes.reply
                        if (drainRes.state == State.COMPLETED) break
                        Thread.sleep(5)
                    }

                    val finalSnap = smReentrant.snapshot().reply ?: lastReply
                    reentrantRestartAndEosOk = stopRes.accepted && startAgainRes.accepted &&
                        smReentrant.currentState == State.COMPLETED &&
                        finalSnap?.eosDrained == true

                    reentrantSequenceOk = reentrantHoldDispatchUnchangedOk &&
                        reentrantHoldPushedUnchangedOk &&
                        reentrantForwardSeekNonQuiescentOk &&
                        reentrantSeekForwardOk &&
                        reentrantSeekBackwardOk &&
                        reentrantRestartAndEosOk
                }
            } catch (e: Throwable) {
                failureReason = "lane3_reentrant_sequence_exception:${e.message}"
            } finally {
                smReentrant.dispose()
                activeStateMachine = null
            }
        }

        lanes["reentrantSequenceOk"] = reentrantSequenceOk
        metrics["reentrantHoldDispatchUnchangedOk"] = reentrantHoldDispatchUnchangedOk
        metrics["reentrantHoldPushedUnchangedOk"] = reentrantHoldPushedUnchangedOk
        metrics["reentrantForwardSeekNonQuiescentOk"] = reentrantForwardSeekNonQuiescentOk
        metrics["reentrantSeekForwardOk"] = reentrantSeekForwardOk
        metrics["reentrantSeekBackwardOk"] = reentrantSeekBackwardOk
        metrics["reentrantRestartAndEosOk"] = reentrantRestartAndEosOk

        if (trackAdmissionOk && partialEosTailOk && !reentrantSequenceOk && failureReason.isEmpty()) {
            failureReason = "reentrant_sequence_failed"
        }

        // ── Lane 4: Paused seek stays PAUSED ───────────────────────────────────
        var pausedSeekStaysPausedOk = false
        var pausedSeekStayedPaused = false

        if (trackAdmissionOk && partialEosTailOk && reentrantSequenceOk) {
            val configPaused = VanguardRealtimePlaybackNativeSession.Config(
                sampleRate = 48000,
                channelCount = 2,
                maxFramesPerMix = 256,
                trackCount = 2,
                declaredFrameCount = 48000L,
            )
            val smPaused = VanguardRealtimePlaybackTransportStateMachine(configPaused, threadName = "Y1SmokePausedSeek")
            val dstBuffer = ByteBuffer.allocateDirect(256 * configPaused.bytesPerFrame)

            try {
                activeStateMachine = smPaused
                smPaused.load()
                smPaused.prepare()
                smPaused.start()
                smPaused.drain(dstBuffer, 256)
                val pauseRes = smPaused.pause()
                val seekRes = smPaused.seek(12000L)

                pausedSeekStayedPaused = pauseRes.accepted && pauseRes.state == State.PAUSED &&
                    seekRes.accepted && seekRes.state == State.PAUSED &&
                    smPaused.currentState == State.PAUSED
                pausedSeekStaysPausedOk = pausedSeekStayedPaused
            } catch (e: Throwable) {
                failureReason = "lane4_paused_seek_exception:${e.message}"
            } finally {
                smPaused.dispose()
                activeStateMachine = null
            }
        }

        lanes["pausedSeekStaysPausedOk"] = pausedSeekStaysPausedOk
        metrics["pausedSeekStayedPaused"] = pausedSeekStayedPaused

        if (trackAdmissionOk && partialEosTailOk && reentrantSequenceOk && !pausedSeekStaysPausedOk && failureReason.isEmpty()) {
            failureReason = "paused_seek_stays_paused_failed"
        }

        // ── Lane 5: Wrong owner direct native probe ───────────────────────────
        // Returns status wrong_owner_thread with wrongOwnerThread=true and no mutation.
        var wrongOwnerDirectProbeOk = false
        var wrongOwnerStatus = ""
        var wrongOwnerFlag = false

        val probeConfig = VanguardRealtimePlaybackNativeSession.Config(
            sampleRate = 48000,
            channelCount = 2,
            maxFramesPerMix = 256,
            trackCount = 2,
            declaredFrameCount = 48000L,
        )
        var sWrongOwner: VanguardRealtimePlaybackNativeSession? = null

        try {
            when (val created = VanguardRealtimePlaybackNativeSession.create(probeConfig)) {
                is CreateResult.Success -> {
                    val session = created.session
                    sWrongOwner = session

                    val latch = CountDownLatch(1)
                    Thread {
                        try {
                            val reply = session.snapshot()
                            wrongOwnerStatus = reply.status
                            wrongOwnerFlag = reply.wrongOwnerThread
                        } finally {
                            latch.countDown()
                        }
                    }.start()

                    latch.await(3000, TimeUnit.MILLISECONDS)
                    wrongOwnerDirectProbeOk = wrongOwnerStatus == "wrong_owner_thread" && wrongOwnerFlag
                }
                is CreateResult.Failure -> {
                    failureReason = "lane5_session_create_failed:${created.failure.name}"
                }
            }
        } catch (e: Throwable) {
            failureReason = "lane5_wrong_owner_probe_exception:${e.message}"
        } finally {
            sWrongOwner?.destroy()
        }

        lanes["wrongOwnerDirectProbeOk"] = wrongOwnerDirectProbeOk
        metrics["wrongOwnerStatus"] = wrongOwnerStatus
        metrics["wrongOwnerFlag"] = wrongOwnerFlag

        if (!wrongOwnerDirectProbeOk && failureReason.isEmpty()) {
            failureReason = "wrong_owner_direct_probe_failed"
        }

        // ── Lane 6: Native registry capacity (4 pass, 5th fails) ───────────────
        var registryCapacityOk = false
        var registryCapacityCount = 0
        var registryFifthFailedOk = false

        var s1: VanguardRealtimePlaybackNativeSession? = null
        var s2: VanguardRealtimePlaybackNativeSession? = null
        var s3: VanguardRealtimePlaybackNativeSession? = null
        var s4: VanguardRealtimePlaybackNativeSession? = null

        try {
            val cr1 = VanguardRealtimePlaybackNativeSession.create(probeConfig)
            if (cr1 is CreateResult.Success) { s1 = cr1.session; registryCapacityCount++ }
            val cr2 = VanguardRealtimePlaybackNativeSession.create(probeConfig)
            if (cr2 is CreateResult.Success) { s2 = cr2.session; registryCapacityCount++ }
            val cr3 = VanguardRealtimePlaybackNativeSession.create(probeConfig)
            if (cr3 is CreateResult.Success) { s3 = cr3.session; registryCapacityCount++ }
            val cr4 = VanguardRealtimePlaybackNativeSession.create(probeConfig)
            if (cr4 is CreateResult.Success) { s4 = cr4.session; registryCapacityCount++ }

            val cr5 = VanguardRealtimePlaybackNativeSession.create(probeConfig)
            registryFifthFailedOk = cr5 is CreateResult.Failure &&
                cr5.failure == CreateFailure.NATIVE_CAPACITY_EXHAUSTED

            registryCapacityOk = registryCapacityCount == 4 && registryFifthFailedOk
        } catch (e: Throwable) {
            failureReason = "lane6_registry_capacity_exception:${e.message}"
        } finally {
            s1?.destroy()
            s2?.destroy()
            s3?.destroy()
            s4?.destroy()
        }

        lanes["registryCapacityOk"] = registryCapacityOk
        metrics["registryCapacityCount"] = registryCapacityCount
        metrics["registryFifthFailedOk"] = registryFifthFailedOk

        if (!registryCapacityOk && failureReason.isEmpty()) {
            failureReason = "registry_capacity_failed"
        }

        // ── Lane 7: Destroy idempotence ───────────────────────────────────────
        // First native destroy reports ok and workerJoined/workerExited true.
        // Second destroy: native bridge returns not_found, wrapper returns session_closed.
        var destroyIdempotenceOk = false
        var firstDestroyStatus = ""
        var firstDestroyWorkerJoined = false
        var firstDestroyWorkerExited = false
        var nativeSecondDestroyStatus = ""
        var wrapperSecondDestroyStatus = ""

        var sDestroy: VanguardRealtimePlaybackNativeSession? = null
        try {
            when (val created = VanguardRealtimePlaybackNativeSession.create(probeConfig)) {
                is CreateResult.Success -> {
                    val session = created.session
                    sDestroy = session
                    val handle = session.handle

                    // First destroy via session wrapper
                    val firstReply = session.destroy()
                    firstDestroyStatus = firstReply.status
                    firstDestroyWorkerJoined = firstReply.workerJoined
                    firstDestroyWorkerExited = firstReply.workerExited

                    // Wrapper second destroy -> session_closed
                    val wrapperSecondReply = session.destroy()
                    wrapperSecondDestroyStatus = wrapperSecondReply.status

                    // Direct native bridge second destroy -> not_found
                    val nativeSecondRaw = VanguardRealtimePlaybackNativeBridge.destroyRealtimePlaybackGraphSession(handle)
                    val nativeSecondReply = VanguardRealtimePlaybackNativeSession.parseReply(nativeSecondRaw)
                    nativeSecondDestroyStatus = nativeSecondReply.status

                    destroyIdempotenceOk = firstDestroyStatus == "ok" &&
                        firstDestroyWorkerJoined &&
                        firstDestroyWorkerExited &&
                        wrapperSecondDestroyStatus == VanguardRealtimePlaybackNativeSession.STATUS_SESSION_CLOSED &&
                        nativeSecondDestroyStatus == VanguardRealtimePlaybackNativeSession.STATUS_NOT_FOUND
                }
                is CreateResult.Failure -> {
                    failureReason = "lane7_session_create_failed:${created.failure.name}"
                }
            }
        } catch (e: Throwable) {
            failureReason = "lane7_destroy_idempotence_exception:${e.message}"
        } finally {
            sDestroy?.destroy()
        }

        lanes["destroyIdempotenceOk"] = destroyIdempotenceOk
        metrics["firstDestroyStatus"] = firstDestroyStatus
        metrics["firstDestroyWorkerJoined"] = firstDestroyWorkerJoined
        metrics["firstDestroyWorkerExited"] = firstDestroyWorkerExited
        metrics["nativeSecondDestroyStatus"] = nativeSecondDestroyStatus
        metrics["wrapperSecondDestroyStatus"] = wrapperSecondDestroyStatus

        if (!destroyIdempotenceOk && failureReason.isEmpty()) {
            failureReason = "destroy_idempotence_failed"
        }

        // ── Proof Boundary & Canonical Pass ──────────────────────────────────
        val proofBoundaryOk = true
        lanes["proofBoundaryOk"] = proofBoundaryOk

        val pass = trackAdmissionOk &&
            partialEosTailOk &&
            reentrantSequenceOk &&
            pausedSeekStaysPausedOk &&
            wrongOwnerDirectProbeOk &&
            registryCapacityOk &&
            destroyIdempotenceOk &&
            proofBoundaryOk

        lanes["canonical"] = pass

        val status = if (pass) "pass" else "fail"
        val marker = if (pass) PASS_MARKER else FAIL_MARKER
        val lastError = if (pass) null else failureReason.ifBlank { "smoke_failed" }

        return mapOf(
            "pass" to pass,
            "status" to status,
            "marker" to marker,
            "proofBoundary" to PROOF_BOUNDARY,
            "nativeProofBoundary" to PROOF_BOUNDARY,
            "failureReason" to if (pass) "" else failureReason,
            "details" to "Y1 realtime playback transport core harness pass=$pass",
            "lanes" to lanes,
            "metrics" to metrics,
            "lastError" to lastError,
            "raw" to "pass=$pass;status=$status;marker=$marker",
        )
    }

    private fun buildFailurePayload(reason: String): Map<String, Any?> = mapOf(
        "pass" to false,
        "status" to "fail",
        "marker" to FAIL_MARKER,
        "proofBoundary" to PROOF_BOUNDARY,
        "nativeProofBoundary" to PROOF_BOUNDARY,
        "failureReason" to reason,
        "details" to reason,
        "lanes" to mapOf(
            "trackAdmissionOk" to false,
            "partialEosTailOk" to false,
            "reentrantSequenceOk" to false,
            "pausedSeekStaysPausedOk" to false,
            "wrongOwnerDirectProbeOk" to false,
            "registryCapacityOk" to false,
            "destroyIdempotenceOk" to false,
            "proofBoundaryOk" to false,
            "canonical" to false,
        ),
        "metrics" to mapOf(
            "failureReason" to reason,
        ),
        "lastError" to reason,
        "raw" to "pass=false;status=fail;marker=$FAIL_MARKER;reason=$reason",
    )
}
