#pragma once
#include "vanguard/core/status.h"
#include "vanguard/graph/node.h"
#include <vector>
#include <memory>

namespace vanguard {
namespace graph {

class Graph {
public:
    Graph() = default;
    ~Graph() = default;

    core::Status addNode(std::shared_ptr<Node> node);
    size_t nodeCount() const;

private:
    std::vector<std::shared_ptr<Node>> nodes_;
};

} // namespace graph
} // namespace vanguard
