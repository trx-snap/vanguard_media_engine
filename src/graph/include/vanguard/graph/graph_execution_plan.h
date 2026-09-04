// P1-DAG-MULTINODE-CORE-EXEC-PLAN: bounded engine-only execution planner.
//
// Builds a deterministic dependency-ordered execution plan over the active
// subset of an arbitrary-depth/branching DAG, using only Graph's existing
// read-only APIs (evaluatePlayhead / topologicalSort / inputConnections).
// Engine-only foundation: no product/editor/app playback wiring, no pixel
// or handle transport. Does not change Graph::evaluatePlayhead's own
// behavior/semantics.
#pragma once
#include "vanguard/core/status.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/graph.h"
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace graph {

// One resolved input binding on an execution-plan node: which declared
// input port is fed by which active upstream node/port.
struct ExecutionInputBinding {
    std::string  inputPortId;
    std::string  fromNodeId;
    std::string  fromPortId;
    PortDataType dataType{PortDataType::kMetadata};
};

// One node in the resolved execution plan.
struct ExecutionPlanNode {
    std::string                        nodeId;
    NodeKind                           nodeKind{NodeKind::kSource};
    NodeType                           nodeType{NodeType::kCustom};
    uint64_t                           localPtsUs{0};
    float                              weight{1.0f};
    uint32_t                           executionIndex{0};
    std::vector<ExecutionInputBinding> inputs;
};

// Deterministic dependency-ordered execution plan over the active subgraph
// that is transitively reachable from at least one active sink.
struct GraphExecutionPlan {
    uint64_t                       evaluatedPtsUs{0};
    uint64_t                       evaluatedGeneration{0};
    // Dependency/topological order; every entry's executionIndex equals its
    // position in this vector.
    std::vector<ExecutionPlanNode> nodes;
    // Active sink node ids, in the same relative (topological) order in
    // which they appear in `nodes`.
    std::vector<std::string>       sinkNodeIds;
};

// Builds `outPlan` for `graph` at `request`'s playhead.
//
// 1. Calls Graph::evaluatePlayhead() first; any stale-generation/invalid-
//    graph/no-active-nodes failure is returned unchanged (same message) and
//    `outPlan` is left default-constructed (empty).
// 2. Fails closed if the active node set from step 1 contains no active
//    sink node: returns an error whose message contains "no active sink"
//    and leaves `outPlan` default-constructed (empty). This check always
//    runs after step 1, so evaluatePlayhead's own stale-generation/invalid-
//    graph/no-active-nodes failures still take precedence over it.
// 3. Restricts the active node set to nodes transitively reachable, via
//    active incoming connections, from at least one active sink;
//    unreachable active branches (orphan sources/processing) are silently
//    culled - this is not a failure.
// 4. For every reachable active processing/sink node, every declared input
//    port must resolve to exactly one active incoming connection; otherwise
//    this fails closed with a descriptive message. Source nodes are exempt
//    (they may have zero inputs).
// 5. Read-only: never mutates `graph`, its nodes, or its generation.
core::Status BuildGraphExecutionPlan(const Graph& graph,
                                     const FrameRequest& request,
                                     GraphExecutionPlan& outPlan);

} // namespace graph
} // namespace vanguard
