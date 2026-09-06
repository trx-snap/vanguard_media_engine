#include "vanguard/sinks/image_optimizer_sink_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sinks {

ImageOptimizerSinkNode::ImageOptimizerSinkNode(std::string id,
                                                ImageOptimizerSinkDescriptor descriptor)
    : id_(std::move(id)), descriptor_(std::move(descriptor)) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (descriptor_.durationUs == 0) {
        throw std::invalid_argument("invalid_duration_us");
    }
    if (descriptor_.targetWidth <= 0 || descriptor_.targetHeight <= 0) {
        throw std::invalid_argument("invalid_target_dimensions");
    }
    if (descriptor_.qualityPercent < 1 || descriptor_.qualityPercent > 100) {
        throw std::invalid_argument("invalid_quality_percent");
    }

    inputPorts_.push_back({"video_in", vanguard::graph::PortDataType::kVideoFrame});
}

const std::string& ImageOptimizerSinkNode::id() const {
    return id_;
}

vanguard::graph::NodeKind ImageOptimizerSinkNode::kind() const {
    return vanguard::graph::NodeKind::kSink;
}

vanguard::graph::NodeType ImageOptimizerSinkNode::type() const {
    return vanguard::graph::NodeType::kImageOptimizerSink;
}

const std::vector<vanguard::graph::PortDescriptor>& ImageOptimizerSinkNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& ImageOptimizerSinkNode::outputPorts() const {
    return outputPorts_;
}

const ImageOptimizerSinkDescriptor& ImageOptimizerSinkNode::descriptor() const {
    return descriptor_;
}

int32_t ImageOptimizerSinkNode::targetWidth() const {
    return descriptor_.targetWidth;
}

int32_t ImageOptimizerSinkNode::targetHeight() const {
    return descriptor_.targetHeight;
}

int32_t ImageOptimizerSinkNode::qualityPercent() const {
    return descriptor_.qualityPercent;
}

ImageOptimizerOutputFormat ImageOptimizerSinkNode::outputFormat() const {
    return descriptor_.outputFormat;
}

bool ImageOptimizerSinkNode::generateThumbnail() const {
    return descriptor_.generateThumbnail;
}

bool ImageOptimizerSinkNode::preserveExifOrientation() const {
    return descriptor_.preserveExifOrientation;
}

uint64_t ImageOptimizerSinkNode::timelineStartPtsUs() const {
    return descriptor_.timelineStartPtsUs;
}

uint64_t ImageOptimizerSinkNode::durationUs() const {
    return descriptor_.durationUs;
}

uint64_t ImageOptimizerSinkNode::timelineEndPtsUs() const {
    return (std::numeric_limits<uint64_t>::max() - descriptor_.timelineStartPtsUs < descriptor_.durationUs)
        ? std::numeric_limits<uint64_t>::max()
        : descriptor_.timelineStartPtsUs + descriptor_.durationUs;
}

bool ImageOptimizerSinkNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t endPtsUs = timelineEndPtsUs();
    return timelinePtsUs >= descriptor_.timelineStartPtsUs && timelinePtsUs < endPtsUs;
}

uint64_t ImageOptimizerSinkNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    if (timelinePtsUs < descriptor_.timelineStartPtsUs) {
        return 0;
    }

    if (timelinePtsUs >= timelineEndPtsUs()) {
        return descriptor_.durationUs;
    }

    return timelinePtsUs - descriptor_.timelineStartPtsUs;
}

float ImageOptimizerSinkNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

} // namespace sinks
} // namespace vanguard
