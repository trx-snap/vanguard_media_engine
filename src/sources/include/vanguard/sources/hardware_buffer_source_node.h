#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace sources {

// P1-DAG-MULTINODE-HARDWARE-BUFFER-SOURCE-NODE: platform-neutral logical DAG
// source node for hardware-buffer-backed video frames (e.g. Camera2/
// MediaCodec output surfaces on Android, imported on other platforms via
// their own equivalents). This node owns no AHardwareBuffer*, fence,
// texture, memory, or other OS resource, and includes no platform headers -
// Kotlin/platform adapters remain the sole owners of the underlying hardware
// buffer lifecycle. This node only represents the node's identity, ports,
// and timeline-window semantics within the DAG, mirroring
// DecodedAudioPcmSourceNode's timeline behavior (active window
// [start, start+duration), saturating end; map before start to 0; map
// within window to elapsed; map at/after end to duration).
class HardwareBufferSourceNode : public vanguard::graph::Node {
public:
    HardwareBufferSourceNode(std::string id,
                              uint64_t timelineStartPtsUs,
                              uint64_t durationUs);

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    uint64_t timelineStartPtsUs() const;
    uint64_t durationUs()         const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t timelineEndPtsUs()   const;

private:
    std::string id_;
    uint64_t    timelineStartPtsUs_;
    uint64_t    durationUs_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sources
} // namespace vanguard
