package com.connects.vanguard_media_engine.diagnostics

import com.connects.vanguard_media_engine.bridge.VanguardNativeBridge
import com.connects.vanguard_media_engine.lifecycle.VanguardLifecycleObserver

// ── AndroidAudioSchedulerEnvelopeDriver (P4-AUDIO-SCHEDULER-ENVELOPE-WIRING) ─
//
// Drives the one-shot `runAndroidDagPhase4AudioSchedulerEnvelopeSmoke` JNI
// route (android_phase4_audio_scheduler_envelope_jni.cpp) and validates
// every native acceptance lane fail-closed:
//   - wiring lanes (scheduler-applied envelope output matching a direct
//     AudioMixBusNode reference mix, scheduler-owned window pts origin
//     across two consecutive windows, three-source params composition of
//     one envelope / one static-gain / one unit-null source, mix-output
//     envelope metric propagation into SchedulerOutput),
//   - back-compat lane (no params map and an empty params map both
//     bit-identical to the prior unit-gain/null-envelope scheduler output),
//   - reject lanes (out-of-range static source gain, out-of-range envelope
//     gain, window pts overflow, stale graph generation — all with no
//     output mutation),
//   - structural lanes (no per-window allocation, stack-scoped lifecycle).
//
// The native route is fully stack-scoped and synchronous: every graph,
// scheduler, provider, and envelope it creates is destroyed before the
// reply string returns, so there is no handle, no registry, no OS
// resource, and nothing to release on the Kotlin side.
//
// Honest boundary: diagnostic only — GraphAudioScheduler envelope wiring
// only, no production mixdown/export change, no export/pass-2 reroute, no
// runtime queue, no backpressure, no realtime sink, no
// AudioTrack/AAudio/OpenSL/Oboe, no MediaCodec/MediaExtractor, no file IO,
// no native worker threads, no app/editor/product, no streaming/cache, no
// iOS.
class AndroidAudioSchedulerEnvelopeDriver {

    companion object {
        const val PASS_MARKER = "ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_SMOKE_PASS"
        const val FAIL_MARKER = "ANDROID_DAG_PHASE4_AUDIO_SCHEDULER_ENVELOPE_SMOKE_FAIL"

        // Must stay byte-identical to kProofBoundary in
        // android_phase4_audio_scheduler_envelope_jni.cpp.
        const val PROOF_BOUNDARY =
            "native_graph_audio_scheduler_envelope_wiring_diagnostic_only_scheduler_stamps_window_pts_" +
                "origin_non_owning_per_source_static_gain_and_envelope_params_no_production_mixdown_change_" +
                "no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_" +
                "audio_track_no_aaudio_no_opensl_no_oboe_no_media_codec_no_media_extractor_no_file_io_no_" +
                "native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios"

        // Every native acceptance lane; each must be reported and true.
        private val LANE_KEYS = listOf(
            "schedulerEnvelopeAppliedOk",
            "windowPtsOriginOk",
            "multiSourceParamsOk",
            "nullEnvelopeBackCompatOk",
            "mixOutputEnvelopeMetricsPropagatedOk",
            "invalidSourceGainFailClosedOk",
            "invalidEnvelopeGainFailClosedOk",
            "windowPtsOverflowRejectOk",
            "staleGenerationFailClosedOk",
            "noPerWindowAllocationOk",
            "lifecycleOk",
            "stackScoped",
        )

        private val METRIC_LONG_KEYS = listOf(
            "routedSourceCount",
            "windowFrames",
            "windowPtsUs0",
            "windowPtsUs1",
            "framesRenderedWindow0",
            "framesRenderedWindow1",
            "envelopeEvaluationsWindow0",
            "envelopeEvaluationsWindow1",
            "sampleRate",
            "channelCount",
            "maxFramesPerMix",
        )

        private val METRIC_DOUBLE_KEYS = listOf(
            "minEffectiveGainWindow0",
            "maxEffectiveGainWindow0",
        )

        private val METRIC_STRING_KEYS = listOf(
            "schedulerChecksumWindow0Hex",
            "schedulerChecksumWindow1Hex",
            "referenceChecksumWindow0Hex",
            "referenceChecksumWindow1Hex",
            "unitGainChecksumWindow0Hex",
            "wrongOriginChecksumWindow1Hex",
        )

        // Stable failure-shaped result (same lane/metric key shape) for a
        // caller that never got a run.
        fun failedResult(reason: String): RunResult =
            AndroidAudioSchedulerEnvelopeDriver().makeResult(
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
        try {
            val diagnostics = VanguardDiagnostics()
            val bridge = VanguardNativeBridge(
                lifecycleObserver = VanguardLifecycleObserver(diagnostics),
                diagnostics = diagnostics,
                codecAdapter = null,
            )
            val kv = parseStatus(bridge.runAndroidDagPhase4AudioSchedulerEnvelopeSmoke())
            val nativeStatus = kv["status"] ?: throw FailClosed("native_status_field_missing")
            metrics["nativeStatus"] = nativeStatus

            // Every lane must be present and reported true by native; the
            // first false lane (or the native reason) becomes the failure.
            var firstFailedLane = ""
            for (key in LANE_KEYS) {
                val value = booleanField(kv, key)
                lanes[key] = value
                if (!value && firstFailedLane.isEmpty()) firstFailedLane = key
            }

            for (key in METRIC_LONG_KEYS) metrics[key] = longField(kv, key)
            for (key in METRIC_DOUBLE_KEYS) metrics[key] = doubleField(kv, key)
            for (key in METRIC_STRING_KEYS) metrics[key] = stringField(kv, key)

            // The proof boundary must round-trip byte-identically between
            // native and Kotlin.
            if (stringField(kv, "proofBoundary") != PROOF_BOUNDARY) {
                throw FailClosed("proof_boundary_mismatch")
            }

            // Kotlin-side re-checks of the mandatory structural facts (the
            // native lanes already enforce them; this keeps the driver
            // fail-closed against a lane/metric drift).
            val windowFrames = longField(kv, "windowFrames")
            if (longField(kv, "routedSourceCount") != 3L) {
                throw FailClosed("routed_source_count_not_three")
            }
            if (longField(kv, "framesRenderedWindow0") != windowFrames ||
                longField(kv, "framesRenderedWindow1") != windowFrames
            ) {
                throw FailClosed("rendered_window_frame_count_mismatch")
            }
            if (longField(kv, "envelopeEvaluationsWindow0") != windowFrames ||
                longField(kv, "envelopeEvaluationsWindow1") != windowFrames
            ) {
                throw FailClosed("envelope_evaluation_count_mismatch")
            }
            if (longField(kv, "windowPtsUs1") <= longField(kv, "windowPtsUs0")) {
                throw FailClosed("window_pts_origin_not_advancing")
            }

            detailParts.add("nativeOneShotStackScoped=true")
            detailParts.add("scheduler_owns_window_origin_mix_bus_owns_per_frame_gain_math")
            detailParts.add("no_production_mixdown_or_export_reroute_change")

            if (nativeStatus != "PASS") {
                val reason = (kv["reason"] ?: "").ifBlank {
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
                else -> "exception:${e.javaClass.simpleName}:${e.message}"
            }
            return makeResult(false, reason, lanes, metrics, detailParts.joinToString("|"))
        }
    }

    private fun booleanField(kv: Map<String, String>, key: String): Boolean =
        when (kv[key]) {
            "true" -> true
            "false" -> false
            else -> throw FailClosed("missing_or_non_boolean_native_field_$key")
        }

    private fun longField(kv: Map<String, String>, key: String): Long =
        kv[key]?.toLongOrNull() ?: throw FailClosed("missing_native_field_$key")

    private fun doubleField(kv: Map<String, String>, key: String): Double =
        kv[key]?.toDoubleOrNull() ?: throw FailClosed("missing_native_field_$key")

    private fun stringField(kv: Map<String, String>, key: String): String =
        kv[key] ?: throw FailClosed("missing_native_field_$key")

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
