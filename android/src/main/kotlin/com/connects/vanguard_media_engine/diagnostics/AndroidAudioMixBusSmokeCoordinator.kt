package com.connects.vanguard_media_engine.diagnostics

import android.os.Handler
import android.util.Log
import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Android P4-AUDIO-MIXBUS: verification smoke coordinator.
 *
 * Owns [METHOD_NAME] MethodChannel route for validating the native
 * vanguard::audio::AudioMixBusNode PCM16 mix-bus foundation via
 * [VanguardNativeBridge]'s create/add/mix/destroy session calls. Every
 * success lane independently recomputes the expected mixed PCM, checksum,
 * and clip flag in Kotlin from the same track inputs -- native
 * `status=PASS` is never trusted on its own. No decoder, no AAC, no
 * export/mixdown route, no realtime playback wiring, no product UI.
 */
class AndroidAudioMixBusSmokeCoordinator(
    private val mainHandler: Handler,
) {
    companion object {
        private const val TAG = "VanguardP4AudioMixBus"
        private const val METHOD_NAME = "runAndroidDagPhase4AudioMixBusSmoke"
        private const val PROOF_BOUNDARY =
            "native_audio_mix_bus_node_pcm16_mix_math_only_no_decoder_no_aac_no_export_no_realtime_no_playback_no_product"

        fun ownsMethod(method: String): Boolean = method == METHOD_NAME
    }

    fun ownsMethod(method: String): Boolean = Companion.ownsMethod(method)

    fun handleMethodCall(
        method: String,
        args: Map<*, *>?,
        result: MethodChannel.Result,
    ): Boolean {
        if (method != METHOD_NAME) {
            return false
        }
        runSmoke(result)
        return true
    }

    private data class LaneResult(
        val name: String,
        val pass: Boolean,
        val raw: Map<String, String>,
        val detail: String,
    )

    private data class TrackSpec(
        val pcm: ShortArray,
        val frameCount: Int,
        val sampleRate: Int,
        val channelCount: Int,
        val gain: Double,
    )

    private data class ExpectedMixOutcome(
        val samples: IntArray,
        val clipped: Boolean,
        val checksum: ULong,
    )

    private fun runSmoke(result: MethodChannel.Result) {
        Thread {
            try {
                val diagnostics = VanguardDiagnostics()
                val nativeBridge = VanguardNativeBridge(
                    lifecycleObserver = VanguardLifecycleObserver(diagnostics),
                    diagnostics = diagnostics,
                    codecAdapter = null,
                )

                val lanes = listOf(
                    laneTopologyAndPorts(nativeBridge),
                    laneStereoStereoDeterministicMix(nativeBridge),
                    laneMonoToStereoUpmix(nativeBridge),
                    laneStereoToMonoDownmix(nativeBridge),
                    lanePositiveSaturation(nativeBridge),
                    laneNegativeSaturation(nativeBridge),
                    laneOddSampleTruncation(nativeBridge),
                    laneNegativeDownmixDivision(nativeBridge),
                    laneShorterTrackSilence(nativeBridge),
                    laneLongerTrackShortWindowMix(nativeBridge),
                    laneInvalidGainRejection(nativeBridge),
                    laneNonFiniteGainRejection(nativeBridge),
                    laneSampleRateMismatchRejection(nativeBridge),
                    laneInsufficientOutputCapacityRejection(nativeBridge),
                    laneInvalidSessionRejection(nativeBridge),
                    laneDestroyAndIdempotentDestroy(nativeBridge),
                )

                val overallPass = lanes.all { it.pass }
                val firstFailure = lanes.firstOrNull { !it.pass }

                val rawMap = mutableMapOf<String, String>()
                val metrics = mutableMapOf<String, Any?>()
                for (lane in lanes) {
                    for ((key, value) in lane.raw) {
                        rawMap["${lane.name}.$key"] = value
                    }
                    metrics["${lane.name}.pass"] = lane.pass
                }
                metrics["laneCount"] = lanes.size
                metrics["lanePassCount"] = lanes.count { it.pass }

                val payload = mapOf(
                    "pass" to overallPass,
                    "raw" to rawMap,
                    "proofBoundary" to PROOF_BOUNDARY,
                    "metrics" to metrics,
                    "lastError" to firstFailure?.let { "${it.name}: ${it.detail}" },
                )

                mainHandler.post {
                    result.success(payload)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "runAndroidDagPhase4AudioMixBusSmoke failed", t)
                mainHandler.post {
                    result.success(
                        mapOf(
                            "pass" to false,
                            "raw" to emptyMap<String, String>(),
                            "proofBoundary" to PROOF_BOUNDARY,
                            "metrics" to emptyMap<String, Any?>(),
                            "lastError" to "exception:${t.javaClass.simpleName}:${t.message}",
                        )
                    )
                }
            }
        }.start()
    }

    // ── Lanes: mixed-math success cases ───────────────────────────────────────

    private fun laneStereoStereoDeterministicMix(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(
                pcm = shortArrayOf(100, 200, 300, 400, -100, -200, 1000, -1000),
                frameCount = 4, sampleRate = 48000, channelCount = 2, gain = 0.5,
            ),
            TrackSpec(
                pcm = shortArrayOf(10, 20, 30, 40, -10, -20, 500, 500),
                frameCount = 4, sampleRate = 48000, channelCount = 2, gain = 0.25,
            ),
        )
        return runSuccessMixLane(
            bridge, "stereoStereoDeterministic",
            nodeSampleRate = 48000, nodeChannelCount = 2, maxFramesPerMix = 8,
            tracks = tracks, framesToMix = 4,
        )
    }

    private fun laneMonoToStereoUpmix(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(
                pcm = shortArrayOf(1000, -2000, 3000),
                frameCount = 3, sampleRate = 48000, channelCount = 1, gain = 0.5,
            ),
        )
        return runSuccessMixLane(
            bridge, "monoToStereoUpmix",
            nodeSampleRate = 48000, nodeChannelCount = 2, maxFramesPerMix = 4,
            tracks = tracks, framesToMix = 3,
        )
    }

    private fun laneStereoToMonoDownmix(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(
                pcm = shortArrayOf(7, 2, 10, 3),
                frameCount = 2, sampleRate = 48000, channelCount = 2, gain = 1.0,
            ),
        )
        return runSuccessMixLane(
            bridge, "stereoToMonoDownmix",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 4,
            tracks = tracks, framesToMix = 2,
        )
    }

    private fun lanePositiveSaturation(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(pcm = shortArrayOf(32767), frameCount = 1, sampleRate = 48000, channelCount = 1, gain = 1.0),
            TrackSpec(pcm = shortArrayOf(32767), frameCount = 1, sampleRate = 48000, channelCount = 1, gain = 1.0),
        )
        return runSuccessMixLane(
            bridge, "positiveSaturation",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 2,
            tracks = tracks, framesToMix = 1,
        )
    }

    private fun laneNegativeSaturation(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(pcm = shortArrayOf(-32768), frameCount = 1, sampleRate = 48000, channelCount = 1, gain = 1.0),
            TrackSpec(pcm = shortArrayOf(-32768), frameCount = 1, sampleRate = 48000, channelCount = 1, gain = 1.0),
        )
        return runSuccessMixLane(
            bridge, "negativeSaturation",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 2,
            tracks = tracks, framesToMix = 1,
        )
    }

    private fun laneOddSampleTruncation(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(
                pcm = shortArrayOf(1001, -1001),
                frameCount = 2, sampleRate = 48000, channelCount = 1, gain = 0.5,
            ),
        )
        return runSuccessMixLane(
            bridge, "oddSampleTruncation",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 2,
            tracks = tracks, framesToMix = 2,
        )
    }

    private fun laneNegativeDownmixDivision(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(
                pcm = shortArrayOf(-3, -2),
                frameCount = 1, sampleRate = 48000, channelCount = 2, gain = 1.0,
            ),
        )
        return runSuccessMixLane(
            bridge, "negativeDownmixDivision",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 2,
            tracks = tracks, framesToMix = 1,
        )
    }

    private fun laneShorterTrackSilence(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(
                pcm = shortArrayOf(100, 200, 300, 400),
                frameCount = 4, sampleRate = 48000, channelCount = 1, gain = 1.0,
            ),
            TrackSpec(
                pcm = shortArrayOf(10, 20),
                frameCount = 2, sampleRate = 48000, channelCount = 1, gain = 1.0,
            ),
        )
        return runSuccessMixLane(
            bridge, "shorterTrackSilence",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 4,
            tracks = tracks, framesToMix = 4,
        )
    }

    private fun laneLongerTrackShortWindowMix(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(
                pcm = shortArrayOf(100, 200, 300, 400, 500, 600),
                frameCount = 6, sampleRate = 48000, channelCount = 1, gain = 1.0,
            ),
        )
        return runSuccessMixLane(
            bridge, "longerTrackShortWindowMix",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 6,
            tracks = tracks, framesToMix = 3,
        )
    }

    // ── Lanes: rejection / lifecycle cases ─────────────────────────────────────

    private fun laneInvalidGainRejection(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(pcm = shortArrayOf(100), frameCount = 1, sampleRate = 48000, channelCount = 1, gain = 1.5),
        )
        return runFailureMixLane(
            bridge, "invalidGainRejection",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 1,
            tracks = tracks, framesToMix = 1, expectedReason = "invalid_gain",
        )
    }

    private fun laneNonFiniteGainRejection(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(pcm = shortArrayOf(100), frameCount = 1, sampleRate = 48000, channelCount = 1, gain = Double.NaN),
        )
        return runFailureMixLane(
            bridge, "nonFiniteGainRejection",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 1,
            tracks = tracks, framesToMix = 1, expectedReason = "invalid_gain",
        )
    }

    private fun laneSampleRateMismatchRejection(bridge: VanguardNativeBridge): LaneResult {
        val tracks = listOf(
            TrackSpec(pcm = shortArrayOf(100), frameCount = 1, sampleRate = 44100, channelCount = 1, gain = 1.0),
        )
        return runFailureMixLane(
            bridge, "sampleRateMismatchRejection",
            nodeSampleRate = 48000, nodeChannelCount = 1, maxFramesPerMix = 1,
            tracks = tracks, framesToMix = 1, expectedReason = "sample_rate_mismatch",
        )
    }

    private fun laneInsufficientOutputCapacityRejection(bridge: VanguardNativeBridge): LaneResult {
        val raw = mutableMapOf<String, String>()

        val createRaw = bridge.createAndroidDagPhase4AudioMixBusSession(
            nodeId = "mixbus_insufficient_output_capacity",
            sampleRate = 48000, channelCount = 2, maxFramesPerMix = 4,
        )
        raw["create"] = createRaw
        val sessionId = extractField(createRaw, "sessionId")
        if (sessionId == null || !createRaw.startsWith("status=PASS")) {
            return LaneResult("insufficientOutputCapacityRejection", false, raw, "session create failed: $createRaw")
        }

        val addRaw = bridge.addAndroidDagPhase4AudioMixBusTrack(
            sessionId = sessionId,
            pcm16Buffer = directBuffer(shortArrayOf(1, 2, 3, 4)),
            frameCount = 2, sampleRate = 48000, channelCount = 2, gain = 1.0,
        )
        raw["add0"] = addRaw

        // framesToMix=2 with nodeChannelCount=2 requires 4 samples (8 bytes)
        // of output capacity; deliberately supply half that.
        val undersizedOutBuffer = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        val mixRaw = bridge.mixAndroidDagPhase4AudioMixBusSession(sessionId, 2, undersizedOutBuffer)
        raw["mix"] = mixRaw

        val destroyRaw = bridge.destroyAndroidDagPhase4AudioMixBusSession(sessionId)
        raw["destroy"] = destroyRaw

        val pass = addRaw.startsWith("status=PASS") &&
            mixRaw.startsWith("status=FAIL") &&
            extractField(mixRaw, "reason") == "insufficient_output_capacity" &&
            destroyRaw.startsWith("status=PASS")

        return LaneResult(
            "insufficientOutputCapacityRejection", pass, raw,
            if (pass) {
                "ok"
            } else {
                "expected mix FAIL/insufficient_output_capacity: add=$addRaw mix=$mixRaw destroy=$destroyRaw"
            },
        )
    }

    private fun laneInvalidSessionRejection(bridge: VanguardNativeBridge): LaneResult {
        val bogusSessionId = "p4amb_nonexistent_session_id"
        val addRaw = bridge.addAndroidDagPhase4AudioMixBusTrack(
            sessionId = bogusSessionId,
            pcm16Buffer = directBuffer(shortArrayOf(1, 2)),
            frameCount = 1,
            sampleRate = 48000,
            channelCount = 2,
            gain = 1.0,
        )
        val outBuffer = ByteBuffer.allocateDirect(2).order(ByteOrder.nativeOrder())
        val mixRaw = bridge.mixAndroidDagPhase4AudioMixBusSession(bogusSessionId, 1, outBuffer)

        val pass = addRaw.startsWith("status=FAIL") &&
            extractField(addRaw, "reason") == "session_not_found" &&
            mixRaw.startsWith("status=FAIL") &&
            extractField(mixRaw, "reason") == "session_not_found"

        return LaneResult(
            name = "invalidSessionRejection",
            pass = pass,
            raw = mapOf("add" to addRaw, "mix" to mixRaw),
            detail = if (pass) "ok" else "expected session_not_found for both add and mix: add=$addRaw mix=$mixRaw",
        )
    }

    private fun laneDestroyAndIdempotentDestroy(bridge: VanguardNativeBridge): LaneResult {
        val createRaw = bridge.createAndroidDagPhase4AudioMixBusSession(
            nodeId = "mixbus_destroy_idempotent",
            sampleRate = 48000,
            channelCount = 1,
            maxFramesPerMix = 4,
        )
        val sessionId = extractField(createRaw, "sessionId")
        if (sessionId == null || !createRaw.startsWith("status=PASS")) {
            return LaneResult(
                name = "destroyIdempotent",
                pass = false,
                raw = mapOf("create" to createRaw),
                detail = "session create failed: $createRaw",
            )
        }

        val firstDestroyRaw = bridge.destroyAndroidDagPhase4AudioMixBusSession(sessionId)
        val secondDestroyRaw = bridge.destroyAndroidDagPhase4AudioMixBusSession(sessionId)

        val pass = firstDestroyRaw.startsWith("status=PASS") &&
            secondDestroyRaw.startsWith("status=FAIL") &&
            extractField(secondDestroyRaw, "reason") == "session_not_found"

        return LaneResult(
            name = "destroyIdempotent",
            pass = pass,
            raw = mapOf("create" to createRaw, "destroy1" to firstDestroyRaw, "destroy2" to secondDestroyRaw),
            detail = if (pass) {
                "ok"
            } else {
                "expected destroy1=PASS destroy2=FAIL/session_not_found: $firstDestroyRaw / $secondDestroyRaw"
            },
        )
    }

    private fun laneTopologyAndPorts(bridge: VanguardNativeBridge): LaneResult {
        val createRaw = bridge.createAndroidDagPhase4AudioMixBusSession(
            nodeId = "mixbus_topology",
            sampleRate = 48000,
            channelCount = 2,
            maxFramesPerMix = 8,
        )
        val sessionId = extractField(createRaw, "sessionId")
        val topologyOk = createRaw.startsWith("status=PASS") &&
            extractField(createRaw, "kind") == "processing" &&
            extractField(createRaw, "type") == "audio_mix_bus" &&
            extractField(createRaw, "inputPortCount") == "2" &&
            extractField(createRaw, "inputPort0") == "primary_audio_in" &&
            extractField(createRaw, "inputPort1") == "secondary_audio_in" &&
            extractField(createRaw, "outputPortCount") == "1" &&
            extractField(createRaw, "outputPort0") == "mixed_audio_out"

        var destroyRaw = "status=FAIL;reason=not_run"
        if (sessionId != null) {
            destroyRaw = bridge.destroyAndroidDagPhase4AudioMixBusSession(sessionId)
        }

        val pass = topologyOk && destroyRaw.startsWith("status=PASS")
        return LaneResult(
            name = "topologyPorts",
            pass = pass,
            raw = mapOf("create" to createRaw, "destroy" to destroyRaw),
            detail = if (pass) "ok" else "topology/port mismatch or destroy failed: create=$createRaw destroy=$destroyRaw",
        )
    }

    // ── Shared lane runners ─────────────────────────────────────────────────────

    private fun runSuccessMixLane(
        bridge: VanguardNativeBridge,
        name: String,
        nodeSampleRate: Int,
        nodeChannelCount: Int,
        maxFramesPerMix: Int,
        tracks: List<TrackSpec>,
        framesToMix: Int,
    ): LaneResult {
        val raw = mutableMapOf<String, String>()

        val createRaw = bridge.createAndroidDagPhase4AudioMixBusSession(
            nodeId = name, sampleRate = nodeSampleRate, channelCount = nodeChannelCount,
            maxFramesPerMix = maxFramesPerMix,
        )
        raw["create"] = createRaw
        val sessionId = extractField(createRaw, "sessionId")
        if (sessionId == null || !createRaw.startsWith("status=PASS")) {
            return LaneResult(name, false, raw, "session create failed: $createRaw")
        }

        var addFailed = false
        for ((i, track) in tracks.withIndex()) {
            val addRaw = bridge.addAndroidDagPhase4AudioMixBusTrack(
                sessionId = sessionId,
                pcm16Buffer = directBuffer(track.pcm),
                frameCount = track.frameCount,
                sampleRate = track.sampleRate,
                channelCount = track.channelCount,
                gain = track.gain,
            )
            raw["add$i"] = addRaw
            if (!addRaw.startsWith("status=PASS")) {
                addFailed = true
            }
        }

        val outCapacitySamples = framesToMix * nodeChannelCount
        val outBuffer = ByteBuffer.allocateDirect(outCapacitySamples * 2).order(ByteOrder.nativeOrder())
        val mixRaw = if (addFailed) {
            "status=FAIL;reason=add_failed_precondition"
        } else {
            bridge.mixAndroidDagPhase4AudioMixBusSession(sessionId, framesToMix, outBuffer)
        }
        raw["mix"] = mixRaw

        val destroyRaw = bridge.destroyAndroidDagPhase4AudioMixBusSession(sessionId)
        raw["destroy"] = destroyRaw

        if (addFailed) {
            return LaneResult(name, false, raw, "one or more addTrack calls failed: $raw")
        }
        if (!mixRaw.startsWith("status=PASS")) {
            return LaneResult(name, false, raw, "expected mix success, got: $mixRaw")
        }
        if (!destroyRaw.startsWith("status=PASS")) {
            return LaneResult(name, false, raw, "destroy failed: $destroyRaw")
        }

        val expected = computeExpectedMix(nodeChannelCount, framesToMix, tracks)
        val actualSamples = readOutputSamples(outBuffer, expected.samples.size)
        if (!actualSamples.contentEquals(expected.samples)) {
            return LaneResult(
                name, false, raw,
                "output PCM mismatch: expected=${expected.samples.toList()} actual=${actualSamples.toList()}",
            )
        }

        val actualChecksum = extractField(mixRaw, "checksum")?.toULongOrNull()
        if (actualChecksum != expected.checksum) {
            return LaneResult(
                name, false, raw,
                "checksum mismatch: expected=${expected.checksum} actual=$actualChecksum",
            )
        }

        val actualClipped = extractField(mixRaw, "clipped")?.toBooleanStrictOrNull()
        if (actualClipped != expected.clipped) {
            return LaneResult(
                name, false, raw,
                "clipped mismatch: expected=${expected.clipped} actual=$actualClipped",
            )
        }

        return LaneResult(name, true, raw, "ok")
    }

    private fun runFailureMixLane(
        bridge: VanguardNativeBridge,
        name: String,
        nodeSampleRate: Int,
        nodeChannelCount: Int,
        maxFramesPerMix: Int,
        tracks: List<TrackSpec>,
        framesToMix: Int,
        expectedReason: String,
    ): LaneResult {
        val raw = mutableMapOf<String, String>()

        val createRaw = bridge.createAndroidDagPhase4AudioMixBusSession(
            nodeId = name, sampleRate = nodeSampleRate, channelCount = nodeChannelCount,
            maxFramesPerMix = maxFramesPerMix,
        )
        raw["create"] = createRaw
        val sessionId = extractField(createRaw, "sessionId")
        if (sessionId == null || !createRaw.startsWith("status=PASS")) {
            return LaneResult(name, false, raw, "session create failed: $createRaw")
        }

        for ((i, track) in tracks.withIndex()) {
            val addRaw = bridge.addAndroidDagPhase4AudioMixBusTrack(
                sessionId = sessionId,
                pcm16Buffer = directBuffer(track.pcm),
                frameCount = track.frameCount,
                sampleRate = track.sampleRate,
                channelCount = track.channelCount,
                gain = track.gain,
            )
            raw["add$i"] = addRaw
        }

        val outCapacitySamples = framesToMix * nodeChannelCount
        val outBuffer = ByteBuffer.allocateDirect(outCapacitySamples * 2).order(ByteOrder.nativeOrder())
        val mixRaw = bridge.mixAndroidDagPhase4AudioMixBusSession(sessionId, framesToMix, outBuffer)
        raw["mix"] = mixRaw

        val destroyRaw = bridge.destroyAndroidDagPhase4AudioMixBusSession(sessionId)
        raw["destroy"] = destroyRaw

        val pass = mixRaw.startsWith("status=FAIL") &&
            extractField(mixRaw, "reason") == expectedReason &&
            destroyRaw.startsWith("status=PASS")

        return LaneResult(
            name, pass, raw,
            if (pass) "ok" else "expected mix FAIL/$expectedReason and destroy PASS: mix=$mixRaw destroy=$destroyRaw",
        )
    }

    // ── Independent expected-value math (mirrors AudioMixBusNode::mix, never ──
    // reads native output as ground truth).

    private fun computeExpectedMix(
        nodeChannelCount: Int,
        framesToMix: Int,
        tracks: List<TrackSpec>,
    ): ExpectedMixOutcome {
        val accumulator = IntArray(framesToMix * nodeChannelCount)
        for (track in tracks) {
            for (frame in 0 until framesToMix) {
                if (frame >= track.frameCount) {
                    continue
                }
                when {
                    track.channelCount == nodeChannelCount -> {
                        for (ch in 0 until nodeChannelCount) {
                            val sample = track.pcm[frame * nodeChannelCount + ch].toInt()
                            accumulator[frame * nodeChannelCount + ch] += scaleTrunc(sample, track.gain)
                        }
                    }
                    track.channelCount == 1 && nodeChannelCount == 2 -> {
                        val mono = track.pcm[frame].toInt()
                        val scaled = scaleTrunc(mono, track.gain)
                        accumulator[frame * 2 + 0] += scaled
                        accumulator[frame * 2 + 1] += scaled
                    }
                    track.channelCount == 2 && nodeChannelCount == 1 -> {
                        val left = track.pcm[frame * 2 + 0].toInt()
                        val right = track.pcm[frame * 2 + 1].toInt()
                        val downmixed = (left + right) / 2
                        accumulator[frame] += scaleTrunc(downmixed, track.gain)
                    }
                }
            }
        }

        var clipped = false
        val samples = IntArray(accumulator.size)
        for (i in accumulator.indices) {
            var value = accumulator[i]
            if (value > 32767) {
                value = 32767
                clipped = true
            } else if (value < -32768) {
                value = -32768
                clipped = true
            }
            samples[i] = value
        }
        return ExpectedMixOutcome(samples, clipped, expectedChecksum(samples))
    }

    private fun scaleTrunc(sample: Int, gain: Double): Int = (sample.toDouble() * gain).toInt()

    private fun expectedChecksum(samples: IntArray): ULong {
        var checksum = 0uL
        for (sample in samples) {
            checksum = checksum * 31uL + sample.toShort().toUShort().toULong()
        }
        return checksum
    }

    private fun directBuffer(values: ShortArray): ByteBuffer {
        val buffer = ByteBuffer.allocateDirect(values.size * 2).order(ByteOrder.nativeOrder())
        buffer.asShortBuffer().put(values)
        return buffer
    }

    private fun readOutputSamples(buffer: ByteBuffer, sampleCount: Int): IntArray {
        val shortBuffer = buffer.asShortBuffer()
        return IntArray(sampleCount) { shortBuffer.get(it).toInt() }
    }

    private fun extractField(raw: String, field: String): String? {
        for (part in raw.split(";")) {
            val idx = part.indexOf('=')
            if (idx <= 0) continue
            if (part.substring(0, idx) == field) {
                return part.substring(idx + 1)
            }
        }
        return null
    }
}
