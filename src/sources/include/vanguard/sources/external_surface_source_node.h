#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace sources {

// P1-EXTERNAL-SURFACE-SOURCE-NODE-A: platform-neutral logical DAG source
// node representing an externally-produced surface feed (e.g. a Flutter
// Texture/SurfaceProducer-backed external texture, screen-share, or other
// caller-owned surface) within the DAG. This node owns no Android Surface,
// SurfaceTexture, ANativeWindow, AHardwareBuffer, EGL/GLES/Vulkan object,
// JNI reference, thread, file descriptor, or other OS resource - it only
// carries primitive/string identity metadata and timeline-window semantics,
// mirroring CameraFrameSourceNode's and DecodedMediaFrameSourceNode's role
// for their respective ingest sources (active window [start, start+duration),
// saturating end; map before start to 0; map within window to elapsed; map
// at/after end to duration).
class ExternalSurfaceSourceNode : public vanguard::graph::Node {
public:
    ExternalSurfaceSourceNode(std::string id,
                               std::string surfaceId,
                               uint64_t timelineStartPtsUs,
                               uint64_t durationUs,
                               int32_t width,
                               int32_t height);

    // Delegating overload defaulting surfaceId to id.
    ExternalSurfaceSourceNode(std::string id,
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

    const std::string& surfaceId()           const;
    uint64_t            timelineStartPtsUs() const;
    uint64_t            durationUs()         const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t            timelineEndPtsUs()   const;
    int32_t              width()              const;
    int32_t              height()             const;

private:
    std::string id_;
    std::string surfaceId_;
    uint64_t    timelineStartPtsUs_;
    uint64_t    durationUs_;
    int32_t     width_;
    int32_t     height_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sources
} // namespace vanguard
