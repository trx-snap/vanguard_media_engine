#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace vanguard {
namespace sinks {

// Logical DAG sink node representing a passthrough remux target.
//
// This node is a pure graph-topology/timeline participant: it carries no
// MediaExtractor/MediaMuxer state and performs no file IO. Kotlin remains the
// sole owner of the actual remux pipeline; this node only lets the native
// graph reason about the sink's activation window and required ports so a
// Kotlin-initiated validation pass can check topology/timeline correctness
// before any production remux work happens.
class PassthroughRemuxSinkNode : public vanguard::graph::Node {
public:
    PassthroughRemuxSinkNode(std::string id,
                              uint64_t startPtsUs,
                              uint64_t durationUs,
                              bool requiresAudio);

    const std::string&                                id()          const override;
    vanguard::graph::NodeKind                         kind()        const override;
    vanguard::graph::NodeType                         type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    uint64_t startPtsUs()    const;
    uint64_t durationUs()    const;
    bool     requiresAudio() const;

private:
    std::string                                   id_;
    uint64_t                                       startPtsUs_;
    uint64_t                                       durationUs_;
    bool                                            requiresAudio_;
    std::vector<vanguard::graph::PortDescriptor>  inputPorts_;
    std::vector<vanguard::graph::PortDescriptor>  outputPorts_;
};

} // namespace sinks
} // namespace vanguard
