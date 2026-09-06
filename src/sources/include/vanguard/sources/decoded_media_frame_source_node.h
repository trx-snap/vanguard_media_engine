#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace sources {

// P2-DECODED-MEDIA-FRAME-SOURCE-NODE-A: platform-neutral logical DAG source
// node for decoded video frames delivered by Kotlin MediaCodec/
// MediaExtractor decode, mirroring DecodedAudioPcmSourceNode's role for
// video. This node owns no decoder, frame buffer, texture, or other OS
// resource, and includes no Android/NDK headers - Kotlin remains the sole
// owner of the decode/extract lifecycle. This node only represents the
// node's identity, ports, and timeline-window semantics within the DAG,
// mirroring HardwareBufferSourceNode's timeline behavior (active window
// [start, start+duration), saturating end; map before start to 0; map
// within window to elapsed; map at/after end to duration).
class DecodedMediaFrameSourceNode : public vanguard::graph::Node {
public:
    DecodedMediaFrameSourceNode(std::string id,
                                 uint64_t timelineStartPtsUs,
                                 uint64_t durationUs,
                                 int32_t width,
                                 int32_t height);

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
    int32_t  width()              const;
    int32_t  height()             const;

private:
    std::string id_;
    uint64_t    timelineStartPtsUs_;
    uint64_t    durationUs_;
    int32_t     width_;
    int32_t     height_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sources
} // namespace vanguard
