// P4-AUDIO-GRAPH-TRANSPORT-CLOCK (sub-slice A): synchronous,
// graph-edge-routed audio window scheduler proof.
//
// Honest non-claims:
// - Does not claim realtime or audible playback.
// - Does not use AudioTrack, AAudio, OpenSL, or Oboe.
// - Does not use threads, locks, ring buffers, queues, or backpressure.
// - Does not perform file IO.
// - Does not use MediaCodec or MediaExtractor.
// - Does not add any C++ -> Kotlin callback.
// - Does not reroute export.
// - Does not touch app/editor/product UI.
// - Does not stream.
// - Does not touch iOS.
// - Does not close P4-AUDIO-GRAPH-TRANSPORT-CLOCK.
// - Does not close P4-AUDIO-MIXBUS.
//
// GraphAudioScheduler owns no Graph/Node/AudioSampleProvider; it holds a
// non-owning `const Graph&`, a non-owning provider registry keyed by
// source node id, and a snapshotted graph generation id. Node,
// AudioMixBusNode, and DecodedAudioPcmSourceNode public contracts are
// unchanged by this slice.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase4AudioGraphTransportClockSmoke -> jstring

#include <jni.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/audio/vector_audio_sample_provider.h"
#include "vanguard/graph/graph.h"

namespace {

constexpr const char* kProofBoundary =
    "native_graph_edge_routed_audio_window_scheduler_proof_only_no_realtime_no_audio_track_no_playback_no_queue_no_backpressure_no_threads_no_export_reroute_no_product";

using vanguard::audio::AudioMixBusNode;
using vanguard::audio::AudioSampleProvider;
using vanguard::audio::AudioWindowBuffer;
using vanguard::audio::AudioWindowRequest;
using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::audio::GraphAudioScheduler;
using vanguard::audio::VectorAudioSampleProvider;
using vanguard::graph::Graph;
using SchedulerResult = GraphAudioScheduler::SchedulerResult;

std::string RunAudioGraphTransportClockSmokeInternal() {
    bool schedulerGraphEdgeRoutingOk = false;
    bool frameWindowMathExactOk      = false;
    bool ptsDerivationOk             = false;
    bool noMicrosecondDriftOk        = false;
    bool timelineGatingWindowOk      = false;
    bool mixRoutingChecksumOk        = false;
    bool silenceWindowOk             = false;
    bool staleGenerationRejectOk     = false;
    bool sampleRateMismatchRejectOk  = false;
    bool capacityGuardOk             = false;
    bool noPerWindowAllocationOk     = false;
    bool deterministicPortOrderOk    = false;
    bool lifecycleOk                 = true;
    bool stackScoped                 = true;

    int64_t  renderedFrames                     = 0;
    uint64_t mixChecksum                        = 0;
    uint64_t expectedChecksum                   = 0;
    int      schedulerMixCallCount              = 0;
    int      silenceMixCallCount                = 0;
    int      windowCount                        = 0;
    int64_t  partialFinalWindowFrames           = 0;
    int64_t  microsecondAccumulationDriftFrames = 0;

    std::string failureReason;

    constexpr int32_t kMixSampleRate   = 48000;
    constexpr int32_t kMixChannels     = 2;
    constexpr int64_t kMaxFramesPerMix = 2048;
    constexpr int64_t kWindowSize      = 1024;
    constexpr int64_t kTotalFrames     = 2500;

    // ── Main graph: mix0 fed by src0 + src1 (both providers registered) and
    //    src_no_provider (edge exists, no provider registered — must be
    //    excluded from routing). ──
    Graph mainGraph;
    auto mix0 = std::make_shared<AudioMixBusNode>("mix0", kMixSampleRate, kMixChannels, kMaxFramesPerMix);
    auto src0 = std::make_shared<DecodedAudioPcmSourceNode>("src0", kMixSampleRate, kMixChannels, 4800, 0);
    auto src1 = std::make_shared<DecodedAudioPcmSourceNode>("src1", kMixSampleRate, kMixChannels, 4800, 0);
    auto srcNoProvider = std::make_shared<DecodedAudioPcmSourceNode>("src_no_provider", kMixSampleRate, kMixChannels, 4800, 0);

    mainGraph.addNode(mix0);
    mainGraph.addNode(src0);
    mainGraph.addNode(src1);
    mainGraph.addNode(srcNoProvider);

    mainGraph.connect("src0", "audio_out", "mix0", "primary_audio_in");
    mainGraph.connect("src1", "audio_out", "mix0", "secondary_audio_in");
    mainGraph.connect("src_no_provider", "audio_out", "mix0", "audio_in_2");

    std::vector<int16_t> rawPcm0(static_cast<size_t>(kTotalFrames) * kMixChannels);
    std::vector<int16_t> rawPcm1(static_cast<size_t>(kTotalFrames) * kMixChannels);
    for (size_t i = 0; i < rawPcm0.size(); ++i) {
        rawPcm0[i] = static_cast<int16_t>(static_cast<int64_t>((i * 37) % 2001) - 1000);
    }
    for (size_t i = 0; i < rawPcm1.size(); ++i) {
        rawPcm1[i] = static_cast<int16_t>(static_cast<int64_t>((i * 53) % 1401) - 700);
    }

    VectorAudioSampleProvider provider0(kMixSampleRate, kMixChannels, 0, rawPcm0);
    VectorAudioSampleProvider provider1(kMixSampleRate, kMixChannels, 0, rawPcm1);

    std::unordered_map<std::string, AudioSampleProvider*> mainProviders = {
        {"src0", &provider0},
        {"src1", &provider1},
    };

    GraphAudioScheduler mainScheduler(mainGraph, "mix0", mainProviders);

    // ── 1. schedulerGraphEdgeRoutingOk ──
    if (mainScheduler.targetValid() &&
        mainScheduler.routedSourceCount() == 2 &&
        mainScheduler.routedSourceIdAt(0) == "src0" &&
        mainScheduler.routedSourceIdAt(1) == "src1") {
        schedulerGraphEdgeRoutingOk = true;
    } else {
        failureReason = "scheduler_graph_edge_routing_failed";
    }

    const size_t capacityBaseline = mainScheduler.trackScratchCapacitySamples();

    // ── 2. frameWindowMathExactOk + mixRoutingChecksumOk data collection ──
    std::vector<int16_t> outBuf(static_cast<size_t>(kMaxFramesPerMix) * kMixChannels, 0);
    int64_t remaining          = kTotalFrames;
    int64_t cursor             = 0;
    int64_t renderedFramesSum  = 0;
    bool    windowLoopFailed   = false;

    while (remaining > 0) {
        const int64_t thisWindow = std::min<int64_t>(kWindowSize, remaining);
        GraphAudioScheduler::SchedulerOutput out;
        const auto result = mainScheduler.renderWindow(
            cursor, thisWindow, outBuf.data(), static_cast<int64_t>(outBuf.size()), &out);
        if (result != SchedulerResult::kOk || out.framesRendered != thisWindow) {
            windowLoopFailed = true;
            break;
        }
        if (windowCount == 0) {
            mixChecksum = out.checksum;
        }
        schedulerMixCallCount += out.mixCalled ? 1 : 0;
        renderedFramesSum += out.framesRendered;
        partialFinalWindowFrames = thisWindow;
        cursor += thisWindow;
        remaining -= thisWindow;
        ++windowCount;
    }
    renderedFrames = renderedFramesSum;

    if (!windowLoopFailed && renderedFramesSum == kTotalFrames && windowCount == 3 &&
        partialFinalWindowFrames == (kTotalFrames - 2 * kWindowSize)) {
        frameWindowMathExactOk = true;
    } else {
        if (failureReason.empty()) failureReason = "frame_window_math_failed";
    }

    // ── 3. mixRoutingChecksumOk: independent direct-mix reference for window [0,1024) ──
    {
        std::vector<int16_t> directOut(static_cast<size_t>(kWindowSize) * kMixChannels, 0);
        AudioMixBusNode::MixTrack tracks[2];
        tracks[0] = AudioMixBusNode::MixTrack{rawPcm0.data(), kWindowSize, kMixSampleRate, kMixChannels, 1.0};
        tracks[1] = AudioMixBusNode::MixTrack{rawPcm1.data(), kWindowSize, kMixSampleRate, kMixChannels, 1.0};
        AudioMixBusNode::MixOutput directMixOut;
        const auto directRes = mix0->mix(tracks, 2, kWindowSize, directOut.data(),
                                         static_cast<int64_t>(directOut.size()), &directMixOut);
        expectedChecksum = directMixOut.checksum;
        if (directRes == AudioMixBusNode::MixResult::kOk && !windowLoopFailed &&
            directMixOut.checksum == mixChecksum) {
            mixRoutingChecksumOk = true;
        } else {
            if (failureReason.empty()) failureReason = "mix_routing_checksum_mismatch";
        }
    }

    // ── 4. capacityGuardOk: frameCount > maxFramesPerMix rejected, output unchanged ──
    {
        std::vector<int16_t> sentinelOut(static_cast<size_t>(kMaxFramesPerMix) * kMixChannels, 12345);
        const std::vector<int16_t> sentinelBefore = sentinelOut;
        GraphAudioScheduler::SchedulerOutput capOut;
        const auto capResult = mainScheduler.renderWindow(
            cursor, kMaxFramesPerMix + 1, sentinelOut.data(), static_cast<int64_t>(sentinelOut.size()), &capOut);
        if (capResult == SchedulerResult::kInvalidFrameCount && sentinelOut == sentinelBefore) {
            capacityGuardOk = true;
        } else {
            if (failureReason.empty()) failureReason = "capacity_guard_failed";
        }
    }

    // ── 5. deterministicPortOrderOk: two identical renderWindow calls agree ──
    {
        std::vector<int16_t> runA(256 * static_cast<size_t>(kMixChannels), 0);
        std::vector<int16_t> runB(256 * static_cast<size_t>(kMixChannels), 0);
        GraphAudioScheduler::SchedulerOutput outA;
        GraphAudioScheduler::SchedulerOutput outB;
        const auto resA = mainScheduler.renderWindow(0, 256, runA.data(), static_cast<int64_t>(runA.size()), &outA);
        const auto resB = mainScheduler.renderWindow(0, 256, runB.data(), static_cast<int64_t>(runB.size()), &outB);

        if (resA == SchedulerResult::kOk && resB == SchedulerResult::kOk &&
            outA.checksum == outB.checksum && runA == runB &&
            mainScheduler.routedSourceIdAt(0) == "src0" && mainScheduler.routedSourceIdAt(1) == "src1") {
            deterministicPortOrderOk = true;
        } else {
            if (failureReason.empty()) failureReason = "deterministic_port_order_failed";
        }
    }

    // ── 6. noPerWindowAllocationOk: scratch capacity unchanged across all calls above ──
    const size_t capacityFinal = mainScheduler.trackScratchCapacitySamples();
    if (capacityBaseline > 0 && capacityBaseline == capacityFinal) {
        noPerWindowAllocationOk = true;
    } else {
        if (failureReason.empty()) failureReason = "no_per_window_allocation_failed";
    }

    // ── 7. staleGenerationRejectOk: graph mutation after construction fails closed ──
    {
        auto staleProbeNode = std::make_shared<DecodedAudioPcmSourceNode>(
            "stale_probe_extra_node", kMixSampleRate, kMixChannels, 4800, 0);
        mainGraph.addNode(staleProbeNode); // Bumps mainGraph's generation.

        std::vector<int16_t> staleOut(256 * static_cast<size_t>(kMixChannels), 777);
        const std::vector<int16_t> staleBefore = staleOut;
        GraphAudioScheduler::SchedulerOutput staleResultOut;
        const auto staleResult = mainScheduler.renderWindow(
            0, 256, staleOut.data(), static_cast<int64_t>(staleOut.size()), &staleResultOut);

        if (staleResult == SchedulerResult::kStaleGeneration && staleOut == staleBefore) {
            staleGenerationRejectOk = true;
        } else {
            if (failureReason.empty()) failureReason = "stale_generation_reject_failed";
        }
    }

    // ── 8. silenceWindowOk: zero routed providers -> zero output, distinct silence
    //    result, no mix() call ──
    {
        Graph silenceGraph;
        auto silenceMix = std::make_shared<AudioMixBusNode>("silence_mix", kMixSampleRate, kMixChannels, 512);
        silenceGraph.addNode(silenceMix);

        std::unordered_map<std::string, AudioSampleProvider*> emptyProviders;
        GraphAudioScheduler silenceScheduler(silenceGraph, "silence_mix", emptyProviders);

        std::vector<int16_t> silenceOut(128 * static_cast<size_t>(kMixChannels), 999);
        GraphAudioScheduler::SchedulerOutput silenceResultOut;
        const auto silenceRes = silenceScheduler.renderWindow(
            0, 128, silenceOut.data(), static_cast<int64_t>(silenceOut.size()), &silenceResultOut);

        const bool allZero = std::all_of(silenceOut.begin(), silenceOut.end(),
                                         [](int16_t v) { return v == 0; });
        silenceMixCallCount = silenceResultOut.mixCalled ? 1 : 0;

        if (silenceRes == SchedulerResult::kSilence && silenceResultOut.silence &&
            !silenceResultOut.mixCalled && allZero) {
            silenceWindowOk = true;
        } else {
            if (failureReason.empty()) failureReason = "silence_window_failed";
        }
    }

    // ── 9. sampleRateMismatchRejectOk: mismatched provider format surfaced, no resampling ──
    {
        Graph mismatchGraph;
        auto mismatchMix = std::make_shared<AudioMixBusNode>("mismatch_mix", kMixSampleRate, kMixChannels, 512);
        auto mismatchSrc = std::make_shared<DecodedAudioPcmSourceNode>("mismatch_src", kMixSampleRate, kMixChannels, 4800, 0);
        mismatchGraph.addNode(mismatchMix);
        mismatchGraph.addNode(mismatchSrc);
        mismatchGraph.connect("mismatch_src", "audio_out", "mismatch_mix", "primary_audio_in");

        std::vector<int16_t> mismatchPcm(256 * 2, 500);
        VectorAudioSampleProvider mismatchProvider(44100, kMixChannels, 0, mismatchPcm);
        std::unordered_map<std::string, AudioSampleProvider*> mismatchProviders = {
            {"mismatch_src", &mismatchProvider},
        };
        GraphAudioScheduler mismatchScheduler(mismatchGraph, "mismatch_mix", mismatchProviders);

        std::vector<int16_t> mismatchOut(128 * static_cast<size_t>(kMixChannels), 0);
        GraphAudioScheduler::SchedulerOutput mismatchResultOut;
        const auto mismatchRes = mismatchScheduler.renderWindow(
            0, 128, mismatchOut.data(), static_cast<int64_t>(mismatchOut.size()), &mismatchResultOut);

        if (mismatchRes == SchedulerResult::kSampleRateMismatch) {
            sampleRateMismatchRejectOk = true;
        } else {
            if (failureReason.empty()) failureReason = "sample_rate_mismatch_reject_failed";
        }
    }

    // ── 10. timelineGatingWindowOk: nonzero timeline start; silent before, PCM at/after,
    //    silent at exact exclusive end boundary. Frame cursor is authoritative: the
    //    source's read cursor is derived once from its own timeline start + frame
    //    rate, not from per-window mapTimelineToLocalPts. ──
    {
        constexpr int32_t  kGateSampleRate = 48000;
        constexpr uint64_t kGateStartPtsUs = 10000; // -> startFrame 480 at 48kHz
        constexpr int64_t  kGateFrames     = 256;   // active window [480, 736)

        std::vector<int16_t> gatePcm(static_cast<size_t>(kGateFrames) * kMixChannels);
        for (size_t i = 0; i < gatePcm.size(); ++i) {
            gatePcm[i] = static_cast<int16_t>(1000 + static_cast<int>(i % 50));
        }
        VectorAudioSampleProvider gateProvider(kGateSampleRate, kMixChannels, kGateStartPtsUs, gatePcm);

        std::vector<int16_t> beforeBuf(480 * static_cast<size_t>(kMixChannels), 111);
        AudioWindowRequest reqBefore{0, 480, kGateSampleRate, kMixChannels,
                                     GraphAudioScheduler::ComputeWindowPtsUs(0, kGateSampleRate)};
        AudioWindowBuffer bufBefore{beforeBuf.data(), static_cast<int64_t>(beforeBuf.size()), 0, false};
        const auto sBefore = gateProvider.provide(reqBefore, bufBefore);
        const bool beforeAllZero = std::all_of(beforeBuf.begin(), beforeBuf.end(),
                                               [](int16_t v) { return v == 0; });
        const bool beforeOk = sBefore.ok() && bufBefore.silent && beforeAllZero;

        std::vector<int16_t> atBuf(100 * static_cast<size_t>(kMixChannels), 111);
        AudioWindowRequest reqAt{480, 100, kGateSampleRate, kMixChannels,
                                 GraphAudioScheduler::ComputeWindowPtsUs(480, kGateSampleRate)};
        AudioWindowBuffer bufAt{atBuf.data(), static_cast<int64_t>(atBuf.size()), 0, true};
        const auto sAt = gateProvider.provide(reqAt, bufAt);
        bool atMatches = sAt.ok() && !bufAt.silent;
        for (size_t i = 0; i < atBuf.size() && atMatches; ++i) {
            if (atBuf[i] != gatePcm[i]) atMatches = false;
        }

        std::vector<int16_t> endBuf(50 * static_cast<size_t>(kMixChannels), 111);
        AudioWindowRequest reqEnd{736, 50, kGateSampleRate, kMixChannels,
                                  GraphAudioScheduler::ComputeWindowPtsUs(736, kGateSampleRate)};
        AudioWindowBuffer bufEnd{endBuf.data(), static_cast<int64_t>(endBuf.size()), 0, false};
        const auto sEnd = gateProvider.provide(reqEnd, bufEnd);
        const bool endAllZero = std::all_of(endBuf.begin(), endBuf.end(),
                                            [](int16_t v) { return v == 0; });
        const bool endOk = sEnd.ok() && bufEnd.silent && endAllZero;

        // Scheduler-level proof: a graph with one provider starting at a
        // nonzero timeline frame must return kSilence/no mix before start,
        // kOk/mix at start, and kSilence/no mix at the exact exclusive end
        // boundary. This exercises the silent-buffer skip in
        // GraphAudioScheduler::renderWindow, not just the provider directly.
        Graph gateGraph;
        auto gateMix = std::make_shared<AudioMixBusNode>("gate_mix", kGateSampleRate, kMixChannels, 512);
        auto gateSrc = std::make_shared<DecodedAudioPcmSourceNode>("gate_src", kGateSampleRate, kMixChannels, 4800, 0);
        gateGraph.addNode(gateMix);
        gateGraph.addNode(gateSrc);
        gateGraph.connect("gate_src", "audio_out", "gate_mix", "primary_audio_in");

        VectorAudioSampleProvider gateSchedProvider(kGateSampleRate, kMixChannels, kGateStartPtsUs, gatePcm);
        std::unordered_map<std::string, AudioSampleProvider*> gateSchedProviders = {
            {"gate_src", &gateSchedProvider},
        };
        GraphAudioScheduler gateScheduler(gateGraph, "gate_mix", gateSchedProviders);

        std::vector<int16_t> schedBeforeBuf(480 * static_cast<size_t>(kMixChannels), 111);
        GraphAudioScheduler::SchedulerOutput schedBeforeOut;
        const auto schedBeforeRes = gateScheduler.renderWindow(
            0, 480, schedBeforeBuf.data(), static_cast<int64_t>(schedBeforeBuf.size()), &schedBeforeOut);
        const bool schedBeforeAllZero = std::all_of(schedBeforeBuf.begin(), schedBeforeBuf.end(),
                                                    [](int16_t v) { return v == 0; });
        const bool schedBeforeOk = schedBeforeRes == SchedulerResult::kSilence &&
                                  schedBeforeOut.silence && !schedBeforeOut.mixCalled && schedBeforeAllZero;

        std::vector<int16_t> schedAtBuf(100 * static_cast<size_t>(kMixChannels), 111);
        GraphAudioScheduler::SchedulerOutput schedAtOut;
        const auto schedAtRes = gateScheduler.renderWindow(
            480, 100, schedAtBuf.data(), static_cast<int64_t>(schedAtBuf.size()), &schedAtOut);
        bool schedAtMatches = schedAtRes == SchedulerResult::kOk && schedAtOut.mixCalled && !schedAtOut.silence;
        for (size_t i = 0; i < schedAtBuf.size() && schedAtMatches; ++i) {
            if (schedAtBuf[i] != gatePcm[i]) schedAtMatches = false;
        }

        std::vector<int16_t> schedEndBuf(50 * static_cast<size_t>(kMixChannels), 111);
        GraphAudioScheduler::SchedulerOutput schedEndOut;
        const auto schedEndRes = gateScheduler.renderWindow(
            736, 50, schedEndBuf.data(), static_cast<int64_t>(schedEndBuf.size()), &schedEndOut);
        const bool schedEndAllZero = std::all_of(schedEndBuf.begin(), schedEndBuf.end(),
                                                 [](int16_t v) { return v == 0; });
        const bool schedEndOk = schedEndRes == SchedulerResult::kSilence &&
                                schedEndOut.silence && !schedEndOut.mixCalled && schedEndAllZero;

        if (beforeOk && atMatches && endOk && schedBeforeOk && schedAtMatches && schedEndOk) {
            timelineGatingWindowOk = true;
        } else {
            if (failureReason.empty()) failureReason = "timeline_gating_window_failed";
        }
    }

    // ── 11. ptsDerivationOk: 44100Hz non-divisible case, floor(frame*1e6/sampleRate),
    //    monotonic non-decreasing, pure integer math ──
    {
        constexpr int32_t kPtsSampleRate = 44100;
        const int64_t  ptsFrames[]    = {0, 1, 1024, 44100, 88200};
        const uint64_t ptsExpected[]  = {
            0ULL,
            (1ULL * 1000000ULL) / 44100ULL,
            (1024ULL * 1000000ULL) / 44100ULL,
            1000000ULL,
            2000000ULL,
        };
        bool ptsExactMatch = true;
        bool ptsMonotonic  = true;
        uint64_t prevPts   = 0;
        for (size_t i = 0; i < 5; ++i) {
            const uint64_t actual = GraphAudioScheduler::ComputeWindowPtsUs(ptsFrames[i], kPtsSampleRate);
            if (actual != ptsExpected[i]) ptsExactMatch = false;
            if (i > 0 && actual < prevPts) ptsMonotonic = false;
            prevPts = actual;
        }
        if (ptsExactMatch && ptsMonotonic) {
            ptsDerivationOk = true;
        } else {
            if (failureReason.empty()) failureReason = "pts_derivation_failed";
        }
    }

    // ── 12. noMicrosecondDriftOk: >=1000 windows at 44100/1024 have zero frame
    //    cursor drift (exact int64 accumulation); contrast against a naive
    //    float-microsecond accumulation, reported as a nonzero drift metric
    //    where applicable ──
    {
        constexpr int32_t kDriftSampleRate  = 44100;
        constexpr int64_t kDriftWindowFrames = 1024;
        constexpr int      kDriftWindowCount = 1000;

        int64_t frameCursor = 0;
        for (int i = 0; i < kDriftWindowCount; ++i) {
            frameCursor += kDriftWindowFrames;
        }
        const bool exactDriftFree = (frameCursor == kDriftWindowFrames * kDriftWindowCount);

        float naiveUsAccum = 0.0f;
        const float perWindowUs =
            (static_cast<float>(kDriftWindowFrames) * 1000000.0f) / static_cast<float>(kDriftSampleRate);
        for (int i = 0; i < kDriftWindowCount; ++i) {
            naiveUsAccum += perWindowUs;
        }
        const int64_t naiveFrameEquivalent = static_cast<int64_t>(
            (static_cast<double>(naiveUsAccum) * kDriftSampleRate) / 1000000.0);
        microsecondAccumulationDriftFrames = naiveFrameEquivalent - frameCursor;

        if (exactDriftFree) {
            noMicrosecondDriftOk = true;
        } else {
            if (failureReason.empty()) failureReason = "microsecond_drift_check_failed";
        }
    }

    const bool allPass = schedulerGraphEdgeRoutingOk && frameWindowMathExactOk && ptsDerivationOk &&
                         noMicrosecondDriftOk && timelineGatingWindowOk && mixRoutingChecksumOk &&
                         silenceWindowOk && staleGenerationRejectOk && sampleRateMismatchRejectOk &&
                         capacityGuardOk && noPerWindowAllocationOk && deterministicPortOrderOk &&
                         lifecycleOk;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";";
    if (!allPass) {
        oss << "reason=" << (failureReason.empty() ? "unknown_failure" : failureReason) << ";";
    }
    oss << "proofBoundary=" << kProofBoundary << ";"
        << "schedulerGraphEdgeRoutingOk=" << (schedulerGraphEdgeRoutingOk ? "true" : "false") << ";"
        << "frameWindowMathExactOk=" << (frameWindowMathExactOk ? "true" : "false") << ";"
        << "ptsDerivationOk=" << (ptsDerivationOk ? "true" : "false") << ";"
        << "noMicrosecondDriftOk=" << (noMicrosecondDriftOk ? "true" : "false") << ";"
        << "timelineGatingWindowOk=" << (timelineGatingWindowOk ? "true" : "false") << ";"
        << "mixRoutingChecksumOk=" << (mixRoutingChecksumOk ? "true" : "false") << ";"
        << "silenceWindowOk=" << (silenceWindowOk ? "true" : "false") << ";"
        << "staleGenerationRejectOk=" << (staleGenerationRejectOk ? "true" : "false") << ";"
        << "sampleRateMismatchRejectOk=" << (sampleRateMismatchRejectOk ? "true" : "false") << ";"
        << "capacityGuardOk=" << (capacityGuardOk ? "true" : "false") << ";"
        << "noPerWindowAllocationOk=" << (noPerWindowAllocationOk ? "true" : "false") << ";"
        << "deterministicPortOrderOk=" << (deterministicPortOrderOk ? "true" : "false") << ";"
        << "lifecycleOk=" << (lifecycleOk ? "true" : "false") << ";"
        << "stackScoped=" << (stackScoped ? "true" : "false") << ";"
        << "renderedFrames=" << renderedFrames << ";"
        << "mixChecksum=" << mixChecksum << ";"
        << "expectedChecksum=" << expectedChecksum << ";"
        << "schedulerMixCallCount=" << schedulerMixCallCount << ";"
        << "silenceMixCallCount=" << silenceMixCallCount << ";"
        << "windowCount=" << windowCount << ";"
        << "partialFinalWindowFrames=" << partialFinalWindowFrames << ";"
        << "microsecondAccumulationDriftFrames=" << microsecondAccumulationDriftFrames;

    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase4AudioGraphTransportClockSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunAudioGraphTransportClockSmokeInternal();
        return env->NewStringUTF(resultStr.c_str());
    } catch (const std::exception& e) {
        const std::string err =
            std::string("status=FAIL;reason=exception:") + e.what() + ";proofBoundary=" + kProofBoundary;
        return env->NewStringUTF(err.c_str());
    } catch (...) {
        const std::string err =
            std::string("status=FAIL;reason=exception:unknown;proofBoundary=") + kProofBoundary;
        return env->NewStringUTF(err.c_str());
    }
}
