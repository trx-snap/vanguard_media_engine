#include "vanguard/sinks/preview_surface_sink_node.h"

#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sinks {

PreviewSurfaceSinkNode::PreviewSurfaceSinkNode(std::string id)
    : id_(std::move(id)) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    inputPorts_.push_back({"video_in", vanguard::graph::PortDataType::kVideoFrame});
}

const std::string& PreviewSurfaceSinkNode::id() const {
    return id_;
}

vanguard::graph::NodeKind PreviewSurfaceSinkNode::kind() const {
    return vanguard::graph::NodeKind::kSink;
}

vanguard::graph::NodeType PreviewSurfaceSinkNode::type() const {
    return vanguard::graph::NodeType::kPreviewSurfaceSink;
}

const std::vector<vanguard::graph::PortDescriptor>& PreviewSurfaceSinkNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& PreviewSurfaceSinkNode::outputPorts() const {
    return outputPorts_;
}

} // namespace sinks
} // namespace vanguard
