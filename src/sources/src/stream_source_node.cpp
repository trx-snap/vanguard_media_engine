#include "vanguard/sources/stream_source_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sources {

StreamSourceNode::StreamSourceNode(std::string id,
                                    std::string streamId,
                                    uint64_t timelineStartPtsUs,
                                    uint64_t durationUs,
                                    int32_t width,
                                    int32_t height,
                                    bool live)
    : id_(std::move(id)),
      streamId_(std::move(streamId)),
      timelineStartPtsUs_(timelineStartPtsUs),
      durationUs_(durationUs),
      width_(width),
      height_(height),
      live_(live) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (streamId_.empty()) {
        throw std::invalid_argument("empty_stream_id");
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

const std::string& StreamSourceNode::id() const {
    return id_;
}

vanguard::graph::NodeKind StreamSourceNode::kind() const {
    return vanguard::graph::NodeKind::kSource;
}

vanguard::graph::NodeType StreamSourceNode::type() const {
    return vanguard::graph::NodeType::kStreamSource;
}

const std::vector<vanguard::graph::PortDescriptor>& StreamSourceNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& StreamSourceNode::outputPorts() const {
    return outputPorts_;
}

const std::string& StreamSourceNode::streamId() const {
    return streamId_;
}

uint64_t StreamSourceNode::timelineStartPtsUs() const {
    return timelineStartPtsUs_;
}

uint64_t StreamSourceNode::durationUs() const {
    return durationUs_;
}

uint64_t StreamSourceNode::timelineEndPtsUs() const {
    return (std::numeric_limits<uint64_t>::max() - timelineStartPtsUs_ < durationUs_)
        ? std::numeric_limits<uint64_t>::max()
        : timelineStartPtsUs_ + durationUs_;
}

int32_t StreamSourceNode::width() const {
    return width_;
}

int32_t StreamSourceNode::height() const {
    return height_;
}

bool StreamSourceNode::live() const {
    return live_;
}

bool StreamSourceNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t endPtsUs = timelineEndPtsUs();
    return timelinePtsUs >= timelineStartPtsUs_ && timelinePtsUs < endPtsUs;
}

uint64_t StreamSourceNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    if (timelinePtsUs < timelineStartPtsUs_) {
        return 0;
    }

    if (timelinePtsUs >= timelineEndPtsUs()) {
        return durationUs_;
    }

    return timelinePtsUs - timelineStartPtsUs_;
}

float StreamSourceNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

} // namespace sources
} // namespace vanguard
