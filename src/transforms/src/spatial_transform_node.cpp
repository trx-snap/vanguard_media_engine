#include "vanguard/transforms/spatial_transform_node.h"

#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace transforms {

namespace {

bool IsFiniteMatrix(const SpatialAffineMatrix& m) {
    return std::isfinite(m.a) && std::isfinite(m.b) && std::isfinite(m.c) &&
        std::isfinite(m.d) && std::isfinite(m.tx) && std::isfinite(m.ty);
}

bool IsValidCrop(const SpatialCropRect& c) {
    if (!std::isfinite(c.x) || !std::isfinite(c.y) || !std::isfinite(c.width) ||
        !std::isfinite(c.height)) {
        return false;
    }
    if (c.x < 0.0 || c.x > 1.0 || c.y < 0.0 || c.y > 1.0) {
        return false;
    }
    if (c.width <= 0.0 || c.width > 1.0 || c.height <= 0.0 || c.height > 1.0) {
        return false;
    }
    if (c.x + c.width > 1.0 || c.y + c.height > 1.0) {
        return false;
    }
    return true;
}

} // namespace

SpatialTransformNode::SpatialTransformNode(std::string id, SpatialTransformDescriptor descriptor)
    : id_(std::move(id)), descriptor_(std::move(descriptor)) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (descriptor_.durationUs == 0) {
        throw std::invalid_argument("invalid_duration_us");
    }
    if (!IsFiniteMatrix(descriptor_.matrix)) {
        throw std::invalid_argument("invalid_matrix");
    }
    if (!IsValidCrop(descriptor_.crop)) {
        throw std::invalid_argument("invalid_crop");
    }

    inputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
    outputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
}

const std::string& SpatialTransformNode::id() const {
    return id_;
}

vanguard::graph::NodeKind SpatialTransformNode::kind() const {
    return vanguard::graph::NodeKind::kProcessing;
}

vanguard::graph::NodeType SpatialTransformNode::type() const {
    return vanguard::graph::NodeType::kSpatialTransform;
}

const std::vector<vanguard::graph::PortDescriptor>& SpatialTransformNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& SpatialTransformNode::outputPorts() const {
    return outputPorts_;
}

const SpatialTransformDescriptor& SpatialTransformNode::descriptor() const {
    return descriptor_;
}

const SpatialAffineMatrix& SpatialTransformNode::matrix() const {
    return descriptor_.matrix;
}

const SpatialCropRect& SpatialTransformNode::crop() const {
    return descriptor_.crop;
}

uint64_t SpatialTransformNode::timelineStartPtsUs() const {
    return descriptor_.timelineStartPtsUs;
}

uint64_t SpatialTransformNode::durationUs() const {
    return descriptor_.durationUs;
}

uint64_t SpatialTransformNode::timelineEndPtsUs() const {
    const uint64_t start = descriptor_.timelineStartPtsUs;
    const uint64_t duration = descriptor_.durationUs;
    return (std::numeric_limits<uint64_t>::max() - start < duration)
        ? std::numeric_limits<uint64_t>::max()
        : start + duration;
}

bool SpatialTransformNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t start = descriptor_.timelineStartPtsUs;
    const uint64_t end = timelineEndPtsUs();
    return timelinePtsUs >= start && timelinePtsUs < end;
}

uint64_t SpatialTransformNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    const uint64_t start = descriptor_.timelineStartPtsUs;
    if (timelinePtsUs < start) {
        return 0;
    }
    if (timelinePtsUs >= timelineEndPtsUs()) {
        return descriptor_.durationUs;
    }
    return timelinePtsUs - start;
}

float SpatialTransformNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

bool SpatialTransformNode::isIdentityTransform(double epsilon) const {
    const auto& m = descriptor_.matrix;
    return std::fabs(m.a - 1.0) < epsilon && std::fabs(m.b) < epsilon &&
        std::fabs(m.c) < epsilon && std::fabs(m.d - 1.0) < epsilon &&
        std::fabs(m.tx) < epsilon && std::fabs(m.ty) < epsilon;
}

SpatialPoint SpatialTransformNode::applyToPoint(const SpatialPoint& point) const {
    const auto& m = descriptor_.matrix;
    return SpatialPoint{
        m.a * point.x + m.c * point.y + m.tx,
        m.b * point.x + m.d * point.y + m.ty,
    };
}

} // namespace transforms
} // namespace vanguard
