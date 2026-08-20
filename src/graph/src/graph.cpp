#include "vanguard/graph/graph.h"

namespace vanguard {
namespace graph {

core::Status Graph::addNode(std::shared_ptr<Node> node) {
    if (!node) {
        return core::Status(core::StatusCode::kError, "Null node");
    }
    nodes_.push_back(std::move(node));
    return core::Status::OK();
}

size_t Graph::nodeCount() const {
    return nodes_.size();
}

} // namespace graph
} // namespace vanguard
