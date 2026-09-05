#include "vanguard/graph/graph_execution_plan.h"

#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace vanguard {
namespace graph {

core::Status BuildGraphExecutionPlan(const Graph& graph,
                                     const FrameRequest& request,
                                     GraphExecutionPlan& outPlan) {
    outPlan = GraphExecutionPlan{};

    // 1. Preserve evaluatePlayhead's own stale/invalid/no-active semantics.
    FrameEvaluationResult evalResult;
    core::Status evalStatus = graph.evaluatePlayhead(request, evalResult);
    if (!evalStatus.ok() || !evalResult.ok()) {
        return core::Status(core::StatusCode::kError,
                            evalResult.errorMessage.empty() ? evalStatus.message()
                                                              : evalResult.errorMessage);
    }

    // Deterministic topological order over the whole graph, then filtered to
    // the active subset (preserves dependency order).
    std::vector<std::shared_ptr<Node>> sortedAll;
    core::Status sortStatus = graph.topologicalSort(sortedAll);
    if (!sortStatus.ok()) {
        return core::Status(core::StatusCode::kError,
                            "BuildGraphExecutionPlan: " + sortStatus.message());
    }

    std::unordered_set<std::string> activeIds;
    activeIds.reserve(evalResult.activeNodes.size());
    for (const auto& n : evalResult.activeNodes) {
        if (n) activeIds.insert(n->id());
    }

    std::vector<std::shared_ptr<Node>> activeSorted;
    activeSorted.reserve(evalResult.activeNodes.size());
    for (const auto& n : sortedAll) {
        if (n && activeIds.find(n->id()) != activeIds.end()) {
            activeSorted.push_back(n);
        }
    }

    std::unordered_map<std::string, std::shared_ptr<Node>> activeById;
    activeById.reserve(activeSorted.size());
    for (const auto& n : activeSorted) {
        activeById.emplace(n->id(), n);
    }

    // 2. Culling: walk backwards from every active sink over active incoming
    // connections. Active nodes never reached this way are silently culled.
    std::unordered_set<std::string> reachable;
    std::vector<std::string> stack;
    for (const auto& n : activeSorted) {
        if (n->kind() == NodeKind::kSink) {
            if (reachable.insert(n->id()).second) {
                stack.push_back(n->id());
            }
        }
    }
    // Fail closed: a plan with no active sink has nothing to walk or build.
    if (stack.empty()) {
        return core::Status(
            core::StatusCode::kError,
            "BuildGraphExecutionPlan: no active sink found in the active node "
            "set; a plan requires at least one active sink");
    }

    while (!stack.empty()) {
        const std::string nodeId = stack.back();
        stack.pop_back();
        std::vector<Connection> incoming;
        if (!graph.inputConnections(nodeId, incoming).ok()) {
            continue;
        }
        for (const auto& c : incoming) {
            if (activeById.find(c.fromNodeId) == activeById.end()) {
                continue; // upstream node is not active - not part of this plan
            }
            if (reachable.insert(c.fromNodeId).second) {
                stack.push_back(c.fromNodeId);
            }
        }
    }

    std::unordered_map<std::string, const ActiveNodeInfo*> detailsById;
    detailsById.reserve(evalResult.activeNodeDetails.size());
    for (const auto& info : evalResult.activeNodeDetails) {
        detailsById.emplace(info.nodeId, &info);
    }

    // 3. Required-input validation + plan node construction, over the
    // reachable (culled) subset only, in topological order.
    GraphExecutionPlan result;
    result.evaluatedPtsUs = evalResult.evaluatedPtsUs;
    result.evaluatedGeneration = evalResult.evaluatedGeneration;
    result.nodes.reserve(reachable.size());

    for (const auto& n : activeSorted) {
        if (reachable.find(n->id()) == reachable.end()) {
            continue; // culled: active but unreachable from any active sink
        }

        std::vector<Connection> incoming;
        core::Status inputStatus = graph.inputConnections(n->id(), incoming);
        if (!inputStatus.ok()) {
            return core::Status(core::StatusCode::kError,
                                "BuildGraphExecutionPlan: " + inputStatus.message());
        }

        ExecutionPlanNode planNode;
        planNode.nodeId = n->id();
        planNode.nodeKind = n->kind();
        planNode.nodeType = n->type();
        planNode.executionIndex = static_cast<uint32_t>(result.nodes.size());
        planNode.outputPorts = n->outputPorts();

        auto detailIt = detailsById.find(n->id());
        if (detailIt != detailsById.end()) {
            planNode.localPtsUs = detailIt->second->localPtsUs;
            planNode.weight = detailIt->second->weight;
        }

        for (const auto& port : n->inputPorts()) {
            const Connection* resolved = nullptr;
            int matchCount = 0;
            for (const auto& c : incoming) {
                if (c.toPortId != port.id) continue;
                if (activeById.find(c.fromNodeId) == activeById.end()) continue;
                resolved = &c;
                ++matchCount;
            }

            if (matchCount == 1) {
                ExecutionInputBinding binding;
                binding.inputPortId = port.id;
                binding.fromNodeId = resolved->fromNodeId;
                binding.fromPortId = resolved->fromPortId;
                binding.dataType = port.dataType;
                planNode.inputs.push_back(std::move(binding));
                continue;
            }

            if (n->kind() == NodeKind::kSource) {
                continue; // source nodes are exempt from the required-input rule
            }

            return core::Status(
                core::StatusCode::kError,
                "BuildGraphExecutionPlan: required input port '" + port.id +
                    "' on node '" + n->id() + "' has " + std::to_string(matchCount) +
                    " active incoming connection(s), expected exactly 1");
        }

        if (n->kind() == NodeKind::kSink) {
            result.sinkNodeIds.push_back(n->id());
        }

        result.nodes.push_back(std::move(planNode));
    }

    outPlan = std::move(result);
    return core::Status::OK();
}

} // namespace graph
} // namespace vanguard
