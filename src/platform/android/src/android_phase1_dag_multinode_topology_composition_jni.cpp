// P1-DAG-MULTINODE-TOPOLOGY-COMPOSITION: real multi-node DAG topology
// diagnostic proof.
//
// Diagnostic-only: proves vanguard::graph::BuildGraphExecutionPlan() can plan
// a real multi-node topology built entirely from concrete, platform-neutral
// production node classes - two vanguard::sources::HardwareBufferSourceNode
// instances feeding a vanguard::compositors::MultiCamCompositorNode's
// "primary_video_in"/"secondary_video_in" ports, whose
// "composited_video_out" output feeds a
// vanguard::sinks::PreviewSurfaceSinkNode's "video_in" port. No TU-local Node
// subclasses are used anywhere in this file. None of these three node
// classes owns any OS/GPU resource (no AHardwareBuffer allocation, no
// Surface, no TextureRegistry, no EGL/Vulkan, no Camera2/MediaCodec) - this
// slice only proves DAG topology/execution-plan shape.
//
// Non-claims: no rendering, no GPU/pixel/handle transport, no product/
// editor/app/ConnectsApp wiring. Per the UMF phase_1_core_dag_render_backend
// tracker, broader arbitrary compositor-node execution and intermediate GPU
// node transport remain open beyond this topology-proof slice.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// Lane list (exactly 10):
//   1. nodePortContract               - real node port/kind/type contract
//                                        observed on all three node classes
//   2. fourNodeGraphWired             - the four-node graph (2 sources ->
//                                        compositor -> sink) wires cleanly
//   3. buildPlanPass                  - BuildGraphExecutionPlan() passes over
//                                        that four-node graph
//   4. dependencyOrder                - deterministic dependency order: both
//                                        sources before the compositor,
//                                        compositor before the sink
//   5. compositorBindings             - compositor input bindings resolve
//                                        both primary/secondary from distinct
//                                        source nodes
//   6. sinkBinding                    - sink's "video_in" binding resolves
//                                        from the compositor's
//                                        "composited_video_out"
//   7. orphanCulled                   - an unreachable active orphan source
//                                        is silently culled, not a failure
//   8. missingSecondaryInputFailClosed - an unwired "secondary_video_in"
//                                        fails BuildGraphExecutionPlan closed,
//                                        mentioning "secondary_video_in"
//   9. inactiveSecondaryFailClosed    - a wired but timeline-inactive
//                                        secondary source at the request pts
//                                        fails closed the same way
//  10. staleGenerationRejects         - a stale FrameRequest.generationId is
//                                        rejected before required-input
//                                        validation runs (proven against a
//                                        graph that would otherwise also fail
//                                        on a missing "secondary_video_in")
//
// JNI entry point:
//   runAndroidDagPhase1DagMultinodeTopologyCompositionSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "vanguard/compositors/multi_cam_compositor_node.h"
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
using vanguard::compositors::MultiCamCompositorNode;
using vanguard::sinks::PreviewSurfaceSinkNode;
using vanguard::sources::HardwareBufferSourceNode;

constexpr const char* kProofBoundary =
    "real_node_multinode_topology_composition_diagnostic_only_no_render_no_gpu_"
    "transport_no_product_app_editor_wiring";

bool PlanHasNode(const GraphExecutionPlan& plan, const std::string& nodeId) {
    for (const auto& n : plan.nodes) {
        if (n.nodeId == nodeId) return true;
    }
    return false;
}

int PlanIndexOf(const GraphExecutionPlan& plan, const std::string& nodeId) {
    for (size_t i = 0; i < plan.nodes.size(); ++i) {
        if (plan.nodes[i].nodeId == nodeId) return static_cast<int>(i);
    }
    return -1;
}

const ExecutionPlanNode* PlanFind(const GraphExecutionPlan& plan, const std::string& nodeId) {
    for (const auto& n : plan.nodes) {
        if (n.nodeId == nodeId) return &n;
    }
    return nullptr;
}

std::string RunMultinodeTopologyCompositionSmokeInternal() {
    bool nodePortContractOk = false;
    bool fourNodeGraphWiredOk = false;
    bool buildPlanPassOk = false;
    bool dependencyOrderOk = false;
    bool compositorBindingsOk = false;
    bool sinkBindingOk = false;
    bool orphanCulledOk = false;
    bool missingSecondaryInputFailClosedOk = false;
    bool inactiveSecondaryFailClosedOk = false;
    bool staleGenerationRejectsOk = false;
    std::string failureReason;

    // ---- Lane 1: real node port/kind/type contract observed ----
    {
        HardwareBufferSourceNode source("contract_source", 0, 5000);
        MultiCamCompositorNode compositor("contract_compositor");
        PreviewSurfaceSinkNode sink("contract_sink");

        nodePortContractOk =
            source.kind() == NodeKind::kSource &&
            source.type() == NodeType::kHardwareBufferSource &&
            source.inputPorts().empty() &&
            source.outputPorts().size() == 1 &&
            source.outputPorts()[0].id == "kVideoFrame" &&
            source.outputPorts()[0].dataType == PortDataType::kVideoFrame &&

            compositor.kind() == NodeKind::kProcessing &&
            compositor.type() == NodeType::kMultiCamCompositor &&
            compositor.inputPorts().size() == 2 &&
            compositor.inputPorts()[0].id == "primary_video_in" &&
            compositor.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            compositor.inputPorts()[1].id == "secondary_video_in" &&
            compositor.inputPorts()[1].dataType == PortDataType::kVideoFrame &&
            compositor.outputPorts().size() == 1 &&
            compositor.outputPorts()[0].id == "composited_video_out" &&
            compositor.outputPorts()[0].dataType == PortDataType::kVideoFrame &&

            sink.kind() == NodeKind::kSink &&
            sink.type() == NodeType::kPreviewSurfaceSink &&
            sink.inputPorts().size() == 1 &&
            sink.inputPorts()[0].id == "video_in" &&
            sink.inputPorts()[0].dataType == PortDataType::kVideoFrame &&
            sink.outputPorts().empty();

        if (!nodePortContractOk && failureReason.empty()) failureReason = "node_port_contract_failed";
    }

    // ---- Lanes 2-6: the real four-node topology (2 sources -> compositor ->
    //      sink), wiring / plan-pass / dependency-order / compositor-bindings
    //      / sink-binding, all derived from one shared BuildGraphExecutionPlan
    //      result ----
    {
        Graph g;
        auto primary = std::make_shared<HardwareBufferSourceNode>("mn_primary_source", 0, 5000);
        auto secondary = std::make_shared<HardwareBufferSourceNode>("mn_secondary_source", 0, 5000);
        auto compositor = std::make_shared<MultiCamCompositorNode>("mn_compositor");
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("mn_sink");

        const bool added =
            g.addNode(primary).ok() && g.addNode(secondary).ok() &&
            g.addNode(compositor).ok() && g.addNode(sink).ok();

        const bool wired = added &&
            g.connect("mn_primary_source", "kVideoFrame", "mn_compositor", "primary_video_in").ok() &&
            g.connect("mn_secondary_source", "kVideoFrame", "mn_compositor", "secondary_video_in").ok() &&
            g.connect("mn_compositor", "composited_video_out", "mn_sink", "video_in").ok();

        fourNodeGraphWiredOk = wired;
        if (!fourNodeGraphWiredOk && failureReason.empty()) failureReason = "four_node_graph_wired_failed";

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        buildPlanPassOk = wired && status.ok() && plan.nodes.size() == 4;
        if (!buildPlanPassOk && failureReason.empty()) failureReason = "build_plan_pass_failed";

        const int idxPrimary = PlanIndexOf(plan, "mn_primary_source");
        const int idxSecondary = PlanIndexOf(plan, "mn_secondary_source");
        const int idxCompositor = PlanIndexOf(plan, "mn_compositor");
        const int idxSink = PlanIndexOf(plan, "mn_sink");

        dependencyOrderOk = buildPlanPassOk &&
            idxPrimary >= 0 && idxSecondary >= 0 && idxCompositor >= 0 && idxSink >= 0 &&
            idxPrimary < idxCompositor && idxSecondary < idxCompositor &&
            idxCompositor < idxSink;
        if (!dependencyOrderOk && failureReason.empty()) failureReason = "dependency_order_failed";

        const auto* compositorPlanNode = PlanFind(plan, "mn_compositor");
        bool foundPrimaryBinding = false;
        bool foundSecondaryBinding = false;
        if (compositorPlanNode != nullptr) {
            for (const auto& in : compositorPlanNode->inputs) {
                if (in.inputPortId == "primary_video_in" && in.fromNodeId == "mn_primary_source" &&
                    in.fromPortId == "kVideoFrame" && in.dataType == PortDataType::kVideoFrame) {
                    foundPrimaryBinding = true;
                }
                if (in.inputPortId == "secondary_video_in" && in.fromNodeId == "mn_secondary_source" &&
                    in.fromPortId == "kVideoFrame" && in.dataType == PortDataType::kVideoFrame) {
                    foundSecondaryBinding = true;
                }
            }
        }
        compositorBindingsOk = buildPlanPassOk && compositorPlanNode != nullptr &&
            compositorPlanNode->inputs.size() == 2 &&
            foundPrimaryBinding && foundSecondaryBinding;
        if (!compositorBindingsOk && failureReason.empty()) failureReason = "compositor_bindings_failed";

        const auto* sinkPlanNode = PlanFind(plan, "mn_sink");
        sinkBindingOk = buildPlanPassOk && sinkPlanNode != nullptr &&
            sinkPlanNode->inputs.size() == 1 &&
            sinkPlanNode->inputs[0].inputPortId == "video_in" &&
            sinkPlanNode->inputs[0].fromNodeId == "mn_compositor" &&
            sinkPlanNode->inputs[0].fromPortId == "composited_video_out" &&
            sinkPlanNode->inputs[0].dataType == PortDataType::kVideoFrame &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "mn_sink";
        if (!sinkBindingOk && failureReason.empty()) failureReason = "sink_binding_failed";
    }

    // ---- Lane 7: an unreachable active orphan source is silently culled ----
    {
        Graph g;
        auto primary = std::make_shared<HardwareBufferSourceNode>("orphan_primary_source", 0, 5000);
        auto secondary = std::make_shared<HardwareBufferSourceNode>("orphan_secondary_source", 0, 5000);
        auto compositor = std::make_shared<MultiCamCompositorNode>("orphan_compositor");
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("orphan_sink");
        auto orphanSource = std::make_shared<HardwareBufferSourceNode>("orphan_unreachable_source", 0, 5000);

        const bool added =
            g.addNode(primary).ok() && g.addNode(secondary).ok() &&
            g.addNode(compositor).ok() && g.addNode(sink).ok() &&
            g.addNode(orphanSource).ok();

        // orphanSource is added to the graph but never connected to anything.
        const bool wired = added &&
            g.connect("orphan_primary_source", "kVideoFrame", "orphan_compositor", "primary_video_in").ok() &&
            g.connect("orphan_secondary_source", "kVideoFrame", "orphan_compositor", "secondary_video_in").ok() &&
            g.connect("orphan_compositor", "composited_video_out", "orphan_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        orphanCulledOk = wired && status.ok() && plan.nodes.size() == 4 &&
            PlanHasNode(plan, "orphan_primary_source") && PlanHasNode(plan, "orphan_secondary_source") &&
            PlanHasNode(plan, "orphan_compositor") && PlanHasNode(plan, "orphan_sink") &&
            !PlanHasNode(plan, "orphan_unreachable_source");

        if (!orphanCulledOk && failureReason.empty()) failureReason = "orphan_culled_failed";
    }

    // ---- Lane 8: compositor's "secondary_video_in" left unwired fails
    //      BuildGraphExecutionPlan closed, mentioning "secondary_video_in" ----
    {
        Graph g;
        auto primary = std::make_shared<HardwareBufferSourceNode>("missing_primary_source", 0, 5000);
        auto compositor = std::make_shared<MultiCamCompositorNode>("missing_compositor");
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("missing_sink");

        const bool added =
            g.addNode(primary).ok() && g.addNode(compositor).ok() && g.addNode(sink).ok();

        // missing_compositor.secondary_video_in is deliberately left unconnected.
        const bool wired = added &&
            g.connect("missing_primary_source", "kVideoFrame", "missing_compositor", "primary_video_in").ok() &&
            g.connect("missing_compositor", "composited_video_out", "missing_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        missingSecondaryInputFailClosedOk = wired && !status.ok() && plan.nodes.empty() &&
            status.message().find("secondary_video_in") != std::string::npos &&
            status.message().find("missing_compositor") != std::string::npos;

        if (!missingSecondaryInputFailClosedOk && failureReason.empty()) {
            failureReason = "missing_secondary_input_fail_closed_failed";
        }
    }

    // ---- Lane 9: secondary source is wired but timeline-inactive at the
    //      request pts, so it drops out of the active set and
    //      "secondary_video_in" resolves to zero active incoming
    //      connections - same fail-closed path as lane 8 ----
    {
        Graph g;
        auto primary = std::make_shared<HardwareBufferSourceNode>("inactive_primary_source", 0, 5000);
        // Active window [10000, 15000); the request below asks for pts=0,
        // which is before this source's window opens.
        auto secondary = std::make_shared<HardwareBufferSourceNode>("inactive_secondary_source", 10000, 5000);
        auto compositor = std::make_shared<MultiCamCompositorNode>("inactive_compositor");
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("inactive_sink");

        const bool added =
            g.addNode(primary).ok() && g.addNode(secondary).ok() &&
            g.addNode(compositor).ok() && g.addNode(sink).ok();

        const bool wired = added &&
            g.connect("inactive_primary_source", "kVideoFrame", "inactive_compositor", "primary_video_in").ok() &&
            g.connect("inactive_secondary_source", "kVideoFrame", "inactive_compositor", "secondary_video_in").ok() &&
            g.connect("inactive_compositor", "composited_video_out", "inactive_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        inactiveSecondaryFailClosedOk = wired &&
            primary->isActiveAt(0) && !secondary->isActiveAt(0) &&
            !status.ok() && plan.nodes.empty() &&
            status.message().find("secondary_video_in") != std::string::npos;

        if (!inactiveSecondaryFailClosedOk && failureReason.empty()) {
            failureReason = "inactive_secondary_fail_closed_failed";
        }
    }

    // ---- Lane 10: a stale FrameRequest.generationId is rejected before
    //      required-input validation runs, proven against a graph whose
    //      compositor also has an unwired "secondary_video_in" - if input
    //      validation ran first, the message would mention
    //      "secondary_video_in" instead of "stale" ----
    {
        Graph g;
        auto primary = std::make_shared<HardwareBufferSourceNode>("stale_primary_source", 0, 5000);
        auto compositor = std::make_shared<MultiCamCompositorNode>("stale_compositor");
        auto sink = std::make_shared<PreviewSurfaceSinkNode>("stale_sink");

        const bool added =
            g.addNode(primary).ok() && g.addNode(compositor).ok() && g.addNode(sink).ok();

        // stale_compositor.secondary_video_in is deliberately left unconnected.
        const bool wired = added &&
            g.connect("stale_primary_source", "kVideoFrame", "stale_compositor", "primary_video_in").ok() &&
            g.connect("stale_compositor", "composited_video_out", "stale_sink", "video_in").ok();

        const uint64_t staleGenerationId = g.generationId();
        g.bumpGeneration(); // graph mutates further; staleGenerationId is now stale.

        FrameRequest req;
        req.generationId = staleGenerationId;
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        staleGenerationRejectsOk = wired && !status.ok() && plan.nodes.empty() &&
            status.message().find("stale") != std::string::npos &&
            status.message().find("secondary_video_in") == std::string::npos;

        if (!staleGenerationRejectsOk && failureReason.empty()) failureReason = "stale_generation_rejects_failed";
    }

    constexpr int kTotalLanes = 10;
    const int passedLanes =
        (nodePortContractOk ? 1 : 0) + (fourNodeGraphWiredOk ? 1 : 0) + (buildPlanPassOk ? 1 : 0) +
        (dependencyOrderOk ? 1 : 0) + (compositorBindingsOk ? 1 : 0) + (sinkBindingOk ? 1 : 0) +
        (orphanCulledOk ? 1 : 0) + (missingSecondaryInputFailClosedOk ? 1 : 0) +
        (inactiveSecondaryFailClosedOk ? 1 : 0) + (staleGenerationRejectsOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=nodePortContract:" << (nodePortContractOk ? "true" : "false")
        << ",fourNodeGraphWired:" << (fourNodeGraphWiredOk ? "true" : "false")
        << ",buildPlanPass:" << (buildPlanPassOk ? "true" : "false")
        << ",dependencyOrder:" << (dependencyOrderOk ? "true" : "false")
        << ",compositorBindings:" << (compositorBindingsOk ? "true" : "false")
        << ",sinkBinding:" << (sinkBindingOk ? "true" : "false")
        << ",orphanCulled:" << (orphanCulledOk ? "true" : "false")
        << ",missingSecondaryInputFailClosed:" << (missingSecondaryInputFailClosedOk ? "true" : "false")
        << ",inactiveSecondaryFailClosed:" << (inactiveSecondaryFailClosedOk ? "true" : "false")
        << ",staleGenerationRejects:" << (staleGenerationRejectsOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1DagMultinodeTopologyCompositionSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunMultinodeTopologyCompositionSmokeInternal();
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
