#include "vanguard/compositors/graphic_overlay_compositor_node.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace compositors {

namespace {

constexpr uint32_t kMinOverlayInputCount = 1;
constexpr uint32_t kMaxOverlayInputCount = 16;

bool IsValidBounds(const GraphicOverlayBounds& b) {
    if (!std::isfinite(b.x) || !std::isfinite(b.y) || !std::isfinite(b.width) ||
        !std::isfinite(b.height)) {
        return false;
    }
    if (b.x < 0.0 || b.x > 1.0 || b.y < 0.0 || b.y > 1.0) {
        return false;
    }
    if (b.width <= 0.0 || b.width > 1.0 || b.height <= 0.0 || b.height > 1.0) {
        return false;
    }
    if (b.x + b.width > 1.0 || b.y + b.height > 1.0) {
        return false;
    }
    return true;
}

bool IsValidOpacity(double opacity) {
    return std::isfinite(opacity) && opacity >= 0.0 && opacity <= 1.0;
}

uint64_t SaturatedEnd(uint64_t start, uint64_t duration) {
    return (std::numeric_limits<uint64_t>::max() - start < duration)
        ? std::numeric_limits<uint64_t>::max()
        : start + duration;
}

bool OverlayActiveAt(const GraphicOverlayDescriptor& overlay, uint64_t timelinePtsUs) {
    const uint64_t end = SaturatedEnd(overlay.timelineStartPtsUs, overlay.durationUs);
    return timelinePtsUs >= overlay.timelineStartPtsUs && timelinePtsUs < end;
}

} // namespace

GraphicOverlayCompositorNode::GraphicOverlayCompositorNode(
    std::string id, GraphicOverlayCompositorDescriptor descriptor)
    : id_(std::move(id)), descriptor_(std::move(descriptor)) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (descriptor_.durationUs == 0) {
        throw std::invalid_argument("invalid_duration_us");
    }
    if (descriptor_.overlayInputCount < kMinOverlayInputCount ||
        descriptor_.overlayInputCount > kMaxOverlayInputCount) {
        throw std::invalid_argument("invalid_overlay_input_count");
    }
    for (const auto& overlay : descriptor_.overlays) {
        if (overlay.overlayId.empty()) {
            throw std::invalid_argument("invalid_overlay_id");
        }
        if (overlay.durationUs == 0) {
            throw std::invalid_argument("invalid_overlay_duration_us");
        }
        if (!IsValidBounds(overlay.bounds)) {
            throw std::invalid_argument("invalid_overlay_bounds");
        }
        if (!IsValidOpacity(overlay.opacity)) {
            throw std::invalid_argument("invalid_overlay_opacity");
        }
    }

    inputPorts_.push_back({"base_video_in", vanguard::graph::PortDataType::kVideoFrame});
    for (uint32_t i = 0; i < descriptor_.overlayInputCount; ++i) {
        inputPorts_.push_back(
            {"overlay_" + std::to_string(i) + "_video_in", vanguard::graph::PortDataType::kVideoFrame});
    }
    outputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
}

const std::string& GraphicOverlayCompositorNode::id() const {
    return id_;
}

vanguard::graph::NodeKind GraphicOverlayCompositorNode::kind() const {
    return vanguard::graph::NodeKind::kProcessing;
}

vanguard::graph::NodeType GraphicOverlayCompositorNode::type() const {
    return vanguard::graph::NodeType::kGraphicOverlayCompositor;
}

const std::vector<vanguard::graph::PortDescriptor>& GraphicOverlayCompositorNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& GraphicOverlayCompositorNode::outputPorts() const {
    return outputPorts_;
}

const GraphicOverlayCompositorDescriptor& GraphicOverlayCompositorNode::descriptor() const {
    return descriptor_;
}

uint32_t GraphicOverlayCompositorNode::overlayInputCount() const {
    return descriptor_.overlayInputCount;
}

const std::vector<GraphicOverlayDescriptor>& GraphicOverlayCompositorNode::overlays() const {
    return descriptor_.overlays;
}

uint64_t GraphicOverlayCompositorNode::timelineStartPtsUs() const {
    return descriptor_.timelineStartPtsUs;
}

uint64_t GraphicOverlayCompositorNode::durationUs() const {
    return descriptor_.durationUs;
}

uint64_t GraphicOverlayCompositorNode::timelineEndPtsUs() const {
    return SaturatedEnd(descriptor_.timelineStartPtsUs, descriptor_.durationUs);
}

bool GraphicOverlayCompositorNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t start = descriptor_.timelineStartPtsUs;
    const uint64_t end = timelineEndPtsUs();
    return timelinePtsUs >= start && timelinePtsUs < end;
}

uint64_t GraphicOverlayCompositorNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    const uint64_t start = descriptor_.timelineStartPtsUs;
    if (timelinePtsUs < start) {
        return 0;
    }
    if (timelinePtsUs >= timelineEndPtsUs()) {
        return descriptor_.durationUs;
    }
    return timelinePtsUs - start;
}

float GraphicOverlayCompositorNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

bool GraphicOverlayCompositorNode::hasOverlays() const {
    return !descriptor_.overlays.empty();
}

std::vector<GraphicOverlayDescriptor> GraphicOverlayCompositorNode::activeOverlaysAt(
    uint64_t timelinePtsUs) const {
    std::vector<GraphicOverlayDescriptor> result;
    for (const auto& overlay : descriptor_.overlays) {
        if (OverlayActiveAt(overlay, timelinePtsUs)) {
            result.push_back(overlay);
        }
    }
    std::sort(result.begin(), result.end(),
              [](const GraphicOverlayDescriptor& a, const GraphicOverlayDescriptor& b) {
                  if (a.zIndex != b.zIndex) return a.zIndex < b.zIndex;
                  return a.overlayId < b.overlayId;
              });
    return result;
}

} // namespace compositors
} // namespace vanguard
