// P1-DAG-MULTINODE-EXECUTION-DISPATCHER: bounded platform-neutral graph-layer
// execution dispatcher diagnostic proof.
//
// Diagnostic-only: proves vanguard::graph::GraphExecutionDispatcher over a
// real four-node topology built entirely from concrete, platform-neutral
// production node classes - two vanguard::sources::HardwareBufferSourceNode
// instances feeding a vanguard::compositors::MultiCamCompositorNode's
// "primary_video_in"/"secondary_video_in" ports, whose
// "composited_video_out" output feeds a
// vanguard::sinks::PreviewSurfaceSinkNode's "video_in" port, planned via
// vanguard::graph::BuildGraphExecutionPlan(). One lane (nonGpuBindingsSkipped)
// additionally uses a small TU-local Node subclass to exercise a mixed
// GPU/non-GPU input-binding shape that the production node classes above do
// not expose. GraphExecutionDispatcher never calls Node::execute - Node
// remains topology/timeline-only - and owns no OS/GPU resource: this slice
// only proves per-node GPU-input resolution/output-publish sequencing, not
// rendering or GPU/pixel transport.
//
// Non-claims: no Node::execute, no OS resource ownership, no rendering, no
// GPU/pixel/handle transport, no product/editor/app/ConnectsApp wiring.
//
// This translation unit is Android-only and must NOT be included in iOS or
// host builds. It is added via the Android-only target_sources block in
// src/CMakeLists.txt.
//
// Lane list (exactly 10):
//   1.  emptyPlanRejected             - dispatch() over a default-
//                                        constructed (empty) plan fails
//                                        closed, invokes no callback, and
//                                        leaves outResult default.
//   2.  staleSessionRejected          - dispatch() over a valid plan but a
//                                        session whose evaluatedPtsUs does
//                                        not match fails closed, invokes no
//                                        callback, and leaves outResult
//                                        default.
//   3.  executionIndexRejected        - dispatch() over a plan whose first
//                                        node's executionIndex no longer
//                                        matches its position fails closed
//                                        before any callback runs.
//   4.  sourceCallbacksPublished      - both source nodes' callbacks run
//                                        exactly once and their output
//                                        tokens are published and resolvable
//                                        from the session afterwards.
//   5.  compositorInputsResolved      - the compositor's callback receives
//                                        exactly its two resolved
//                                        primary/secondary GPU inputs,
//                                        matching the published source
//                                        tokens.
//   6.  compositorOutputPublished     - the compositor's own returned output
//                                        token publishes cleanly and is
//                                        resolvable from the session.
//   7.  sinkInputResolvedNoOutput     - the sink's callback receives exactly
//                                        one resolved input (the compositor
//                                        output) and returns zero outputs;
//                                        the overall dispatch still
//                                        succeeds.
//   8.  callbackFailureStopsBeforePublish - a compositor callback that
//                                        returns a non-ok Status stops
//                                        dispatch before its own output
//                                        publishes, while the two source
//                                        nodes' earlier publishes remain in
//                                        the session (no rollback).
//   9.  undeclaredOutputRejected      - a compositor callback that returns
//                                        an output token naming a port not
//                                        declared on that node fails closed
//                                        and that token is never published.
//   10. nonGpuBindingsSkipped         - a processing node with one
//                                        kVideoFrame and one kMetadata input
//                                        binding receives only the
//                                        kVideoFrame binding in
//                                        resolvedInputs; the kMetadata
//                                        binding is skipped without failure.
//
// JNI entry point:
//   runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke -> jstring

#include <jni.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "vanguard/compositors/multi_cam_compositor_node.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/graph_execution_dispatcher.h"
#include "vanguard/graph/graph_execution_plan.h"
#include "vanguard/graph/gpu_frame_token.h"
#include "vanguard/graph/node.h"
#include "vanguard/sinks/preview_surface_sink_node.h"
#include "vanguard/sources/hardware_buffer_source_node.h"

namespace {

using vanguard::core::Status;
using vanguard::core::StatusCode;
using vanguard::graph::BuildGraphExecutionPlan;
using vanguard::graph::ExecutionInputBinding;
using vanguard::graph::ExecutionPlanNode;
using vanguard::graph::FrameRequest;
using vanguard::graph::Graph;
using vanguard::graph::GraphExecutionDispatcher;
using vanguard::graph::GraphExecutionDispatchResult;
using vanguard::graph::GraphExecutionNodeCallback;
using vanguard::graph::GraphExecutionPlan;
using vanguard::graph::GpuFrameDescriptor;
using vanguard::graph::GpuFrameToken;
using vanguard::graph::GpuFrameTokenSession;
using vanguard::graph::Node;
using vanguard::graph::NodeKind;
using vanguard::graph::NodeType;
using vanguard::graph::PortDataType;
using vanguard::graph::PortDescriptor;
using vanguard::graph::ResolvedGpuFrameInput;
using vanguard::compositors::MultiCamCompositorNode;
using vanguard::sinks::PreviewSurfaceSinkNode;
using vanguard::sources::HardwareBufferSourceNode;

constexpr const char* kProofBoundary =
    "platform_neutral_dag_execution_dispatcher_diagnostic_only_no_node_execute_no_os_resource_"
    "ownership_no_render_no_gpu_transport_no_product_app_editor_wiring";

// Builds the shared real four-node topology (two HardwareBufferSourceNode
// instances -> MultiCamCompositorNode -> PreviewSurfaceSinkNode) under
// caller-supplied node-id `prefix`, and resolves it via
// BuildGraphExecutionPlan(). The Graph itself is not retained: a resolved
// GraphExecutionPlan holds no reference back to it.
struct DispatchTopology {
    GraphExecutionPlan plan;
    bool               ok{false};
};

DispatchTopology BuildDispatchTopology(const std::string& prefix) {
    DispatchTopology topo;

    Graph g;
    auto primary = std::make_shared<HardwareBufferSourceNode>(prefix + "_primary_source", 0, 5000);
    auto secondary = std::make_shared<HardwareBufferSourceNode>(prefix + "_secondary_source", 0, 5000);
    auto compositor = std::make_shared<MultiCamCompositorNode>(prefix + "_compositor");
    auto sink = std::make_shared<PreviewSurfaceSinkNode>(prefix + "_sink");

    const bool added =
        g.addNode(primary).ok() && g.addNode(secondary).ok() &&
        g.addNode(compositor).ok() && g.addNode(sink).ok();

    const bool wired = added &&
        g.connect(prefix + "_primary_source", "kVideoFrame", prefix + "_compositor", "primary_video_in").ok() &&
        g.connect(prefix + "_secondary_source", "kVideoFrame", prefix + "_compositor", "secondary_video_in").ok() &&
        g.connect(prefix + "_compositor", "composited_video_out", prefix + "_sink", "video_in").ok();

    FrameRequest req;
    req.generationId = g.generationId();
    req.timelinePtsUs = 0;

    const auto status = BuildGraphExecutionPlan(g, req, topo.plan);
    topo.ok = wired && status.ok() && topo.plan.nodes.size() == 4;
    return topo;
}

GpuFrameToken MakeVideoToken(uint64_t handle,
                            const std::string& producingNodeId,
                            const std::string& outputPortId,
                            const GraphExecutionPlan& plan) {
    GpuFrameToken token;
    token.handle = handle;
    token.descriptor = GpuFrameDescriptor{640, 480, 1, 1, 640, 0};
    token.producingNodeId = producingNodeId;
    token.outputPortId = outputPortId;
    token.evaluatedPtsUs = plan.evaluatedPtsUs;
    token.evaluatedGeneration = plan.evaluatedGeneration;
    return token;
}

// TU-local generic DAG node used only by the nonGpuBindingsSkipped lane,
// which needs a node with a mixed GPU/non-GPU input-binding shape that none
// of the real production node classes above expose.
class DispatcherDiagNode final : public Node {
public:
    DispatcherDiagNode(std::string id,
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
    std::string                 id_;
    NodeKind                    kind_;
    NodeType                    type_;
    std::vector<PortDescriptor> inputPorts_;
    std::vector<PortDescriptor> outputPorts_;
};

std::string RunExecutionDispatcherSmokeInternal() {
    bool emptyPlanRejectedOk = false;
    bool staleSessionRejectedOk = false;
    bool executionIndexRejectedOk = false;
    bool sourceCallbacksPublishedOk = false;
    bool compositorInputsResolvedOk = false;
    bool compositorOutputPublishedOk = false;
    bool sinkInputResolvedNoOutputOk = false;
    bool callbackFailureStopsBeforePublishOk = false;
    bool undeclaredOutputRejectedOk = false;
    bool nonGpuBindingsSkippedOk = false;
    std::string failureReason;

    const DispatchTopology mainTopo = BuildDispatchTopology("disp_main");
    const bool topologyReady = mainTopo.ok;

    // ---- Lane 1: dispatch() over an empty plan fails closed, invokes no
    //      callback, and leaves outResult default ----
    {
        GraphExecutionPlan emptyPlan;
        GpuFrameTokenSession session(0, 0);
        GraphExecutionDispatcher dispatcher;
        GraphExecutionDispatchResult result;
        bool callbackInvoked = false;
        GraphExecutionNodeCallback callback =
            [&](const ExecutionPlanNode&, const std::vector<ResolvedGpuFrameInput>&,
                std::vector<GpuFrameToken>&) -> Status {
            callbackInvoked = true;
            return Status::OK();
        };

        const auto status = dispatcher.dispatch(emptyPlan, session, callback, result);

        emptyPlanRejectedOk = !status.ok() && !callbackInvoked &&
            result.nodesDispatched == 0 && result.outputsPublished == 0;
        if (!emptyPlanRejectedOk && failureReason.empty()) failureReason = "empty_plan_rejected_failed";
    }

    // ---- Lane 2: dispatch() over a valid plan but a stale session fails
    //      closed, invokes no callback, and leaves outResult default ----
    if (topologyReady) {
        GpuFrameTokenSession staleSession(mainTopo.plan.evaluatedPtsUs + 1,
                                          mainTopo.plan.evaluatedGeneration);
        GraphExecutionDispatcher dispatcher;
        GraphExecutionDispatchResult result;
        bool callbackInvoked = false;
        GraphExecutionNodeCallback callback =
            [&](const ExecutionPlanNode&, const std::vector<ResolvedGpuFrameInput>&,
                std::vector<GpuFrameToken>&) -> Status {
            callbackInvoked = true;
            return Status::OK();
        };

        const auto status = dispatcher.dispatch(mainTopo.plan, staleSession, callback, result);

        staleSessionRejectedOk = !status.ok() && !callbackInvoked &&
            result.nodesDispatched == 0 && result.outputsPublished == 0;
        if (!staleSessionRejectedOk && failureReason.empty()) failureReason = "stale_session_rejected_failed";
    } else if (failureReason.empty()) {
        failureReason = "stale_session_rejected_skipped_prereq";
    }

    // ---- Lane 3: a plan whose executionIndex no longer matches its
    //      position fails closed before any callback runs ----
    if (topologyReady) {
        GraphExecutionPlan corrupted = mainTopo.plan;
        if (!corrupted.nodes.empty()) {
            corrupted.nodes[0].executionIndex = 99;
        }
        GpuFrameTokenSession session(corrupted.evaluatedPtsUs, corrupted.evaluatedGeneration);
        GraphExecutionDispatcher dispatcher;
        GraphExecutionDispatchResult result;
        bool callbackInvoked = false;
        GraphExecutionNodeCallback callback =
            [&](const ExecutionPlanNode&, const std::vector<ResolvedGpuFrameInput>&,
                std::vector<GpuFrameToken>&) -> Status {
            callbackInvoked = true;
            return Status::OK();
        };

        const auto status = dispatcher.dispatch(corrupted, session, callback, result);

        executionIndexRejectedOk = !status.ok() && !callbackInvoked &&
            result.nodesDispatched == 0 && result.outputsPublished == 0;
        if (!executionIndexRejectedOk && failureReason.empty()) failureReason = "execution_index_rejected_failed";
    } else if (failureReason.empty()) {
        failureReason = "execution_index_rejected_skipped_prereq";
    }

    // ---- Lanes 4-7: one full successful dispatch over the shared real
    //      four-node topology ----
    if (topologyReady) {
        GpuFrameTokenSession session(mainTopo.plan.evaluatedPtsUs, mainTopo.plan.evaluatedGeneration);
        GraphExecutionDispatcher dispatcher;

        int primaryCallbackCount = 0;
        int secondaryCallbackCount = 0;
        size_t compositorResolvedInputsCount = 0;
        bool compositorResolvedPrimaryOk = false;
        bool compositorResolvedSecondaryOk = false;
        size_t sinkResolvedInputsCount = 0;
        bool sinkResolvedInputOk = false;
        bool sinkCallbackRan = false;

        GraphExecutionNodeCallback callback =
            [&](const ExecutionPlanNode& node, const std::vector<ResolvedGpuFrameInput>& resolvedInputs,
                std::vector<GpuFrameToken>& outOutputs) -> Status {
            if (node.nodeId == "disp_main_primary_source") {
                ++primaryCallbackCount;
                outOutputs.push_back(MakeVideoToken(301, node.nodeId, "kVideoFrame", mainTopo.plan));
                return Status::OK();
            }
            if (node.nodeId == "disp_main_secondary_source") {
                ++secondaryCallbackCount;
                outOutputs.push_back(MakeVideoToken(302, node.nodeId, "kVideoFrame", mainTopo.plan));
                return Status::OK();
            }
            if (node.nodeId == "disp_main_compositor") {
                compositorResolvedInputsCount = resolvedInputs.size();
                for (const auto& in : resolvedInputs) {
                    if (in.binding.inputPortId == "primary_video_in" && in.token.handle == 301 &&
                        in.token.producingNodeId == "disp_main_primary_source") {
                        compositorResolvedPrimaryOk = true;
                    }
                    if (in.binding.inputPortId == "secondary_video_in" && in.token.handle == 302 &&
                        in.token.producingNodeId == "disp_main_secondary_source") {
                        compositorResolvedSecondaryOk = true;
                    }
                }
                outOutputs.push_back(
                    MakeVideoToken(401, node.nodeId, "composited_video_out", mainTopo.plan));
                return Status::OK();
            }
            if (node.nodeId == "disp_main_sink") {
                sinkCallbackRan = true;
                sinkResolvedInputsCount = resolvedInputs.size();
                sinkResolvedInputOk = resolvedInputs.size() == 1 &&
                    resolvedInputs[0].binding.inputPortId == "video_in" &&
                    resolvedInputs[0].token.handle == 401 &&
                    resolvedInputs[0].token.producingNodeId == "disp_main_compositor";
                return Status::OK();
            }
            return Status(StatusCode::kError, "unexpected_node_" + node.nodeId);
        };

        GraphExecutionDispatchResult result;
        const auto status = dispatcher.dispatch(mainTopo.plan, session, callback, result);

        ExecutionInputBinding primaryProbe;
        primaryProbe.inputPortId = "probe_in";
        primaryProbe.fromNodeId = "disp_main_primary_source";
        primaryProbe.fromPortId = "kVideoFrame";
        GpuFrameToken resolvedPrimary;
        const bool primaryResolvable = session.resolve(primaryProbe, resolvedPrimary).ok() &&
            resolvedPrimary.handle == 301;

        ExecutionInputBinding secondaryProbe;
        secondaryProbe.inputPortId = "probe_in";
        secondaryProbe.fromNodeId = "disp_main_secondary_source";
        secondaryProbe.fromPortId = "kVideoFrame";
        GpuFrameToken resolvedSecondary;
        const bool secondaryResolvable = session.resolve(secondaryProbe, resolvedSecondary).ok() &&
            resolvedSecondary.handle == 302;

        ExecutionInputBinding compositorProbe;
        compositorProbe.inputPortId = "probe_in";
        compositorProbe.fromNodeId = "disp_main_compositor";
        compositorProbe.fromPortId = "composited_video_out";
        GpuFrameToken resolvedCompositorOutput;
        const bool compositorOutputResolvable =
            session.resolve(compositorProbe, resolvedCompositorOutput).ok() &&
            resolvedCompositorOutput.handle == 401;

        sourceCallbacksPublishedOk = status.ok() &&
            primaryCallbackCount == 1 && secondaryCallbackCount == 1 &&
            primaryResolvable && secondaryResolvable;
        if (!sourceCallbacksPublishedOk && failureReason.empty()) {
            failureReason = "source_callbacks_published_failed";
        }

        compositorInputsResolvedOk = status.ok() &&
            compositorResolvedInputsCount == 2 &&
            compositorResolvedPrimaryOk && compositorResolvedSecondaryOk;
        if (!compositorInputsResolvedOk && failureReason.empty()) {
            failureReason = "compositor_inputs_resolved_failed";
        }

        compositorOutputPublishedOk = status.ok() && compositorOutputResolvable &&
            result.outputsPublished == 3;
        if (!compositorOutputPublishedOk && failureReason.empty()) {
            failureReason = "compositor_output_published_failed";
        }

        sinkInputResolvedNoOutputOk = status.ok() && sinkCallbackRan &&
            sinkResolvedInputsCount == 1 && sinkResolvedInputOk &&
            result.nodesDispatched == 4;
        if (!sinkInputResolvedNoOutputOk && failureReason.empty()) {
            failureReason = "sink_input_resolved_no_output_failed";
        }
    } else if (failureReason.empty()) {
        failureReason = "source_callbacks_published_skipped_prereq";
    }

    // ---- Lane 8: a compositor callback failure stops dispatch before its
    //      own output publishes, while the two sources' earlier publishes
    //      remain in the session (no rollback) ----
    {
        const DispatchTopology topo8 = BuildDispatchTopology("disp8");
        if (topo8.ok) {
            GpuFrameTokenSession session(topo8.plan.evaluatedPtsUs, topo8.plan.evaluatedGeneration);
            GraphExecutionDispatcher dispatcher;

            GraphExecutionNodeCallback callback =
                [&](const ExecutionPlanNode& node, const std::vector<ResolvedGpuFrameInput>&,
                    std::vector<GpuFrameToken>& outOutputs) -> Status {
                if (node.nodeKind == NodeKind::kSource) {
                    const uint64_t handle = (node.nodeId == "disp8_primary_source") ? 501 : 502;
                    outOutputs.push_back(MakeVideoToken(handle, node.nodeId, "kVideoFrame", topo8.plan));
                    return Status::OK();
                }
                if (node.nodeId == "disp8_compositor") {
                    outOutputs.push_back(
                        MakeVideoToken(601, node.nodeId, "composited_video_out", topo8.plan));
                    return Status(StatusCode::kError, "deliberate_compositor_callback_failure");
                }
                return Status(StatusCode::kError, "unexpected_sink_callback_invocation");
            };

            GraphExecutionDispatchResult result;
            const auto status = dispatcher.dispatch(topo8.plan, session, callback, result);

            ExecutionInputBinding compositorProbe;
            compositorProbe.inputPortId = "probe_in";
            compositorProbe.fromNodeId = "disp8_compositor";
            compositorProbe.fromPortId = "composited_video_out";
            GpuFrameToken resolvedCompositorOutput;
            const bool compositorOutputNotPublished =
                !session.resolve(compositorProbe, resolvedCompositorOutput).ok();

            callbackFailureStopsBeforePublishOk = !status.ok() &&
                status.message().find("deliberate_compositor_callback_failure") != std::string::npos &&
                result.nodesDispatched == 0 && result.outputsPublished == 0 &&
                session.publishedCount() == 2 && compositorOutputNotPublished;
            if (!callbackFailureStopsBeforePublishOk && failureReason.empty()) {
                failureReason = "callback_failure_stops_before_publish_failed";
            }
        } else if (failureReason.empty()) {
            failureReason = "callback_failure_stops_before_publish_skipped_prereq";
        }
    }

    // ---- Lane 9: an output token naming an undeclared port fails closed
    //      and is never published ----
    {
        const DispatchTopology topo9 = BuildDispatchTopology("disp9");
        if (topo9.ok) {
            GpuFrameTokenSession session(topo9.plan.evaluatedPtsUs, topo9.plan.evaluatedGeneration);
            GraphExecutionDispatcher dispatcher;

            GraphExecutionNodeCallback callback =
                [&](const ExecutionPlanNode& node, const std::vector<ResolvedGpuFrameInput>&,
                    std::vector<GpuFrameToken>& outOutputs) -> Status {
                if (node.nodeKind == NodeKind::kSource) {
                    const uint64_t handle = (node.nodeId == "disp9_primary_source") ? 701 : 702;
                    outOutputs.push_back(MakeVideoToken(handle, node.nodeId, "kVideoFrame", topo9.plan));
                    return Status::OK();
                }
                if (node.nodeId == "disp9_compositor") {
                    outOutputs.push_back(
                        MakeVideoToken(801, node.nodeId, "not_a_declared_port", topo9.plan));
                    return Status::OK();
                }
                return Status(StatusCode::kError, "unexpected_sink_callback_invocation");
            };

            GraphExecutionDispatchResult result;
            const auto status = dispatcher.dispatch(topo9.plan, session, callback, result);

            undeclaredOutputRejectedOk = !status.ok() &&
                status.message().find("not_a_declared_port") != std::string::npos &&
                result.nodesDispatched == 0 && result.outputsPublished == 0 &&
                session.publishedCount() == 2;
            if (!undeclaredOutputRejectedOk && failureReason.empty()) {
                failureReason = "undeclared_output_rejected_failed";
            }
        } else if (failureReason.empty()) {
            failureReason = "undeclared_output_rejected_skipped_prereq";
        }
    }

    // ---- Lane 10: a processing node's non-GPU-bearing (kMetadata) input
    //      binding is skipped without failure; only its kVideoFrame binding
    //      appears in resolvedInputs ----
    {
        Graph g;
        g.addNode(std::make_shared<DispatcherDiagNode>(
            "disp10_video_source", NodeKind::kSource, NodeType::kHardwareBufferSource,
            std::vector<PortDescriptor>{},
            std::vector<PortDescriptor>{{"video_out", PortDataType::kVideoFrame}}));
        g.addNode(std::make_shared<DispatcherDiagNode>(
            "disp10_meta_source", NodeKind::kSource, NodeType::kCustom,
            std::vector<PortDescriptor>{},
            std::vector<PortDescriptor>{{"meta_out", PortDataType::kMetadata}}));
        g.addNode(std::make_shared<DispatcherDiagNode>(
            "disp10_processing", NodeKind::kProcessing, NodeType::kFilter,
            std::vector<PortDescriptor>{{"video_in", PortDataType::kVideoFrame},
                                        {"meta_in", PortDataType::kMetadata}},
            std::vector<PortDescriptor>{{"video_out", PortDataType::kVideoFrame}}));
        g.addNode(std::make_shared<DispatcherDiagNode>(
            "disp10_sink", NodeKind::kSink, NodeType::kPreviewSurfaceSink,
            std::vector<PortDescriptor>{{"video_in", PortDataType::kVideoFrame}},
            std::vector<PortDescriptor>{}));

        const bool wired =
            g.connect("disp10_video_source", "video_out", "disp10_processing", "video_in").ok() &&
            g.connect("disp10_meta_source", "meta_out", "disp10_processing", "meta_in").ok() &&
            g.connect("disp10_processing", "video_out", "disp10_sink", "video_in").ok();

        FrameRequest req;
        req.generationId = g.generationId();
        req.timelinePtsUs = 0;

        GraphExecutionPlan plan10;
        const auto planStatus = BuildGraphExecutionPlan(g, req, plan10);

        if (wired && planStatus.ok() && plan10.nodes.size() == 4) {
            GpuFrameTokenSession session(plan10.evaluatedPtsUs, plan10.evaluatedGeneration);
            GraphExecutionDispatcher dispatcher;

            size_t processingResolvedInputsCount = 0;
            bool processingSawOnlyVideoBinding = false;

            GraphExecutionNodeCallback callback =
                [&](const ExecutionPlanNode& node, const std::vector<ResolvedGpuFrameInput>& resolvedInputs,
                    std::vector<GpuFrameToken>& outOutputs) -> Status {
                if (node.nodeId == "disp10_video_source") {
                    outOutputs.push_back(MakeVideoToken(901, node.nodeId, "video_out", plan10));
                    return Status::OK();
                }
                if (node.nodeId == "disp10_meta_source") {
                    return Status::OK();
                }
                if (node.nodeId == "disp10_processing") {
                    processingResolvedInputsCount = resolvedInputs.size();
                    processingSawOnlyVideoBinding = resolvedInputs.size() == 1 &&
                        resolvedInputs[0].binding.inputPortId == "video_in" &&
                        resolvedInputs[0].token.handle == 901;
                    outOutputs.push_back(MakeVideoToken(902, node.nodeId, "video_out", plan10));
                    return Status::OK();
                }
                return Status::OK();
            };

            GraphExecutionDispatchResult result;
            const auto status = dispatcher.dispatch(plan10, session, callback, result);

            nonGpuBindingsSkippedOk = status.ok() &&
                processingResolvedInputsCount == 1 && processingSawOnlyVideoBinding &&
                result.nodesDispatched == 4;
        }

        if (!nonGpuBindingsSkippedOk && failureReason.empty()) {
            failureReason = "non_gpu_bindings_skipped_failed";
        }
    }

    constexpr int kTotalLanes = 10;
    const int passedLanes =
        (emptyPlanRejectedOk ? 1 : 0) + (staleSessionRejectedOk ? 1 : 0) +
        (executionIndexRejectedOk ? 1 : 0) + (sourceCallbacksPublishedOk ? 1 : 0) +
        (compositorInputsResolvedOk ? 1 : 0) + (compositorOutputPublishedOk ? 1 : 0) +
        (sinkInputResolvedNoOutputOk ? 1 : 0) + (callbackFailureStopsBeforePublishOk ? 1 : 0) +
        (undeclaredOutputRejectedOk ? 1 : 0) + (nonGpuBindingsSkippedOk ? 1 : 0);
    const bool allPass = passedLanes == kTotalLanes;

    std::ostringstream oss;
    oss << "status=" << (allPass ? "PASS" : "FAIL") << ";"
        << "totalLanes=" << kTotalLanes << ";"
        << "passedLanes=" << passedLanes << ";"
        << "proofBoundary=" << kProofBoundary << ";"
        << "lanes=emptyPlanRejected:" << (emptyPlanRejectedOk ? "true" : "false")
        << ",staleSessionRejected:" << (staleSessionRejectedOk ? "true" : "false")
        << ",executionIndexRejected:" << (executionIndexRejectedOk ? "true" : "false")
        << ",sourceCallbacksPublished:" << (sourceCallbacksPublishedOk ? "true" : "false")
        << ",compositorInputsResolved:" << (compositorInputsResolvedOk ? "true" : "false")
        << ",compositorOutputPublished:" << (compositorOutputPublishedOk ? "true" : "false")
        << ",sinkInputResolvedNoOutput:" << (sinkInputResolvedNoOutputOk ? "true" : "false")
        << ",callbackFailureStopsBeforePublish:" << (callbackFailureStopsBeforePublishOk ? "true" : "false")
        << ",undeclaredOutputRejected:" << (undeclaredOutputRejectedOk ? "true" : "false")
        << ",nonGpuBindingsSkipped:" << (nonGpuBindingsSkippedOk ? "true" : "false") << ";"
        << "reason=" << (allPass ? "none" : failureReason);
    return oss.str();
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_connects_vanguard_1media_1engine_bridge_VanguardNativeBridge_runAndroidDagPhase1DagMultinodeExecutionDispatcherSmoke(
    JNIEnv* env,
    jobject /* this */) {
    try {
        const std::string resultStr = RunExecutionDispatcherSmokeInternal();
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
