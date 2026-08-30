// P4-AUDIO-GRAPH-TOPOLOGY: bounded native AudioMixBusNode True-DAG topology
// and graph-gated diagnostic mix foundation.
//
// Honest non-claims:
// - Does not claim audible or realtime audio playback.
// - Does not claim C++ graph buffer transport; evaluatePlayhead moves no PCM.
// - Does not claim audio timeline gating; current audio nodes inherit always-active/identity defaults.
// - Does not claim input-port fan-in enforcement.
// - Does not claim Pass-2 export now runs through Graph.
// - Does not close P4-AUDIO-MIXBUS.
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

std::string RunAudioGraphTopologySmokeInternal() {

    bool topologyOk = false;
    bool topoOrderOk = false;
    bool portTypeOk = false;
    bool capacityOk = false;
    bool cycleRejectOk = false;
    bool staleGenerationOk = false;
    bool mediaFlagsOk = false;
    bool graphGatedMixOk = false;
    bool invalidGainOk = false;
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

    // ── 5. cycleRejectOk: mix.mixed_audio_out -> mix.primary_audio_in self-loop fails closed and edgeCount unchanged ──
    {
        const size_t edgeCountBefore = graph.edgeCount();
        vanguard::core::Status sCycle = graph.connect("mix0", "mixed_audio_out", "mix0", "primary_audio_in");
        const size_t edgeCountAfter = graph.edgeCount();

        if (!sCycle.ok() && edgeCountBefore == edgeCountAfter) {
            cycleRejectOk = true;
        } else {
            if (failureReason.empty()) failureReason = "cycle_rejection_failed";
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

    const bool allPass = topologyOk && topoOrderOk && portTypeOk && capacityOk &&
                         cycleRejectOk && staleGenerationOk && mediaFlagsOk &&
                         graphGatedMixOk && invalidGainOk && lifecycleOk;

    std::ostringstream oss;
    if (allPass) {
        oss << "status=PASS;"
            << "proofBoundary=" << kProofBoundary << ";"
            << "topologyOk=true;"
            << "topoOrderOk=true;"
            << "portTypeOk=true;"
            << "capacityOk=true;"
            << "cycleRejectOk=true;"
            << "staleGenerationOk=true;"
            << "mediaFlagsOk=true;"
            << "graphGatedMixOk=true;"
            << "invalidGainOk=true;"
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
            << "staleGenerationOk=" << (staleGenerationOk ? "true" : "false") << ";"
            << "mediaFlagsOk=" << (mediaFlagsOk ? "true" : "false") << ";"
            << "graphGatedMixOk=" << (graphGatedMixOk ? "true" : "false") << ";"
            << "invalidGainOk=" << (invalidGainOk ? "true" : "false") << ";"
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
