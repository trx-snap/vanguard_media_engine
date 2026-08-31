// P4-AUDIO-GRAPH-TOPOLOGY: bounded native AudioMixBusNode True-DAG topology
// and graph-gated diagnostic mix foundation.
//
// Honest non-claims:
// - Does not claim audible or realtime audio playback.
// - Does not claim C++ graph buffer transport; evaluatePlayhead moves no PCM.
// - Does not claim AudioTrack playback.
// - Does not claim Pass-2 export now runs through Graph.
// - Does not close P4-AUDIO-MIXBUS.
//
// P4-AUDIO-NODE-TIMELINE (sub-slice A): DecodedAudioPcmSourceNode now
// implements per-node timeline gating (isActiveAt/mapTimelineToLocalPts)
// against its own [timelineStartPtsUs, timelineStartPtsUs + durationUs)
// window. AudioMixBusNode and sink nodes remain always-active with
// identity-mapped localPtsUs, inherited unchanged from Node's defaults.
//
// P4-AUDIO-SCHEDULER-TIMELINE-GATING: GraphAudioScheduler::renderWindow()
// now consults each routed source node's isActiveAt at the window's derived
// pts and skips inactive sources before provide() is called
// (schedulerTimelineGatingOk lane). This proves scheduler-level gating, not
// just Graph::evaluatePlayhead gating; mapTimelineToLocalPts is not used
// and the frame cursor stays authoritative. No EOS/exhaustion semantics.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase4AudioGraphTopologySmoke -> jstring

#include <jni.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "vanguard/audio/audio_mix_bus_node.h"
#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/audio/graph_audio_scheduler.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/node.h"

namespace {

constexpr const char* kProofBoundary =
    "native_audio_mix_bus_graph_topology_and_graph_gated_diagnostic_mix_only_no_realtime_no_playback_no_audio_track_no_graph_buffer_transport_no_product";

// TU-local audio-only sink node: inherits default timeline virtuals without
// claiming timeline gating.
class DiagnosticAudioSinkNode : public vanguard::graph::Node {
public:
    explicit DiagnosticAudioSinkNode(std::string id)
        : id_(std::move(id)),
          inputPorts_{{"audio_in", vanguard::graph::PortDataType::kAudioPacket}} {}

    const std::string& id() const override { return id_; }
    vanguard::graph::NodeKind kind() const override { return vanguard::graph::NodeKind::kSink; }
    vanguard::graph::NodeType type() const override { return vanguard::graph::NodeType::kCustom; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts() const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

// TU-local video-only sink node: helper used solely for port-type mismatch proof.
class DiagnosticVideoSinkNode : public vanguard::graph::Node {
public:
    explicit DiagnosticVideoSinkNode(std::string id)
        : id_(std::move(id)),
          inputPorts_{{"video_in", vanguard::graph::PortDataType::kVideoFrame}} {}

    const std::string& id() const override { return id_; }
    vanguard::graph::NodeKind kind() const override { return vanguard::graph::NodeKind::kSink; }
    vanguard::graph::NodeType type() const override { return vanguard::graph::NodeType::kCustom; }
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts() const override { return inputPorts_; }
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override { return outputPorts_; }

private:
    std::string id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

// TU-local diagnostic provider: fills every requested frame with one
// constant nonzero sample and counts provide() calls, so the
// schedulerTimelineGatingOk lane can prove a timeline-inactive source's
// provider is never consulted — a stray call would both bump the count and
// poison the mix checksum/output with its distinct constant.
class CountingConstantPcmProvider : public vanguard::audio::AudioSampleProvider {
public:
    CountingConstantPcmProvider(int32_t sampleRate, int32_t channelCount, int16_t sampleValue)
        : sampleRate_(sampleRate), channelCount_(channelCount), sampleValue_(sampleValue) {}

    int32_t sampleRate()   const override { return sampleRate_; }
    int32_t channelCount() const override { return channelCount_; }

    int provideCallCount() const { return provideCallCount_; }

    vanguard::core::Status provide(const vanguard::audio::AudioWindowRequest& request,
                                   vanguard::audio::AudioWindowBuffer& outBuffer) noexcept override {
        ++provideCallCount_;
        outBuffer.framesWritten = 0;
        outBuffer.silent        = true;
        if (outBuffer.pcm == nullptr || request.frameCount <= 0 ||
            request.sampleRate != sampleRate_ || request.channelCount != channelCount_) {
            return vanguard::core::Status(vanguard::core::StatusCode::kError,
                                          "provide: invalid request");
        }
        const int64_t requiredSamples =
            request.frameCount * static_cast<int64_t>(channelCount_);
        if (outBuffer.capacitySamples < requiredSamples) {
            return vanguard::core::Status(vanguard::core::StatusCode::kError,
                                          "provide: insufficient capacity");
        }
        for (int64_t i = 0; i < requiredSamples; ++i) {
            outBuffer.pcm[i] = sampleValue_;
        }
        outBuffer.framesWritten = request.frameCount;
        outBuffer.silent        = false;
        return vanguard::core::Status::OK();
    }

private:
    int32_t sampleRate_;
    int32_t channelCount_;
    int16_t sampleValue_;
    int     provideCallCount_{0};
};

std::string RunAudioGraphTopologySmokeInternal() {

    bool topologyOk = false;
    bool topoOrderOk = false;
    bool portTypeOk = false;
    bool capacityOk = false;
    bool cycleRejectOk = false;
    bool inputFanInRejectOk = false;
    bool staleGenerationOk = false;
    bool mediaFlagsOk = false;
    bool graphGatedMixOk = false;
    bool invalidGainOk = false;
    bool audioTimelineGatingOk = false;
    bool audioPtsMappingOk = false;
    bool schedulerTimelineGatingOk = false;
    bool lifecycleOk = true;
    bool stackScoped = true;

    size_t reportedNodeCount = 0;
    size_t reportedEdgeCount = 0;
    size_t reportedActiveNodeCount = 0;
    bool reportedHasAudio = false;
    bool reportedHasVideo = false;

    int mixCallCount = 0;
    int staleMixCallCount = 0;
    int64_t framesMixed = 0;
    uint64_t mixChecksum = 0;
    uint64_t expectedChecksum = 0;
    int32_t maxAccumulatorAbs = 0;
    bool clipped = false;

    std::string failureReason;

    // ── 1. topologyOk: 3 DecodedAudioPcmSourceNode sources -> AudioMixBusNode -> local audio sink ──
    vanguard::graph::Graph graph;
    auto src0 = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>("src0", 48000, 2, 4800, 0);
    auto src1 = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>("src1", 48000, 2, 4800, 0);
    auto src2 = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>("src2", 48000, 2, 4800, 0);
    auto mix0 = std::make_shared<vanguard::audio::AudioMixBusNode>("mix0", 48000, 2, 512);
    auto sink0 = std::make_shared<DiagnosticAudioSinkNode>("sink0");

    vanguard::core::Status sAdd0 = graph.addNode(src0);
    vanguard::core::Status sAdd1 = graph.addNode(src1);
    vanguard::core::Status sAdd2 = graph.addNode(src2);
    vanguard::core::Status sAddMix = graph.addNode(mix0);
    vanguard::core::Status sAddSink = graph.addNode(sink0);

    vanguard::core::Status sConn0 = graph.connect("src0", "audio_out", "mix0", "primary_audio_in");
    vanguard::core::Status sConn1 = graph.connect("src1", "audio_out", "mix0", "secondary_audio_in");
    vanguard::core::Status sConn2 = graph.connect("src2", "audio_out", "mix0", "audio_in_2");
    vanguard::core::Status sConnSink = graph.connect("mix0", "mixed_audio_out", "sink0", "audio_in");

    reportedNodeCount = graph.nodeCount();
    reportedEdgeCount = graph.edgeCount();

    if (sAdd0.ok() && sAdd1.ok() && sAdd2.ok() && sAddMix.ok() && sAddSink.ok() &&
        sConn0.ok() && sConn1.ok() && sConn2.ok() && sConnSink.ok() &&
        reportedNodeCount == 5 && reportedEdgeCount == 4) {
        topologyOk = true;
    } else {
        failureReason = "topology_build_failed";
    }

    // ── 2. topoOrderOk: deterministic, stable topologicalSort; sources before mix, mix before sink ──
    std::vector<std::shared_ptr<vanguard::graph::Node>> order1;
    std::vector<std::shared_ptr<vanguard::graph::Node>> order2;
    vanguard::core::Status sSort1 = graph.topologicalSort(order1);
    vanguard::core::Status sSort2 = graph.topologicalSort(order2);

    if (sSort1.ok() && sSort2.ok() && order1.size() == 5 && order2.size() == 5) {
        bool stable = true;
        for (size_t i = 0; i < 5; ++i) {
            if (order1[i]->id() != order2[i]->id()) {
                stable = false;
                break;
            }
        }

        auto findIndex = [&](const std::string& nid) -> int {
            for (size_t i = 0; i < order1.size(); ++i) {
                if (order1[i]->id() == nid) return static_cast<int>(i);
            }
            return -1;
        };

        const int idxSrc0 = findIndex("src0");
        const int idxSrc1 = findIndex("src1");
        const int idxSrc2 = findIndex("src2");
        const int idxMix0 = findIndex("mix0");
        const int idxSink0 = findIndex("sink0");

        const bool orderValid = (idxSrc0 >= 0 && idxSrc1 >= 0 && idxSrc2 >= 0 && idxMix0 >= 0 && idxSink0 >= 0) &&
                                (idxSrc0 < idxMix0) && (idxSrc1 < idxMix0) && (idxSrc2 < idxMix0) &&
                                (idxMix0 < idxSink0);

        if (stable && orderValid) {
            topoOrderOk = true;
        } else {
            if (failureReason.empty()) failureReason = "topo_order_invalid";
        }
    } else {
        if (failureReason.empty()) failureReason = "topological_sort_failed";
    }

    // ── 3. portTypeOk: audio_out -> primary_audio_in succeeds; kAudioPacket -> kVideoFrame fails with type mismatch ──
    {
        vanguard::graph::Graph mismatchGraph;
        auto srcM = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>("src_m", 48000, 2, 4800, 0);
        auto videoSink = std::make_shared<DiagnosticVideoSinkNode>("video_sink");
        mismatchGraph.addNode(srcM);
        mismatchGraph.addNode(videoSink);
        vanguard::core::Status mismatchStatus = mismatchGraph.connect("src_m", "audio_out", "video_sink", "video_in");
        if (!mismatchStatus.ok() &&
            mismatchStatus.message().find("port data type mismatch") != std::string::npos &&
            sConn0.ok()) {
            portTypeOk = true;
        } else {
            if (failureReason.empty()) failureReason = "port_type_mismatch_check_failed";
        }
    }

    // ── 4. capacityOk: 8 sources connect to 8 distinct declared input ports; nonexistent 9th port fails closed ──
    {
        vanguard::graph::Graph capGraph;
        auto mixCap = std::make_shared<vanguard::audio::AudioMixBusNode>("mix_cap", 48000, 2, 512);
        capGraph.addNode(mixCap);

        const char* const kInputPorts[8] = {
            "primary_audio_in",
            "secondary_audio_in",
            "audio_in_2",
            "audio_in_3",
            "audio_in_4",
            "audio_in_5",
            "audio_in_6",
            "audio_in_7"
        };

        bool all8Connected = true;
        for (int i = 0; i < 8; ++i) {
            std::string srcId = "src_cap_" + std::to_string(i);
            auto srcNode = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>(srcId, 48000, 2, 4800, 0);
            capGraph.addNode(srcNode);
            vanguard::core::Status sConn = capGraph.connect(srcId, "audio_out", "mix_cap", kInputPorts[i]);
            if (!sConn.ok()) {
                all8Connected = false;
                break;
            }
        }

        auto src9 = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>("src_cap_8", 48000, 2, 4800, 0);
        capGraph.addNode(src9);
        vanguard::core::Status sConn9 = capGraph.connect("src_cap_8", "audio_out", "mix_cap", "audio_in_8");

        if (all8Connected && capGraph.edgeCount() == 8 &&
            !sConn9.ok() && sConn9.message().find("input port not found") != std::string::npos) {
            capacityOk = true;
        } else {
            if (failureReason.empty()) failureReason = "capacity_port_exhaustion_check_failed";
        }
    }

    // ── 5. cycleRejectOk: mix.mixed_audio_out -> mix.audio_in_3 self-loop fails closed and edgeCount unchanged ──
    {
        const size_t edgeCountBefore = graph.edgeCount();
        vanguard::core::Status sCycle = graph.connect("mix0", "mixed_audio_out", "mix0", "audio_in_3");
        const size_t edgeCountAfter = graph.edgeCount();

        if (!sCycle.ok() && edgeCountBefore == edgeCountAfter &&
            sCycle.message().find("would create a cycle") != std::string::npos) {
            cycleRejectOk = true;
        } else {
            if (failureReason.empty()) failureReason = "cycle_rejection_failed";
        }
    }

    // ── 5b. inputFanInRejectOk: second edge targeting an already-occupied input port fails closed ──
    {
        vanguard::graph::Graph fanInGraph;
        auto fanSrcA = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>("fan_src_a", 48000, 2, 4800, 0);
        auto fanSrcB = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>("fan_src_b", 48000, 2, 4800, 0);
        auto fanMix = std::make_shared<vanguard::audio::AudioMixBusNode>("fan_mix", 48000, 2, 512);
        fanInGraph.addNode(fanSrcA);
        fanInGraph.addNode(fanSrcB);
        fanInGraph.addNode(fanMix);

        vanguard::core::Status sFanFirst =
            fanInGraph.connect("fan_src_a", "audio_out", "fan_mix", "primary_audio_in");
        const size_t fanEdgeCountAfterFirst = fanInGraph.edgeCount();
        const uint64_t fanGenerationAfterFirst = fanInGraph.generationId();

        vanguard::core::Status sFanSecond =
            fanInGraph.connect("fan_src_b", "audio_out", "fan_mix", "primary_audio_in");
        const size_t fanEdgeCountAfterSecond = fanInGraph.edgeCount();
        const uint64_t fanGenerationAfterSecond = fanInGraph.generationId();

        if (sFanFirst.ok() &&
            !sFanSecond.ok() &&
            sFanSecond.message().find("input port already connected") != std::string::npos &&
            fanEdgeCountAfterSecond == fanEdgeCountAfterFirst &&
            fanGenerationAfterSecond == fanGenerationAfterFirst) {
            inputFanInRejectOk = true;
        } else {
            if (failureReason.empty()) failureReason = "input_fan_in_rejection_failed";
        }
    }

    // ── 6. staleGenerationOk: stale generation evaluatePlayhead fails and executes zero mix calls ──
    {
        vanguard::graph::FrameRequest staleReq;
        staleReq.generationId = graph.generationId() - 1;
        staleReq.timelinePtsUs = 0;
        vanguard::graph::FrameEvaluationResult staleResult;
        vanguard::core::Status sStale = graph.evaluatePlayhead(staleReq, staleResult);

        if (!sStale.ok() && staleResult.statusCode == vanguard::graph::EvaluationStatusCode::kStaleGeneration) {
            staleMixCallCount = 0;
            staleGenerationOk = true;
        } else {
            if (failureReason.empty()) failureReason = "stale_generation_check_failed";
        }
    }

    // ── 7. mediaFlagsOk: valid evaluatePlayhead on audio-only graph returns ok, hasAudio=true, hasVideo=false, activeNodeDetails.size()==5 ──
    vanguard::graph::FrameRequest validReq;
    validReq.generationId = graph.generationId();
    validReq.timelinePtsUs = 0;
    vanguard::graph::FrameEvaluationResult validResult;
    vanguard::core::Status sValid = graph.evaluatePlayhead(validReq, validResult);

    if (sValid.ok() && validResult.ok()) {
        reportedActiveNodeCount = validResult.activeNodeDetails.size();
        reportedHasAudio = validResult.hasAudio;
        reportedHasVideo = validResult.hasVideo;

        if (reportedHasAudio && !reportedHasVideo && reportedActiveNodeCount == 5 &&
            validResult.activeNodes.size() == 5) {
            mediaFlagsOk = true;
        } else {
            if (failureReason.empty()) failureReason = "media_flags_mismatch";
        }
    } else {
        if (failureReason.empty()) failureReason = "valid_playhead_evaluation_failed";
    }

    // ── 8. graphGatedMixOk: gated only on valid evaluation; active NodeType::kAudioSource feed MixTrack; independent checksum verification ──
    if (sValid.ok() && validResult.ok()) {
        std::vector<std::string> activeAudioSourceIds;
        for (const auto& node : validResult.activeNodes) {
            if (node && node->type() == vanguard::graph::NodeType::kAudioSource) {
                activeAudioSourceIds.push_back(node->id());
            }
        }

        std::vector<std::string> sortedActiveIds = activeAudioSourceIds;
        std::sort(sortedActiveIds.begin(), sortedActiveIds.end());
        const std::vector<std::string> expectedActiveSourceIds = {"src0", "src1", "src2"};

        if (sortedActiveIds != expectedActiveSourceIds) {
            if (failureReason.empty()) failureReason = "unexpected_active_audio_source_ids";
        } else {
            constexpr int64_t kFramesToMix = 4;
            constexpr int32_t kChannels = 2;
            constexpr int64_t kTotalSamples = kFramesToMix * kChannels; // 8 samples

            const int16_t pcm0[8] = {100, 200, 300, 400, -100, -200, 1000, -1000};
            const int16_t pcm1[8] = {10, 20, 30, 40, -10, -20, 500, 500};
            const int16_t pcm2[8] = {-50, -50, 100, 100, -200, 200, 0, 0};

            struct SyntheticTrackData {
                const int16_t* pcm{nullptr};
                double gain{0.0};
            };

            const std::unordered_map<std::string, SyntheticTrackData> syntheticTable = {
                {"src0", {pcm0, 0.5}},
                {"src1", {pcm1, 0.25}},
                {"src2", {pcm2, 1.0}},
            };

            std::vector<vanguard::audio::AudioMixBusNode::MixTrack> tracks;
            tracks.reserve(activeAudioSourceIds.size());
            bool missingSynthetic = false;

            for (const auto& srcId : activeAudioSourceIds) {
                auto it = syntheticTable.find(srcId);
                if (it == syntheticTable.end() || it->second.pcm == nullptr) {
                    missingSynthetic = true;
                    break;
                }
                vanguard::audio::AudioMixBusNode::MixTrack track{};
                track.pcm = it->second.pcm;
                track.frameCount = kFramesToMix;
                track.sampleRate = 48000;
                track.channelCount = kChannels;
                track.gain = it->second.gain;
                tracks.push_back(track);
            }

            if (missingSynthetic || tracks.size() != activeAudioSourceIds.size()) {
                if (failureReason.empty()) failureReason = "missing_synthetic_pcm_for_active_source";
            } else {
                int16_t outPcm[8] = {0};
                vanguard::audio::AudioMixBusNode::MixOutput mixOut{};
                auto mixRes = mix0->mix(tracks.data(), tracks.size(), kFramesToMix, outPcm, kTotalSamples, &mixOut);
                mixCallCount = 1;

                int32_t expectedAcc[8] = {0};
                for (size_t t = 0; t < tracks.size(); ++t) {
                    for (size_t s = 0; s < 8; ++s) {
                        expectedAcc[s] += static_cast<int32_t>(static_cast<double>(tracks[t].pcm[s]) * tracks[t].gain);
                    }
                }

                bool expClipped = false;
                int32_t expMaxAbs = 0;
                uint64_t expChecksum = 0;
                int16_t expOut[8] = {0};

                for (size_t s = 0; s < 8; ++s) {
                    int32_t acc = expectedAcc[s];
                    int32_t absAcc = (acc == INT32_MIN) ? INT32_MAX : std::abs(acc);
                    if (absAcc > expMaxAbs) expMaxAbs = absAcc;

                    if (acc > 32767) {
                        acc = 32767;
                        expClipped = true;
                    } else if (acc < -32768) {
                        acc = -32768;
                        expClipped = true;
                    }

                    expOut[s] = static_cast<int16_t>(acc);
                    expChecksum = expChecksum * 31u + static_cast<uint64_t>(static_cast<uint16_t>(expOut[s]));
                }

                framesMixed = mixOut.framesMixed;
                mixChecksum = mixOut.checksum;
                expectedChecksum = expChecksum;
                maxAccumulatorAbs = mixOut.maxAccumulatorAbs;
                clipped = mixOut.clipped;

                bool pcmMatches = true;
                for (size_t s = 0; s < 8; ++s) {
                    if (outPcm[s] != expOut[s]) {
                        pcmMatches = false;
                        break;
                    }
                }

                if (mixRes == vanguard::audio::AudioMixBusNode::MixResult::kOk &&
                    framesMixed == kFramesToMix &&
                    mixChecksum == expectedChecksum &&
                    clipped == expClipped &&
                    maxAccumulatorAbs == expMaxAbs &&
                    pcmMatches) {
                    graphGatedMixOk = true;
                } else {
                    if (failureReason.empty()) failureReason = "graph_gated_mix_checksum_or_output_mismatch";
                }
            }
        }
    } else {
        if (failureReason.empty()) failureReason = "gated_mix_unreachable_evaluation_failed";
    }

    // ── 9. invalidGainOk: track with gain=1.5 returns kInvalidGain ──
    {
        const int16_t pcmBad[2] = {100, 200};
        vanguard::audio::AudioMixBusNode::MixTrack badTrack{};
        badTrack.pcm = pcmBad;
        badTrack.frameCount = 1;
        badTrack.sampleRate = 48000;
        badTrack.channelCount = 2;
        badTrack.gain = 1.5;

        int16_t dummyOut[2] = {0};
        vanguard::audio::AudioMixBusNode::MixOutput badMixOut{};
        auto badRes = mix0->mix(&badTrack, 1, 1, dummyOut, 2, &badMixOut);
        if (badRes == vanguard::audio::AudioMixBusNode::MixResult::kInvalidGain) {
            invalidGainOk = true;
        } else {
            if (failureReason.empty()) failureReason = "invalid_gain_rejection_failed";
        }
    }

    // ── 10. audioTimelineGatingOk: at timelinePtsUs=200000, the 100ms-duration sources (src0/src1/src2)
    //        are timeline-inactive while mix0/sink0 (identity-mapped defaults) remain active ──
    {
        vanguard::graph::FrameRequest pts200Req;
        pts200Req.generationId = graph.generationId();
        pts200Req.timelinePtsUs = 200000;
        vanguard::graph::FrameEvaluationResult pts200Result;
        vanguard::core::Status sPts200 = graph.evaluatePlayhead(pts200Req, pts200Result);

        if (sPts200.ok() && pts200Result.ok() && pts200Result.activeNodeDetails.size() == 2) {
            std::vector<std::string> activeIds;
            bool localPtsOk = true;
            for (const auto& info : pts200Result.activeNodeDetails) {
                activeIds.push_back(info.nodeId);
                if (info.localPtsUs != 200000) {
                    localPtsOk = false;
                }
            }
            std::sort(activeIds.begin(), activeIds.end());
            const std::vector<std::string> expectedActiveIds = {"mix0", "sink0"};

            if (activeIds == expectedActiveIds && localPtsOk) {
                audioTimelineGatingOk = true;
            } else {
                if (failureReason.empty()) failureReason = "audio_timeline_gating_active_set_mismatch";
            }
        } else {
            if (failureReason.empty()) failureReason = "audio_timeline_gating_evaluation_failed";
        }
    }

    // ── 11. audioPtsMappingOk: standalone DecodedAudioPcmSourceNode isActiveAt/mapTimelineToLocalPts
    //        boundary semantics for [timelineStartPtsUs, timelineStartPtsUs + durationUs) ──
    {
        vanguard::audio::DecodedAudioPcmSourceNode ptsNode("pts_probe", 48000, 2, 4800, 50000);

        const bool activeChecks =
            !ptsNode.isActiveAt(49999) &&
            ptsNode.isActiveAt(50000) &&
            ptsNode.isActiveAt(149999) &&
            !ptsNode.isActiveAt(150000);

        const bool mappingChecks =
            ptsNode.mapTimelineToLocalPts(40000) == 0 &&
            ptsNode.mapTimelineToLocalPts(60000) == 10000 &&
            ptsNode.mapTimelineToLocalPts(150000) == 100000 &&
            ptsNode.mapTimelineToLocalPts(9999999) == 100000;

        if (activeChecks && mappingChecks) {
            audioPtsMappingOk = true;
        } else {
            if (failureReason.empty()) failureReason = "audio_pts_mapping_check_failed";
        }
    }

    // ── 12. schedulerTimelineGatingOk: GraphAudioScheduler::renderWindow consults
    //        Node::isActiveAt per routed source at the window's derived pts. Both
    //        sources stay routed at construction, but a timeline-inactive source is
    //        skipped before provide(): its counting provider would otherwise bump
    //        its call count and poison the checksum/output with a distinct nonzero
    //        constant. An all-inactive window must preserve kSilence + zero output. ──
    {
        using SchedResult = vanguard::audio::GraphAudioScheduler::SchedulerResult;

        vanguard::graph::Graph gateGraph;
        auto gateActive = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>(
            "gate_active", 48000, 2, 4800, 0);      // timeline-active [0us, 100000us)
        auto gateFuture = std::make_shared<vanguard::audio::DecodedAudioPcmSourceNode>(
            "gate_future", 48000, 2, 4800, 500000); // timeline-active [500000us, 600000us)
        auto gateMix = std::make_shared<vanguard::audio::AudioMixBusNode>("gate_mix", 48000, 2, 512);

        const bool gateWiringOk =
            gateGraph.addNode(gateActive).ok() &&
            gateGraph.addNode(gateFuture).ok() &&
            gateGraph.addNode(gateMix).ok() &&
            gateGraph.connect("gate_active", "audio_out", "gate_mix", "primary_audio_in").ok() &&
            gateGraph.connect("gate_future", "audio_out", "gate_mix", "secondary_audio_in").ok();

        CountingConstantPcmProvider activeProvider(48000, 2, 400);
        CountingConstantPcmProvider futureProvider(48000, 2, -9000);
        std::unordered_map<std::string, vanguard::audio::AudioSampleProvider*> gateProviders = {
            {"gate_active", &activeProvider},
            {"gate_future", &futureProvider},
        };

        vanguard::audio::GraphAudioScheduler gateScheduler(gateGraph, "gate_mix", gateProviders);

        constexpr int64_t kGateFrames  = 256;
        constexpr int64_t kGateSamples = kGateFrames * 2;
        int16_t gateOut[kGateSamples];

        // Independent single-track unit-gain mix reference for a constant value.
        auto constantMixChecksum = [&](int16_t value, uint64_t& outChecksum) -> bool {
            int16_t refPcm[kGateSamples];
            for (int64_t i = 0; i < kGateSamples; ++i) {
                refPcm[i] = value;
            }
            vanguard::audio::AudioMixBusNode::MixTrack refTrack{refPcm, kGateFrames, 48000, 2, 1.0};
            int16_t refOut[kGateSamples] = {0};
            vanguard::audio::AudioMixBusNode::MixOutput refMixOut{};
            const auto refRes = gateMix->mix(&refTrack, 1, kGateFrames, refOut, kGateSamples, &refMixOut);
            outChecksum = refMixOut.checksum;
            return refRes == vanguard::audio::AudioMixBusNode::MixResult::kOk;
        };

        auto allSamplesEqual = [&](int16_t value) -> bool {
            for (int64_t i = 0; i < kGateSamples; ++i) {
                if (gateOut[i] != value) {
                    return false;
                }
            }
            return true;
        };

        // Window A: startFrame 0 -> ptsUs 0: only gate_active is timeline-active.
        bool activeWindowOk = false;
        if (gateWiringOk && gateScheduler.targetValid() && gateScheduler.routedSourceCount() == 2) {
            for (int64_t i = 0; i < kGateSamples; ++i) {
                gateOut[i] = 12345;
            }
            vanguard::audio::GraphAudioScheduler::SchedulerOutput outA{};
            const auto resA = gateScheduler.renderWindow(0, kGateFrames, gateOut, kGateSamples, &outA);
            uint64_t refChecksumA = 0;
            activeWindowOk =
                resA == SchedResult::kOk &&
                outA.mixCalled && !outA.silence &&
                outA.framesRendered == kGateFrames &&
                outA.routedTrackCount == 1 &&
                allSamplesEqual(400) &&
                constantMixChecksum(400, refChecksumA) &&
                outA.checksum == refChecksumA &&
                activeProvider.provideCallCount() == 1 &&
                futureProvider.provideCallCount() == 0;
        }

        // Window B: startFrame 6000 -> ptsUs 125000: both sources timeline-inactive;
        // kSilence with zeroed output and no additional provide() calls.
        bool allInactiveWindowOk = false;
        {
            for (int64_t i = 0; i < kGateSamples; ++i) {
                gateOut[i] = 12345;
            }
            vanguard::audio::GraphAudioScheduler::SchedulerOutput outB{};
            const auto resB = gateScheduler.renderWindow(6000, kGateFrames, gateOut, kGateSamples, &outB);
            allInactiveWindowOk =
                resB == SchedResult::kSilence &&
                outB.silence && !outB.mixCalled &&
                outB.framesRendered == kGateFrames &&
                outB.routedTrackCount == 0 &&
                allSamplesEqual(0) &&
                activeProvider.provideCallCount() == 1 &&
                futureProvider.provideCallCount() == 0;
        }

        // Window C: startFrame 24000 -> ptsUs 500000: gating flips per window; the
        // previously skipped gate_future provider is now the only one consulted.
        bool futureWindowOk = false;
        {
            for (int64_t i = 0; i < kGateSamples; ++i) {
                gateOut[i] = 12345;
            }
            vanguard::audio::GraphAudioScheduler::SchedulerOutput outC{};
            const auto resC = gateScheduler.renderWindow(24000, kGateFrames, gateOut, kGateSamples, &outC);
            uint64_t refChecksumC = 0;
            futureWindowOk =
                resC == SchedResult::kOk &&
                outC.mixCalled && !outC.silence &&
                outC.framesRendered == kGateFrames &&
                outC.routedTrackCount == 1 &&
                allSamplesEqual(-9000) &&
                constantMixChecksum(-9000, refChecksumC) &&
                outC.checksum == refChecksumC &&
                activeProvider.provideCallCount() == 1 &&
                futureProvider.provideCallCount() == 1;
        }

        if (activeWindowOk && allInactiveWindowOk && futureWindowOk) {
            schedulerTimelineGatingOk = true;
        } else if (!activeWindowOk) {
            if (failureReason.empty()) failureReason = "scheduler_gating_active_window_failed";
        } else if (!allInactiveWindowOk) {
            if (failureReason.empty()) failureReason = "scheduler_gating_all_inactive_window_failed";
        } else {
            if (failureReason.empty()) failureReason = "scheduler_gating_future_window_failed";
        }
    }

    const bool allPass = topologyOk && topoOrderOk && portTypeOk && capacityOk &&
                         cycleRejectOk && inputFanInRejectOk && staleGenerationOk && mediaFlagsOk &&
                         graphGatedMixOk && invalidGainOk && audioTimelineGatingOk && audioPtsMappingOk &&
                         schedulerTimelineGatingOk && lifecycleOk;

    std::ostringstream oss;
    if (allPass) {
        oss << "status=PASS;"
            << "proofBoundary=" << kProofBoundary << ";"
            << "topologyOk=true;"
            << "topoOrderOk=true;"
            << "portTypeOk=true;"
            << "capacityOk=true;"
            << "cycleRejectOk=true;"
            << "inputFanInRejectOk=true;"
            << "staleGenerationOk=true;"
            << "mediaFlagsOk=true;"
            << "graphGatedMixOk=true;"
            << "invalidGainOk=true;"
            << "audioTimelineGatingOk=true;"
            << "audioPtsMappingOk=true;"
            << "schedulerTimelineGatingOk=true;"
            << "lifecycleOk=true;"
            << "stackScoped=true;"
            << "nodeCount=" << reportedNodeCount << ";"
            << "edgeCount=" << reportedEdgeCount << ";"
            << "activeNodeCount=" << reportedActiveNodeCount << ";"
            << "hasAudio=" << (reportedHasAudio ? "true" : "false") << ";"
            << "hasVideo=" << (reportedHasVideo ? "true" : "false") << ";"
            << "mixCallCount=" << mixCallCount << ";"
            << "staleMixCallCount=" << staleMixCallCount << ";"
            << "framesMixed=" << framesMixed << ";"
            << "mixChecksum=" << mixChecksum << ";"
            << "expectedChecksum=" << expectedChecksum << ";"
            << "maxAccumulatorAbs=" << maxAccumulatorAbs << ";"
            << "clipped=" << (clipped ? "true" : "false");
    } else {
        oss << "status=FAIL;"
            << "reason=" << (failureReason.empty() ? "unknown_failure" : failureReason) << ";"
            << "proofBoundary=" << kProofBoundary << ";"
            << "topologyOk=" << (topologyOk ? "true" : "false") << ";"
            << "topoOrderOk=" << (topoOrderOk ? "true" : "false") << ";"
            << "portTypeOk=" << (portTypeOk ? "true" : "false") << ";"
            << "capacityOk=" << (capacityOk ? "true" : "false") << ";"
            << "cycleRejectOk=" << (cycleRejectOk ? "true" : "false") << ";"
            << "inputFanInRejectOk=" << (inputFanInRejectOk ? "true" : "false") << ";"
            << "staleGenerationOk=" << (staleGenerationOk ? "true" : "false") << ";"
            << "mediaFlagsOk=" << (mediaFlagsOk ? "true" : "false") << ";"
            << "graphGatedMixOk=" << (graphGatedMixOk ? "true" : "false") << ";"
            << "invalidGainOk=" << (invalidGainOk ? "true" : "false") << ";"
            << "audioTimelineGatingOk=" << (audioTimelineGatingOk ? "true" : "false") << ";"
            << "audioPtsMappingOk=" << (audioPtsMappingOk ? "true" : "false") << ";"
            << "schedulerTimelineGatingOk=" << (schedulerTimelineGatingOk ? "true" : "false") << ";"
            << "lifecycleOk=" << (lifecycleOk ? "true" : "false") << ";"
            << "stackScoped=" << (stackScoped ? "true" : "false") << ";"
            << "nodeCount=" << reportedNodeCount << ";"
            << "edgeCount=" << reportedEdgeCount << ";"
            << "activeNodeCount=" << reportedActiveNodeCount << ";"
            << "hasAudio=" << (reportedHasAudio ? "true" : "false") << ";"
            << "hasVideo=" << (reportedHasVideo ? "true" : "false") << ";"
            << "mixCallCount=" << mixCallCount << ";"
            << "staleMixCallCount=" << staleMixCallCount << ";"
            << "framesMixed=" << framesMixed << ";"
            << "mixChecksum=" << mixChecksum << ";"
            << "expectedChecksum=" << expectedChecksum << ";"
            << "maxAccumulatorAbs=" << maxAccumulatorAbs << ";"
            << "clipped=" << (clipped ? "true" : "false");
    }

    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase4AudioGraphTopologySmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunAudioGraphTopologySmokeInternal();
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
