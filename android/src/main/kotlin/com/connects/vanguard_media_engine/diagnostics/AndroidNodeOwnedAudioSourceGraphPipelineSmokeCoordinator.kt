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
 * Android True-DAG P4-AUDIO-DECODER-SOURCE-NODE-WIRING: verification smoke
 * coordinator with an embedded compact synthetic PCM16 step driver.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the session-scoped
 * node-owned-source closed-loop native audio graph pipeline JNI seam:
 * DecodedAudioPcmSourceNode (6-arg constructor) owns its source
 * ring/writer/provider triple by composition, and GraphAudioScheduler
 * auto-discovers the provider from graph topology alone (tag-dispatched
 * constructor; no external provider map, no hybrid routing).
 *
 * Honest non-claims (Proof Boundary):
 * - Diagnostic node-owned decoded audio source ring/provider wiring proof
 *   only; no production export or pass-2 graph reroute, no product/editor
 *   UI, no ConnectsApp integration, no streaming/cache, no iOS. No
 *   MediaCodec, no MediaExtractor ownership in C++, no AudioTrack, no
 *   AAudio, no OpenSL, no Oboe, and no realtime/audio-focus/route/
 *   dead-object/audible/speaker/latency/glitch claims. Native spawns no
 *   threads, takes no locks inside the vanguard audio primitives, does no
 *   file IO, and never reads a wall clock; every tick is caller-derived.
 *   Single routed track at unit gain; forward-only seek; writer-local EOS
 *   only.
 * - The coordinator dispatches to one background [Thread] per accepted run
 *   to keep the Flutter UI thread responsive; runs are serialized by an
 *   active flag and never overlap, so that one thread is the session's
 *   single native owner thread.
 * - Detach-safe: after [disposeAll] no MethodChannel reply is ever
 *   delivered; an in-flight driver run finishes naturally on its own thread
 *   and destroys its own native session in its finally block.
 */
class AndroidNodeOwnedAudioSourceGraphPipelineSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4NodeOwnedSrcPipe"
        private const val METHOD_NAME = "runAndroidNodeOwnedAudioSourceGraphPipelineSmoke"

        const val PASS_MARKER = "ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_AUDIO_DECODER_SOURCE_NODE_WIRING_SMOKE_FAIL"
        const val PROOF_BOUNDARY =
            "diagnostic_node_owned_decoded_audio_source_ring_provider_wiring_proof_only_source_node_owns_ring_writer_provider_by_composition_scheduler_auto_discovers_provider_from_graph_topology_tag_dispatched_ctor_only_no_external_provider_map_no_hybrid_routing_no_production_export_reroute_no_pass2_graph_reroute_no_product_no_editor_ui_no_connects_app_no_mediacodec_no_mediaextractor_no_cpp_os_decoder_ownership_no_audio_track_no_aaudio_no_opensl_no_oboe_no_realtime_no_audio_focus_no_route_no_dead_object_no_audible_no_speaker_no_latency_no_glitch_claims_no_streaming_no_cache_no_ios_no_native_threads_no_locks_in_vanguard_audio_primitives_jni_session_registry_mutex_lifecycle_only_no_jni_reverse_callbacks_single_owner_thread_only_destroy_idempotent_any_thread_no_cpp_file_io_no_native_wall_clock_read_caller_derived_systime_ticks_only_single_routed_track_unit_gain_only_no_resample_no_downmix_channels_1_or_2_only_forward_only_seek_writer_local_eos_only_tail_flush_diagnostic_only_native_zero_steady_state_allocation_only_jvm_heap_and_jni_string_allocation_non_claim"

        private const val EXPECTED_SOURCE_NODE_ID = "node_owned_pipeline_src"
        private const val ANCHOR_SYS_TIME_NS = 1_000_000_000L
        private const val MIN_STEADY_STATE_DISPATCHES = 50L

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
            // Detached: never reply after disposeAll(); the engine-side
            // channel is already torn down.
            Log.w(TAG, "$METHOD_NAME ignored: coordinator disposed")
            return true
        }
        val config = RunConfig(
            sampleRate = (args?.get("sampleRate") as? Number)?.toInt() ?: 48_000,
            channelCount = (args?.get("channelCount") as? Number)?.toInt() ?: 2,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 8_192,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 4_096,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            preSeekWindows = (args?.get("preSeekWindows") as? Number)?.toInt() ?: 32,
            postSeekWindows = (args?.get("postSeekWindows") as? Number)?.toInt() ?: 32,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_NODE_OWNED_SOURCE_PIPELINE_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        val replied = AtomicBoolean(false)
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
        return true
    }

    /**
     * Marks the coordinator disposed. An in-flight driver run is allowed to
     * finish naturally (its reply is dropped); the native session is
     * destroyed by the driver's own finally block.
     */
    fun disposeAll() {
        disposed.set(true)
    }

    // Delivers success at most once, on the main thread, and never after
    // disposeAll() — checked both before posting and inside the posted block.
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

    // ── Embedded compact synthetic PCM16 step driver ────────────────────────

    private data class RunConfig(
        val sampleRate: Int,
        val channelCount: Int,
        val sourceRingCapacityFrames: Int,
        val outputRingCapacityFrames: Int,
        val maxFramesPerMix: Int,
        val preSeekWindows: Int,
        val postSeekWindows: Int,
        val deadlineMs: Long,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    // Mutable telemetry threaded through the run so fail-closed paths still
    // report everything observed up to the failure point.
    private class Telemetry {
        var invalidCreateRejectedOk = false
        var routeDiscoveryOk = false
        var nodeOwnsRingOk = false
        var checksumIdentityOk = false
        var frameAccountingOk = false
        var seekOk = false
        var tailFlushOk = false
        var underrunGateOk = false
        var noUnderrunOk = false
        var noSilenceOk = false
        var zeroNativeSteadyStateAllocationOk = false
        var lifecycleOk = false

        var routedSourceCount = -1L
        var routedSourceId0 = ""
        var nodeOwnsRing = false
        var kotlinChecksum = 0L
        var kotlinFramesAccepted = 0L
        var totalFramesAccepted = 0L
        var totalOutputFramesDrained = 0L
        var providerUnderrunEvents = -1L
        var providerFramesZeroFilled = -1L
        var providerForwardSkipFrames = -1L
        var providerRewindRejects = -1L
        var coordinatorSilenceCount = -1L
        var dispatchCount = 0L
        var nativeAcceptedChecksumHex = ""
        var nativeOutputDrainChecksumHex = ""
        var sourceAvailableReadFrames = -1L
        var outputAvailableReadFrames = -1L
        var schedulerTrackScratchCapacitySamples = -1L
        var schedulerTrackScratchCapacityTracks = -1L
        var sourceRingStorageCapacitySamples = -1L
        var outputRingStorageCapacitySamples = -1L
        val detailParts = mutableListOf<String>()
    }

    private fun runDriver(config: RunConfig): Map<String, Any?> {
        val t = Telemetry()
        val deadline = SystemClock.elapsedRealtime() + config.deadlineMs
        var handle = 0L
        try {
            val sr = config.sampleRate
            val ch = config.channelCount
            val mfpm = config.maxFramesPerMix.toLong()
            if (mfpm < 4) throw FailClosed("invalid_driver_config_max_frames_per_mix")
            if (config.preSeekWindows < 1 || config.postSeekWindows < 1) {
                throw FailClosed("invalid_driver_config_window_counts")
            }

            fun checkDeadline() {
                if (SystemClock.elapsedRealtime() > deadline) throw FailClosed("deadline_exceeded")
            }

            // ── Lifecycle lane part 1: fail-closed construction validation ──
            // (invalid ring capacity must be rejected by the node-owned
            // AudioSpscAudioRingBuffer construction path, invalid channel
            // count by the shared 5-arg validation path).
            if (VanguardNativeBridge.createNodeOwnedAudioSourceGraphPipelineSmokeSession(
                    sr, ch, 100, config.outputRingCapacityFrames, config.maxFramesPerMix) != 0L
            ) throw FailClosed("non_power_of_two_ring_session_not_rejected")
            if (VanguardNativeBridge.createNodeOwnedAudioSourceGraphPipelineSmokeSession(
                    sr, 3, config.sourceRingCapacityFrames,
                    config.outputRingCapacityFrames, config.maxFramesPerMix) != 0L
            ) throw FailClosed("invalid_channel_count_session_not_rejected")
            t.invalidCreateRejectedOk = true

            // ── Create ──────────────────────────────────────────────────────
            handle = VanguardNativeBridge.createNodeOwnedAudioSourceGraphPipelineSmokeSession(
                sr, ch, config.sourceRingCapacityFrames,
                config.outputRingCapacityFrames, config.maxFramesPerMix,
            )
            if (handle == 0L) throw FailClosed("native_session_create_failed")

            val bytesPerFrame = 2 * ch
            val scratch = ByteBuffer.allocateDirect(config.maxFramesPerMix * bytesPerFrame)
                .order(ByteOrder.LITTLE_ENDIAN)
            var patternCounter = 0L

            // Caller-derived tick anchor, re-based at start() and seek().
            var anchorPtsUs = 0L
            var anchorSysNs = ANCHOR_SYS_TIME_NS
            var lastTickNs = Long.MIN_VALUE

            fun ceilDiv(a: Long, b: Long): Long = (a + b - 1) / b

            fun tickForFrame(frame: Long): Long {
                val ptsUs = ceilDiv(frame * 1_000_000L, sr.toLong())
                val tick = anchorSysNs + (ptsUs - anchorPtsUs) * 1_000L
                if (tick < lastTickNs) throw FailClosed("non_monotonic_driver_tick")
                lastTickNs = tick
                return tick
            }

            fun snapshot(): Map<String, String> {
                val kv = parseStatus(
                    VanguardNativeBridge.snapshotNodeOwnedAudioSourceGraphPipeline(handle)
                )
                if (kv["status"] != "ok") throw FailClosed("snapshot_status_${kv["status"]}")
                t.routedSourceCount = longField(kv, "routedSourceCount")
                t.routedSourceId0 = kv["routedSourceId0"] ?: ""
                t.nodeOwnsRing = kv["nodeOwnsRing"] == "true"
                t.providerUnderrunEvents = longField(kv, "providerUnderrunEvents")
                t.providerFramesZeroFilled = longField(kv, "providerFramesZeroFilled")
                t.providerForwardSkipFrames = longField(kv, "providerForwardSkipFrames")
                t.providerRewindRejects = longField(kv, "providerRewindRejects")
                t.coordinatorSilenceCount = longField(kv, "silenceCount")
                t.totalFramesAccepted = longField(kv, "totalFramesAccepted")
                t.totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
                t.nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
                t.nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
                t.sourceAvailableReadFrames = longField(kv, "sourceAvailableReadFrames")
                t.outputAvailableReadFrames = longField(kv, "outputAvailableReadFrames")
                t.dispatchCount = longField(kv, "dispatchCount")
                t.schedulerTrackScratchCapacitySamples =
                    longField(kv, "schedulerTrackScratchCapacitySamples")
                t.schedulerTrackScratchCapacityTracks =
                    longField(kv, "schedulerTrackScratchCapacityTracks")
                t.sourceRingStorageCapacitySamples =
                    longField(kv, "sourceRingStorageCapacitySamples")
                t.outputRingStorageCapacitySamples =
                    longField(kv, "outputRingStorageCapacitySamples")
                return kv
            }

            // One ingest call of [frames] deterministic pattern frames
            // through the node-owned writer, mirroring the native
            // accepted-side checksum over exactly the accepted samples.
            fun ingest(frames: Int) {
                checkDeadline()
                for (i in 0 until frames * ch) {
                    val v = ((patternCounter * 31L + 7L) % 24_001L - 12_000L).toInt().toShort()
                    scratch.putShort(i * 2, v)
                    patternCounter += 1L
                }
                val kv = parseStatus(
                    VanguardNativeBridge.ingestNodeOwnedAudioSourceGraphPipelinePcm16(
                        handle, scratch, frames,
                    )
                )
                if (kv["status"] != "ok") throw FailClosed("ingest_status_${kv["status"]}")
                val accepted = longField(kv, "framesAccepted")
                if (accepted != frames.toLong() || kv["writerStatus"] != "ok") {
                    throw FailClosed("ingest_rejected_${kv["writerStatus"]}_$accepted")
                }
                var c = t.kotlinChecksum
                for (i in 0 until frames * ch) {
                    c = c * 31L + (scratch.getShort(i * 2).toLong() and 0xFFFFL)
                }
                t.kotlinChecksum = c
                t.kotlinFramesAccepted += accepted
                t.totalFramesAccepted = longField(kv, "totalFramesAccepted")
                t.nativeAcceptedChecksumHex = kv["nativeAcceptedChecksumHex"] ?: ""
            }

            fun step(sysTimeNs: Long, flushTail: Boolean): Map<String, String> {
                checkDeadline()
                val kv = parseStatus(
                    VanguardNativeBridge.stepNodeOwnedAudioSourceGraphPipeline(
                        handle, sysTimeNs, flushTail,
                    )
                )
                if (!kv.containsKey("sourceAvailableReadFrames")) {
                    throw FailClosed("step_missing_source_available_read_frames")
                }
                if (kv["status"] == "dispatch_silence") {
                    throw FailClosed("unexpected_silence_window")
                }
                return kv
            }

            fun drain(maxFrames: Int): Map<String, String> {
                checkDeadline()
                val kv = parseStatus(
                    VanguardNativeBridge.drainNodeOwnedAudioSourceGraphPipelineOutput(
                        handle, maxFrames,
                    )
                )
                if (kv["status"] != "ok") throw FailClosed("drain_status_${kv["status"]}")
                t.totalOutputFramesDrained = longField(kv, "totalOutputFramesDrained")
                t.nativeOutputDrainChecksumHex = kv["nativeOutputDrainChecksumHex"] ?: ""
                return kv
            }

            // Ingest/step/drain closed-loop identity cycle for exactly one
            // full window ending at absolute frame [windowEndFrame].
            fun identityCycle(windowEndFrame: Long) {
                ingest(mfpm.toInt())
                val kv = step(tickForFrame(windowEndFrame), false)
                if (kv["status"] != "dispatch_ok" ||
                    longField(kv, "framesRendered") != mfpm ||
                    longField(kv, "nextDispatchFrame") != windowEndFrame
                ) {
                    throw FailClosed("identity_step_${kv["status"]}")
                }
                if (longField(drain(mfpm.toInt()), "framesDrained") != mfpm) {
                    throw FailClosed("identity_drain_short")
                }
            }

            // ── Route-discovery lane + capacity baseline ────────────────────
            val snapStart = snapshot()
            t.routeDiscoveryOk = t.routedSourceCount == 1L &&
                t.routedSourceId0 == EXPECTED_SOURCE_NODE_ID
            if (!t.routeDiscoveryOk) throw FailClosed("route_discovery_mismatch")
            t.nodeOwnsRingOk = t.nodeOwnsRing
            if (!t.nodeOwnsRingOk) throw FailClosed("node_does_not_own_ring")
            val schedCapBefore = longField(snapStart, "schedulerTrackScratchCapacitySamples")
            val schedTracksBefore = longField(snapStart, "schedulerTrackScratchCapacityTracks")
            val srcCapBefore = longField(snapStart, "sourceRingStorageCapacitySamples")
            val outCapBefore = longField(snapStart, "outputRingStorageCapacitySamples")
            if (schedCapBefore <= 0L || srcCapBefore <= 0L || outCapBefore <= 0L) {
                throw FailClosed("capacity_baseline_invalid")
            }

            // ── Start + output-ring ack drain ───────────────────────────────
            val startKv = parseStatus(
                VanguardNativeBridge.startNodeOwnedAudioSourceGraphPipeline(handle, 0L, anchorSysNs)
            )
            if (startKv["status"] != "ok") throw FailClosed("start_status_${startKv["status"]}")
            lastTickNs = anchorSysNs
            val firstStepKv = step(anchorSysNs, false)
            if (firstStepKv["status"] != "awaiting_seek_ack") {
                throw FailClosed("first_step_not_awaiting_seek_ack_${firstStepKv["status"]}")
            }
            val startAckKv = drain(config.outputRingCapacityFrames)
            if (startAckKv["seekAckConsumed"] != "true" ||
                longField(startAckKv, "newStartFrame") != 0L ||
                longField(startAckKv, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("start_ack_not_consumed_cleanly")
            }

            // ── Pre-seek closed-loop identity windows ───────────────────────
            var nextFrame = 0L
            repeat(config.preSeekWindows) {
                identityCycle(nextFrame + mfpm)
                nextFrame += mfpm
            }

            // ── Forward-only seek (re-anchor at the current frame cursor) ───
            val seekTargetFrame = nextFrame
            val seekPtsUs = ceilDiv(seekTargetFrame * 1_000_000L, sr.toLong())
            val seekSysNs = tickForFrame(seekTargetFrame)
            val seekKv = parseStatus(
                VanguardNativeBridge.seekNodeOwnedAudioSourceGraphPipeline(
                    handle, seekPtsUs, seekSysNs,
                )
            )
            if (seekKv["status"] != "ok" ||
                longField(seekKv, "targetFrame") != seekTargetFrame ||
                longField(seekKv, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("seek_failed_${seekKv["status"]}")
            }
            anchorPtsUs = seekPtsUs
            anchorSysNs = seekSysNs
            val seekAckKv = drain(config.outputRingCapacityFrames)
            if (seekAckKv["seekAckConsumed"] != "true" ||
                longField(seekAckKv, "newStartFrame") != seekTargetFrame ||
                longField(seekAckKv, "discardedFramesOnSeek") != 0L
            ) {
                throw FailClosed("seek_ack_not_consumed_cleanly")
            }
            t.seekOk = true

            // ── Post-seek closed-loop identity windows ──────────────────────
            repeat(config.postSeekWindows) {
                identityCycle(nextFrame + mfpm)
                nextFrame += mfpm
            }

            // ── Underrun gate + writer EOS + tail flush ─────────────────────
            val tailFrames = mfpm / 2L + 1L
            ingest(tailFrames.toInt())
            val tailTick = tickForFrame(nextFrame + mfpm)
            val deferredKv = step(tailTick, false)
            if (deferredKv["status"] != "deferred_insufficient_source" ||
                longField(deferredKv, "nextDispatchFrame") != nextFrame ||
                longField(deferredKv, "sourceAvailableReadFrames") != tailFrames
            ) {
                throw FailClosed("underrun_gate_not_observed_${deferredKv["status"]}")
            }
            t.underrunGateOk = true

            val eosKv = parseStatus(
                VanguardNativeBridge.setNodeOwnedAudioSourceGraphPipelineEos(handle)
            )
            if (eosKv["status"] != "ok" || eosKv["eos"] != "true") {
                throw FailClosed("eos_set_failed_${eosKv["status"]}")
            }

            val tailStepKv = step(tailTick, true)
            if (tailStepKv["status"] != "tail_flush_partial_window" ||
                longField(tailStepKv, "framesRendered") != tailFrames
            ) {
                throw FailClosed("tail_flush_partial_window_not_observed_${tailStepKv["status"]}")
            }
            nextFrame += tailFrames
            if (longField(drain(mfpm.toInt()), "framesDrained") != tailFrames) {
                throw FailClosed("tail_drain_short")
            }
            val tailDoneKv = step(tailTick, true)
            if (tailDoneKv["status"] != "tail_flush_complete") {
                throw FailClosed("tail_flush_complete_not_observed_${tailDoneKv["status"]}")
            }
            t.tailFlushOk = true

            // ── Final snapshot + verdict lanes ──────────────────────────────
            val snapEnd = snapshot()
            t.detailParts.add("preSeekWindows=${config.preSeekWindows}")
            t.detailParts.add("postSeekWindows=${config.postSeekWindows}")
            t.detailParts.add("tailFrames=$tailFrames")
            t.detailParts.add("finalNextFrame=$nextFrame")

            if (t.routedSourceCount != 1L || t.routedSourceId0 != EXPECTED_SOURCE_NODE_ID ||
                !t.nodeOwnsRing
            ) {
                throw FailClosed("route_discovery_drifted")
            }
            t.noUnderrunOk = t.providerUnderrunEvents == 0L &&
                t.providerFramesZeroFilled == 0L &&
                t.providerRewindRejects == 0L
            if (!t.noUnderrunOk) throw FailClosed("provider_underrun_observed")
            t.noSilenceOk = t.coordinatorSilenceCount == 0L
            if (!t.noSilenceOk) throw FailClosed("silence_window_observed")
            if (snapEnd["terminal"] == "true") throw FailClosed("terminal_coordinator_state")

            t.zeroNativeSteadyStateAllocationOk =
                t.dispatchCount >= MIN_STEADY_STATE_DISPATCHES &&
                schedCapBefore == t.schedulerTrackScratchCapacitySamples &&
                schedTracksBefore == t.schedulerTrackScratchCapacityTracks &&
                srcCapBefore == t.sourceRingStorageCapacitySamples &&
                outCapBefore == t.outputRingStorageCapacitySamples
            if (!t.zeroNativeSteadyStateAllocationOk) {
                throw FailClosed("native_steady_state_allocation_detected")
            }

            val kotlinChecksumHex = String.format("%016x", t.kotlinChecksum)
            t.checksumIdentityOk = kotlinChecksumHex == t.nativeAcceptedChecksumHex &&
                kotlinChecksumHex == t.nativeOutputDrainChecksumHex
            if (!t.checksumIdentityOk) throw FailClosed("checksum_identity_mismatch")

            t.frameAccountingOk = t.totalFramesAccepted == t.totalOutputFramesDrained &&
                t.totalFramesAccepted == t.kotlinFramesAccepted &&
                t.totalFramesAccepted == nextFrame
            if (!t.frameAccountingOk) throw FailClosed("frame_accounting_mismatch")

            // ── Lifecycle lane part 2: idempotent any-thread destroy ────────
            val destroyKv = parseStatus(
                VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
            )
            val destroyAgainKv = parseStatus(
                VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
            )
            val postDestroySnapshotKv = parseStatus(
                VanguardNativeBridge.snapshotNodeOwnedAudioSourceGraphPipeline(handle)
            )
            handle = 0L
            t.lifecycleOk = destroyKv["status"] == "ok" &&
                destroyAgainKv["status"] == "not_found" &&
                postDestroySnapshotKv["status"] == "not_found"
            if (!t.lifecycleOk) throw FailClosed("lifecycle_destroy_not_idempotent")

            return makePayload(t, pass = true, failureReason = "")
        } catch (f: FailClosed) {
            return makePayload(t, pass = false, failureReason = f.reason)
        } finally {
            if (handle != 0L) {
                try {
                    VanguardNativeBridge.destroyNodeOwnedAudioSourceGraphPipelineSmokeSession(handle)
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
            "invalidCreateRejectedOk" to t.invalidCreateRejectedOk,
            "routeDiscoveryOk" to t.routeDiscoveryOk,
            "nodeOwnsRingOk" to t.nodeOwnsRingOk,
            "checksumIdentityOk" to t.checksumIdentityOk,
            "frameAccountingOk" to t.frameAccountingOk,
            "seekOk" to t.seekOk,
            "underrunGateOk" to t.underrunGateOk,
            "tailFlushOk" to t.tailFlushOk,
            "noUnderrunOk" to t.noUnderrunOk,
            "noSilenceOk" to t.noSilenceOk,
            "zeroNativeSteadyStateAllocationOk" to t.zeroNativeSteadyStateAllocationOk,
            "lifecycleOk" to t.lifecycleOk,
        )
        val metrics = mapOf<String, Any?>(
            "routedSourceCount" to t.routedSourceCount,
            "routedSourceId0" to t.routedSourceId0,
            "nodeOwnsRing" to t.nodeOwnsRing,
            "totalFramesAccepted" to t.totalFramesAccepted,
            "totalOutputFramesDrained" to t.totalOutputFramesDrained,
            "providerUnderrunEvents" to t.providerUnderrunEvents,
            "providerFramesZeroFilled" to t.providerFramesZeroFilled,
            "providerForwardSkipFrames" to t.providerForwardSkipFrames,
            "providerRewindRejects" to t.providerRewindRejects,
            "coordinatorSilenceCount" to t.coordinatorSilenceCount,
            "dispatchCount" to t.dispatchCount,
            "nativeAcceptedChecksumHex" to t.nativeAcceptedChecksumHex,
            "nativeOutputDrainChecksumHex" to t.nativeOutputDrainChecksumHex,
            "kotlinAcceptedChecksumHex" to String.format("%016x", t.kotlinChecksum),
            "sourceAvailableReadFrames" to t.sourceAvailableReadFrames,
            "outputAvailableReadFrames" to t.outputAvailableReadFrames,
            "schedulerTrackScratchCapacitySamples" to t.schedulerTrackScratchCapacitySamples,
            "schedulerTrackScratchCapacityTracks" to t.schedulerTrackScratchCapacityTracks,
            "sourceRingStorageCapacitySamples" to t.sourceRingStorageCapacitySamples,
            "outputRingStorageCapacitySamples" to t.outputRingStorageCapacitySamples,
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
