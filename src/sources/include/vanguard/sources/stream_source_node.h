#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace sources {

// P6-STREAM-SOURCE-NODE-A: platform-neutral logical DAG source node for
// producer-agnostic streaming video ingest (Path A Media3/ExoPlayer or
// Path B WebRTC/LiveKit decode, per
// "UMF Android_Documentation/status/phase_6_streaming_transport.md" and
// "UMF Android_Documentation/architecture/01_True_DAG_Parity_Spec_V4.3.md").
// This node owns no network SDK session, decoder, frame buffer, texture, or
// other OS resource, and includes no Android/NDK/WebRTC/LiveKit headers -
// the platform producer remains the sole owner of the ingest/decode
// lifecycle. This node only represents the node's identity, ports, and
// timeline-window semantics within the DAG, mirroring
// DecodedMediaFrameSourceNode's timeline behavior (active window
// [start, start+duration), saturating end; map before start to 0; map
// within window to elapsed; map at/after end to duration). Live streams may
// pass a large/saturating durationUs to model an open-ended window; this
// node does not invent or track wall-clock time.
class StreamSourceNode : public vanguard::graph::Node {
public:
    StreamSourceNode(std::string id,
                      std::string streamId,
                      uint64_t timelineStartPtsUs,
                      uint64_t durationUs,
                      int32_t width,
                      int32_t height,
                      bool live);

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    const std::string& streamId()           const;
    uint64_t            timelineStartPtsUs() const;
    uint64_t            durationUs()         const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t            timelineEndPtsUs()   const;
    int32_t              width()              const;
    int32_t              height()             const;
    bool                 live()               const;

private:
    std::string id_;
    std::string streamId_;
    uint64_t    timelineStartPtsUs_;
    uint64_t    durationUs_;
    int32_t     width_;
    int32_t     height_;
    bool        live_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sources
} // namespace vanguard
