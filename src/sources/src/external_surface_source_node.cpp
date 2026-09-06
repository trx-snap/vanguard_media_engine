#include "vanguard/sources/external_surface_source_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sources {

ExternalSurfaceSourceNode::ExternalSurfaceSourceNode(std::string id,
                                                      std::string surfaceId,
                                                      uint64_t timelineStartPtsUs,
                                                      uint64_t durationUs,
                                                      int32_t width,
                                                      int32_t height)
    : id_(std::move(id)),
      surfaceId_(std::move(surfaceId)),
      timelineStartPtsUs_(timelineStartPtsUs),
      durationUs_(durationUs),
      width_(width),
      height_(height) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (surfaceId_.empty()) {
        throw std::invalid_argument("empty_surface_id");
    }
    if (durationUs_ == 0) {
        throw std::invalid_argument("invalid_duration_us");
    }
    if (width_ <= 0) {
        throw std::invalid_argument("invalid_width");
    }
    if (height_ <= 0) {
        throw std::invalid_argument("invalid_height");
    }

    outputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
}

ExternalSurfaceSourceNode::ExternalSurfaceSourceNode(std::string id,
                                                      uint64_t timelineStartPtsUs,
                                                      uint64_t durationUs,
                                                      int32_t width,
                                                      int32_t height)
    : ExternalSurfaceSourceNode(id,
                                 id,
                                 timelineStartPtsUs,
                                 durationUs,
                                 width,
                                 height) {}

const std::string& ExternalSurfaceSourceNode::id() const {
    return id_;
}

vanguard::graph::NodeKind ExternalSurfaceSourceNode::kind() const {
    return vanguard::graph::NodeKind::kSource;
}

vanguard::graph::NodeType ExternalSurfaceSourceNode::type() const {
    return vanguard::graph::NodeType::kExternalSurfaceSource;
}

const std::vector<vanguard::graph::PortDescriptor>& ExternalSurfaceSourceNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& ExternalSurfaceSourceNode::outputPorts() const {
    return outputPorts_;
}

const std::string& ExternalSurfaceSourceNode::surfaceId() const {
    return surfaceId_;
}

uint64_t ExternalSurfaceSourceNode::timelineStartPtsUs() const {
    return timelineStartPtsUs_;
}

uint64_t ExternalSurfaceSourceNode::durationUs() const {
    return durationUs_;
}

uint64_t ExternalSurfaceSourceNode::timelineEndPtsUs() const {
    return (std::numeric_limits<uint64_t>::max() - timelineStartPtsUs_ < durationUs_)
        ? std::numeric_limits<uint64_t>::max()
        : timelineStartPtsUs_ + durationUs_;
}

int32_t ExternalSurfaceSourceNode::width() const {
    return width_;
}

int32_t ExternalSurfaceSourceNode::height() const {
    return height_;
}

bool ExternalSurfaceSourceNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t endPtsUs = timelineEndPtsUs();
    return timelinePtsUs >= timelineStartPtsUs_ && timelinePtsUs < endPtsUs;
}

uint64_t ExternalSurfaceSourceNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    if (timelinePtsUs < timelineStartPtsUs_) {
        return 0;
    }

    if (timelinePtsUs >= timelineEndPtsUs()) {
        return durationUs_;
    }

    return timelinePtsUs - timelineStartPtsUs_;
}

float ExternalSurfaceSourceNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

} // namespace sources
} // namespace vanguard
