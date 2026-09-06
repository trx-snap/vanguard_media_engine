#include "vanguard/sources/image_texture_source_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sources {

ImageTextureSourceNode::ImageTextureSourceNode(std::string id,
                                                std::string imageId,
                                                uint64_t timelineStartPtsUs,
                                                uint64_t durationUs,
                                                int32_t width,
                                                int32_t height,
                                                int32_t orientationDegrees)
    : id_(std::move(id)),
      imageId_(std::move(imageId)),
      timelineStartPtsUs_(timelineStartPtsUs),
      durationUs_(durationUs),
      width_(width),
      height_(height),
      orientationDegrees_(orientationDegrees) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (imageId_.empty()) {
        throw std::invalid_argument("empty_image_id");
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
    if (orientationDegrees_ != 0 && orientationDegrees_ != 90 &&
        orientationDegrees_ != 180 && orientationDegrees_ != 270) {
        throw std::invalid_argument("invalid_orientation_degrees");
    }

    outputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
}

ImageTextureSourceNode::ImageTextureSourceNode(std::string id,
                                                std::string imageId,
                                                uint64_t timelineStartPtsUs,
                                                uint64_t durationUs,
                                                int32_t width,
                                                int32_t height)
    : ImageTextureSourceNode(std::move(id),
                              std::move(imageId),
                              timelineStartPtsUs,
                              durationUs,
                              width,
                              height,
                              /*orientationDegrees=*/0) {}

ImageTextureSourceNode::ImageTextureSourceNode(std::string id,
                                                uint64_t timelineStartPtsUs,
                                                uint64_t durationUs,
                                                int32_t width,
                                                int32_t height)
    : ImageTextureSourceNode(id,
                              id,
                              timelineStartPtsUs,
                              durationUs,
                              width,
                              height,
                              /*orientationDegrees=*/0) {}

const std::string& ImageTextureSourceNode::id() const {
    return id_;
}

vanguard::graph::NodeKind ImageTextureSourceNode::kind() const {
    return vanguard::graph::NodeKind::kSource;
}

vanguard::graph::NodeType ImageTextureSourceNode::type() const {
    return vanguard::graph::NodeType::kImageTextureSource;
}

const std::vector<vanguard::graph::PortDescriptor>& ImageTextureSourceNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& ImageTextureSourceNode::outputPorts() const {
    return outputPorts_;
}

const std::string& ImageTextureSourceNode::imageId() const {
    return imageId_;
}

uint64_t ImageTextureSourceNode::timelineStartPtsUs() const {
    return timelineStartPtsUs_;
}

uint64_t ImageTextureSourceNode::durationUs() const {
    return durationUs_;
}

uint64_t ImageTextureSourceNode::timelineEndPtsUs() const {
    return (std::numeric_limits<uint64_t>::max() - timelineStartPtsUs_ < durationUs_)
        ? std::numeric_limits<uint64_t>::max()
        : timelineStartPtsUs_ + durationUs_;
}

int32_t ImageTextureSourceNode::width() const {
    return width_;
}

int32_t ImageTextureSourceNode::height() const {
    return height_;
}

int32_t ImageTextureSourceNode::orientationDegrees() const {
    return orientationDegrees_;
}

bool ImageTextureSourceNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t endPtsUs = timelineEndPtsUs();
    return timelinePtsUs >= timelineStartPtsUs_ && timelinePtsUs < endPtsUs;
}

uint64_t ImageTextureSourceNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    if (timelinePtsUs < timelineStartPtsUs_) {
        return 0;
    }

    if (timelinePtsUs >= timelineEndPtsUs()) {
        return durationUs_;
    }

    return timelinePtsUs - timelineStartPtsUs_;
}

float ImageTextureSourceNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

} // namespace sources
} // namespace vanguard
