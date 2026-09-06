#include "vanguard/sources/decoded_media_frame_source_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sources {

DecodedMediaFrameSourceNode::DecodedMediaFrameSourceNode(std::string id,
                                                           uint64_t timelineStartPtsUs,
                                                           uint64_t durationUs,
                                                           int32_t width,
                                                           int32_t height)
    : id_(std::move(id)),
      timelineStartPtsUs_(timelineStartPtsUs),
      durationUs_(durationUs),
      width_(width),
      height_(height) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
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

const std::string& DecodedMediaFrameSourceNode::id() const {
    return id_;
}

vanguard::graph::NodeKind DecodedMediaFrameSourceNode::kind() const {
    return vanguard::graph::NodeKind::kSource;
}

vanguard::graph::NodeType DecodedMediaFrameSourceNode::type() const {
    return vanguard::graph::NodeType::kDecodedMediaFrameSource;
}

const std::vector<vanguard::graph::PortDescriptor>& DecodedMediaFrameSourceNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& DecodedMediaFrameSourceNode::outputPorts() const {
    return outputPorts_;
}

uint64_t DecodedMediaFrameSourceNode::timelineStartPtsUs() const {
    return timelineStartPtsUs_;
}

uint64_t DecodedMediaFrameSourceNode::durationUs() const {
    return durationUs_;
}

uint64_t DecodedMediaFrameSourceNode::timelineEndPtsUs() const {
    return (std::numeric_limits<uint64_t>::max() - timelineStartPtsUs_ < durationUs_)
        ? std::numeric_limits<uint64_t>::max()
        : timelineStartPtsUs_ + durationUs_;
}

int32_t DecodedMediaFrameSourceNode::width() const {
    return width_;
}

int32_t DecodedMediaFrameSourceNode::height() const {
    return height_;
}

bool DecodedMediaFrameSourceNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t endPtsUs = timelineEndPtsUs();
    return timelinePtsUs >= timelineStartPtsUs_ && timelinePtsUs < endPtsUs;
}

uint64_t DecodedMediaFrameSourceNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    if (timelinePtsUs < timelineStartPtsUs_) {
        return 0;
    }

    if (timelinePtsUs >= timelineEndPtsUs()) {
        return durationUs_;
    }

    return timelinePtsUs - timelineStartPtsUs_;
}

float DecodedMediaFrameSourceNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

} // namespace sources
} // namespace vanguard
