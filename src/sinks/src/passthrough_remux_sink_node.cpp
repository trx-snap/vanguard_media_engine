#include "vanguard/sinks/passthrough_remux_sink_node.h"

namespace vanguard {
namespace sinks {

PassthroughRemuxSinkNode::PassthroughRemuxSinkNode(std::string id,
                                                     uint64_t startPtsUs,
                                                     uint64_t durationUs,
                                                     bool requiresAudio)
    : id_(std::move(id)),
      startPtsUs_(startPtsUs),
      durationUs_(durationUs),
      requiresAudio_(requiresAudio) {
    inputPorts_.push_back({"video_in", vanguard::graph::PortDataType::kVideoFrame});
    if (requiresAudio_) {
        inputPorts_.push_back({"audio_in", vanguard::graph::PortDataType::kAudioPacket});
    }
}

const std::string& PassthroughRemuxSinkNode::id() const {
    return id_;
}

vanguard::graph::NodeKind PassthroughRemuxSinkNode::kind() const {
    return vanguard::graph::NodeKind::kSink;
}

vanguard::graph::NodeType PassthroughRemuxSinkNode::type() const {
    return vanguard::graph::NodeType::kPassthroughRemuxSink;
}

const std::vector<vanguard::graph::PortDescriptor>& PassthroughRemuxSinkNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& PassthroughRemuxSinkNode::outputPorts() const {
    return outputPorts_;
}

bool PassthroughRemuxSinkNode::isActiveAt(uint64_t timelinePtsUs) const {
    uint64_t end = (durationUs_ > std::numeric_limits<uint64_t>::max() - startPtsUs_)
                       ? std::numeric_limits<uint64_t>::max()
                       : startPtsUs_ + durationUs_;
    return timelinePtsUs >= startPtsUs_ && timelinePtsUs < end;
}

uint64_t PassthroughRemuxSinkNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    return timelinePtsUs >= startPtsUs_ ? timelinePtsUs - startPtsUs_ : 0;
}

float PassthroughRemuxSinkNode::blendWeightAt(uint64_t /* timelinePtsUs */) const {
    return 1.0f;
}

uint64_t PassthroughRemuxSinkNode::startPtsUs() const {
    return startPtsUs_;
}

uint64_t PassthroughRemuxSinkNode::durationUs() const {
    return durationUs_;
}

bool PassthroughRemuxSinkNode::requiresAudio() const {
    return requiresAudio_;
}

} // namespace sinks
} // namespace vanguard
