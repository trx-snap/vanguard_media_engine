// P1-DAG-MULTINODE-CORE-EXEC-PLAN: bounded engine-only GraphExecutionPlanner
// diagnostic proof.
//
// Diagnostic-only: proves vanguard::graph::BuildGraphExecutionPlan() over
// synthetic TU-local DAGs (deep chain, diamond fan-out/reconvergence,
// multi-sink fan-out, unreachable orphan branches, missing required inputs,
// stale-generation precedence, N>=3-source fan-in, no-active-sink fail-
// closed, unchanged Graph cycle rejection) built only from the existing
// Graph API (evaluatePlayhead / topologicalSort / inputConnections). Does
// not mutate Graph/Node/evaluatePlayhead semantics.
//
// Non-claims: no production timeline playback, no product/editor/app/
// ConnectsApp wiring, no SurfaceProducer production path, no pixel/handle
// transport - this slice is DAG topology/execution-plan shape only.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// JNI entry point:
//   runAndroidDagPhase1DagMultinodeExecutionPlanSmoke -> jstring

#include <jni.h>

#include <cstdint>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/node.h"

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

constexpr const char* kProofBoundary =
    "diagnostic_only_engine_execution_plan_no_production_timeline_playback_"
    "no_product_editor_app_connectsapp_wiring_no_surfaceproducer_production_path";

// TU-local generic DAG node: configurable kind/type/ports so every lane
// below can build its own synthetic topology without a family of
// near-duplicate node classes. Local to this translation unit only.
class DiagPlanNode final : public Node {
public:
    DiagPlanNode(std::string id,
                NodeKind kind,
                NodeType type,
                std::vector<PortDescriptor> inputPorts,
                std::vector<PortDescriptor> outputPorts)
        : id_(std::move(id)), kind_(kind), type_(type),
          inputPorts_(std::move(inputPorts)), outputPorts_(std::move(outputPorts)) {}

    const std::string&                 id()          const override { return id_; }
    NodeKind                           kind()        const override { return kind_; }
    NodeType                           type()        const override { return type_; }
    const std::vector<PortDescriptor>& inputPorts()  const override { return inputPorts_; }
    const std::vector<PortDescriptor>& outputPorts() const override { return outputPorts_; }

private:
    std::string id_;
    NodeKind kind_;
    NodeType type_;
    std::vector<PortDescriptor> inputPorts_;
    std::vector<PortDescriptor> outputPorts_;
};

std::shared_ptr<Node> MakeNode(std::string id,
                               NodeKind kind,
                               NodeType type,
                               std::vector<PortDescriptor> inputPorts,
                               std::vector<PortDescriptor> outputPorts) {
    return std::make_shared<DiagPlanNode>(
        std::move(id), kind, type, std::move(inputPorts), std::move(outputPorts));
}

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

std::string RunExecutionPlanSmokeInternal() {
    bool deepChainOk = false;
    bool diamondReconvergeOk = false;
    bool multiSinkOrderOk = false;
    bool orphanCulledOk = false;
    bool missingInputFailClosedOk = false;
    bool staleGenerationOk = false;
    bool nSourceBindingsOk = false;
    bool proofBoundaryLaneOk = false;
    bool noActiveSinkFailClosedOk = false;
    bool cycleRejectionUnchangedOk = false;
    std::string failureReason;

    constexpr PortDataType kFrame = PortDataType::kVideoFrame;

    // ---- Lane 1: deep chain (>=4 levels), fully dependency ordered ----
    // source -> transform -> compositor -> overlay -> sink
    {
        Graph g;
        g.addNode(MakeNode("l1_source", NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
        g.addNode(MakeNode("l1_transform", NodeKind::kProcessing, NodeType::kSpatialTransform, {{"in", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l1_compositor", NodeKind::kProcessing, NodeType::kMultiCamCompositor, {{"in", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l1_overlay", NodeKind::kProcessing, NodeType::kGraphicOverlayCompositor, {{"in", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l1_sink", NodeKind::kSink, NodeType::kPreviewSurfaceSink, {{"in", kFrame}}, {}));

        const bool wired =
            g.connect("l1_source", "out", "l1_transform", "in").ok() &&
            g.connect("l1_transform", "out", "l1_compositor", "in").ok() &&
            g.connect("l1_compositor", "out", "l1_overlay", "in").ok() &&
            g.connect("l1_overlay", "out", "l1_sink", "in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const int idxSource     = PlanIndexOf(plan, "l1_source");
        const int idxTransform  = PlanIndexOf(plan, "l1_transform");
        const int idxCompositor = PlanIndexOf(plan, "l1_compositor");
        const int idxOverlay    = PlanIndexOf(plan, "l1_overlay");
        const int idxSink       = PlanIndexOf(plan, "l1_sink");
        const auto* transformNode = PlanFind(plan, "l1_transform");
        const auto* sinkNode      = PlanFind(plan, "l1_sink");

        deepChainOk = wired && status.ok() && plan.nodes.size() == 5 &&
            idxSource == 0 && idxTransform == 1 && idxCompositor == 2 &&
            idxOverlay == 3 && idxSink == 4 &&
            plan.nodes[0].executionIndex == 0 && plan.nodes[4].executionIndex == 4 &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "l1_sink" &&
            transformNode != nullptr && transformNode->inputs.size() == 1 &&
            transformNode->inputs[0].fromNodeId == "l1_source" &&
            sinkNode != nullptr && sinkNode->inputs.size() == 1 &&
            sinkNode->inputs[0].fromNodeId == "l1_overlay";

        if (!deepChainOk && failureReason.empty()) failureReason = "deep_chain_failed";
    }

    // ---- Lane 2: diamond fan-out with reconvergence ----
    // source -> branchA -> compositor.inA
    // source -> branchB -> compositor.inB
    // compositor -> sink
    {
        Graph g;
        g.addNode(MakeNode("l2_source", NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
        g.addNode(MakeNode("l2_branch_a", NodeKind::kProcessing, NodeType::kFilter, {{"in", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l2_branch_b", NodeKind::kProcessing, NodeType::kFilter, {{"in", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l2_compositor", NodeKind::kProcessing, NodeType::kMultiCamCompositor,
                           {{"inA", kFrame}, {"inB", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l2_sink", NodeKind::kSink, NodeType::kPreviewSurfaceSink, {{"in", kFrame}}, {}));

        const bool wired =
            g.connect("l2_source", "out", "l2_branch_a", "in").ok() &&
            g.connect("l2_source", "out", "l2_branch_b", "in").ok() &&
            g.connect("l2_branch_a", "out", "l2_compositor", "inA").ok() &&
            g.connect("l2_branch_b", "out", "l2_compositor", "inB").ok() &&
            g.connect("l2_compositor", "out", "l2_sink", "in").ok();

        FrameRequest req;
        req.generationId = g.generationId();

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const int idxSource     = PlanIndexOf(plan, "l2_source");
        const int idxA          = PlanIndexOf(plan, "l2_branch_a");
        const int idxB          = PlanIndexOf(plan, "l2_branch_b");
        const int idxCompositor = PlanIndexOf(plan, "l2_compositor");
        const int idxSink       = PlanIndexOf(plan, "l2_sink");
        const auto* compositorNode = PlanFind(plan, "l2_compositor");

        bool bindingsOk = false;
        if (compositorNode != nullptr && compositorNode->inputs.size() == 2) {
            bool foundA = false, foundB = false;
            for (const auto& in : compositorNode->inputs) {
                if (in.inputPortId == "inA" && in.fromNodeId == "l2_branch_a") foundA = true;
                if (in.inputPortId == "inB" && in.fromNodeId == "l2_branch_b") foundB = true;
            }
            bindingsOk = foundA && foundB;
        }

        diamondReconvergeOk = wired && status.ok() && plan.nodes.size() == 5 &&
            idxSource == 0 && idxA >= 0 && idxB >= 0 && idxA != idxB &&
            idxSource < idxA && idxSource < idxB &&
            idxA < idxCompositor && idxB < idxCompositor &&
            idxCompositor < idxSink && bindingsOk &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "l2_sink";

        if (!diamondReconvergeOk && failureReason.empty()) failureReason = "diamond_reconverge_failed";
    }

    // ---- Lane 3: multi-sink deterministic ordering from one shared branch ----
    // source -> processing -> sinkA
    //                       -> sinkB
    {
        Graph g;
        g.addNode(MakeNode("l3_source", NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
        g.addNode(MakeNode("l3_processing", NodeKind::kProcessing, NodeType::kFilter, {{"in", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l3_sink_a", NodeKind::kSink, NodeType::kPreviewSurfaceSink, {{"in", kFrame}}, {}));
        g.addNode(MakeNode("l3_sink_b", NodeKind::kSink, NodeType::kOfflineMediaMuxerSink, {{"in", kFrame}}, {}));

        const bool wired =
            g.connect("l3_source", "out", "l3_processing", "in").ok() &&
            g.connect("l3_processing", "out", "l3_sink_a", "in").ok() &&
            g.connect("l3_processing", "out", "l3_sink_b", "in").ok();

        FrameRequest req;
        req.generationId = g.generationId();

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        multiSinkOrderOk = wired && status.ok() && plan.nodes.size() == 4 &&
            plan.sinkNodeIds.size() == 2 &&
            plan.sinkNodeIds[0] == "l3_sink_a" && plan.sinkNodeIds[1] == "l3_sink_b" &&
            PlanIndexOf(plan, "l3_processing") < PlanIndexOf(plan, "l3_sink_a") &&
            PlanIndexOf(plan, "l3_processing") < PlanIndexOf(plan, "l3_sink_b");

        if (!multiSinkOrderOk && failureReason.empty()) failureReason = "multi_sink_order_failed";
    }

    // ---- Lane 4: unreachable active orphan branch is culled, not a failure ----
    {
        Graph g;
        g.addNode(MakeNode("l4_source", NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
        g.addNode(MakeNode("l4_processing", NodeKind::kProcessing, NodeType::kFilter, {{"in", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l4_sink", NodeKind::kSink, NodeType::kPreviewSurfaceSink, {{"in", kFrame}}, {}));
        g.addNode(MakeNode("l4_orphan_source", NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
        g.addNode(MakeNode("l4_orphan_processing", NodeKind::kProcessing, NodeType::kFilter, {{"in", kFrame}}, {{"out", kFrame}}));

        const bool wired =
            g.connect("l4_source", "out", "l4_processing", "in").ok() &&
            g.connect("l4_processing", "out", "l4_sink", "in").ok() &&
            g.connect("l4_orphan_source", "out", "l4_orphan_processing", "in").ok();

        FrameRequest req;
        req.generationId = g.generationId();

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        orphanCulledOk = wired && status.ok() && plan.nodes.size() == 3 &&
            PlanHasNode(plan, "l4_source") && PlanHasNode(plan, "l4_processing") &&
            PlanHasNode(plan, "l4_sink") &&
            !PlanHasNode(plan, "l4_orphan_source") &&
            !PlanHasNode(plan, "l4_orphan_processing");

        if (!orphanCulledOk && failureReason.empty()) failureReason = "orphan_cull_failed";
    }

    // ---- Lane 5: reachable processing node with an unconnected required
    //      input port fails closed ----
    {
        Graph g;
        g.addNode(MakeNode("l5_source", NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
        g.addNode(MakeNode("l5_processing", NodeKind::kProcessing, NodeType::kMultiCamCompositor,
                           {{"primary", kFrame}, {"secondary", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l5_sink", NodeKind::kSink, NodeType::kPreviewSurfaceSink, {{"in", kFrame}}, {}));

        // l5_processing.secondary is deliberately left unconnected.
        const bool wired =
            g.connect("l5_source", "out", "l5_processing", "primary").ok() &&
            g.connect("l5_processing", "out", "l5_sink", "in").ok();

        FrameRequest req;
        req.generationId = g.generationId();

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        missingInputFailClosedOk = wired && !status.ok() && plan.nodes.empty() &&
            status.message().find("secondary") != std::string::npos &&
            status.message().find("l5_processing") != std::string::npos;

        if (!missingInputFailClosedOk && failureReason.empty()) failureReason = "missing_input_fail_closed_failed";
    }

    // ---- Lane 6: stale generation precedence unchanged ----
    {
        Graph g;
        g.addNode(MakeNode("l6_source", NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
        g.addNode(MakeNode("l6_sink", NodeKind::kSink, NodeType::kPreviewSurfaceSink, {{"in", kFrame}}, {}));
        const bool wired = g.connect("l6_source", "out", "l6_sink", "in").ok();

        FrameRequest staleReq;
        staleReq.generationId = g.generationId() - 1; // stale on purpose

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, staleReq, plan);

        staleGenerationOk = wired && !status.ok() && plan.nodes.empty() &&
            status.message().find("stale") != std::string::npos;

        if (!staleGenerationOk && failureReason.empty()) failureReason = "stale_generation_failed";
    }

    // ---- Lane 7: N>=3 sources feeding one processing node are represented as
    //      input bindings from plan data, not hardcoded topology ----
    {
        constexpr int kSourceCount = 5;
        Graph g;

        std::vector<PortDescriptor> processingInputs;
        for (int i = 0; i < kSourceCount; ++i) {
            processingInputs.push_back({"in" + std::to_string(i), kFrame});
        }
        g.addNode(MakeNode("l7_processing", NodeKind::kProcessing, NodeType::kFilter,
                           processingInputs, {{"out", kFrame}}));
        g.addNode(MakeNode("l7_sink", NodeKind::kSink, NodeType::kPreviewSurfaceSink, {{"in", kFrame}}, {}));

        bool wired = g.connect("l7_processing", "out", "l7_sink", "in").ok();
        std::unordered_map<std::string, std::string> expectedFromNodeByPort; // portId -> sourceNodeId
        for (int i = 0; i < kSourceCount; ++i) {
            const std::string sourceId = "l7_source_" + std::to_string(i);
            const std::string portId = "in" + std::to_string(i);
            g.addNode(MakeNode(sourceId, NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
            wired = wired && g.connect(sourceId, "out", "l7_processing", portId).ok();
            expectedFromNodeByPort[portId] = sourceId;
        }

        FrameRequest req;
        req.generationId = g.generationId();

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        const auto* processingNode = PlanFind(plan, "l7_processing");
        bool bindingsMatch = processingNode != nullptr &&
            processingNode->inputs.size() == static_cast<size_t>(kSourceCount);
        if (bindingsMatch) {
            std::unordered_map<std::string, std::string> actualFromNodeByPort;
            for (const auto& binding : processingNode->inputs) {
                actualFromNodeByPort[binding.inputPortId] = binding.fromNodeId;
            }
            bindingsMatch = actualFromNodeByPort == expectedFromNodeByPort;
        }

        nSourceBindingsOk = wired && status.ok() &&
            plan.nodes.size() == static_cast<size_t>(kSourceCount + 2) &&
            bindingsMatch;

        if (!nSourceBindingsOk && failureReason.empty()) failureReason = "n_source_bindings_failed";
    }

    // ---- Lane 8: production non-claim / proof-boundary lane ----
    {
        const std::string boundary(kProofBoundary);
        proofBoundaryLaneOk =
            boundary.find("diagnostic_only") != std::string::npos &&
            boundary.find("no_production_timeline_playback") != std::string::npos &&
            boundary.find("no_product_editor_app_connectsapp_wiring") != std::string::npos &&
            boundary.find("no_surfaceproducer_production_path") != std::string::npos;

        if (!proofBoundaryLaneOk && failureReason.empty()) failureReason = "proof_boundary_lane_failed";
    }

    // ---- Lane 9: active graph with no sink at all fails closed with the
    //      planner's "no active sink" error and leaves plan empty ----
    {
        Graph g;
        g.addNode(MakeNode("l9_source", NodeKind::kSource, NodeType::kHardwareBufferSource, {}, {{"out", kFrame}}));
        g.addNode(MakeNode("l9_processing", NodeKind::kProcessing, NodeType::kFilter, {{"in", kFrame}}, {{"out", kFrame}}));

        // No sink node is added at all; both nodes above are active (the
        // default Node::isActiveAt() always returns true) but there is no
        // kSink-kind node anywhere in the graph.
        const bool wired = g.connect("l9_source", "out", "l9_processing", "in").ok();

        FrameRequest req;
        req.generationId = g.generationId();

        GraphExecutionPlan plan;
        const auto status = BuildGraphExecutionPlan(g, req, plan);

        noActiveSinkFailClosedOk = wired && !status.ok() && plan.nodes.empty() &&
            plan.sinkNodeIds.empty() &&
            status.message().find("no active sink") != std::string::npos;

        if (!noActiveSinkFailClosedOk && failureReason.empty()) failureReason = "no_active_sink_fail_closed_failed";
    }

    // ---- Lane 10: Graph's existing cycle rejection is unchanged; a rejected
    //      back-edge attempt does not affect a valid acyclic
    //      BuildGraphExecutionPlan result ----
    {
        Graph g;
        g.addNode(MakeNode("l10_source", NodeKind::kSource, NodeType::kHardwareBufferSource,
                           {{"loop_in", kFrame}}, {{"out", kFrame}}));
        g.addNode(MakeNode("l10_mid", NodeKind::kProcessing, NodeType::kFilter,
                           {{"in", kFrame}}, {{"out", kFrame}, {"loop_out", kFrame}}));
        g.addNode(MakeNode("l10_sink", NodeKind::kSink, NodeType::kPreviewSurfaceSink, {{"in", kFrame}}, {}));

        const bool wired =
            g.connect("l10_source", "out", "l10_mid", "in").ok() &&
            g.connect("l10_mid", "out", "l10_sink", "in").ok();

        // Back-edge that would close a cycle (l10_source -> l10_mid ->
        // l10_source via the loop ports); Graph::connect() must reject it and
        // leave the graph's edges unchanged.
        const auto backEdgeStatus = g.connect("l10_mid", "loop_out", "l10_source", "loop_in");

        FrameRequest req;
        req.generationId = g.generationId();

        GraphExecutionPlan plan;
        const auto planStatus = BuildGraphExecutionPlan(g, req, plan);

        cycleRejectionUnchangedOk = wired &&
            !backEdgeStatus.ok() &&
            backEdgeStatus.message().find("cycle") != std::string::npos &&
            planStatus.ok() && plan.nodes.size() == 3 &&
            plan.sinkNodeIds.size() == 1 && plan.sinkNodeIds[0] == "l10_sink" &&
            PlanIndexOf(plan, "l10_source") < PlanIndexOf(plan, "l10_mid") &&
            PlanIndexOf(plan, "l10_mid") < PlanIndexOf(plan, "l10_sink");

        if (!cycleRejectionUnchangedOk && failureReason.empty()) failureReason = "cycle_rejection_unchanged_failed";
    }

    constexpr int kTotalLanes = 10;
    const int passedLanes =
        (deepChainOk ? 1 : 0) + (diamondReconvergeOk ? 1 : 0) + (multiSinkOrderOk ? 1 : 0) +
        (orphanCulledOk ? 1 : 0) + (missingInputFailClosedOk ? 1 : 0) + (staleGenerationOk ? 1 : 0) +
        (nSourceBindingsOk ? 1 : 0) + (proofBoundaryLaneOk ? 1 : 0) +
        (noActiveSinkFailClosedOk ? 1 : 0) + (cycleRejectionUnchangedOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=deepChain:" << (deepChainOk ? "true" : "false")
        << ",diamondReconverge:" << (diamondReconvergeOk ? "true" : "false")
        << ",multiSinkOrder:" << (multiSinkOrderOk ? "true" : "false")
        << ",orphanCulled:" << (orphanCulledOk ? "true" : "false")
        << ",missingInputFailClosed:" << (missingInputFailClosedOk ? "true" : "false")
        << ",staleGeneration:" << (staleGenerationOk ? "true" : "false")
        << ",nSourceBindings:" << (nSourceBindingsOk ? "true" : "false")
        << ",proofBoundaryLane:" << (proofBoundaryLaneOk ? "true" : "false")
        << ",noActiveSinkFailClosed:" << (noActiveSinkFailClosedOk ? "true" : "false")
        << ",cycleRejectionUnchanged:" << (cycleRejectionUnchangedOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1DagMultinodeExecutionPlanSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunExecutionPlanSmokeInternal();
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
