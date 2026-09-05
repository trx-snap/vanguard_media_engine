#include "vanguard/sources/hardware_buffer_source_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sources {

HardwareBufferSourceNode::HardwareBufferSourceNode(std::string id,
                                                     uint64_t timelineStartPtsUs,
                                                     uint64_t durationUs)
    : id_(std::move(id)),
      timelineStartPtsUs_(timelineStartPtsUs),
      durationUs_(durationUs) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (durationUs_ == 0) {
        throw std::invalid_argument("invalid_duration_us");
    }

    outputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
}

const std::string& HardwareBufferSourceNode::id() const {
    return id_;
}

vanguard::graph::NodeKind HardwareBufferSourceNode::kind() const {
    return vanguard::graph::NodeKind::kSource;
}

vanguard::graph::NodeType HardwareBufferSourceNode::type() const {
    return vanguard::graph::NodeType::kHardwareBufferSource;
}

const std::vector<vanguard::graph::PortDescriptor>& HardwareBufferSourceNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& HardwareBufferSourceNode::outputPorts() const {
    return outputPorts_;
}

uint64_t HardwareBufferSourceNode::timelineStartPtsUs() const {
    return timelineStartPtsUs_;
}

uint64_t HardwareBufferSourceNode::durationUs() const {
    return durationUs_;
}

uint64_t HardwareBufferSourceNode::timelineEndPtsUs() const {
    return (std::numeric_limits<uint64_t>::max() - timelineStartPtsUs_ < durationUs_)
        ? std::numeric_limits<uint64_t>::max()
        : timelineStartPtsUs_ + durationUs_;
}

bool HardwareBufferSourceNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t endPtsUs = timelineEndPtsUs();
    return timelinePtsUs >= timelineStartPtsUs_ && timelinePtsUs < endPtsUs;
}

uint64_t HardwareBufferSourceNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    if (timelinePtsUs < timelineStartPtsUs_) {
        return 0;
    }

    if (timelinePtsUs >= timelineEndPtsUs()) {
        return durationUs_;
    }

    return timelinePtsUs - timelineStartPtsUs_;
}

float HardwareBufferSourceNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

} // namespace sources
} // namespace vanguard
