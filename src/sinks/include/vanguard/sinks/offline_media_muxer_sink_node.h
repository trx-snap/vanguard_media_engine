#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace sinks {

// P2-OFFLINE-MEDIA-MUXER-SINK-NODE-A: platform-neutral logical DAG sink node
// representing the eventual offline (pass-2/export) container-mux output
// (see "UMF architecture/01_True_DAG_Parity_Spec_V4.3.md" and
// "UMF architecture/02_Node_Taxonomy_And_Graph.md"), mirroring
// PreviewSurfaceSinkNode's and PassthroughRemuxSinkNode's role for their
// respective sink targets.
//
// This node is a pure graph-topology/timeline participant: it owns no
// android.media.MediaMuxer, MediaCodec, PlatformCodecAdapter, file
// descriptor, output path, thread, or other OS resource, and includes no
// Android/NDK header. Kotlin/platform adapters remain the sole owners of the
// actual container-mux lifecycle; this node only lets the native graph
// reason about the sink's identity, required ports, and timeline-window
// semantics (active window [start, start+duration), saturating end; map
// before start to 0; map within window to elapsed; map at/after end to
// duration), mirroring CameraFrameSourceNode's and
// ExternalSurfaceSourceNode's timeline behavior.
class OfflineMediaMuxerSinkNode : public vanguard::graph::Node {
public:
    OfflineMediaMuxerSinkNode(std::string id,
                               uint64_t timelineStartPtsUs,
                               uint64_t durationUs,
                               bool hasVideo,
                               bool hasAudio);

    // Delegating overload defaulting hasVideo=true, hasAudio=false.
    OfflineMediaMuxerSinkNode(std::string id,
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
    bool     hasVideo()           const;
    bool     hasAudio()           const;

private:
    std::string id_;
    uint64_t    timelineStartPtsUs_;
    uint64_t    durationUs_;
    bool        hasVideo_;
    bool        hasAudio_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sinks
} // namespace vanguard
