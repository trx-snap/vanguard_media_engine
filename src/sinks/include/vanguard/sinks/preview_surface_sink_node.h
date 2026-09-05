#pragma once
#include "vanguard/graph/node.h"
#include <string>
#include <vector>

namespace vanguard {
namespace sinks {

// P1-DAG-MULTINODE-PREVIEW-SURFACE-SINK-NODE: platform-neutral logical DAG
// sink node representing the eventual output to Flutter's
// TextureRegistry-backed preview surface (see
// "UMF architecture/01_True_DAG_Parity_Spec_V4.3.md" and
// "UMF architecture/02_Node_Taxonomy_And_Graph.md").
//
// This node is a pure graph-topology/timeline participant: it owns no
// Surface, ANativeWindow, TextureRegistry, EGL/Vulkan object, hardware
// buffer, memory, Android/NDK header, thread, or other OS resource.
// Kotlin/platform adapters remain the sole owners of the actual preview
// surface lifecycle; this node only lets the native graph reason about the
// sink's identity and required ports.
class PreviewSurfaceSinkNode : public vanguard::graph::Node {
public:
    explicit PreviewSurfaceSinkNode(std::string id);

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

private:
    std::string                                   id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sinks
} // namespace vanguard
