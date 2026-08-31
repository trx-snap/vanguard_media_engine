#include "vanguard/graph/graph.h"
#include <algorithm>
#include <unordered_map>
#include <utility>

namespace vanguard {
namespace graph {

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

Graph::Graph() : generation_(0) {}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

static bool hasPort(const std::vector<PortDescriptor>& ports,
                    const std::string& portId,
                    PortDataType* outType = nullptr) {
    for (const auto& p : ports) {
        if (p.id == portId) {
            if (outType) *outType = p.dataType;
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Node management
// ---------------------------------------------------------------------------

core::Status Graph::addNode(std::shared_ptr<Node> node) {
    if (!node) {
        return core::Status(core::StatusCode::kError, "addNode: null node");
    }
    const std::string& nid = node->id();
    if (nid.empty()) {
        return core::Status(core::StatusCode::kError, "addNode: empty node id");
    }
    for (const auto& existing : nodes_) {
        if (existing->id() == nid) {
            return core::Status(core::StatusCode::kError,
                                "addNode: duplicate node id: " + nid);
        }
    }
    nodes_.push_back(std::move(node));
    ++generation_;
    return core::Status::OK();
}

core::Status Graph::removeNode(const std::string& nodeId) {
    auto it = std::find_if(nodes_.begin(), nodes_.end(),
                           [&](const std::shared_ptr<Node>& n) {
                               return n->id() == nodeId;
                           });
    if (it == nodes_.end()) {
        return core::Status(core::StatusCode::kError,
                            "removeNode: node not found: " + nodeId);
    }
    nodes_.erase(it);

    // Remove all incident edges.
    edges_.erase(
        std::remove_if(edges_.begin(), edges_.end(),
                       [&](const Connection& c) {
                           return c.fromNodeId == nodeId || c.toNodeId == nodeId;
                       }),
        edges_.end());

    ++generation_;
    return core::Status::OK();
}

std::shared_ptr<Node> Graph::getNode(const std::string& nodeId) const {
    for (const auto& n : nodes_) {
        if (n->id() == nodeId) return n;
    }
    return nullptr;
}

size_t Graph::nodeCount() const {
    return nodes_.size();
}

// ---------------------------------------------------------------------------
// Edge management
// ---------------------------------------------------------------------------

core::Status Graph::connect(const std::string& fromNodeId,
                            const std::string& fromPortId,
                            const std::string& toNodeId,
                            const std::string& toPortId) {
    // Validate source node.
    auto srcNode = getNode(fromNodeId);
    if (!srcNode) {
        return core::Status(core::StatusCode::kError,
                            "connect: source node not found: " + fromNodeId);
    }
    // Validate target node.
    auto dstNode = getNode(toNodeId);
    if (!dstNode) {
        return core::Status(core::StatusCode::kError,
                            "connect: target node not found: " + toNodeId);
    }
    // fromPort must be an output port of source.
    PortDataType srcType;
    if (!hasPort(srcNode->outputPorts(), fromPortId, &srcType)) {
        return core::Status(core::StatusCode::kError,
                            "connect: output port not found: " + fromPortId +
                            " on node " + fromNodeId);
    }
    // toPort must be an input port of target.
    PortDataType dstType;
    if (!hasPort(dstNode->inputPorts(), toPortId, &dstType)) {
        return core::Status(core::StatusCode::kError,
                            "connect: input port not found: " + toPortId +
                            " on node " + toNodeId);
    }
    // PortDataType must match.
    if (srcType != dstType) {
        return core::Status(core::StatusCode::kError,
                            "connect: port data type mismatch between " +
                            fromPortId + " and " + toPortId);
    }
    // Reject duplicate edge.
    for (const auto& c : edges_) {
        if (c.fromNodeId == fromNodeId && c.fromPortId == fromPortId &&
            c.toNodeId  == toNodeId   && c.toPortId   == toPortId) {
            return core::Status(core::StatusCode::kError,
                                "connect: duplicate edge");
        }
    }
    // Reject fan-in: an input port may only be targeted by one edge.
    for (const auto& c : edges_) {
        if (c.toNodeId == toNodeId && c.toPortId == toPortId) {
            return core::Status(core::StatusCode::kError,
                                "connect: input port already connected: " +
                                toPortId + " on node " + toNodeId);
        }
    }
    // Cycle check: tentatively add the edge.
    edges_.push_back({fromNodeId, fromPortId, toNodeId, toPortId});
    std::vector<std::shared_ptr<Node>> dummy;
    core::Status cycleStatus = topologicalSort(dummy);
    if (!cycleStatus.ok()) {
        edges_.pop_back();   // Restore.
        return core::Status(core::StatusCode::kError,
                            "connect: would create a cycle");
    }
    ++generation_;
    return core::Status::OK();
}

core::Status Graph::disconnect(const std::string& fromNodeId,
                               const std::string& fromPortId,
                               const std::string& toNodeId,
                               const std::string& toPortId) {
    auto it = std::find_if(edges_.begin(), edges_.end(),
                           [&](const Connection& c) {
                               return c.fromNodeId == fromNodeId &&
                                      c.fromPortId == fromPortId &&
                                      c.toNodeId   == toNodeId   &&
                                      c.toPortId   == toPortId;
                           });
    if (it == edges_.end()) {
        return core::Status(core::StatusCode::kError,
                            "disconnect: edge not found");
    }
    edges_.erase(it);
    ++generation_;
    return core::Status::OK();
}

size_t Graph::edgeCount() const {
    return edges_.size();
}

core::Status Graph::inputConnections(const std::string& nodeId,
                                     std::vector<Connection>& out) const {
    out.clear();
    if (!getNode(nodeId)) {
        return core::Status(core::StatusCode::kError,
                            "inputConnections: node not found: " + nodeId);
    }
    for (const auto& c : edges_) {
        if (c.toNodeId == nodeId) {
            out.push_back(c);
        }
    }
    return core::Status::OK();
}

// ---------------------------------------------------------------------------
// Topology
// ---------------------------------------------------------------------------

// Kahn's algorithm.  Processes nodes in deterministic insertion order by
// using an index-based queue sorted by insertion index.
core::Status Graph::topologicalSort(
        std::vector<std::shared_ptr<Node>>& outOrder) const {
    outOrder.clear();

    const size_t n = nodes_.size();
    if (n == 0) return core::Status::OK();

    // Map node id -> insertion index.
    std::unordered_map<std::string, size_t> indexMap;
    indexMap.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        indexMap[nodes_[i]->id()] = i;
    }

    // Compute in-degrees (count edges arriving at each node).
    std::vector<size_t> inDeg(n, 0);
    // Adjacency list: adjacency[u] = list of v indices (in edge-insertion order).
    std::vector<std::vector<size_t>> adj(n);
    for (const auto& c : edges_) {
        auto itSrc = indexMap.find(c.fromNodeId);
        auto itDst = indexMap.find(c.toNodeId);
        if (itSrc == indexMap.end() || itDst == indexMap.end()) continue;
        size_t u = itSrc->second;
        size_t v = itDst->second;
        adj[u].push_back(v);
        ++inDeg[v];
    }

    // Seed queue with all zero-in-degree nodes, in insertion order (smallest
    // index first).  Use a sorted structure keyed on insertion index.
    // We use a plain vector as a min-priority queue to keep determinism.
    std::vector<size_t> ready;
    ready.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        if (inDeg[i] == 0) ready.push_back(i);
    }
    // ready is already in ascending insertion-index order since we iterate 0..n-1.

    outOrder.reserve(n);
    size_t front = 0;
    while (front < ready.size()) {
        size_t u = ready[front++];
        outOrder.push_back(nodes_[u]);
        // Collect neighbours in edge-insertion order, then sort by index
        // to maintain determinism.
        std::vector<size_t> toSort = adj[u];
        std::sort(toSort.begin(), toSort.end());
        for (size_t v : toSort) {
            if (--inDeg[v] == 0) {
                // Insert in sorted position to keep ready in ascending order.
                auto pos = std::lower_bound(ready.begin() + static_cast<ptrdiff_t>(front),
                                            ready.end(), v);
                ready.insert(pos, v);
            }
        }
    }

    if (outOrder.size() != n) {
        outOrder.clear();
        return core::Status(core::StatusCode::kError,
                            "topologicalSort: graph contains a cycle");
    }
    return core::Status::OK();
}

bool Graph::hasCycle() const {
    std::vector<std::shared_ptr<Node>> dummy;
    return !topologicalSort(dummy).ok();
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

uint64_t Graph::generationId() const {
    return generation_;
}

uint64_t Graph::bumpGeneration() {
    return ++generation_;
}

// ---------------------------------------------------------------------------
// clear
// ---------------------------------------------------------------------------

void Graph::clear() {
    if (nodes_.empty() && edges_.empty()) return;
    nodes_.clear();
    edges_.clear();
    ++generation_;
}

// ---------------------------------------------------------------------------
// Playhead evaluation
// ---------------------------------------------------------------------------

core::Status Graph::evaluatePlayhead(const FrameRequest& request,
                                     FrameEvaluationResult& outResult) const {
    outResult = FrameEvaluationResult{};
    outResult.evaluatedPtsUs = request.timelinePtsUs;
    outResult.evaluatedGeneration = generationId();

    if (request.generationId != generationId()) {
        outResult.statusCode = EvaluationStatusCode::kStaleGeneration;
        outResult.errorMessage = "evaluatePlayhead: stale generation id " +
                                 std::to_string(request.generationId) +
                                 " does not match graph generation " +
                                 std::to_string(generationId());
        return core::Status(core::StatusCode::kError, outResult.errorMessage);
    }

    if (nodes_.empty()) {
        outResult.statusCode = EvaluationStatusCode::kInvalidGraph;
        outResult.errorMessage = "evaluatePlayhead: graph has zero nodes";
        return core::Status(core::StatusCode::kError, outResult.errorMessage);
    }

    std::vector<std::shared_ptr<Node>> sortedNodes;
    core::Status sortStatus = topologicalSort(sortedNodes);
    if (!sortStatus.ok()) {
        outResult.statusCode = EvaluationStatusCode::kInvalidGraph;
        outResult.errorMessage = sortStatus.message();
        return core::Status(core::StatusCode::kError, outResult.errorMessage);
    }

    uint32_t activeLayerIndex = 0;
    for (const auto& node : sortedNodes) {
        if (!node) continue;
        if (node->isActiveAt(request.timelinePtsUs)) {
            outResult.activeNodes.push_back(node);

            ActiveNodeInfo info;
            info.nodeId = node->id();
            info.nodeType = node->type();
            info.nodeKind = node->kind();
            info.localPtsUs = node->mapTimelineToLocalPts(request.timelinePtsUs);
            info.weight = std::clamp(node->blendWeightAt(request.timelinePtsUs), 0.0f, 1.0f);
            info.layerIndex = activeLayerIndex++;
            outResult.activeNodeDetails.push_back(std::move(info));

            for (const auto& port : node->inputPorts()) {
                if (port.dataType == PortDataType::kVideoFrame ||
                    port.dataType == PortDataType::kTextureBuffer) {
                    outResult.hasVideo = true;
                } else if (port.dataType == PortDataType::kAudioPacket) {
                    outResult.hasAudio = true;
                }
            }
            for (const auto& port : node->outputPorts()) {
                if (port.dataType == PortDataType::kVideoFrame ||
                    port.dataType == PortDataType::kTextureBuffer) {
                    outResult.hasVideo = true;
                } else if (port.dataType == PortDataType::kAudioPacket) {
                    outResult.hasAudio = true;
                }
            }
        }
    }

    if (outResult.activeNodes.empty()) {
        outResult.statusCode = EvaluationStatusCode::kNoActiveNodes;
        outResult.errorMessage = "evaluatePlayhead: no active nodes at pts " +
                                 std::to_string(request.timelinePtsUs);
        return core::Status(core::StatusCode::kError, outResult.errorMessage);
    }

    outResult.statusCode = EvaluationStatusCode::kSuccess;
    return core::Status::OK();
}

} // namespace graph
} // namespace vanguard
