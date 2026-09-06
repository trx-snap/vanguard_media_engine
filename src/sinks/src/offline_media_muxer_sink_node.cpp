#include "vanguard/sinks/offline_media_muxer_sink_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sinks {

OfflineMediaMuxerSinkNode::OfflineMediaMuxerSinkNode(std::string id,
                                                      uint64_t timelineStartPtsUs,
                                                      uint64_t durationUs,
                                                      bool hasVideo,
                                                      bool hasAudio)
    : id_(std::move(id)),
      timelineStartPtsUs_(timelineStartPtsUs),
      durationUs_(durationUs),
      hasVideo_(hasVideo),
      hasAudio_(hasAudio) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (durationUs_ == 0) {
        throw std::invalid_argument("invalid_duration_us");
    }
    if (!hasVideo_ && !hasAudio_) {
        throw std::invalid_argument("empty_tracks");
    }

    if (hasVideo_) {
        inputPorts_.push_back({"video_in", vanguard::graph::PortDataType::kVideoFrame});
    }
    if (hasAudio_) {
        inputPorts_.push_back({"audio_in", vanguard::graph::PortDataType::kAudioPacket});
    }
}

OfflineMediaMuxerSinkNode::OfflineMediaMuxerSinkNode(std::string id,
                                                      uint64_t timelineStartPtsUs,
                                                      uint64_t durationUs)
    : OfflineMediaMuxerSinkNode(std::move(id),
                                 timelineStartPtsUs,
                                 durationUs,
                                 /*hasVideo=*/true,
                                 /*hasAudio=*/false) {}

const std::string& OfflineMediaMuxerSinkNode::id() const {
    return id_;
}

vanguard::graph::NodeKind OfflineMediaMuxerSinkNode::kind() const {
    return vanguard::graph::NodeKind::kSink;
}

vanguard::graph::NodeType OfflineMediaMuxerSinkNode::type() const {
    return vanguard::graph::NodeType::kOfflineMediaMuxerSink;
}

const std::vector<vanguard::graph::PortDescriptor>& OfflineMediaMuxerSinkNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& OfflineMediaMuxerSinkNode::outputPorts() const {
    return outputPorts_;
}

uint64_t OfflineMediaMuxerSinkNode::timelineStartPtsUs() const {
    return timelineStartPtsUs_;
}

uint64_t OfflineMediaMuxerSinkNode::durationUs() const {
    return durationUs_;
}

uint64_t OfflineMediaMuxerSinkNode::timelineEndPtsUs() const {
    return (std::numeric_limits<uint64_t>::max() - timelineStartPtsUs_ < durationUs_)
        ? std::numeric_limits<uint64_t>::max()
        : timelineStartPtsUs_ + durationUs_;
}

bool OfflineMediaMuxerSinkNode::hasVideo() const {
    return hasVideo_;
}

bool OfflineMediaMuxerSinkNode::hasAudio() const {
    return hasAudio_;
}

bool OfflineMediaMuxerSinkNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t endPtsUs = timelineEndPtsUs();
    return timelinePtsUs >= timelineStartPtsUs_ && timelinePtsUs < endPtsUs;
}

uint64_t OfflineMediaMuxerSinkNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    if (timelinePtsUs < timelineStartPtsUs_) {
        return 0;
    }

    if (timelinePtsUs >= timelineEndPtsUs()) {
        return durationUs_;
    }

    return timelinePtsUs - timelineStartPtsUs_;
}

float OfflineMediaMuxerSinkNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

} // namespace sinks
} // namespace vanguard
