// P1-DAG-MULTINODE-HARDWARE-BUFFER-SOURCE-NODE: platform-neutral logical DAG
// hardware-buffer source node diagnostic proof.
//
// Diagnostic-only: proves vanguard::sources::HardwareBufferSourceNode's
// construction validation, identity/port shape, and timeline-window
// semantics (mirroring DecodedAudioPcmSourceNode's precedent), plus a real
// GraphExecutionPlan source->sink pass using this node against a TU-local
// sink node. HardwareBufferSourceNode itself owns no AHardwareBuffer*,
// fence, texture, memory, or other OS resource and includes no Android/NDK
// headers.
//
// Non-claims: no production AHardwareBuffer ownership, no Camera2/
// MediaCodec lifecycle, no product/editor/app/ConnectsApp wiring, no dual-
// camera production route - this slice is DAG foundation only.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase1HardwareBufferSourceNodeSmoke -> jstring

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
#include "vanguard/sources/hardware_buffer_source_node.h"

namespace {

using vanguard::graph::BuildGraphExecutionPlan;
using vanguard::graph::ExecutionPlanNode;
using vanguard::graph::FrameRequest;
using vanguard::graph::Graph;
using vanguard::graph::GraphExecutionPlan;
using vanguard::graph::Node;
using vanguard::graph::NodeKind;
using vanguard::graph::NodeType;
using vanguard::graph::PortDataType;
using vanguard::graph::PortDescriptor;
using vanguard::sources::HardwareBufferSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_hardware_buffer_source_node_logical_dag_source_no_ahardwarebuffer_"
    "ownership_no_android_lifecycle_no_product_app_editor_wiring";

// TU-local sink node: declares exactly one required input port ("video_in")
// so the real GraphExecutionPlan source->sink pass below has a real active
// sink to reach. Local to this translation unit only.
class DiagSinkNode final : public Node {
public:
    explicit DiagSinkNode(std::string id)
        : id_(std::move(id)), inputPorts_{{"video_in", PortDataType::kVideoFrame}} {}

    const std::string&                 id()          const override { return id_; }
    NodeKind                           kind()        const override { return NodeKind::kSink; }
    NodeType                           type()        const override { return NodeType::kPreviewSurfaceSink; }
    const std::vector<PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<PortDescriptor>& outputPorts() const override { return outputPorts_; }

private:
    std::string id_;
    std::vector<PortDescriptor> inputPorts_;
    std::vector<PortDescriptor> outputPorts_;
};

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

std::string RunHardwareBufferSourceNodeSmokeInternal() {
    bool emptyIdRejectedOk = false;
    bool zeroDurationRejectedOk = false;
    bool identityOk = false;
    bool outputPortOk = false;
    bool timelineActiveWindowOk = false;
    bool timelineMappingOk = false;
    bool timelineClampAndOverflowOk = false;
    bool inactiveBlendZeroOk = false;
    bool executionPlanSourceToSinkOk = false;
    bool proofBoundaryLaneOk = false;
    std::string failureReason;

    // ---- Lane 1: empty id is rejected ----
    {
        try {
            HardwareBufferSourceNode node("", 0, 1000);
            (void)node;
        } catch (const std::invalid_argument& e) {
            emptyIdRejectedOk = std::string(e.what()) == "empty_id";
        } catch (...) {
        }
        if (!emptyIdRejectedOk && failureReason.empty()) failureReason = "empty_id_rejected_failed";
    }

    // ---- Lane 2: zero duration is rejected ----
    {
        try {
            HardwareBufferSourceNode node("hb_zero_duration", 0, 0);
            (void)node;
        } catch (const std::invalid_argument& e) {
            zeroDurationRejectedOk = std::string(e.what()) == "invalid_duration_us";
        } catch (...) {
        }
        if (!zeroDurationRejectedOk && failureReason.empty()) failureReason = "zero_duration_rejected_failed";
    }

    // ---- Lane 3: id/kind/type ----
    {
        HardwareBufferSourceNode node("hb_identity", 1000, 5000);
        identityOk = node.id() == "hb_identity" &&
            node.kind() == NodeKind::kSource &&
            node.type() == NodeType::kHardwareBufferSource;
        if (!identityOk && failureReason.empty()) failureReason = "identity_failed";
    }

    // ---- Lane 4: exact single output port kVideoFrame, no input ports ----
    {
        HardwareBufferSourceNode node("hb_ports", 0, 1000);
        outputPortOk = node.inputPorts().empty() &&
            node.outputPorts().size() == 1 &&
            node.outputPorts()[0].id == "kVideoFrame" &&
            node.outputPorts()[0].dataType == PortDataType::kVideoFrame;
        if (!outputPortOk && failureReason.empty()) failureReason = "output_port_failed";
    }

    // ---- Lane 5: timeline active window [start, start+duration) ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        constexpr uint64_t kEnd = kStart + kDuration;
        HardwareBufferSourceNode node("hb_active_window", kStart, kDuration);

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

    // ---- Lane 6: mapTimelineToLocalPts mirrors DecodedAudioPcmSourceNode:
    //      before start -> 0, within window -> elapsed, at/after end ->
    //      clamped to duration ----
    {
        constexpr uint64_t kStart = 10000;
        constexpr uint64_t kDuration = 5000;
        HardwareBufferSourceNode node("hb_mapping", kStart, kDuration);

        timelineMappingOk =
            node.mapTimelineToLocalPts(kStart - 1) == 0 &&
            node.mapTimelineToLocalPts(kStart) == 0 &&
            node.mapTimelineToLocalPts(kStart + 1234) == 1234 &&
            node.mapTimelineToLocalPts(kStart + kDuration) == kDuration &&
            node.mapTimelineToLocalPts(kStart + kDuration + 999) == kDuration;

        if (!timelineMappingOk && failureReason.empty()) failureReason = "timeline_mapping_failed";
    }

    // ---- Lane 7: timelineEndPtsUs()/isActiveAt() saturate instead of
    //      overflowing when start + duration would exceed UINT64_MAX, and
    //      mapTimelineToLocalPts stays well-defined at UINT64_MAX ----
    {
        constexpr uint64_t kMaxU64 = std::numeric_limits<uint64_t>::max();
        constexpr uint64_t kStart = kMaxU64 - 10;
        constexpr uint64_t kDuration = 1000; // start + duration overflows uint64_t
        HardwareBufferSourceNode node("hb_overflow", kStart, kDuration);

        timelineClampAndOverflowOk =
            node.timelineEndPtsUs() == kMaxU64 &&
            node.isActiveAt(kStart) &&
            node.isActiveAt(kMaxU64 - 1) &&
            !node.isActiveAt(kMaxU64) &&
            node.mapTimelineToLocalPts(kMaxU64) == kDuration;

        if (!timelineClampAndOverflowOk && failureReason.empty()) failureReason = "timeline_clamp_overflow_failed";
    }

    // ---- Lane 8: blendWeightAt is 1.0 inside the active window, 0.0 outside ----
    {
        constexpr uint64_t kStart = 2000;
        constexpr uint64_t kDuration = 3000;
        HardwareBufferSourceNode node("hb_blend", kStart, kDuration);

        inactiveBlendZeroOk =
            node.blendWeightAt(kStart - 1) == 0.0f &&
            node.blendWeightAt(kStart + kDuration) == 0.0f &&
            node.blendWeightAt(kStart) == 1.0f &&
            node.blendWeightAt(kStart + kDuration - 1) == 1.0f;

        if (!inactiveBlendZeroOk && failureReason.empty()) failureReason = "inactive_blend_zero_failed";
    }

    // ---- Lane 9: real GraphExecutionPlan source->sink pass using this real
    //      HardwareBufferSourceNode and a TU-local sink node ----
    {
        Graph g;
        auto source = std::make_shared<HardwareBufferSourceNode>("hb_plan_source", 0, 5000);
        auto sink = std::make_shared<DiagSinkNode>("hb_plan_sink");

        const bool added = g.addNode(source).ok() && g.addNode(sink).ok();
        const bool wired = added &&
            g.connect("hb_plan_source", "kVideoFrame", "hb_plan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* sinkNode = PlanFind(plan, "hb_plan_sink");

        executionPlanSourceToSinkOk = wired && status.ok() &&
            plan.nodes.size() == 2 &&
            PlanIndexOf(plan, "hb_plan_source") < PlanIndexOf(plan, "hb_plan_sink") &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "hb_plan_sink" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].inputPortId == "video_in" &&
            sinkNode->inputs[0].fromNodeId == "hb_plan_source" &&
            sinkNode->inputs[0].fromPortId == "kVideoFrame" &&
            sinkNode->inputs[0].dataType == PortDataType::kVideoFrame;

        if (!executionPlanSourceToSinkOk && failureReason.empty()) failureReason = "execution_plan_source_to_sink_failed";
    }

    // ---- Lane 10: proof-boundary token ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("platform_neutral") != std::string::npos &&
            boundary.find("logical_dag_source") != std::string::npos &&
            boundary.find("no_ahardwarebuffer_ownership") != std::string::npos &&
            boundary.find("no_android_lifecycle") != std::string::npos &&
            boundary.find("no_product_app_editor_wiring") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    constexpr int kTotalLanes = 10;
    const int passedLanes =
        (emptyIdRejectedOk ? 1 : 0) + (zeroDurationRejectedOk ? 1 : 0) + (identityOk ? 1 : 0) +
        (outputPortOk ? 1 : 0) + (timelineActiveWindowOk ? 1 : 0) + (timelineMappingOk ? 1 : 0) +
        (timelineClampAndOverflowOk ? 1 : 0) + (inactiveBlendZeroOk ? 1 : 0) +
        (executionPlanSourceToSinkOk ? 1 : 0) + (proofBoundaryLaneOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyIdRejected:" << (emptyIdRejectedOk ? "true" : "false")
        << ",zeroDurationRejected:" << (zeroDurationRejectedOk ? "true" : "false")
        << ",identity:" << (identityOk ? "true" : "false")
        << ",outputPort:" << (outputPortOk ? "true" : "false")
        << ",timelineActiveWindow:" << (timelineActiveWindowOk ? "true" : "false")
        << ",timelineMapping:" << (timelineMappingOk ? "true" : "false")
        << ",timelineClampAndOverflow:" << (timelineClampAndOverflowOk ? "true" : "false")
        << ",inactiveBlendZero:" << (inactiveBlendZeroOk ? "true" : "false")
        << ",executionPlanSourceToSink:" << (executionPlanSourceToSinkOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1HardwareBufferSourceNodeSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunHardwareBufferSourceNodeSmokeInternal();
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
