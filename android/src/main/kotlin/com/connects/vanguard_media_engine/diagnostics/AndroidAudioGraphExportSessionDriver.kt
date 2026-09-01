package com.connects.vanguard_media_engine.diagnostics

import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver
import java.nio.ByteBuffer
import java.nio.ByteOrder

// ── AndroidAudioGraphExportSessionDriver (P4-AUDIO-PASS2-GRAPH-NATIVE-SESSION) ─
//
// Synchronous diagnostic proof of the parameterized N-source native
// True-DAG audio graph export session seam
// (android_phase4_audio_graph_export_session_jni.cpp) through
// VanguardNativeBridge:
//   create -> addTrack xN (DecodedAudioPcmSourceNode 6-arg node-owned
//   ring/writer/provider, timelineStartPtsUs=0,
//   expectedFrameCount=totalFrames) -> prepare (GraphAudioScheduler
//   AutoDiscoverSourceProviders, null mix params = static unit gain, null
//   envelope) -> per-track full-window PCM ingest -> contiguous window
//   render -> idempotent destroy.
//
// Lanes (all fail-closed):
//   - sessionCreateOk / proofBoundaryOk: create PASS with the byte-identical
//     canonical proof boundary.
//   - longTimelineAdmissionOk: a 600-second track (48000 * 600 frames) is
//     admitted in a throwaway session (admission only; no PCM ingested).
//   - addEightTracksOk / totalTrackLimitRejectOk: 8 tracks admitted; the
//     9th rejects with total_track_count_exceeded:9.
//   - prepareBarrierOk: ingest/render before prepare reject with
//     session_not_prepared (throwaway session); addTrack after prepare
//     rejects with session_already_prepared.
//   - routedSourceCountOk: prepare reports routed=8/requested=8.
//   - contiguousWindowOk: re-rendering an already-rendered window rejects
//     with non_contiguous_window:<expected>/<got>.
//   - renderTwoWindowsOk / checksumNonZeroOk: two contiguous windows render
//     PASS after exact full-window ingest for every track before each
//     render; both mixed checksums are non-zero and bit-exactly match a
//     Kotlin-computed reference of the deterministic synthetic mix
//     (sum of 8 tracks, int16 clamp, checksum = c*31 + uint16(sample)).
//   - underrunFailClosedOk: a prepared one-track session rendered without
//     ingest FAILs with source_underrun:<trackId> (never a silent PASS).
//   - lifecycleDestroyIdempotentOk: destroy twice both report PASS.
//   - noProductionRouteSwapOk: structural non-claim — this slice is
//     driver/coordinator/native-session only; AndroidAudioMixdownEngine and
//     AndroidNativeAudioMixBusChunkMixer are untouched and no production
//     pass-2 route consults this seam.
//
// Honest boundary: diagnostic foundation only — no production route swap,
// no runtime/realtime sink, no AudioTrack/AAudio/OpenSL/Oboe, no
// MediaCodec/MediaExtractor, no file IO, no native worker threads, no
// gain/envelope production use, no app/editor/product, no streaming/cache,
// no iOS.
class AndroidAudioGraphExportSessionDriver {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_AUDIO_GRAPH_EXPORT_SESSION_SMOKE_FAIL"

        // Must stay byte-identical to kProofBoundary in
        // android_phase4_audio_graph_export_session_jni.cpp.
        const val PROOF_BOUNDARY =
            "native_true_dag_pass2_graph_export_session_diagnostic_only_n_source_node_owned_ring_graph_" +
                "scheduler_mixbus_unit_gain_no_production_route_swap_no_android_mixdown_engine_change_no_" +
                "legacy_chunk_mixer_change_no_runtime_realtime_sink_no_audiotrack_no_aaudio_no_opensl_no_" +
                "oboe_no_mediacodec_no_mediaextractor_no_file_io_no_native_worker_threads_no_app_no_editor_" +
                "no_product_no_streaming_no_cache_no_ios"

        private const val SAMPLE_RATE = 48000
        private const val CHANNEL_COUNT = 2
        private const val MAX_FRAMES_PER_MIX = 1024
        private const val WINDOW_FRAMES = 1024
        private const val TRACK_COUNT = 8
        private const val TOTAL_FRAMES = 2L * WINDOW_FRAMES // exactly two windows
        private const val LONG_TIMELINE_FRAMES = 48000L * 600L

        private val LANE_KEYS = listOf(
            "sessionCreateOk",
            "longTimelineAdmissionOk",
            "addEightTracksOk",
            "totalTrackLimitRejectOk",
            "prepareBarrierOk",
            "routedSourceCountOk",
            "contiguousWindowOk",
            "renderTwoWindowsOk",
            "checksumNonZeroOk",
            "underrunFailClosedOk",
            "lifecycleDestroyIdempotentOk",
            "proofBoundaryOk",
            "noProductionRouteSwapOk",
        )

        // Stable failure-shaped result (same lane/metric key shape) for a
        // caller that never got a run.
        fun failedResult(reason: String): RunResult =
            AndroidAudioGraphExportSessionDriver().makeResult(
                pass = false,
                failureReason = reason,
                lanes = LANE_KEYS.associateWith { false },
                metrics = emptyMap(),
                details = "",
            )
    }

    // Lanes/metrics are flat maps so the coordinator payload and the
    // failure default shape stay identical by construction.
    data class RunResult(
        val pass: Boolean,
        val status: String,
        val marker: String,
        val proofBoundary: String,
        val failureReason: String,
        val details: String,
        val lanes: Map<String, Any?>,
        val metrics: Map<String, Any?>,
    )

    private class FailClosed(val reason: String) : Exception(reason)

    fun run(): RunResult {
        val lanes = LANE_KEYS.associateWithTo(mutableMapOf<String, Any?>()) { false }
        val metrics = mutableMapOf<String, Any?>()
        val detailParts = mutableListOf<String>()
        val bridge = makeBridge()
        // Every session created by this run; destroyed defensively in
        // finally (destroy is idempotent, repeated destroys are PASS).
        val createdSessionIds = mutableListOf<String>()
        try {
            // ── Lane: sessionCreateOk + proofBoundaryOk ──────────────────
            val createKv = parseStatus(
                bridge.createAndroidDagPhase4AudioGraphExportSession(
                    SAMPLE_RATE, CHANNEL_COUNT, MAX_FRAMES_PER_MIX,
                )
            )
            requirePass(createKv, "main_session_create")
            val mainSessionId = stringField(createKv, "sessionId")
            createdSessionIds.add(mainSessionId)
            lanes["sessionCreateOk"] = true
            lanes["proofBoundaryOk"] = stringField(createKv, "proofBoundary") == PROOF_BOUNDARY
            if (lanes["proofBoundaryOk"] != true) {
                throw FailClosed("proof_boundary_mismatch")
            }

            // ── Lane: longTimelineAdmissionOk (throwaway; admission only,
            // no 600s PCM ingest) ────────────────────────────────────────
            val longKv = parseStatus(
                bridge.createAndroidDagPhase4AudioGraphExportSession(
                    SAMPLE_RATE, CHANNEL_COUNT, MAX_FRAMES_PER_MIX,
                )
            )
            requirePass(longKv, "long_timeline_session_create")
            val longSessionId = stringField(longKv, "sessionId")
            createdSessionIds.add(longSessionId)
            val longAddKv = parseStatus(
                bridge.addAndroidDagPhase4AudioGraphExportTrack(
                    longSessionId, "long_track", LONG_TIMELINE_FRAMES,
                )
            )
            requirePass(longAddKv, "long_timeline_track_admission")
            if (longField(longAddKv, "totalFrames") != LONG_TIMELINE_FRAMES) {
                throw FailClosed("long_timeline_total_frames_mismatch")
            }
            requirePass(
                parseStatus(bridge.destroyAndroidDagPhase4AudioGraphExportSession(longSessionId)),
                "long_timeline_session_destroy",
            )
            lanes["longTimelineAdmissionOk"] = true
            metrics["longTimelineFrames"] = LONG_TIMELINE_FRAMES

            // ── Lane: addEightTracksOk ───────────────────────────────────
            val trackIds = (0 until TRACK_COUNT).map { "track_$it" }
            for ((index, trackId) in trackIds.withIndex()) {
                val addKv = parseStatus(
                    bridge.addAndroidDagPhase4AudioGraphExportTrack(
                        mainSessionId, trackId, TOTAL_FRAMES,
                    )
                )
                requirePass(addKv, "add_track_$trackId")
                if (longField(addKv, "trackIndex") != index.toLong()) {
                    throw FailClosed("track_index_mismatch_$trackId")
                }
            }
            lanes["addEightTracksOk"] = true
            metrics["requestedTrackCount"] = TRACK_COUNT.toLong()

            // ── Lane: totalTrackLimitRejectOk (9th track) ────────────────
            val ninthKv = parseStatus(
                bridge.addAndroidDagPhase4AudioGraphExportTrack(
                    mainSessionId, "track_8", TOTAL_FRAMES,
                )
            )
            val ninthReason = requireFailReason(ninthKv, "ninth_track_add")
            metrics["totalTrackLimitReason"] = ninthReason
            if (ninthReason != "total_track_count_exceeded:9") {
                throw FailClosed("unexpected_track_limit_reason:$ninthReason")
            }
            lanes["totalTrackLimitRejectOk"] = true

            // ── Lane: prepareBarrierOk part 1 (throwaway session:
            // ingest/render before prepare reject session_not_prepared) ──
            val pbKv = parseStatus(
                bridge.createAndroidDagPhase4AudioGraphExportSession(
                    SAMPLE_RATE, CHANNEL_COUNT, MAX_FRAMES_PER_MIX,
                )
            )
            requirePass(pbKv, "prepare_barrier_session_create")
            val pbSessionId = stringField(pbKv, "sessionId")
            createdSessionIds.add(pbSessionId)
            requirePass(
                parseStatus(
                    bridge.addAndroidDagPhase4AudioGraphExportTrack(
                        pbSessionId, "pb_track", TOTAL_FRAMES,
                    )
                ),
                "prepare_barrier_track_add",
            )
            val pbScratch = allocatePcmBuffer()
            fillWindowPcm(pbScratch, trackIndex = 0, startFrame = 0L)
            val pbIngestReason = requireFailReason(
                parseStatus(
                    bridge.ingestAndroidDagPhase4AudioGraphExportTrackPcm(
                        pbSessionId, "pb_track", pbScratch, WINDOW_FRAMES,
                    )
                ),
                "ingest_before_prepare",
            )
            val pbRenderReason = requireFailReason(
                parseStatus(
                    bridge.renderAndroidDagPhase4AudioGraphExportWindow(
                        pbSessionId, 0L, WINDOW_FRAMES, allocateOutBuffer(),
                    )
                ),
                "render_before_prepare",
            )
            if (pbIngestReason != "session_not_prepared" || pbRenderReason != "session_not_prepared") {
                throw FailClosed(
                    "unexpected_pre_prepare_reason:$pbIngestReason/$pbRenderReason"
                )
            }
            requirePass(
                parseStatus(bridge.destroyAndroidDagPhase4AudioGraphExportSession(pbSessionId)),
                "prepare_barrier_session_destroy",
            )

            // ── Lane: routedSourceCountOk (prepare main session) ─────────
            val prepareKv = parseStatus(
                bridge.prepareAndroidDagPhase4AudioGraphExportSession(mainSessionId)
            )
            requirePass(prepareKv, "main_session_prepare")
            val routed = longField(prepareKv, "routedSourceCount")
            val requested = longField(prepareKv, "requestedTrackCount")
            metrics["routedSourceCount"] = routed
            if (routed != TRACK_COUNT.toLong() || requested != TRACK_COUNT.toLong()) {
                throw FailClosed("routed_source_count_unexpected:$routed/$requested")
            }
            lanes["routedSourceCountOk"] = true

            // ── Lane: prepareBarrierOk part 2 (addTrack after prepare) ───
            val lateAddReason = requireFailReason(
                parseStatus(
                    bridge.addAndroidDagPhase4AudioGraphExportTrack(
                        mainSessionId, "late_track", TOTAL_FRAMES,
                    )
                ),
                "add_track_after_prepare",
            )
            if (lateAddReason != "session_already_prepared") {
                throw FailClosed("unexpected_post_prepare_reason:$lateAddReason")
            }
            lanes["prepareBarrierOk"] = true

            // ── Lanes: renderTwoWindowsOk + contiguousWindowOk +
            // checksumNonZeroOk ──────────────────────────────────────────
            val ingestBuffer = allocatePcmBuffer()
            val outBuffer = allocateOutBuffer()
            val windowChecksums = mutableListOf<String>()
            var framesRenderedTotal = 0L
            var windowCount = 0L
            var silentWindowCount = 0L

            for (window in 0 until 2) {
                val startFrame = window.toLong() * WINDOW_FRAMES
                // Exact full-window ingest for EVERY track before each
                // render keeps all node-owned rings in lockstep.
                for ((trackIndex, trackId) in trackIds.withIndex()) {
                    fillWindowPcm(ingestBuffer, trackIndex, startFrame)
                    val ingestKv = parseStatus(
                        bridge.ingestAndroidDagPhase4AudioGraphExportTrackPcm(
                            mainSessionId, trackId, ingestBuffer, WINDOW_FRAMES,
                        )
                    )
                    requirePass(ingestKv, "ingest_window${window}_$trackId")
                    if (longField(ingestKv, "acceptedFrames") != WINDOW_FRAMES.toLong()) {
                        throw FailClosed("partial_ingest_window${window}_$trackId")
                    }
                }

                val renderKv = parseStatus(
                    bridge.renderAndroidDagPhase4AudioGraphExportWindow(
                        mainSessionId, startFrame, WINDOW_FRAMES, outBuffer,
                    )
                )
                requirePass(renderKv, "render_window$window")
                if (longField(renderKv, "framesRendered") != WINDOW_FRAMES.toLong() ||
                    longField(renderKv, "routedTrackCount") != TRACK_COUNT.toLong() ||
                    stringField(renderKv, "mixCalled") != "true" ||
                    stringField(renderKv, "silence") != "false"
                ) {
                    throw FailClosed("render_window${window}_shape_unexpected")
                }
                framesRenderedTotal += longField(renderKv, "framesRendered")
                windowCount = longField(renderKv, "windowCount")
                silentWindowCount = longField(renderKv, "silentWindowCount")
                windowChecksums.add(stringField(renderKv, "checksum"))

                if (window == 0) {
                    // Retry of the already-rendered window 0 must reject:
                    // expected cursor is now 1024, got 0.
                    val retryReason = requireFailReason(
                        parseStatus(
                            bridge.renderAndroidDagPhase4AudioGraphExportWindow(
                                mainSessionId, 0L, WINDOW_FRAMES, outBuffer,
                            )
                        ),
                        "retry_window0",
                    )
                    metrics["nonContiguousReason"] = retryReason
                    if (retryReason != "non_contiguous_window:$WINDOW_FRAMES/0") {
                        throw FailClosed("unexpected_non_contiguous_reason:$retryReason")
                    }
                    lanes["contiguousWindowOk"] = true
                }
            }
            if (windowCount != 2L || silentWindowCount != 0L) {
                throw FailClosed("window_count_unexpected:$windowCount/$silentWindowCount")
            }
            lanes["renderTwoWindowsOk"] = true
            metrics["framesRendered"] = framesRenderedTotal
            metrics["windowCount"] = windowCount
            metrics["silentWindowCount"] = silentWindowCount
            metrics["checksumWindow0Hex"] = windowChecksums[0]
            metrics["checksumWindow1Hex"] = windowChecksums[1]

            // Deterministic checksum proof: non-zero AND bit-exactly equal
            // to the Kotlin-computed reference of the same unit-gain mix.
            val expected0 = expectedWindowChecksumHex(0L)
            val expected1 = expectedWindowChecksumHex(WINDOW_FRAMES.toLong())
            val zeroChecksum = "0".padStart(16, '0')
            if (windowChecksums[0] == zeroChecksum || windowChecksums[1] == zeroChecksum) {
                throw FailClosed("mixed_checksum_zero")
            }
            if (windowChecksums[0] != expected0 || windowChecksums[1] != expected1) {
                throw FailClosed(
                    "checksum_reference_mismatch:${windowChecksums[0]}/$expected0"
                )
            }
            lanes["checksumNonZeroOk"] = true

            // ── Lane: underrunFailClosedOk (prepared one-track session,
            // no ingest: render must FAIL source_underrun, never a silent
            // PASS) ──────────────────────────────────────────────────────
            val urKv = parseStatus(
                bridge.createAndroidDagPhase4AudioGraphExportSession(
                    SAMPLE_RATE, CHANNEL_COUNT, MAX_FRAMES_PER_MIX,
                )
            )
            requirePass(urKv, "underrun_session_create")
            val urSessionId = stringField(urKv, "sessionId")
            createdSessionIds.add(urSessionId)
            requirePass(
                parseStatus(
                    bridge.addAndroidDagPhase4AudioGraphExportTrack(
                        urSessionId, "underrun_track", TOTAL_FRAMES,
                    )
                ),
                "underrun_track_add",
            )
            requirePass(
                parseStatus(bridge.prepareAndroidDagPhase4AudioGraphExportSession(urSessionId)),
                "underrun_session_prepare",
            )
            val underrunReason = requireFailReason(
                parseStatus(
                    bridge.renderAndroidDagPhase4AudioGraphExportWindow(
                        urSessionId, 0L, WINDOW_FRAMES, outBuffer,
                    )
                ),
                "underrun_render",
            )
            metrics["underrunReason"] = underrunReason
            if (underrunReason != "source_underrun:underrun_track") {
                throw FailClosed("unexpected_underrun_reason:$underrunReason")
            }
            requirePass(
                parseStatus(bridge.destroyAndroidDagPhase4AudioGraphExportSession(urSessionId)),
                "underrun_session_destroy",
            )
            lanes["underrunFailClosedOk"] = true

            // ── Lane: lifecycleDestroyIdempotentOk (main session, twice) ─
            val destroy1 = parseStatus(
                bridge.destroyAndroidDagPhase4AudioGraphExportSession(mainSessionId)
            )
            requirePass(destroy1, "main_session_destroy_first")
            if (stringField(destroy1, "destroyed") != "true") {
                throw FailClosed("first_destroy_not_effective")
            }
            requirePass(
                parseStatus(bridge.destroyAndroidDagPhase4AudioGraphExportSession(mainSessionId)),
                "main_session_destroy_second",
            )
            lanes["lifecycleDestroyIdempotentOk"] = true

            // ── Lane: noProductionRouteSwapOk (structural non-claim) ─────
            // This slice touches only this driver, its coordinator, the
            // bridge externals, and the diagnostic-only native session;
            // AndroidAudioMixdownEngine and AndroidNativeAudioMixBusChunkMixer
            // remain byte-unchanged and no production pass-2 route consults
            // this seam.
            lanes["noProductionRouteSwapOk"] = true

            detailParts.add("nodeOwnedRingSourceNodesLockstepTimeline=true")
            detailParts.add("static_unit_gain_null_envelope_only")
            detailParts.add("no_production_route_swap_no_mixdown_engine_change")
            return makeResult(true, "", lanes, metrics, detailParts.joinToString("|"))
        } catch (e: Throwable) {
            val reason = when (e) {
                is FailClosed -> e.reason
                else -> "exception:${e.javaClass.simpleName}:${e.message}"
            }
            return makeResult(false, reason, lanes, metrics, detailParts.joinToString("|"))
        } finally {
            // Defensive cleanup: destroy is idempotent, so re-destroying
            // sessions already destroyed by their lanes is a PASS no-op.
            for (sessionId in createdSessionIds) {
                try {
                    bridge.destroyAndroidDagPhase4AudioGraphExportSession(sessionId)
                } catch (_: Throwable) {
                    // Cleanup must never mask the run's own verdict.
                }
            }
        }
    }

    private fun makeBridge(): VanguardNativeBridge {
        val diagnostics = VanguardDiagnostics()
        return VanguardNativeBridge(
            lifecycleObserver = VanguardLifecycleObserver(diagnostics),
            diagnostics = diagnostics,
            codecAdapter = null,
        )
    }

    // Deterministic synthetic PCM. Amplitudes are small on purpose: the
    // 8-track sum stays far below int16 clipping, so the Kotlin reference
    // checksum needs no saturation cases while the clamp is still applied
    // identically to native.
    private fun trackSample(trackIndex: Int, frameIndex: Long, channel: Int): Short {
        val v = ((frameIndex + trackIndex * 37L + channel * 11L) % 53L).toInt() + trackIndex + 1
        return v.toShort()
    }

    private fun allocatePcmBuffer(): ByteBuffer =
        ByteBuffer.allocateDirect(WINDOW_FRAMES * CHANNEL_COUNT * 2)
            .order(ByteOrder.nativeOrder())

    private fun allocateOutBuffer(): ByteBuffer = allocatePcmBuffer()

    private fun fillWindowPcm(buffer: ByteBuffer, trackIndex: Int, startFrame: Long) {
        buffer.clear()
        for (f in 0 until WINDOW_FRAMES) {
            for (c in 0 until CHANNEL_COUNT) {
                buffer.putShort(trackSample(trackIndex, startFrame + f, c))
            }
        }
        // Native reads from byte offset 0 by capacity; position is unused.
    }

    // Bit-exact reference of the native unit-gain mix checksum for one
    // window: per output sample, sum the 8 track samples in int32, clamp to
    // int16, then checksum = checksum * 31 + uint16(sample). Kotlin Long
    // multiplication/addition wraps identically to native uint64 in the low
    // 64 bits, and %016llx equals the zero-padded unsigned hex below.
    private fun expectedWindowChecksumHex(startFrame: Long): String {
        var checksum = 0L
        for (f in 0 until WINDOW_FRAMES) {
            for (c in 0 until CHANNEL_COUNT) {
                var acc = 0
                for (t in 0 until TRACK_COUNT) {
                    acc += trackSample(t, startFrame + f, c).toInt()
                }
                val clamped = acc.coerceIn(-32768, 32767)
                checksum = checksum * 31L + (clamped.toLong() and 0xFFFFL)
            }
        }
        return java.lang.Long.toHexString(checksum).padStart(16, '0')
    }

    private fun requirePass(kv: Map<String, String>, step: String) {
        val status = kv["status"] ?: throw FailClosed("missing_status_$step")
        if (status != "PASS") {
            throw FailClosed("${step}_failed:${kv["reason"] ?: status}")
        }
    }

    private fun requireFailReason(kv: Map<String, String>, step: String): String {
        val status = kv["status"] ?: throw FailClosed("missing_status_$step")
        if (status != "FAIL") {
            throw FailClosed("${step}_unexpectedly_passed")
        }
        return kv["reason"] ?: throw FailClosed("missing_reason_$step")
    }

    private fun stringField(kv: Map<String, String>, key: String): String =
        kv[key] ?: throw FailClosed("missing_native_field_$key")

    private fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw FailClosed("missing_native_field_$key")

    private fun parseStatus(raw: String): Map<String, String> =
        raw.split(';').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx <= 0) null else part.substring(0, idx) to part.substring(idx + 1)
        }.toMap()

    private fun makeResult(
        pass: Boolean,
        failureReason: String,
        lanes: Map<String, Any?>,
        metrics: Map<String, Any?>,
        details: String,
    ): RunResult {
        val lanesOut = lanes.toMutableMap()
        lanesOut["canonical"] = pass
        return RunResult(
            pass = pass,
            status = if (pass) "pass" else failureReason.substringBefore(':').ifBlank { "fail" },
            marker = if (pass) PASS_MARKER else FAIL_MARKER,
            proofBoundary = PROOF_BOUNDARY,
            failureReason = failureReason,
            details = details,
            lanes = lanesOut,
            metrics = metrics,
        )
    }
}
