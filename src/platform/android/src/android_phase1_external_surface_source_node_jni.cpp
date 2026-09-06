// P1-EXTERNAL-SURFACE-SOURCE-NODE-A: platform-neutral logical DAG
// external-surface-source-node diagnostic proof.
//
// Diagnostic-only: proves vanguard::sources::ExternalSurfaceSourceNode's
// construction validation, identity/port shape, surfaceId/dimension
// accessors, and timeline-window semantics (mirroring
// CameraFrameSourceNode's and DecodedMediaFrameSourceNode's precedent),
// plus a real GraphExecutionPlan source->sink pass using this node against
// the real vanguard::sinks::PreviewSurfaceSinkNode.
// ExternalSurfaceSourceNode itself owns no Android Surface, SurfaceTexture,
// ANativeWindow, AHardwareBuffer, EGL/GLES/Vulkan object, JNI reference,
// thread, file descriptor, or other OS resource, and includes no
// Android/NDK/EGL/GLES/Vulkan headers.
//
// Non-claims: no external surface ownership, no Android lifecycle, no
// product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase1ExternalSurfaceSourceNodeSmoke -> jstring

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
#include "vanguard/sources/external_surface_source_node.h"

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
using vanguard::sources::ExternalSurfaceSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_external_surface_source_node_logical_dag_source_no_external_surface_"
    "ownership_no_android_lifecycle_no_product_app_editor_wiring";

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

std::string RunExternalSurfaceSourceNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool emptySurfaceIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool invalidWidthRejectedOk = false;
    bool invalidHeightRejectedOk = false;
    bool identityOk = false;
    bool outputPortOk = false;
    bool surfacePropertiesOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool timelineClampAndOverflowOk = false;
    bool blendWeightsOk = false;
    bool executionPlanSourceToSinkOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected with empty_id ----
    {
        try {
            ExternalSurfaceSourceNode node("", "surf_1", 0, 1000, 1920, 1080);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: empty surfaceId is rejected with empty_surface_id ----
    {
        try {
            ExternalSurfaceSourceNode node("ess_empty_surface_id", "", 0, 1000, 1920, 1080);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptySurfaceIdRejectedOk = std::string(e.what()) == "empty_surface_id";
        } catch (...) {
        }
        if (!emptySurfaceIdRejectedOk && failureReason.empty()) {
            failureReason = "empty_surface_id_rejected_failed";
        }
    }

    // ---- Lane 3: zero duration is rejected with invalid_duration_us ----
    {
        try {
            ExternalSurfaceSourceNode node("ess_zero_duration", "surf_1", 0, 0, 1920, 1080);
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
            ExternalSurfaceSourceNode node("ess_zero_w", "surf_1", 0, 1000, 0, 1080);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroWidthRejected = std::string(e.what()) == "invalid_width";
        } catch (...) {
        }
        try {
            ExternalSurfaceSourceNode node("ess_neg_w", "surf_1", 0, 1000, -1, 1080);
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
            ExternalSurfaceSourceNode node("ess_zero_h", "surf_1", 0, 1000, 1920, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroHeightRejected = std::string(e.what()) == "invalid_height";
        } catch (...) {
        }
        try {
            ExternalSurfaceSourceNode node("ess_neg_h", "surf_1", 0, 1000, 1920, -1);
            (void)node;
        } catch (const std::invalid_argument& e) {
            negativeHeightRejected = std::string(e.what()) == "invalid_height";
        } catch (...) {
        }
        invalidHeightRejectedOk = zeroHeightRejected && negativeHeightRejected;
        if (!invalidHeightRejectedOk && failureReason.empty()) failureReason = "invalid_height_rejected_failed";
    }

    // ---- Lane 6: identity: id/kind/type (kSource, kExternalSurfaceSource) ----
    {
        ExternalSurfaceSourceNode node("ess_identity", "surf_identity", 1000, 5000, 1920, 1080);
        identityOk = node.id() == "ess_identity" &&
            node.kind() == NodeKind::kSource &&
            node.type() == NodeType::kExternalSurfaceSource;
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 7: exact ports: zero inputs, one kVideoFrame output with PortDataType::kVideoFrame ----
    {
        ExternalSurfaceSourceNode node("ess_ports", "surf_1", 0, 1000, 1280, 720);
        outputPortOk = node.inputPorts().empty() &&
            node.outputPorts().size() == 1 &&
            node.outputPorts()[0].id == "kVideoFrame" &&
            node.outputPorts()[0].dataType == PortDataType::kVideoFrame;
        if (!outputPortOk && failureReason.empty()) failureReason = "output_port_failed";
    }

    // ---- Lane 8: surfaceId/dimension accessors reflect constructor args for
    //      the 6-arg constructor, and the 5-arg delegating overload defaults
    //      surfaceId to id ----
    {
        ExternalSurfaceSourceNode fullNode(
            "ess_accessors_full", "surf_42", 0, 1000, 1920, 1080);
        const bool fullOk = fullNode.surfaceId() == "surf_42" &&
            fullNode.width() == 1920 && fullNode.height() == 1080;

        ExternalSurfaceSourceNode defaultedNode("ess_accessors_defaulted", 0, 1000, 1280, 720);
        const bool defaultedOk = defaultedNode.surfaceId() == "ess_accessors_defaulted" &&
            defaultedNode.width() == 1280 && defaultedNode.height() == 720;

        surfacePropertiesOk = fullOk && defaultedOk;
        if (!surfacePropertiesOk && failureReason.empty()) failureReason = "surface_properties_failed";
    }

    // ---- Lane 9: active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        ExternalSurfaceSourceNode node(
            "ess_active_window", "surf_1", kStart, kDuration, 1920, 1080);

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
        ExternalSurfaceSourceNode node("ess_mapping", "surf_1", kStart, kDuration, 1920, 1080);

        timelineMappingOk =
            node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration;

        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 11: overflow-safe timelineEndPtsUs() saturation to UINT64_MAX
    //      plus clamp behavior at/after the saturated end ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        ExternalSurfaceSourceNode node("ess_overflow", "surf_1", kStart, kDuration, 1920, 1080);

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
        ExternalSurfaceSourceNode node("ess_blend", "surf_1", kStart, kDuration, 1920, 1080);

        blendWeightsOk =
            node.blendWeightAt(kStart - 1) == 0.0f &&
            node.blendWeightAt(kStart + kDuration) == 0.0f &&
            node.blendWeightAt(kStart) == 1.0f &&
            node.blendWeightAt(kStart + kDuration - 1) == 1.0f;

        if (!blendWeightsOk && failureReason.empty()) failureReason = "blend_weights_failed";
    }

    // ---- Lane 13: real BuildGraphExecutionPlan pass from a real
    //      ExternalSurfaceSourceNode to the real PreviewSurfaceSinkNode,
    //      verifying dependency order and input binding from kVideoFrame to
    //      video_in ----
    {
        Graph g;
        auto source = std::make_shared<ExternalSurfaceSourceNode>(
            "ess_plan_source", "surf_plan", 0, 5000, 1920, 1080);
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("ess_plan_sink");

        const bool added = g.addNode(source).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("ess_plan_source", "kVideoFrame", "ess_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "ess_plan_sink");

        executionPlanSourceToSinkOk = wired && status.ok() &&
            plan.nodes.size() == 2 &&
            PlanIndexOf(plan, "ess_plan_source") < PlanIndexOf(plan, "ess_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "ess_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "ess_plan_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceToSinkOk && failureReason.empty()) {
            failureReason = "execution_plan_source_to_sink_failed";
        }
    }

    // ---- Lane 14: proof boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("external_surface_source_node") != std::string::npos &&
            boundary.find("logical_dag_source") != std::string::npos &&
            boundary.find("no_external_surface_ownership") != std::string::npos &&
            boundary.find("no_android_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 14;
    const int passedLanes =
        (emptyIdRejectedOk ? 1 : 0) + (emptySurfaceIdRejectedOk ? 1 : 0) +
        (zeroDurationRejectedOk ? 1 : 0) + (invalidWidthRejectedOk ? 1 : 0) +
        (invalidHeightRejectedOk ? 1 : 0) + (identityOk ? 1 : 0) +
        (outputPortOk ? 1 : 0) + (surfacePropertiesOk ? 1 : 0) +
        (timelineActiveWindowOk ? 1 : 0) + (timelineMappingOk ? 1 : 0) +
        (timelineClampAndOverflowOk ? 1 : 0) + (blendWeightsOk ? 1 : 0) +
        (executionPlanSourceToSinkOk ? 1 : 0) + (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",emptySurfaceIdRejected:" << (emptySurfaceIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",invalidWidthRejected:" << (invalidWidthRejectedOk ? "true" : "false")
        << ",invalidHeightRejected:" << (invalidHeightRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",outputPort:" << (outputPortOk ? "true" : "false")
        << ",surfaceProperties:" << (surfacePropertiesOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",timelineClampAndOverflow:" << (timelineClampAndOverflowOk ? "true" : "false")
        << ",blendWeights:" << (blendWeightsOk ? "true" : "false")
        << ",executionPlanSourceToSink:" << (executionPlanSourceToSinkOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1ExternalSurfaceSourceNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunExternalSurfaceSourceNodeSmokeInternal();
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
