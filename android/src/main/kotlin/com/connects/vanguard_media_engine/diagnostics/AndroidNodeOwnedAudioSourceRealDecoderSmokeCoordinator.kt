package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android True-DAG P4-AUDIO-REAL-DECODER-NODE-OWNED-PIPELINE (sub-slice of
 * P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): verification smoke
 * coordinator.
 *
 * Owns the [METHOD_NAME] MethodChannel route for validating the real
 * MediaExtractor/MediaCodec decoder feeding the NODE-OWNED
 * DecodedAudioPcmSourceNode closed-loop native audio graph pipeline via
 * [AndroidNodeOwnedAudioSourceRealDecoderDriver].
 *
 * Honest non-claims (Proof Boundary):
 * - Kotlin-owned real decoder to node-owned decoded-audio-source graph
 *   pipeline proof only; the native frame axis is the accepted frame count,
 *   not media PTS. No AudioTrack, no AAudio, no OpenSL, no Oboe, no audible
 *   or speaker output, no latency/glitch/realtime A-V sync/audio-focus/
 *   route/dead-object-recovery claims, no production export or pass-2 graph
 *   reroute, no product/editor UI, no ConnectsApp, no streaming/cache, no
 *   iOS. Native never owns MediaCodec/MediaExtractor, spawns no worker
 *   threads, takes no locks inside the vanguard audio primitives (the JNI
 *   session registry mutex guards lifecycle only), does no file IO, and
 *   never reads a wall clock; every tick is caller-derived. Single routed
 *   track at unit gain, no resample, channels 1 or 2 only, forward-only
 *   seek, writer-local EOS/tail flush diagnostic only, native zero
 *   steady-state allocation only (JVM heap and JNI string allocation is a
 *   non-claim).
 * - The coordinator dispatches to one background [Thread] per accepted run
 *   to keep the Flutter UI thread responsive; runs are serialized by an
 *   active flag and never overlap, so that one thread is the session's
 *   single native owner thread.
 * - Detach-safe: after [disposeAll] no MethodChannel reply is ever
 *   delivered; an in-flight driver run finishes naturally on its own thread
 *   and destroys its own native session in its finally block.
 */
class AndroidNodeOwnedAudioSourceRealDecoderSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4NodeOwnedRealDec"
        private const val METHOD_NAME = "runAndroidNodeOwnedAudioSourceRealDecoderPipelineSmoke"
        private const val MAX_DURATION_SEC = 2.0
        private const val FAIL_MARKER =
            AndroidNodeOwnedAudioSourceRealDecoderDriver.FAIL_MARKER
        private const val PROOF_BOUNDARY =
            AndroidNodeOwnedAudioSourceRealDecoderDriver.PROOF_BOUNDARY

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
        // durationSec is clamped here; the driver fail-closes on a blank
        // sourcePath and on a seek target outside [0, duration).
        val config = AndroidNodeOwnedAudioSourceRealDecoderDriver.RunConfig(
            sourcePath = args?.get("sourcePath") as? String ?: "",
            durationSec = ((args?.get("durationSec") as? Number)?.toDouble() ?: 1.0)
                .coerceAtMost(MAX_DURATION_SEC),
            seekTargetSec = (args?.get("seekTargetSec") as? Number)?.toDouble() ?: 0.35,
            sourceRingCapacityFrames =
                (args?.get("sourceRingCapacityFrames") as? Number)?.toInt() ?: 8_192,
            outputRingCapacityFrames =
                (args?.get("outputRingCapacityFrames") as? Number)?.toInt() ?: 4_096,
            maxFramesPerMix = (args?.get("maxFramesPerMix") as? Number)?.toInt() ?: 256,
            deadlineMs = (args?.get("deadlineMs") as? Number)?.toLong() ?: 30_000L,
        )
        if (!active.compareAndSet(false, true)) {
            result.error(
                "P4_NODE_OWNED_REAL_DECODER_PIPELINE_SMOKE_BUSY",
                "$METHOD_NAME: diagnostic already running",
                null,
            )
            return true
        }
        runSmoke(config, result)
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

    private fun runSmoke(
        config: AndroidNodeOwnedAudioSourceRealDecoderDriver.RunConfig,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        Thread {
            try {
                val runResult = AndroidNodeOwnedAudioSourceRealDecoderDriver().run(config)
                postReply(replied, result, toPayload(runResult))
            } catch (t: Throwable) {
                Log.e(TAG, "$METHOD_NAME failed", t)
                postReply(
                    replied,
                    result,
                    makeFailedMap("exception:${t.javaClass.simpleName}:${t.message}"),
                )
            } finally {
                active.set(false)
            }
        }.start()
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

    private fun toPayload(
        r: AndroidNodeOwnedAudioSourceRealDecoderDriver.RunResult,
    ): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to r.formatProbeOk,
            "decoderBenignFormatChangeObserved" to r.decoderBenignFormatChangeObserved,
            "decoderEosReachedOk" to r.decoderEosReachedOk,
            "routeDiscoveryOk" to r.routeDiscoveryOk,
            "nodeOwnsRingOk" to r.nodeOwnsRingOk,
            "checksumIdentityOk" to r.checksumIdentityOk,
            "frameAccountingOk" to r.frameAccountingOk,
            "seekOk" to r.seekOk,
            "tailFlushOk" to r.tailFlushOk,
            "noUnderrunOk" to r.noUnderrunOk,
            "noSilenceOk" to r.noSilenceOk,
            "noForwardSkipOk" to r.noForwardSkipOk,
            "noRewindRejectOk" to r.noRewindRejectOk,
            "finalNotTerminalOk" to r.finalNotTerminalOk,
            "finalSeekAckClearOk" to r.finalSeekAckClearOk,
            "zeroNativeSteadyStateAllocationOk" to r.zeroNativeSteadyStateAllocationOk,
            "lifecycleOk" to r.lifecycleOk,
            "canonical" to r.canonical,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to r.sampleRate,
            "channelCount" to r.channelCount,
            "pcmEncoding" to r.pcmEncoding,
            "expectedFrameCount" to r.expectedFrameCount,
            "totalFramesExtracted" to r.totalFramesExtracted,
            "totalFramesAccepted" to r.totalFramesAccepted,
            "totalOutputFramesDrained" to r.totalOutputFramesDrained,
            "postSeekFramesAccepted" to r.postSeekFramesAccepted,
            "postSeekFramesDrained" to r.postSeekFramesDrained,
            "decoderBenignFormatChangeCount" to r.decoderBenignFormatChangeCount,
            "providerUnderrunEvents" to r.providerUnderrunEvents,
            "providerFramesZeroFilled" to r.providerFramesZeroFilled,
            "providerForwardSkipFrames" to r.providerForwardSkipFrames,
            "providerRewindRejects" to r.providerRewindRejects,
            "coordinatorSilenceCount" to r.coordinatorSilenceCount,
            "dispatchCount" to r.dispatchCount,
            "nativeAcceptedChecksumHex" to r.nativeAcceptedChecksumHex,
            "nativeOutputDrainChecksumHex" to r.nativeOutputDrainChecksumHex,
            "kotlinAcceptedChecksumHex" to r.kotlinAcceptedChecksumHex,
            "maxFramesPerMix" to r.maxFramesPerMix,
            "sourceAvailableReadFrames" to r.sourceAvailableReadFrames,
            "outputAvailableReadFrames" to r.outputAvailableReadFrames,
            "nextDispatchFrame" to r.nextDispatchFrame,
        )
        return mapOf(
            "pass" to r.pass,
            "status" to r.status,
            "marker" to r.marker,
            "proofBoundary" to r.proofBoundary,
            "failureReason" to r.failureReason,
            "details" to r.details,
            "lanes" to lanes,
            "metrics" to metrics,
            "lastError" to if (r.pass) null else r.failureReason.ifBlank { r.status },
        )
    }

    // Same key shape as toPayload so the Dart harness sees a stable map even
    // when the driver throws before producing a RunResult.
    private fun makeFailedMap(reason: String): Map<String, Any?> {
        val lanes = mapOf<String, Any?>(
            "formatProbeOk" to false,
            "decoderBenignFormatChangeObserved" to false,
            "decoderEosReachedOk" to false,
            "routeDiscoveryOk" to false,
            "nodeOwnsRingOk" to false,
            "checksumIdentityOk" to false,
            "frameAccountingOk" to false,
            "seekOk" to false,
            "tailFlushOk" to false,
            "noUnderrunOk" to false,
            "noSilenceOk" to false,
            "noForwardSkipOk" to false,
            "noRewindRejectOk" to false,
            "finalNotTerminalOk" to false,
            "finalSeekAckClearOk" to false,
            "zeroNativeSteadyStateAllocationOk" to false,
            "lifecycleOk" to false,
            "canonical" to false,
        )
        val metrics = mapOf<String, Any?>(
            "sampleRate" to 0,
            "channelCount" to 0,
            "pcmEncoding" to 0,
            "expectedFrameCount" to 0L,
            "totalFramesExtracted" to 0L,
            "totalFramesAccepted" to 0L,
            "totalOutputFramesDrained" to 0L,
            "postSeekFramesAccepted" to 0L,
            "postSeekFramesDrained" to 0L,
            "decoderBenignFormatChangeCount" to 0L,
            "providerUnderrunEvents" to -1L,
            "providerFramesZeroFilled" to -1L,
            "providerForwardSkipFrames" to -1L,
            "providerRewindRejects" to -1L,
            "coordinatorSilenceCount" to -1L,
            "dispatchCount" to 0L,
            "nativeAcceptedChecksumHex" to "",
            "nativeOutputDrainChecksumHex" to "",
            "kotlinAcceptedChecksumHex" to "",
            "maxFramesPerMix" to 0L,
            "sourceAvailableReadFrames" to -1L,
            "outputAvailableReadFrames" to -1L,
            "nextDispatchFrame" to -1L,
        )
        return mapOf(
            "pass" to false,
            "status" to "fail",
            "marker" to FAIL_MARKER,
            "proofBoundary" to PROOF_BOUNDARY,
            "failureReason" to reason,
            "details" to "",
            "lanes" to lanes,
            "metrics" to metrics,
            "lastError" to reason,
        )
    }
}
