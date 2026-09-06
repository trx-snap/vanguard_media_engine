#include "vanguard/filters/filter_node.h"

#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace filters {

namespace {

constexpr double kIdentityColorMatrix[20] = {
    1.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 1.0, 0.0,
};

bool IsFiniteColorMatrix(const FilterColorMatrix& cm) {
    for (double v : cm.m) {
        if (!std::isfinite(v)) return false;
    }
    return true;
}

bool IsValidBeauty(const FilterBeautyV2Parameters& b) {
    const double values[4] = {b.intensity, b.smoothing, b.whitening, b.skinTone};
    for (double v : values) {
        if (!std::isfinite(v) || v < 0.0 || v > 1.0) return false;
    }
    return true;
}

bool IsIdentityColorMatrix(const FilterColorMatrix& cm, double epsilon) {
    for (int i = 0; i < 20; ++i) {
        if (std::fabs(cm.m[i] - kIdentityColorMatrix[i]) >= epsilon) return false;
    }
    return true;
}

bool IsZeroBeauty(const FilterBeautyV2Parameters& b, double epsilon) {
    return std::fabs(b.intensity) < epsilon && std::fabs(b.smoothing) < epsilon &&
        std::fabs(b.whitening) < epsilon && std::fabs(b.skinTone) < epsilon;
}

} // namespace

FilterNode::FilterNode(std::string id, FilterDescriptor descriptor)
    : id_(std::move(id)), descriptor_(std::move(descriptor)) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (descriptor_.durationUs == 0) {
        throw std::invalid_argument("invalid_duration_us");
    }
    if (!IsFiniteColorMatrix(descriptor_.colorMatrix)) {
        throw std::invalid_argument("invalid_color_matrix");
    }
    if (!IsValidBeauty(descriptor_.beauty)) {
        throw std::invalid_argument("invalid_beauty_parameters");
    }

    inputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
    outputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
}

const std::string& FilterNode::id() const {
    return id_;
}

vanguard::graph::NodeKind FilterNode::kind() const {
    return vanguard::graph::NodeKind::kProcessing;
}

vanguard::graph::NodeType FilterNode::type() const {
    return vanguard::graph::NodeType::kFilter;
}

const std::vector<vanguard::graph::PortDescriptor>& FilterNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& FilterNode::outputPorts() const {
    return outputPorts_;
}

const FilterDescriptor& FilterNode::descriptor() const {
    return descriptor_;
}

const FilterColorMatrix& FilterNode::colorMatrix() const {
    return descriptor_.colorMatrix;
}

const FilterBeautyV2Parameters& FilterNode::beauty() const {
    return descriptor_.beauty;
}

uint64_t FilterNode::timelineStartPtsUs() const {
    return descriptor_.timelineStartPtsUs;
}

uint64_t FilterNode::durationUs() const {
    return descriptor_.durationUs;
}

uint64_t FilterNode::timelineEndPtsUs() const {
    const uint64_t start = descriptor_.timelineStartPtsUs;
    const uint64_t duration = descriptor_.durationUs;
    return (std::numeric_limits<uint64_t>::max() - start < duration)
        ? std::numeric_limits<uint64_t>::max()
        : start + duration;
}

bool FilterNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t start = descriptor_.timelineStartPtsUs;
    const uint64_t end = timelineEndPtsUs();
    return timelinePtsUs >= start && timelinePtsUs < end;
}

uint64_t FilterNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    const uint64_t start = descriptor_.timelineStartPtsUs;
    if (timelinePtsUs < start) {
        return 0;
    }
    if (timelinePtsUs >= timelineEndPtsUs()) {
        return descriptor_.durationUs;
    }
    return timelinePtsUs - start;
}

float FilterNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

bool FilterNode::hasColorMatrix() const {
    return descriptor_.colorMatrixEnabled;
}

bool FilterNode::hasBeautyV2() const {
    return descriptor_.beautyV2Enabled;
}

bool FilterNode::isPassThrough(double epsilon) const {
    if (descriptor_.colorMatrixEnabled &&
        !IsIdentityColorMatrix(descriptor_.colorMatrix, epsilon)) {
        return false;
    }
    if (descriptor_.beautyV2Enabled && !IsZeroBeauty(descriptor_.beauty, epsilon)) {
        return false;
    }
    return true;
}

FilterRgba FilterNode::applyColorMatrix(const FilterRgba& input) const {
    if (!descriptor_.colorMatrixEnabled) {
        return input;
    }
    const auto& m = descriptor_.colorMatrix.m;
    FilterRgba out;
    out.r = m[0] * input.r + m[1] * input.g + m[2] * input.b + m[3] * input.a + m[4];
    out.g = m[5] * input.r + m[6] * input.g + m[7] * input.b + m[8] * input.a + m[9];
    out.b = m[10] * input.r + m[11] * input.g + m[12] * input.b + m[13] * input.a + m[14];
    out.a = m[15] * input.r + m[16] * input.g + m[17] * input.b + m[18] * input.a + m[19];
    return out;
}

} // namespace filters
} // namespace vanguard
