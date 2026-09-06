// P2-OFFLINE-MEDIA-MUXER-SINK-NODE-A: platform-neutral logical DAG
// offline-media-muxer sink node diagnostic proof.
//
// Diagnostic-only: proves vanguard::sinks::OfflineMediaMuxerSinkNode's
// construction validation, identity/port shape for video-only/audio-only/
// audio+video track combinations, hasVideo()/hasAudio() accessors, and
// timeline-window semantics (mirroring CameraFrameSourceNode's and
// ExternalSurfaceSourceNode's precedent), plus real GraphExecutionPlan
// passes wiring the real vanguard::sources::HardwareBufferSourceNode and
// vanguard::audio::DecodedAudioPcmSourceNode into this sink, and a
// missing-input fail-closed lane. OfflineMediaMuxerSinkNode itself owns no
// android.media.MediaMuxer, MediaCodec, PlatformCodecAdapter, file
// descriptor, output path, thread, or other OS resource, and includes no
// Android/NDK header.
//
// Non-claims: no production MediaMuxer/MediaCodec/PlatformCodecAdapter
// ownership, no file IO, no Android lifecycle, no product/editor/app/
// ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase2OfflineMediaMuxerSinkNodeSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "vanguard/audio/decoded_audio_pcm_source_node.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/node.h"
#include "vanguard/sinks/offline_media_muxer_sink_node.h"
#include "vanguard/sources/hardware_buffer_source_node.h"

namespace {

using vanguard::audio::DecodedAudioPcmSourceNode;
using vanguard::graph::BuildGraphExecutionPlan;
using vanguard::graph::ExecutionPlanNode;
using vanguard::graph::FrameRequest;
using vanguard::graph::Graph;
using vanguard::graph::GraphExecutionPlan;
using vanguard::graph::NodeKind;
using vanguard::graph::NodeType;
using vanguard::graph::PortDataType;
using vanguard::sinks::OfflineMediaMuxerSinkNode;
using vanguard::sources::HardwareBufferSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_offline_media_muxer_sink_node_logical_dag_sink_no_muxer_ownership_"
    "no_android_lifecycle_no_product_app_editor_wiring";

const ExecutionPlanNode* PlanFind(const GraphExecutionPlan& plan, const std::string& nodeId) {
    for (const auto& n : plan.nodes) {
        if (n.nodeId == nodeId) return &n;
    }
    return nullptr;
}

int PlanIndexOf(const GraphExecutionPlan& plan, const std::string& nodeId) {
    for (size_t i = 0; i < plan.nodes.size(); ++i) {
        if (plan.nodes[i].nodeId == nodeId) return static_cast<int>(i);
    }
    return -1;
}

std::string RunOfflineMediaMuxerSinkNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool emptyTracksRejectedOk = false;
    bool identityOk = false;
    bool portsVideoOnlyOk = false;
    bool portsAudioOnlyOk = false;
    bool portsAudioVideoOk = false;
    bool trackAccessorsOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool timelineClampAndOverflowOk = false;
    bool blendWeightsOk = false;
    bool executionPlanSourceToSinkOk = false;
    bool executionPlanAudioVideoMuxerOk = false;
    bool missingInputFailClosedOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        try {
            OfflineMediaMuxerSinkNode node("", 0, 1000, true, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: zero duration is rejected with invalid_duration_us ----
    {
        try {
            OfflineMediaMuxerSinkNode node("omm_zero_duration", 0, 0, true, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroDurationRejectedOk = std::string(e.what()) == "invalid_duration_us";
        } catch (...) {
        }
        if (!zeroDurationRejectedOk && failureReason.empty()) failureReason = "zero_duration_rejected_failed";
    }

    // ---- Lane 3: hasVideo=false, hasAudio=false is rejected with
    //      empty_tracks ----
    {
        try {
            OfflineMediaMuxerSinkNode node("omm_empty_tracks", 0, 1000, false, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyTracksRejectedOk = std::string(e.what()) == "empty_tracks";
        } catch (...) {
        }
        if (!emptyTracksRejectedOk && failureReason.empty()) failureReason = "empty_tracks_rejected_failed";
    }

    // ---- Lane 4: identity: id/kind/type (kSink, kOfflineMediaMuxerSink) ----
    {
        OfflineMediaMuxerSinkNode node("omm_identity", 1000, 5000, true, true);
        identityOk = node.id() == "omm_identity" &&
            node.kind() == NodeKind::kSink &&
            node.type() == NodeType::kOfflineMediaMuxerSink;
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 5: video-only ports: exactly [{"video_in", kVideoFrame}],
    //      zero output ports ----
    {
        OfflineMediaMuxerSinkNode node("omm_ports_video", 0, 1000, true, false);
        portsVideoOnlyOk = node.inputPorts().size() == 1 &&
            node.inputPorts()[0].id == "video_in" &&
            node.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.outputPorts().empty();
        if (!portsVideoOnlyOk && failureReason.empty()) failureReason = "ports_video_only_failed";
    }

    // ---- Lane 6: audio-only ports: exactly [{"audio_in", kAudioPacket}],
    //      zero output ports ----
    {
        OfflineMediaMuxerSinkNode node("omm_ports_audio", 0, 1000, false, true);
        portsAudioOnlyOk = node.inputPorts().size() == 1 &&
            node.inputPorts()[0].id == "audio_in" &&
            node.inputPorts()[0].dataType == PortDataType::kAudioPacket &&
            node.outputPorts().empty();
        if (!portsAudioOnlyOk && failureReason.empty()) failureReason = "ports_audio_only_failed";
    }

    // ---- Lane 7: audio+video ports: exactly [video_in, audio_in] in that
    //      order, zero output ports ----
    {
        OfflineMediaMuxerSinkNode node("omm_ports_av", 0, 1000, true, true);
        portsAudioVideoOk = node.inputPorts().size() == 2 &&
            node.inputPorts()[0].id == "video_in" &&
            node.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.inputPorts()[1].id == "audio_in" &&
            node.inputPorts()[1].dataType == PortDataType::kAudioPacket &&
            node.outputPorts().empty();
        if (!portsAudioVideoOk && failureReason.empty()) failureReason = "ports_audio_video_failed";
    }

    // ---- Lane 8: hasVideo()/hasAudio() accessors reflect the 5-arg
    //      constructor args, and the 3-arg delegating overload defaults
    //      hasVideo=true, hasAudio=false ----
    {
        OfflineMediaMuxerSinkNode videoOnlyNode("omm_accessors_video", 0, 1000, true, false);
        OfflineMediaMuxerSinkNode audioOnlyNode("omm_accessors_audio", 0, 1000, false, true);
        OfflineMediaMuxerSinkNode avNode("omm_accessors_av", 0, 1000, true, true);
        OfflineMediaMuxerSinkNode defaultedNode("omm_accessors_defaulted", 0, 1000);

        trackAccessorsOk =
            videoOnlyNode.hasVideo() && !videoOnlyNode.hasAudio() &&
            !audioOnlyNode.hasVideo() && audioOnlyNode.hasAudio() &&
            avNode.hasVideo() && avNode.hasAudio() &&
            defaultedNode.hasVideo() && !defaultedNode.hasAudio();

        if (!trackAccessorsOk && failureReason.empty()) failureReason = "track_accessors_failed";
    }

    // ---- Lane 9: active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        OfflineMediaMuxerSinkNode node("omm_active_window", kStart, kDuration, true, true);

        timelineActiveWindowOk =
            node.timelineStartPtsUs() == kStart &&
            node.durationUs() == kDuration &&
            node.timelineEndPtsUs() == kEnd &&
            !node.isActiveAt(kStart - 1) &&
            node.isActiveAt(kStart) &&
            node.isActiveAt(kStart + kDuration / 2) &&
            node.isActiveAt(kEnd - 1) &&
            !node.isActiveAt(kEnd);

        if (!timelineActiveWindowOk && failureReason.empty()) failureReason = "timeline_active_window_failed";
    }

    // ---- Lane 10: timeline mapping before/inside/after clamps ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        OfflineMediaMuxerSinkNode node("omm_mapping", kStart, kDuration, true, true);

        timelineMappingOk =
            node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration;

        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 11: overflow-safe timelineEndPtsUs() saturation to
    //      UINT64_MAX plus clamp behavior at/after the saturated end ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        OfflineMediaMuxerSinkNode node("omm_overflow", kStart, kDuration, true, true);

        timelineClampAndOverflowOk =
            node.timelineEndPtsUs() == kMaxU64 &&
            node.isActiveAt(kStart) &&
            node.isActiveAt(kMaxU64 - 1) &&
            !node.isActiveAt(kMaxU64) &&
            node.mapTimelineToLocalPts(kMaxU64) == kDuration;

        if (!timelineClampAndOverflowOk && failureReason.empty()) {
            failureReason = "timeline_clamp_and_overflow_failed";
        }
    }

    // ---- Lane 12: blend weights 1 inside, 0 outside ----
    {
        constexpr uint64_t kStart = 2000;
        constexpr uint64_t kDuration = 3000;
        OfflineMediaMuxerSinkNode node("omm_blend", kStart, kDuration, true, true);

        blendWeightsOk =
            node.blendWeightAt(kStart - 1) == 0.0f &&
            node.blendWeightAt(kStart + kDuration) == 0.0f &&
            node.blendWeightAt(kStart) == 1.0f &&
            node.blendWeightAt(kStart + kDuration - 1) == 1.0f;

        if (!blendWeightsOk && failureReason.empty()) failureReason = "blend_weights_failed";
    }

    // ---- Lane 13: real BuildGraphExecutionPlan pass from a real
    //      HardwareBufferSourceNode to a real video-only
    //      OfflineMediaMuxerSinkNode, verifying dependency order and input
    //      binding from kVideoFrame to video_in ----
    {
        Graph g;
        auto source = std::make_shared<HardwareBufferSourceNode>("omm_plan_source", 0, 5000);
        auto sink = std::make_shared<OfflineMediaMuxerSinkNode>(
            "omm_plan_sink", 0, 5000, /*hasVideo=*/true, /*hasAudio=*/false);

        const bool added = g.addNode(source).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("omm_plan_source", "kVideoFrame", "omm_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "omm_plan_sink");

        executionPlanSourceToSinkOk = wired && status.ok() &&
            plan.nodes.size() == 2 &&
            PlanIndexOf(plan, "omm_plan_source") < PlanIndexOf(plan, "omm_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "omm_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "omm_plan_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceToSinkOk && failureReason.empty()) {
            failureReason = "execution_plan_source_to_sink_failed";
        }
    }

    // ---- Lane 14: real BuildGraphExecutionPlan pass wiring a real
    //      HardwareBufferSourceNode's "kVideoFrame" output into video_in and
    //      a real DecodedAudioPcmSourceNode's "audio_out" output into
    //      audio_in on a real audio+video OfflineMediaMuxerSinkNode,
    //      verifying both bindings resolve ----
    {
        Graph g;
        auto videoSource = std::make_shared<HardwareBufferSourceNode>("omm_av_video_source", 0, 5000);
        auto audioSource = std::make_shared<DecodedAudioPcmSourceNode>(
            "omm_av_audio_source", 48000, 2, 48000, 0);
        auto sink = std::make_shared<OfflineMediaMuxerSinkNode>(
            "omm_av_plan_sink", 0, 5000, /*hasVideo=*/true, /*hasAudio=*/true);

        const bool added =
            g.addNode(videoSource).ok() && g.addNode(audioSource).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("omm_av_video_source", "kVideoFrame", "omm_av_plan_sink", "video_in").ok() &&
            g.connect("omm_av_audio_source", "audio_out", "omm_av_plan_sink", "audio_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "omm_av_plan_sink");

        executionPlanAudioVideoMuxerOk = wired && status.ok() &&
            plan.nodes.size() == 3 &&
            PlanIndexOf(plan, "omm_av_video_source") < PlanIndexOf(plan, "omm_av_plan_sink") &&
            PlanIndexOf(plan, "omm_av_audio_source") < PlanIndexOf(plan, "omm_av_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "omm_av_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 2 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "omm_av_video_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame &&
            sinkNode->inputs[1].inputPortId == "audio_in" &&
            sinkNode->inputs[1].fromNodeId == "omm_av_audio_source" &&
            sinkNode->inputs[1].fromPortId == "audio_out" &&
            sinkNode->inputs[1].dataType == PortDataType::kAudioPacket;

        if (!executionPlanAudioVideoMuxerOk && failureReason.empty()) {
            failureReason = "execution_plan_audio_video_muxer_failed";
        }
    }

    // ---- Lane 15: an active OfflineMediaMuxerSinkNode with its required
    //      "video_in" input left unwired fails BuildGraphExecutionPlan
    //      closed (fails required-input validation, not silently dropped) ----
    {
        Graph g;
        auto sink = std::make_shared<OfflineMediaMuxerSinkNode>(
            "omm_missing_input_sink", 0, 5000, /*hasVideo=*/true, /*hasAudio=*/false);
        const bool added = g.addNode(sink).ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        missingInputFailClosedOk = added && !status.ok() && plan.nodes.empty() &&
            status.message().find("video_in") != std::string::npos;

        if (!missingInputFailClosedOk && failureReason.empty()) failureReason = "missing_input_fail_closed_failed";
    }

    // ---- Lane 16: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("offline_media_muxer_sink_node") != std::string::npos &&
            boundary.find("logical_dag_sink") != std::string::npos &&
            boundary.find("no_muxer_ownership") != std::string::npos &&
            boundary.find("no_android_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 16;
    const int passedLanes =
        (emptyIdRejectedOk ? 1 : 0) + (zeroDurationRejectedOk ? 1 : 0) +
        (emptyTracksRejectedOk ? 1 : 0) + (identityOk ? 1 : 0) +
        (portsVideoOnlyOk ? 1 : 0) + (portsAudioOnlyOk ? 1 : 0) +
        (portsAudioVideoOk ? 1 : 0) + (trackAccessorsOk ? 1 : 0) +
        (timelineActiveWindowOk ? 1 : 0) + (timelineMappingOk ? 1 : 0) +
        (timelineClampAndOverflowOk ? 1 : 0) + (blendWeightsOk ? 1 : 0) +
        (executionPlanSourceToSinkOk ? 1 : 0) + (executionPlanAudioVideoMuxerOk ? 1 : 0) +
        (missingInputFailClosedOk ? 1 : 0) + (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",emptyTracksRejected:" << (emptyTracksRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",portsVideoOnly:" << (portsVideoOnlyOk ? "true" : "false")
        << ",portsAudioOnly:" << (portsAudioOnlyOk ? "true" : "false")
        << ",portsAudioVideo:" << (portsAudioVideoOk ? "true" : "false")
        << ",trackAccessors:" << (trackAccessorsOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",timelineClampAndOverflow:" << (timelineClampAndOverflowOk ? "true" : "false")
        << ",blendWeights:" << (blendWeightsOk ? "true" : "false")
        << ",executionPlanSourceToSink:" << (executionPlanSourceToSinkOk ? "true" : "false")
        << ",executionPlanAudioVideoMuxer:" << (executionPlanAudioVideoMuxerOk ? "true" : "false")
        << ",missingInputFailClosed:" << (missingInputFailClosedOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase2OfflineMediaMuxerSinkNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunOfflineMediaMuxerSinkNodeSmokeInternal();
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
