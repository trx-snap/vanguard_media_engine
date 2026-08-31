package com.connects.vanguard_media_engine.diagnostics

// ── AndroidAudioMixBusTimelineDriver (P4-AUDIO-MIXBUS-TIMELINE-OWNERSHIP) ─
//
// Drives the one-shot native AudioMixBusNode timeline-aware per-frame
// volume envelope diagnostic through
// [AndroidAudioMixBusTimelineNativeSession] and validates every native
// acceptance lane fail-closed:
//   - Kotlin AndroidAudioVolumeEnvelope parity lanes (normalize / static
//     fade / forTrack fallback / >=2000-sample analytic evaluation parity
//     within 1e-9 / empty-envelope silence / sub-ms rules / boundary
//     inclusivity / mixGain normalization),
//   - mix-path lanes (per-frame envelope application, static-gain
//     composition, null-envelope bit-identical back-compat, single
//     quantization vs the pre-scale approximation, cursor monotonicity and
//     per-call reset, floor PTS derivation),
//   - reject lanes (unsupported interpolation, keyframe cap, negative or
//     inverted envelope track bounds, negative envelopeStartPtsUs,
//     out-of-range envelope gain — all before output mutation),
//   - structural lanes (no per-mix allocation, stack-scoped lifecycle) and
//     the source-level honesty lanes (scheduler unchanged, production
//     mixdown untouched).
//
// Honest boundary: native timeline/envelope ownership is a P0 prerequisite
// for the production graph reroute, NOT a hard blocker for the pure
// runtime queue. GraphAudioScheduler keeps emitting unit gain / null
// envelope and the production export chunk mixer is untouched; the
// scheduler/production lanes are source-level honesty lanes backed by the
// null-envelope back-compat proof, not a runtime execution of production
// export. No runtime queue, no backpressure, no realtime sink, no threads
// in native, no AudioTrack/AAudio, no MediaCodec/MediaExtractor, no file
// IO, no streaming/cache, no iOS, no product/editor UI.
class AndroidAudioMixBusTimelineDriver {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_AUDIO_MIXBUS_TIMELINE_SMOKE_FAIL"

        // Must stay byte-identical to kProofBoundary in
        // android_phase4_audio_mixbus_timeline_jni.cpp.
        const val PROOF_BOUNDARY =
            "native_audio_mix_bus_per_frame_volume_envelope_diagnostic_only_linear_interpolation_only_" +
                "kotlin_android_audio_volume_envelope_parity_normalize_static_fade_and_evaluate_ported_to_" +
                "cpp_node_owns_gain_math_caller_owns_window_origin_no_scheduler_wiring_no_production_" +
                "mixdown_change_no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_" +
                "realtime_sink_no_threads_no_audio_track_no_aaudio_no_media_codec_no_file_io_no_streaming_" +
                "no_cache_no_ios_no_product_no_editor_no_connects_app"

        // Native reports max |nativeGain - kotlinReferenceGain| scaled by
        // 1e15, so the mandatory 1e-9 analytic parity bound is 1e6 scaled.
        private const val MAX_GAIN_DIFF_SCALED_BOUND = 1_000_000L
        private const val MIN_EVALUATION_SAMPLES = 2_000L

        // Every native acceptance lane; each must be reported and true.
        private val LANE_KEYS = listOf(
            "envelopeNormalizationParityOk",
            "envelopeStaticFadePathParityOk",
            "envelopeForTrackFallbackParityOk",
            "envelopeEvaluationParityOk",
            "emptyEnvelopeSilenceParityOk",
            "subMillisecondHoldOk",
            "boundaryInclusivityOk",
            "mixGainNormalizationOk",
            "perFrameEnvelopeAppliedOk",
            "staticGainCompositionOk",
            "nullEnvelopeBackCompatOk",
            "singleQuantizationOk",
            "envelopeCursorMonotonicOk",
            "envelopeCursorResetPerCallOk",
            "floorPtsDerivationOk",
            "unsupportedInterpolationRejectOk",
            "keyframeCapRejectOk",
            "invalidEnvelopeRangeRejectOk",
            "invalidEnvelopeStartPtsRejectOk",
            "invalidEnvelopeGainRejectOk",
            "noPerMixAllocationOk",
            "schedulerUnchangedOk",
            "productionMixdownUntouchedOk",
            "lifecycleOk",
            "stackScoped",
        )

        private val METRIC_LONG_KEYS = listOf(
            "normalizedKeyframeCount",
            "staticFadeKeyframeCount",
            "evaluationSampleCount",
            "maxGainDiffScaled",
            "envelopeEvaluations",
            "framesMixed",
            "sampleRate",
            "channelCount",
            "maxFramesPerMix",
        )

        private val METRIC_STRING_KEYS = listOf(
            "staticGainChecksumHex",
            "envelopeMixChecksumHex",
            "nullEnvelopeChecksumHex",
            "baselineStaticChecksumHex",
            "prescaleApproxChecksumHex",
            "singleQuantChecksumHex",
            "roundPtsChecksumHex",
            "envelopeGainRejectVia",
            "timelineOwnershipHonesty",
        )

        private val METRIC_DOUBLE_KEYS = listOf(
            "minEffectiveGain",
            "maxEffectiveGain",
        )

        // Stable failure-shaped result (same lane/metric key shape) for a
        // caller that never got a run.
        fun failedResult(reason: String): RunResult =
            AndroidAudioMixBusTimelineDriver().makeResult(
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
        val session = AndroidAudioMixBusTimelineNativeSession()
        val lanes = LANE_KEYS.associateWithTo(mutableMapOf<String, Any?>()) { false }
        val metrics = mutableMapOf<String, Any?>()
        val detailParts = mutableListOf<String>()
        try {
            val reply = session.runOnce()
            metrics["nativeStatus"] = session.stringField(reply.kv, "status")

            // Every lane must be present and reported true by native; the
            // first false lane (or the native reason) becomes the failure.
            var firstFailedLane = ""
            for (key in LANE_KEYS) {
                val value = session.booleanField(reply.kv, key)
                lanes[key] = value
                if (!value && firstFailedLane.isEmpty()) firstFailedLane = key
            }

            for (key in METRIC_LONG_KEYS) metrics[key] = session.longField(reply.kv, key)
            for (key in METRIC_DOUBLE_KEYS) metrics[key] = session.doubleField(reply.kv, key)
            for (key in METRIC_STRING_KEYS) metrics[key] = session.stringField(reply.kv, key)

            // The proof boundary must round-trip byte-identically between
            // native and Kotlin.
            val nativeBoundary = session.stringField(reply.kv, "proofBoundary")
            if (nativeBoundary != PROOF_BOUNDARY) {
                throw FailClosed("proof_boundary_mismatch")
            }

            // Kotlin-side re-checks of the mandatory analytic bounds (the
            // native lanes already enforce them; this keeps the driver
            // fail-closed against a lane/metric drift).
            if (session.longField(reply.kv, "evaluationSampleCount") < MIN_EVALUATION_SAMPLES) {
                throw FailClosed("evaluation_sample_count_below_minimum")
            }
            if (session.longField(reply.kv, "maxGainDiffScaled") > MAX_GAIN_DIFF_SCALED_BOUND) {
                throw FailClosed("analytic_parity_bound_exceeded")
            }
            if (session.longField(reply.kv, "framesMixed") <= 0L) {
                throw FailClosed("no_frames_mixed")
            }

            detailParts.add("nativeOneShotStackScoped=true")
            detailParts.add(
                "timeline_ownership_is_p0_prerequisite_for_production_graph_reroute_not_runtime_queue_blocker"
            )
            detailParts.add("scheduler_and_production_mixdown_lanes_are_source_level_honesty_lanes")

            if (!reply.pass) {
                val reason = reply.reason.ifBlank {
                    firstFailedLane.ifBlank { "native_diagnostic_failed" }
                }
                return makeResult(false, reason, lanes, metrics, detailParts.joinToString("|"))
            }
            if (firstFailedLane.isNotEmpty()) {
                // Native claimed PASS with a false lane: fail closed.
                return makeResult(
                    false, "lane_false_despite_pass_$firstFailedLane",
                    lanes, metrics, detailParts.joinToString("|"),
                )
            }
            return makeResult(true, "", lanes, metrics, detailParts.joinToString("|"))
        } catch (e: Throwable) {
            val reason = when (e) {
                is FailClosed -> e.reason
                is AndroidAudioMixBusTimelineNativeSession.Failure -> e.reason
                else -> "exception:${e.javaClass.simpleName}:${e.message}"
            }
            return makeResult(false, reason, lanes, metrics, detailParts.joinToString("|"))
        }
    }

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
