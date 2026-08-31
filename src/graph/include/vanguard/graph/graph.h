#pragma once
#include "vanguard/core/status.h"
#include "vanguard/graph/frame_request.h"
#include "vanguard/graph/node.h"
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace vanguard {
namespace graph {

// Represents a directed edge between two node ports.
struct Connection {
    std::string fromNodeId;
    std::string fromPortId;
    std::string toNodeId;
    std::string toPortId;
};

class Graph {
public:
    Graph();
    ~Graph() = default;

    // Node management (preserves deterministic insertion order).
    core::Status             addNode(std::shared_ptr<Node> node);
    core::Status             removeNode(const std::string& nodeId);
    std::shared_ptr<Node>    getNode(const std::string& nodeId) const;
    size_t                   nodeCount() const;

    // Edge management.
    core::Status connect(const std::string& fromNodeId,
                         const std::string& fromPortId,
                         const std::string& toNodeId,
                         const std::string& toPortId);

    core::Status disconnect(const std::string& fromNodeId,
                            const std::string& fromPortId,
                            const std::string& toNodeId,
                            const std::string& toPortId);

    size_t edgeCount() const;

    // Additive read-only accessor: returns every edge whose toNodeId matches
    // `nodeId`, in deterministic edge-insertion order. Clears `out` first.
    // Errors (leaving `out` empty) if `nodeId` is not present in the graph.
    // Does not expose edges_ directly and never bumps generation.
    core::Status inputConnections(const std::string& nodeId,
                                  std::vector<Connection>& out) const;

    // Topology queries.
    bool         hasCycle() const;
    core::Status topologicalSort(std::vector<std::shared_ptr<Node>>& outOrder) const;

    // Playhead evaluation.
    core::Status evaluatePlayhead(const FrameRequest& request,
                                  FrameEvaluationResult& outResult) const;

    // Generation counter — incremented on every successful mutation.
    uint64_t generationId()   const;
    uint64_t bumpGeneration();

    // Remove all nodes and edges.
    void clear();

private:
    std::vector<std::shared_ptr<Node>> nodes_;
    std::vector<Connection>            edges_;
    uint64_t                           generation_{0};
};

} // namespace graph
} // namespace vanguard
