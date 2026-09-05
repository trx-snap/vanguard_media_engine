// P1-DAG-MULTINODE-PREVIEW-SURFACE-SINK-NODE: platform-neutral logical DAG
// preview-surface sink node diagnostic proof.
//
// Diagnostic-only: proves vanguard::sinks::PreviewSurfaceSinkNode's
// construction validation, identity/port shape, and default (unmodified)
// timeline semantics, plus a real GraphExecutionPlan source->sink pass
// wiring the real vanguard::sources::HardwareBufferSourceNode's
// "kVideoFrame" output into this real sink's "video_in" input.
// PreviewSurfaceSinkNode itself owns no Surface, ANativeWindow,
// TextureRegistry, EGL/Vulkan object, hardware buffer, memory, Android/NDK
// header, thread, or other OS resource.
//
// Non-claims: no production TextureRegistry/SurfaceProducer ownership, no
// EGL/Vulkan presentation, no product/editor/app/ConnectsApp wiring - this
// slice is DAG foundation only.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// Lane list (exactly 10; "identity" and "ports" are each a single combined
// lane, matching the precedent set by
// android_phase1_hardware_buffer_source_node_jni.cpp's outputPortOk lane):
//   1. emptyIdRejected            - empty id throws invalid_argument("empty_id")
//   2. identity                   - id()/kind()/type() are correct
//   3. ports                      - inputPorts() is exactly [{"video_in", kVideoFrame}]
//                                    and outputPorts() is empty
//   4. defaultActiveWindow        - default isActiveAt() is true at pts=0 and
//                                    pts=UINT64_MAX (unmodified Node default)
//   5. identityLocalPtsMapping    - default mapTimelineToLocalPts() is the
//                                    identity function (unmodified Node default)
//   6. unitBlend                  - default blendWeightAt() is always 1.0
//                                    (unmodified Node default)
//   7. executionPlanSourceToSink  - real GraphExecutionPlan pass wiring a real
//                                    HardwareBufferSourceNode's "kVideoFrame"
//                                    output into a real PreviewSurfaceSinkNode's
//                                    "video_in" input
//   8. missingInputFailClosed     - an unwired active PreviewSurfaceSinkNode
//                                    fails BuildGraphExecutionPlan closed
//   9. staleGenerationRejected    - a stale FrameRequest.generationId fails
//                                    BuildGraphExecutionPlan closed before any
//                                    port validation runs
//  10. proofBoundaryLane          - the proof-boundary token contains the
//                                    expected claims
//
// JNI entry point:
//   runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/node.h"
#include "vanguard/sinks/preview_surface_sink_node.h"
#include "vanguard/sources/hardware_buffer_source_node.h"

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
using vanguard::sources::HardwareBufferSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_preview_surface_sink_node_logical_dag_sink_no_surface_ownership_"
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

std::string RunPreviewSurfaceSinkNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool identityOk = false;
    bool portsOk = false;
    bool defaultActiveWindowOk = false;
    bool identityLocalPtsMappingOk = false;
    bool unitBlendOk = false;
    bool executionPlanSourceToSinkOk = false;
    bool missingInputFailClosedOk = false;
    bool staleGenerationRejectedOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected ----
    {
        try {
            PreviewSurfaceSinkNode node("");
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: id/kind/type ----
    {
        PreviewSurfaceSinkNode node("pv_identity");
        identityOk = node.id() == "pv_identity" &&
            node.kind() == NodeKind::kSink &&
            node.type() == NodeType::kPreviewSurfaceSink;
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 3: exactly one input port ("video_in", kVideoFrame), zero
    //      output ports ----
    {
        PreviewSurfaceSinkNode node("pv_ports");
        portsOk = node.inputPorts().size() == 1 &&
            node.inputPorts()[0].id == "video_in" &&
            node.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            node.outputPorts().empty();
        if (!portsOk && failureReason.empty()) failureReason = "ports_failed";
    }

    // ---- Lane 4: default (unoverridden) isActiveAt() is always true,
    //      including at pts=0 and pts=UINT64_MAX ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        PreviewSurfaceSinkNode node("pv_active_window");
        defaultActiveWindowOk = node.isActiveAt(0) && node.isActiveAt(kMaxU64);
        if (!defaultActiveWindowOk && failureReason.empty()) failureReason = "default_active_window_failed";
    }

    // ---- Lane 5: default (unoverridden) mapTimelineToLocalPts() is the
    //      identity function ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        PreviewSurfaceSinkNode node("pv_mapping");
        identityLocalPtsMappingOk =
            node.mapTimelineToLocalPts(0) == 0 &&
            node.mapTimelineToLocalPts(1234) == 1234 &&
            node.mapTimelineToLocalPts(kMaxU64) == kMaxU64;
        if (!identityLocalPtsMappingOk && failureReason.empty()) failureReason = "identity_local_pts_mapping_failed";
    }

    // ---- Lane 6: default (unoverridden) blendWeightAt() is always 1.0 ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        PreviewSurfaceSinkNode node("pv_blend");
        unitBlendOk =
            node.blendWeightAt(0) == 1.0f &&
            node.blendWeightAt(1234) == 1.0f &&
            node.blendWeightAt(kMaxU64) == 1.0f;
        if (!unitBlendOk && failureReason.empty()) failureReason = "unit_blend_failed";
    }

    // ---- Lane 7: real GraphExecutionPlan source->sink pass wiring a real
    //      HardwareBufferSourceNode's "kVideoFrame" output into a real
    //      PreviewSurfaceSinkNode's "video_in" input ----
    {
        Graph g;
        auto source = std::make_shared<HardwareBufferSourceNode>("pv_plan_source", 0, 5000);
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("pv_plan_sink");

        const bool added = g.addNode(source).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("pv_plan_source", "kVideoFrame", "pv_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "pv_plan_sink");

        executionPlanSourceToSinkOk = wired && status.ok() &&
            plan.nodes.size() == 2 &&
            PlanIndexOf(plan, "pv_plan_source") < PlanIndexOf(plan, "pv_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "pv_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "pv_plan_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceToSinkOk && failureReason.empty()) failureReason = "execution_plan_source_to_sink_failed";
    }

    // ---- Lane 8: an active PreviewSurfaceSinkNode with its required
    //      "video_in" input left unwired fails BuildGraphExecutionPlan
    //      closed (fails required-input validation, not silently dropped) ----
    {
        Graph g;
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("pv_missing_input_sink");
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

    // ---- Lane 9: a stale FrameRequest.generationId fails
    //      BuildGraphExecutionPlan closed before any port validation runs ----
    {
        Graph g;
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("pv_stale_sink");
        const bool added = g.addNode(sink).ok();
        const uint64_t staleGenerationId = g.generationId();
        g.bumpGeneration();

        FrameRequest req;
        req.generationId = staleGenerationId;
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        staleGenerationRejectedOk = added && !status.ok() && plan.nodes.empty() &&
            status.message().find("stale generation") != std::string::npos;

        if (!staleGenerationRejectedOk && failureReason.empty()) failureReason = "stale_generation_rejected_failed";
    }

    // ---- Lane 10: proof-boundary token ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("logical_dag_sink") != std::string::npos &&
            boundary.find("no_surface_ownership") != std::string::npos &&
            boundary.find("no_android_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 10;
    const int passedLanes =
        (emptyIdRejectedOk ? 1 : 0) + (identityOk ? 1 : 0) + (portsOk ? 1 : 0) +
        (defaultActiveWindowOk ? 1 : 0) + (identityLocalPtsMappingOk ? 1 : 0) +
        (unitBlendOk ? 1 : 0) + (executionPlanSourceToSinkOk ? 1 : 0) +
        (missingInputFailClosedOk ? 1 : 0) + (staleGenerationRejectedOk ? 1 : 0) +
        (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",ports:" << (portsOk ? "true" : "false")
        << ",defaultActiveWindow:" << (defaultActiveWindowOk ? "true" : "false")
        << ",identityLocalPtsMapping:" << (identityLocalPtsMappingOk ? "true" : "false")
        << ",unitBlend:" << (unitBlendOk ? "true" : "false")
        << ",executionPlanSourceToSink:" << (executionPlanSourceToSinkOk ? "true" : "false")
        << ",missingInputFailClosed:" << (missingInputFailClosedOk ? "true" : "false")
        << ",staleGenerationRejected:" << (staleGenerationRejectedOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1PreviewSurfaceSinkNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunPreviewSurfaceSinkNodeSmokeInternal();
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
