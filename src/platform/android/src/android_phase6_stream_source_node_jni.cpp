// P6-STREAM-SOURCE-NODE-A: platform-neutral logical DAG producer-agnostic
// streaming ingest source node diagnostic proof.
//
// Diagnostic-only: proves vanguard::sources::StreamSourceNode's construction
// validation, identity/port shape, streamId/live accessors, dimension
// accessors, and timeline-window semantics (mirroring
// DecodedMediaFrameSourceNode's precedent), plus a real GraphExecutionPlan
// source->sink pass using this node against the real
// vanguard::sinks::PreviewSurfaceSinkNode (no TU-local diagnostic sink was
// needed - PreviewSurfaceSinkNode's header is already reachable from this
// translation unit, mirroring android_phase1_preview_surface_sink_node_jni.cpp's
// precedent). StreamSourceNode itself owns no network SDK session, decoder,
// frame buffer, texture, memory, or other OS resource and includes no
// Android/NDK/WebRTC/LiveKit/Media3 headers.
//
// Non-claims: no Path A Media3/ExoPlayer or Path B WebRTC/LiveKit session,
// no RealtimeOutputAdapter egress, no frame buffer ownership, no Android
// lifecycle, no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase6StreamSourceNodeSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/node.h"
#include "vanguard/sinks/preview_surface_sink_node.h"
#include "vanguard/sources/stream_source_node.h"

namespace {

using vanguard::graph::BuildGraphExecutionPlan;
using vanguard::graph::ExecutionPlanNode;
using vanguard::graph::FrameRequest;
using vanguard::graph::Graph;
using vanguard::graph::GraphExecutionPlan;
using vanguard::graph::NodeKind;
using vanguard::graph::NodeType;
using vanguard::graph::PortDataType;
using vanguard::sinks::PreviewSurfaceSinkNode;
using vanguard::sources::StreamSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_stream_source_node_logical_dag_source_no_network_sdk_no_decoder_"
    "framebuffer_ownership_no_android_lifecycle_no_product_app_editor_wiring";

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

std::string RunStreamSourceNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool emptyStreamIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool invalidWidthRejectedOk = false;
    bool invalidHeightRejectedOk = false;
    bool identityOk = false;
    bool streamIdLiveAccessorsOk = false;
    bool portShapeOk = false;
    bool dimensionsOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool saturatingEndLiveDurationOk = false;
    bool blendWeightsOk = false;
    bool executionPlanSourceToSinkOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        try {
            StreamSourceNode node("", "stream_1", 0, 1000, 1920, 1080, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: empty streamId is rejected with empty_stream_id ----
    {
        try {
            StreamSourceNode node("ssn_empty_stream_id", "", 0, 1000, 1920, 1080, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyStreamIdRejectedOk = std::string(e.what()) == "empty_stream_id";
        } catch (...) {
        }
        if (!emptyStreamIdRejectedOk && failureReason.empty()) {
            failureReason = "empty_stream_id_rejected_failed";
        }
    }

    // ---- Lane 3: zero duration is rejected with invalid_duration_us ----
    {
        try {
            StreamSourceNode node("ssn_zero_duration", "stream_1", 0, 0, 1920, 1080, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroDurationRejectedOk = std::string(e.what()) == "invalid_duration_us";
        } catch (...) {
        }
        if (!zeroDurationRejectedOk && failureReason.empty()) failureReason = "zero_duration_rejected_failed";
    }

    // ---- Lane 4: invalid width is rejected with invalid_width ----
    {
        bool zeroWidthRejected = false;
        bool negativeWidthRejected = false;
        try {
            StreamSourceNode node("ssn_zero_w", "stream_1", 0, 1000, 0, 1080, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroWidthRejected = std::string(e.what()) == "invalid_width";
        } catch (...) {
        }
        try {
            StreamSourceNode node("ssn_neg_w", "stream_1", 0, 1000, -1, 1080, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            negativeWidthRejected = std::string(e.what()) == "invalid_width";
        } catch (...) {
        }
        invalidWidthRejectedOk = zeroWidthRejected && negativeWidthRejected;
        if (!invalidWidthRejectedOk && failureReason.empty()) failureReason = "invalid_width_rejected_failed";
    }

    // ---- Lane 5: invalid height is rejected with invalid_height ----
    {
        bool zeroHeightRejected = false;
        bool negativeHeightRejected = false;
        try {
            StreamSourceNode node("ssn_zero_h", "stream_1", 0, 1000, 1920, 0, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroHeightRejected = std::string(e.what()) == "invalid_height";
        } catch (...) {
        }
        try {
            StreamSourceNode node("ssn_neg_h", "stream_1", 0, 1000, 1920, -1, false);
            (void)node;
        } catch (const std::invalid_argument& e) {
            negativeHeightRejected = std::string(e.what()) == "invalid_height";
        } catch (...) {
        }
        invalidHeightRejectedOk = zeroHeightRejected && negativeHeightRejected;
        if (!invalidHeightRejectedOk && failureReason.empty()) failureReason = "invalid_height_rejected_failed";
    }

    // ---- Lane 6: identity: id/kind/type (kSource, kStreamSource) ----
    {
        StreamSourceNode node("ssn_identity", "stream_identity", 1000, 5000, 1920, 1080, false);
        identityOk = node.id() == "ssn_identity" &&
            node.kind() == NodeKind::kSource &&
            node.type() == NodeType::kStreamSource;
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 7: streamId()/live() accessors reflect constructor args for
    //      both a VOD-style (live=false) and a live (live=true) stream ----
    {
        StreamSourceNode vodNode("ssn_vod", "stream_vod_42", 0, 1000, 1920, 1080, false);
        StreamSourceNode liveNode("ssn_live", "stream_live_7", 0, 1000, 1280, 720, true);
        streamIdLiveAccessorsOk =
            vodNode.streamId() == "stream_vod_42" && !vodNode.live() &&
            liveNode.streamId() == "stream_live_7" && liveNode.live();
        if (!streamIdLiveAccessorsOk && failureReason.empty()) {
            failureReason = "stream_id_live_accessors_failed";
        }
    }

    // ---- Lane 8: exact ports: zero inputs, one kVideoFrame output with PortDataType::kVideoFrame ----
    {
        StreamSourceNode node("ssn_ports", "stream_1", 0, 1000, 1280, 720, false);
        portShapeOk = node.inputPorts().empty() &&
            node.outputPorts().size() == 1 &&
            node.outputPorts()[0].id == "kVideoFrame" &&
            node.outputPorts()[0].dataType == PortDataType::kVideoFrame;
        if (!portShapeOk && failureReason.empty()) failureReason = "port_shape_failed";
    }

    // ---- Lane 9: dimensions accessors return width/height ----
    {
        StreamSourceNode node("ssn_dimensions", "stream_1", 0, 1000, 1920, 1080, false);
        dimensionsOk = node.width() == 1920 && node.height() == 1080;
        if (!dimensionsOk && failureReason.empty()) failureReason = "dimensions_failed";
    }

    // ---- Lane 10: active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        StreamSourceNode node("ssn_active_window", "stream_1", kStart, kDuration, 1920, 1080, false);

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

    // ---- Lane 11: timeline mapping before/inside/after clamps like DecodedMediaFrameSourceNode ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        StreamSourceNode node("ssn_mapping", "stream_1", kStart, kDuration, 1920, 1080, false);

        timelineMappingOk =
            node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration;

        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 12: overflow-safe timelineEndPtsUs() saturation, plus a live
    //      stream using a saturating/open-ended duration (no invented
    //      wall-clock: durationUs is simply large enough that timelineEndPtsUs()
    //      saturates to UINT64_MAX and the stream stays active far into the
    //      timeline) ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        StreamSourceNode overflowNode("ssn_overflow", "stream_1", kStart, kDuration, 1920, 1080, false);

        const bool overflowOk =
            overflowNode.timelineEndPtsUs() == kMaxU64 &&
            overflowNode.isActiveAt(kStart) &&
            overflowNode.isActiveAt(kMaxU64 - 1) &&
            !overflowNode.isActiveAt(kMaxU64) &&
            overflowNode.mapTimelineToLocalPts(kMaxU64) == kDuration;

        StreamSourceNode liveNode("ssn_live_duration", "stream_live_open_ended", 0, kMaxU64, 1920, 1080, true);
        const bool liveOpenEndedOk =
            liveNode.live() &&
            liveNode.timelineEndPtsUs() == kMaxU64 &&
            liveNode.isActiveAt(kMaxU64 - 1) &&
            !liveNode.isActiveAt(kMaxU64);

        saturatingEndLiveDurationOk = overflowOk && liveOpenEndedOk;
        if (!saturatingEndLiveDurationOk && failureReason.empty()) {
            failureReason = "saturating_end_live_duration_failed";
        }
    }

    // ---- Lane 13: blend weights 1 inside, 0 outside ----
    {
        constexpr uint64_t kStart = 2000;
        constexpr uint64_t kDuration = 3000;
        StreamSourceNode node("ssn_blend", "stream_1", kStart, kDuration, 1920, 1080, false);

        blendWeightsOk =
            node.blendWeightAt(kStart - 1) == 0.0f &&
            node.blendWeightAt(kStart + kDuration) == 0.0f &&
            node.blendWeightAt(kStart) == 1.0f &&
            node.blendWeightAt(kStart + kDuration - 1) == 1.0f;

        if (!blendWeightsOk && failureReason.empty()) failureReason = "blend_weights_failed";
    }

    // ---- Lane 14: real BuildGraphExecutionPlan pass from a real
    //      StreamSourceNode to the real PreviewSurfaceSinkNode, verifying
    //      dependency order and input binding from kVideoFrame to video_in ----
    {
        Graph g;
        auto source = std::make_shared<StreamSourceNode>(
            "ssn_plan_source", "stream_plan", 0, 5000, 1920, 1080, false);
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("ssn_plan_sink");

        const bool added = g.addNode(source).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("ssn_plan_source", "kVideoFrame", "ssn_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "ssn_plan_sink");

        executionPlanSourceToSinkOk = wired && status.ok() &&
            plan.nodes.size() == 2 &&
            PlanIndexOf(plan, "ssn_plan_source") < PlanIndexOf(plan, "ssn_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "ssn_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "ssn_plan_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceToSinkOk && failureReason.empty()) failureReason = "execution_plan_source_to_sink_failed";
    }

    // ---- Lane 15: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("stream_source_node") != std::string::npos &&
            boundary.find("logical_dag_source") != std::string::npos &&
            boundary.find("no_network_sdk") != std::string::npos &&
            boundary.find("no_decoder_framebuffer_ownership") != std::string::npos &&
            boundary.find("no_android_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 15;
    const int passedLanes =
        (emptyIdRejectedOk ? 1 : 0) + (emptyStreamIdRejectedOk ? 1 : 0) +
        (zeroDurationRejectedOk ? 1 : 0) + (invalidWidthRejectedOk ? 1 : 0) +
        (invalidHeightRejectedOk ? 1 : 0) + (identityOk ? 1 : 0) +
        (streamIdLiveAccessorsOk ? 1 : 0) + (portShapeOk ? 1 : 0) +
        (dimensionsOk ? 1 : 0) + (timelineActiveWindowOk ? 1 : 0) +
        (timelineMappingOk ? 1 : 0) + (saturatingEndLiveDurationOk ? 1 : 0) +
        (blendWeightsOk ? 1 : 0) + (executionPlanSourceToSinkOk ? 1 : 0) +
        (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",emptyStreamIdRejected:" << (emptyStreamIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",invalidWidthRejected:" << (invalidWidthRejectedOk ? "true" : "false")
        << ",invalidHeightRejected:" << (invalidHeightRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",streamIdLiveAccessors:" << (streamIdLiveAccessorsOk ? "true" : "false")
        << ",portShape:" << (portShapeOk ? "true" : "false")
        << ",dimensions:" << (dimensionsOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",saturatingEndLiveDuration:" << (saturatingEndLiveDurationOk ? "true" : "false")
        << ",blendWeights:" << (blendWeightsOk ? "true" : "false")
        << ",executionPlanSourceToSink:" << (executionPlanSourceToSinkOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase6StreamSourceNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunStreamSourceNodeSmokeInternal();
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
