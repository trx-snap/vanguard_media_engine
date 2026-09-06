#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace sources {

// P5-IMAGE-TEXTURE-SOURCE-NODE-A: platform-neutral logical DAG source node
// representing a still-image texture feed (e.g. a decoded photo/graphic
// asset uploaded to a GPU texture by a platform decoder/uploader) within
// the DAG. This node owns no decoded pixels, GL/Vulkan texture handle or
// sampler, file IO/path/fd, Android Bitmap/ImageDecoder/NDK decoder
// handle, Android/NDK/JNI object, thread, lock, or queue - it only carries
// primitive/string identity metadata and timeline-window semantics,
// mirroring ExternalSurfaceSourceNode's, CameraFrameSourceNode's, and
// DecodedMediaFrameSourceNode's role for their respective ingest sources
// (active window [start, start+duration), saturating end; map before
// start to 0; map within window to elapsed; map at/after end to
// duration).
class ImageTextureSourceNode : public vanguard::graph::Node {
public:
    ImageTextureSourceNode(std::string id,
                            std::string imageId,
                            uint64_t timelineStartPtsUs,
                            uint64_t durationUs,
                            int32_t width,
                            int32_t height,
                            int32_t orientationDegrees);

    // Delegating overload defaulting orientationDegrees=0.
    ImageTextureSourceNode(std::string id,
                            std::string imageId,
                            uint64_t timelineStartPtsUs,
                            uint64_t durationUs,
                            int32_t width,
                            int32_t height);

    // Delegating overload defaulting imageId to id and orientationDegrees=0.
    ImageTextureSourceNode(std::string id,
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

    const std::string& imageId()             const;
    uint64_t            timelineStartPtsUs() const;
    uint64_t            durationUs()         const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t            timelineEndPtsUs()   const;
    int32_t              width()              const;
    int32_t              height()             const;
    int32_t              orientationDegrees() const;

private:
    std::string id_;
    std::string imageId_;
    uint64_t    timelineStartPtsUs_;
    uint64_t    durationUs_;
    int32_t     width_;
    int32_t     height_;
    int32_t     orientationDegrees_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sources
} // namespace vanguard
