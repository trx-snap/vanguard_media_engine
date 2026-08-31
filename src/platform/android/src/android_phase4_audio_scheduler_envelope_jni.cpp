// P4-AUDIO-SCHEDULER-ENVELOPE-WIRING (sub-slice S under
// P4-AUDIO-GRAPH-TRANSPORT-CLOCK / P4-AUDIO-MIXBUS): one-shot, stack-scoped,
// single-threaded, synchronous native proof that GraphAudioScheduler now
// wires per-source static gain + non-owning AudioGainEnvelope pointers
// (resolved once at construction from an optional SourceMixParams map) into
// every AudioMixBusNode::MixTrack it builds, stamping the scheduler-owned
// window origin (windowPtsUs) into envelopeStartPtsUs so the mix bus owns
// the per-frame gain math, and propagates the mix bus envelope metrics into
// SchedulerOutput. A source with no params entry (or a scheduler built
// without a params map) stays bit-identical to the prior unit-gain/
// null-envelope scheduler output.
//
// Honest non-claims:
// - Diagnostic only: no production mixdown/export change, no export or
//   pass-2 graph reroute.
// - No runtime queue, no backpressure, no realtime sink.
// - No AudioTrack, AAudio, OpenSL, or Oboe.
// - No MediaCodec or MediaExtractor, no file IO.
// - No native worker threads.
// - No app/editor/product wiring, no streaming/cache, no iOS.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds (added via the Android-only target_sources block in
// src/CMakeLists.txt).
//
// JNI entry point (matching VanguardNativeBridge.kt):
//   runAndroidDagPhase4AudioSchedulerEnvelopeSmoke -> jstring

#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_gain_envelope.h"
#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/vector_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

using vanguard::audio::AudioGainEnvelope;
using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AudioSampleProvider;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::VectorAudioSampleProvider;
using vanguard::graph::Graph;
using SchedulerResult = GraphAudioScheduler::SchedulerResult;
using SchedulerOutput = GraphAudioScheduler::SchedulerOutput;
using SourceMixParams = GraphAudioScheduler::SourceMixParams;

// Must stay byte-identical to PROOF_BOUNDARY in
// AndroidAudioSchedulerEnvelopeDriver.kt.
constexpr const char* kProofBoundary =
    "native_graph_audio_scheduler_envelope_wiring_diagnostic_only_scheduler_stamps_window_pts_"
    "origin_non_owning_per_source_static_gain_and_envelope_params_no_production_mixdown_change_"
    "no_export_reroute_no_pass2_reroute_no_runtime_queue_no_backpressure_no_realtime_sink_no_"
    "audio_track_no_aaudio_no_opensl_no_oboe_no_media_codec_no_media_extractor_no_file_io_no_"
    "native_worker_threads_no_app_no_editor_no_product_no_streaming_no_cache_no_ios";

std::string Hex64(uint64_t v) {
    char buf[24];
    std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(v));
    return buf;
}

std::string DoubleStr(double v) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.9f", v);
    return buf;
}

std::string RunAudioSchedulerEnvelopeSmokeInternal() {
    bool schedulerEnvelopeAppliedOk           = false;
    bool windowPtsOriginOk                    = false;
    bool multiSourceParamsOk                  = false;
    bool nullEnvelopeBackCompatOk             = false;
    bool mixOutputEnvelopeMetricsPropagatedOk = false;
    bool invalidSourceGainFailClosedOk        = false;
    bool invalidEnvelopeGainFailClosedOk      = false;
    bool windowPtsOverflowRejectOk            = false;
    bool staleGenerationFailClosedOk          = false;
    bool noPerWindowAllocationOk              = false;
    bool lifecycleOk                          = false;
    bool stackScoped                          = false;

    int64_t  windowPtsUs0             = 0;
    int64_t  windowPtsUs1             = 0;
    int64_t  framesRenderedWindow0    = 0;
    int64_t  framesRenderedWindow1    = 0;
    int64_t  envelopeEvaluations0     = 0;
    int64_t  envelopeEvaluations1     = 0;
    double   minEffectiveGain0        = 0.0;
    double   maxEffectiveGain0        = 0.0;
    uint64_t schedulerChecksum0       = 0;
    uint64_t schedulerChecksum1       = 0;
    uint64_t referenceChecksum0       = 0;
    uint64_t referenceChecksum1       = 0;
    uint64_t unitGainChecksum0        = 0;
    uint64_t wrongOriginChecksum1     = 0;
    long long routedSourceCountMetric = 0;

    std::string failureReason;
    auto fail = [&](const char* reason) {
        if (failureReason.empty()) failureReason = reason;
    };

    constexpr int32_t kRate         = 48000;
    constexpr int32_t kChannels     = 2;
    constexpr int64_t kMaxFrames    = 2048;
    constexpr int64_t kWindowFrames = 960;   // 20 ms per window
    constexpr int64_t kTotalFrames  = 1920;  // two consecutive windows

    try {
        // ── Graph: one mix bus fed by three sources — src_env (unit static
        //    gain + fade envelope), src_gain (static gain 0.5, null
        //    envelope), src_unit (no params entry at all). ──
        Graph graph;
        auto mixBus = std::make_shared<AudioMixBusNode>("env_mix", kRate, kChannels, kMaxFrames);
        auto srcEnv  = std::make_shared<DecodedAudioPcmSourceNode>("src_env", kRate, kChannels, 4800, 0);
        auto srcGain = std::make_shared<DecodedAudioPcmSourceNode>("src_gain", kRate, kChannels, 4800, 0);
        auto srcUnit = std::make_shared<DecodedAudioPcmSourceNode>("src_unit", kRate, kChannels, 4800, 0);
        graph.addNode(mixBus);
        graph.addNode(srcEnv);
        graph.addNode(srcGain);
        graph.addNode(srcUnit);
        graph.connect("src_env", "audio_out", "env_mix", "primary_audio_in");
        graph.connect("src_gain", "audio_out", "env_mix", "secondary_audio_in");
        graph.connect("src_unit", "audio_out", "env_mix", "audio_in_2");

        std::vector<int16_t> pcmEnv(static_cast<size_t>(kTotalFrames) * kChannels);
        std::vector<int16_t> pcmGain(static_cast<size_t>(kTotalFrames) * kChannels);
        std::vector<int16_t> pcmUnit(static_cast<size_t>(kTotalFrames) * kChannels);
        for (size_t i = 0; i < pcmEnv.size(); ++i) {
            pcmEnv[i]  = static_cast<int16_t>(static_cast<int64_t>((i * 37) % 2001) - 1000);
            pcmGain[i] = static_cast<int16_t>(static_cast<int64_t>((i * 53) % 1401) - 700);
            pcmUnit[i] = static_cast<int16_t>(static_cast<int64_t>((i * 71) % 901) - 450);
        }
        VectorAudioSampleProvider providerEnv(kRate, kChannels, 0, pcmEnv);
        VectorAudioSampleProvider providerGain(kRate, kChannels, 0, pcmGain);
        VectorAudioSampleProvider providerUnit(kRate, kChannels, 0, pcmUnit);
        const std::unordered_map<std::string, AudioSampleProvider*> providers = {
            {"src_env", &providerEnv},
            {"src_gain", &providerGain},
            {"src_unit", &providerUnit},
        };

        // Fade envelope spanning both windows: (0,0) -> (20ms,1) -> (30ms,1)
        // -> (40ms,0), so window 1 only mixes correctly when its origin is
        // the scheduler-derived 20000 us, not a reset 0.
        AudioGainEnvelope envRamp;
        if (AudioGainEnvelope::FromStatic(1.0, 1.0, 20000, 10000, 0, 40000, &envRamp) !=
            AudioGainEnvelope::BuildResult::kOk) {
            fail("ramp_envelope_build_failed");
        }

        // The params map is only read during construction (envelopes must
        // outlive renders; the map itself may die immediately after).
        const std::unordered_map<std::string, SourceMixParams> mixParams = {
            {"src_env", SourceMixParams{1.0, &envRamp}},
            {"src_gain", SourceMixParams{0.5, nullptr}},
        };

        GraphAudioScheduler scheduler(graph, "env_mix", providers, &mixParams);
        routedSourceCountMetric = static_cast<long long>(scheduler.routedSourceCount());
        if (!scheduler.targetValid() || scheduler.routedSourceCount() != 3) {
            fail("scheduler_routing_failed");
        }
        const size_t capacityBaseline = scheduler.trackScratchCapacitySamples();

        windowPtsUs0 = static_cast<int64_t>(GraphAudioScheduler::ComputeWindowPtsUs(0, kRate));
        windowPtsUs1 = static_cast<int64_t>(GraphAudioScheduler::ComputeWindowPtsUs(kWindowFrames, kRate));

        // Direct-mix references, built with the same AudioMixBusNode in the
        // same track order the scheduler routes (edge insertion order).
        auto directMix = [&](int64_t frameOffset,
                             int64_t envStartPtsUs,
                             double  srcGainStaticGain,
                             const AudioGainEnvelope* envelope,
                             std::vector<int16_t>* outPcm,
                             AudioMixBusNode::MixOutput* outMix) -> bool {
            AudioMixBusNode::MixTrack tracks[3];
            tracks[0] = AudioMixBusNode::MixTrack{
                pcmEnv.data() + frameOffset * kChannels, kWindowFrames, kRate, kChannels,
                1.0, envelope, envStartPtsUs};
            tracks[1] = AudioMixBusNode::MixTrack{
                pcmGain.data() + frameOffset * kChannels, kWindowFrames, kRate, kChannels,
                srcGainStaticGain, nullptr, envStartPtsUs};
            tracks[2] = AudioMixBusNode::MixTrack{
                pcmUnit.data() + frameOffset * kChannels, kWindowFrames, kRate, kChannels,
                1.0, nullptr, envStartPtsUs};
            outPcm->assign(static_cast<size_t>(kWindowFrames) * kChannels, 0);
            return mixBus->mix(tracks, 3, kWindowFrames, outPcm->data(),
                               static_cast<int64_t>(outPcm->size()), outMix) ==
                   AudioMixBusNode::MixResult::kOk;
        };

        // ── Window 0: envelope wiring + metric propagation ──
        std::vector<int16_t> schedOutBuf0(static_cast<size_t>(kWindowFrames) * kChannels, 0);
        SchedulerOutput schedOut0;
        const auto res0 = scheduler.renderWindow(
            0, kWindowFrames, schedOutBuf0.data(),
            static_cast<int64_t>(schedOutBuf0.size()), &schedOut0);
        schedulerChecksum0    = schedOut0.checksum;
        framesRenderedWindow0 = schedOut0.framesRendered;
        envelopeEvaluations0  = schedOut0.envelopeEvaluations;
        minEffectiveGain0     = schedOut0.minEffectiveGain;
        maxEffectiveGain0     = schedOut0.maxEffectiveGain;

        std::vector<int16_t> refBuf0;
        AudioMixBusNode::MixOutput refMix0{};
        if (!directMix(0, windowPtsUs0, 0.5, &envRamp, &refBuf0, &refMix0)) {
            fail("reference_mix_window0_failed");
        }
        referenceChecksum0 = refMix0.checksum;

        std::vector<int16_t> unitBuf0;
        AudioMixBusNode::MixOutput unitMix0{};
        if (!directMix(0, windowPtsUs0, 1.0, nullptr, &unitBuf0, &unitMix0)) {
            fail("unit_reference_mix_window0_failed");
        }
        unitGainChecksum0 = unitMix0.checksum;

        schedulerEnvelopeAppliedOk =
            res0 == SchedulerResult::kOk && schedOut0.mixCalled &&
            schedOut0.envelopeApplied &&
            schedOut0.checksum == refMix0.checksum &&
            std::equal(schedOutBuf0.begin(), schedOutBuf0.end(), refBuf0.begin()) &&
            schedOut0.checksum != unitMix0.checksum;
        if (!schedulerEnvelopeAppliedOk) fail("scheduler_envelope_applied_failed");

        mixOutputEnvelopeMetricsPropagatedOk =
            res0 == SchedulerResult::kOk &&
            schedOut0.envelopeApplied == refMix0.envelopeApplied &&
            schedOut0.minEffectiveGain == refMix0.minEffectiveGain &&
            schedOut0.maxEffectiveGain == refMix0.maxEffectiveGain &&
            schedOut0.envelopeEvaluations == refMix0.envelopeEvaluations &&
            schedOut0.envelopeEvaluations == kWindowFrames;
        if (!mixOutputEnvelopeMetricsPropagatedOk) fail("mix_output_envelope_metrics_failed");

        // ── Window 1 (consecutive): scheduler-owned window origin ──
        std::vector<int16_t> schedOutBuf1(static_cast<size_t>(kWindowFrames) * kChannels, 0);
        SchedulerOutput schedOut1;
        const auto res1 = scheduler.renderWindow(
            kWindowFrames, kWindowFrames, schedOutBuf1.data(),
            static_cast<int64_t>(schedOutBuf1.size()), &schedOut1);
        schedulerChecksum1    = schedOut1.checksum;
        framesRenderedWindow1 = schedOut1.framesRendered;
        envelopeEvaluations1  = schedOut1.envelopeEvaluations;

        std::vector<int16_t> refBuf1;
        AudioMixBusNode::MixOutput refMix1{};
        if (!directMix(kWindowFrames, windowPtsUs1, 0.5, &envRamp, &refBuf1, &refMix1)) {
            fail("reference_mix_window1_failed");
        }
        referenceChecksum1 = refMix1.checksum;

        // Deliberately wrong origin (0 instead of 20000 us): must differ.
        std::vector<int16_t> wrongOriginBuf1;
        AudioMixBusNode::MixOutput wrongOriginMix1{};
        if (!directMix(kWindowFrames, 0, 0.5, &envRamp, &wrongOriginBuf1, &wrongOriginMix1)) {
            fail("wrong_origin_mix_window1_failed");
        }
        wrongOriginChecksum1 = wrongOriginMix1.checksum;

        windowPtsOriginOk =
            res1 == SchedulerResult::kOk && schedOut1.envelopeApplied &&
            windowPtsUs1 == 20000 &&
            schedOut1.checksum == refMix1.checksum &&
            std::equal(schedOutBuf1.begin(), schedOutBuf1.end(), refBuf1.begin()) &&
            schedOut1.checksum != wrongOriginMix1.checksum;
        if (!windowPtsOriginOk) fail("window_pts_origin_failed");

        // ── multiSourceParamsOk: the three-track references above already
        //    compose one envelope track, one static-gain track, and one
        //    unit/null-envelope track; additionally prove the 0.5 static
        //    gain actually changed the mix (vs src_gain at unit gain). ──
        std::vector<int16_t> wrongStaticBuf0;
        AudioMixBusNode::MixOutput wrongStaticMix0{};
        if (!directMix(0, windowPtsUs0, 1.0, &envRamp, &wrongStaticBuf0, &wrongStaticMix0)) {
            fail("wrong_static_gain_mix_window0_failed");
        }
        multiSourceParamsOk =
            schedulerEnvelopeAppliedOk && windowPtsOriginOk &&
            schedOut0.routedTrackCount == 3 && schedOut1.routedTrackCount == 3 &&
            schedOut0.checksum != wrongStaticMix0.checksum;
        if (!multiSourceParamsOk) fail("multi_source_params_failed");

        // ── nullEnvelopeBackCompatOk: no params map (existing 3-arg call
        //    shape) and an empty params map must both be bit-identical to
        //    the all-unit-gain/null-envelope reference. ──
        {
            GraphAudioScheduler schedulerNoParams(graph, "env_mix", providers);
            const std::unordered_map<std::string, SourceMixParams> emptyParams;
            GraphAudioScheduler schedulerEmptyParams(graph, "env_mix", providers, &emptyParams);

            std::vector<int16_t> noParamsBuf(static_cast<size_t>(kWindowFrames) * kChannels, 0);
            std::vector<int16_t> emptyParamsBuf(static_cast<size_t>(kWindowFrames) * kChannels, 0);
            SchedulerOutput noParamsOut;
            SchedulerOutput emptyParamsOut;
            const auto noParamsRes = schedulerNoParams.renderWindow(
                0, kWindowFrames, noParamsBuf.data(),
                static_cast<int64_t>(noParamsBuf.size()), &noParamsOut);
            const auto emptyParamsRes = schedulerEmptyParams.renderWindow(
                0, kWindowFrames, emptyParamsBuf.data(),
                static_cast<int64_t>(emptyParamsBuf.size()), &emptyParamsOut);

            nullEnvelopeBackCompatOk =
                noParamsRes == SchedulerResult::kOk &&
                emptyParamsRes == SchedulerResult::kOk &&
                noParamsOut.checksum == unitMix0.checksum &&
                emptyParamsOut.checksum == unitMix0.checksum &&
                std::equal(noParamsBuf.begin(), noParamsBuf.end(), unitBuf0.begin()) &&
                noParamsBuf == emptyParamsBuf &&
                !noParamsOut.envelopeApplied && noParamsOut.envelopeEvaluations == 0 &&
                noParamsOut.minEffectiveGain == 0.0 && noParamsOut.maxEffectiveGain == 0.0;
            if (!nullEnvelopeBackCompatOk) fail("null_envelope_back_compat_failed");
        }

        // ── invalidSourceGainFailClosedOk: static gain outside [0,1] must
        //    reach the mix bus, reject via kInvalidGain, and surface as
        //    kMixFailure with no output mutation. ──
        {
            const std::unordered_map<std::string, SourceMixParams> badGainParams = {
                {"src_env", SourceMixParams{1.5, nullptr}},
            };
            GraphAudioScheduler badGainScheduler(graph, "env_mix", providers, &badGainParams);
            std::vector<int16_t> sentinel(static_cast<size_t>(kWindowFrames) * kChannels,
                                          static_cast<int16_t>(0x2222));
            SchedulerOutput badGainOut;
            const auto badGainRes = badGainScheduler.renderWindow(
                0, kWindowFrames, sentinel.data(),
                static_cast<int64_t>(sentinel.size()), &badGainOut);
            const bool sentinelIntact = std::all_of(
                sentinel.begin(), sentinel.end(),
                [](int16_t v) { return v == static_cast<int16_t>(0x2222); });
            invalidSourceGainFailClosedOk =
                badGainRes == SchedulerResult::kMixFailure && sentinelIntact &&
                !badGainOut.mixCalled && badGainOut.framesRendered == 0;
            if (!invalidSourceGainFailClosedOk) fail("invalid_source_gain_fail_closed_failed");
        }

        // ── invalidEnvelopeGainFailClosedOk: an over-unity envelope gain
        //    (legal build product; Kotlin parity does not clamp the static
        //    volume) rejects via kInvalidEnvelopeGain -> kMixFailure with no
        //    output mutation. ──
        {
            AudioGainEnvelope envOverUnity;
            if (AudioGainEnvelope::FromStatic(1.5, 1.0, 0, 0, 0, 40000, &envOverUnity) !=
                AudioGainEnvelope::BuildResult::kOk) {
                fail("over_unity_envelope_build_failed");
            }
            const std::unordered_map<std::string, SourceMixParams> badEnvParams = {
                {"src_env", SourceMixParams{1.0, &envOverUnity}},
            };
            GraphAudioScheduler badEnvScheduler(graph, "env_mix", providers, &badEnvParams);
            std::vector<int16_t> sentinel(static_cast<size_t>(kWindowFrames) * kChannels,
                                          static_cast<int16_t>(0x2222));
            SchedulerOutput badEnvOut;
            const auto badEnvRes = badEnvScheduler.renderWindow(
                0, kWindowFrames, sentinel.data(),
                static_cast<int64_t>(sentinel.size()), &badEnvOut);
            const bool sentinelIntact = std::all_of(
                sentinel.begin(), sentinel.end(),
                [](int16_t v) { return v == static_cast<int16_t>(0x2222); });
            invalidEnvelopeGainFailClosedOk =
                badEnvRes == SchedulerResult::kMixFailure && sentinelIntact &&
                !badEnvOut.mixCalled && badEnvOut.framesRendered == 0;
            if (!invalidEnvelopeGainFailClosedOk) fail("invalid_envelope_gain_fail_closed_failed");
        }

        // ── windowPtsOverflowRejectOk: a startFrame whose derived pts
        //    cannot fit positive int64 (here the uint64 multiplication
        //    guard) fails closed before any provider call or output
        //    mutation. ──
        {
            std::vector<int16_t> sentinel(static_cast<size_t>(kWindowFrames) * kChannels,
                                          static_cast<int16_t>(0x2222));
            SchedulerOutput overflowOut;
            const auto overflowRes = scheduler.renderWindow(
                4000000000000000000LL, kWindowFrames, sentinel.data(),
                static_cast<int64_t>(sentinel.size()), &overflowOut);
            const bool sentinelIntact = std::all_of(
                sentinel.begin(), sentinel.end(),
                [](int16_t v) { return v == static_cast<int16_t>(0x2222); });
            windowPtsOverflowRejectOk =
                overflowRes == SchedulerResult::kWindowPtsOverflow && sentinelIntact &&
                !overflowOut.mixCalled && overflowOut.framesRendered == 0;
            if (!windowPtsOverflowRejectOk) fail("window_pts_overflow_reject_failed");
        }

        // ── noPerWindowAllocationOk: scratch capacity fixed at construction
        //    and repeated identical windows are bit-reproducible. ──
        {
            bool stable = true;
            for (int i = 0; i < 32 && stable; ++i) {
                std::vector<int16_t> repBuf(static_cast<size_t>(kWindowFrames) * kChannels, 0);
                SchedulerOutput repOut;
                const auto repRes = scheduler.renderWindow(
                    0, kWindowFrames, repBuf.data(),
                    static_cast<int64_t>(repBuf.size()), &repOut);
                stable = repRes == SchedulerResult::kOk &&
                    repOut.checksum == schedulerChecksum0 &&
                    repOut.envelopeEvaluations == envelopeEvaluations0 &&
                    repOut.minEffectiveGain == minEffectiveGain0 &&
                    repOut.maxEffectiveGain == maxEffectiveGain0;
            }
            noPerWindowAllocationOk = stable &&
                capacityBaseline > 0 &&
                scheduler.trackScratchCapacitySamples() == capacityBaseline;
            if (!noPerWindowAllocationOk) fail("no_per_window_allocation_failed");
        }

        // ── staleGenerationFailClosedOk (last: mutating the graph stales
        //    every scheduler built on it). ──
        {
            auto staleProbe = std::make_shared<DecodedAudioPcmSourceNode>(
                "stale_probe_extra_node", kRate, kChannels, 4800, 0);
            graph.addNode(staleProbe); // Bumps the graph generation.
            std::vector<int16_t> sentinel(static_cast<size_t>(kWindowFrames) * kChannels,
                                          static_cast<int16_t>(0x2222));
            SchedulerOutput staleOut;
            const auto staleRes = scheduler.renderWindow(
                0, kWindowFrames, sentinel.data(),
                static_cast<int64_t>(sentinel.size()), &staleOut);
            const bool sentinelIntact = std::all_of(
                sentinel.begin(), sentinel.end(),
                [](int16_t v) { return v == static_cast<int16_t>(0x2222); });
            staleGenerationFailClosedOk =
                staleRes == SchedulerResult::kStaleGeneration && sentinelIntact &&
                !staleOut.mixCalled && staleOut.framesRendered == 0;
            if (!staleGenerationFailClosedOk) fail("stale_generation_fail_closed_failed");
        }

        // Everything above lives on this call's stack/locals; the graph,
        // schedulers, providers, and envelopes are destroyed on scope exit
        // before the reply is built. One-shot route: no registry, no handle,
        // no OS resource, no thread.
        stackScoped = true;
        lifecycleOk = true;
    } catch (const std::exception& e) {
        fail(e.what());
    } catch (...) {
        fail("unknown_native_exception");
    }

    const bool pass =
        schedulerEnvelopeAppliedOk && windowPtsOriginOk && multiSourceParamsOk &&
        nullEnvelopeBackCompatOk && mixOutputEnvelopeMetricsPropagatedOk &&
        invalidSourceGainFailClosedOk && invalidEnvelopeGainFailClosedOk &&
        windowPtsOverflowRejectOk && staleGenerationFailClosedOk &&
        noPerWindowAllocationOk && lifecycleOk && stackScoped &&
        failureReason.empty();

    std::ostringstream oss;
    oss << "status=" << (pass ? "PASS" : "FAIL") << ";";
    if (!pass) {
        oss << "reason=" << (failureReason.empty() ? "lane_failed" : failureReason) << ";";
    }
    auto lane = [&](const char* key, bool value) {
        oss << key << "=" << (value ? "true" : "false") << ";";
    };
    lane("schedulerEnvelopeAppliedOk", schedulerEnvelopeAppliedOk);
    lane("windowPtsOriginOk", windowPtsOriginOk);
    lane("multiSourceParamsOk", multiSourceParamsOk);
    lane("nullEnvelopeBackCompatOk", nullEnvelopeBackCompatOk);
    lane("mixOutputEnvelopeMetricsPropagatedOk", mixOutputEnvelopeMetricsPropagatedOk);
    lane("invalidSourceGainFailClosedOk", invalidSourceGainFailClosedOk);
    lane("invalidEnvelopeGainFailClosedOk", invalidEnvelopeGainFailClosedOk);
    lane("windowPtsOverflowRejectOk", windowPtsOverflowRejectOk);
    lane("staleGenerationFailClosedOk", staleGenerationFailClosedOk);
    lane("noPerWindowAllocationOk", noPerWindowAllocationOk);
    lane("lifecycleOk", lifecycleOk);
    lane("stackScoped", stackScoped);
    lane("canonical", pass);
    oss << "routedSourceCount=" << routedSourceCountMetric << ";"
        << "windowFrames=" << kWindowFrames << ";"
        << "windowPtsUs0=" << windowPtsUs0 << ";"
        << "windowPtsUs1=" << windowPtsUs1 << ";"
        << "framesRenderedWindow0=" << framesRenderedWindow0 << ";"
        << "framesRenderedWindow1=" << framesRenderedWindow1 << ";"
        << "envelopeEvaluationsWindow0=" << envelopeEvaluations0 << ";"
        << "envelopeEvaluationsWindow1=" << envelopeEvaluations1 << ";"
        << "minEffectiveGainWindow0=" << DoubleStr(minEffectiveGain0) << ";"
        << "maxEffectiveGainWindow0=" << DoubleStr(maxEffectiveGain0) << ";"
        << "schedulerChecksumWindow0Hex=" << Hex64(schedulerChecksum0) << ";"
        << "schedulerChecksumWindow1Hex=" << Hex64(schedulerChecksum1) << ";"
        << "referenceChecksumWindow0Hex=" << Hex64(referenceChecksum0) << ";"
        << "referenceChecksumWindow1Hex=" << Hex64(referenceChecksum1) << ";"
        << "unitGainChecksumWindow0Hex=" << Hex64(unitGainChecksum0) << ";"
        << "wrongOriginChecksumWindow1Hex=" << Hex64(wrongOriginChecksum1) << ";"
        << "sampleRate=" << kRate << ";"
        << "channelCount=" << kChannels << ";"
        << "maxFramesPerMix=" << kMaxFrames << ";"
        << "proofBoundary=" << kProofBoundary;

    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase4AudioSchedulerEnvelopeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunAudioSchedulerEnvelopeSmokeInternal();
        return env->NewStringUTF(resultStr.c_str());
    } catch (const std::exception& e) {
        const std::string err =
            std::string("status=FAIL;reason=exception:") + e.what() +
            ";proofBoundary=" + kProofBoundary;
        return env->NewStringUTF(err.c_str());
    } catch (...) {
        const std::string err =
            std::string("status=FAIL;reason=exception:unknown;proofBoundary=") + kProofBoundary;
        return env->NewStringUTF(err.c_str());
    }
}
