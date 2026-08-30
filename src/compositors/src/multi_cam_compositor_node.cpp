#include "vanguard/compositors/multi_cam_compositor_node.h"

#include <algorithm>
#include <cmath>

namespace vanguard {
namespace compositors {

namespace {

constexpr double kDefaultCanvasAspect   = 1.0;
constexpr double kDefaultAspectRatio    = 9.0 / 16.0;
constexpr double kDefaultNormalizedWidth = 0.35;
constexpr double kDefaultMarginFraction = 0.05;
constexpr double kDefaultOpacity        = 1.0;
constexpr double kDefaultSplitRatio     = 0.5;
constexpr double kDefaultCenter         = 0.5;

constexpr double kMinPipWidth    = 0.05;
constexpr double kMaxPipWidth    = 0.95;
constexpr double kMinSplitRatio  = 0.2;
constexpr double kMaxSplitRatio  = 0.8;

double SanitizeFinite(double value, double fallback) {
    return std::isfinite(value) ? value : fallback;
}

double Clamp(double value, double lo, double hi) {
    return std::min(hi, std::max(lo, value));
}

// Sanitizes non-finite input to 0.0, then clamps into [0,1]. Used as the
// final fail-safe on every output rect field.
double ClampUnit(double value) {
    return Clamp(SanitizeFinite(value, 0.0), 0.0, 1.0);
}

MultiCamLayoutResult ComputePictureInPictureLayout(const MultiCamLayout& layout) {
    const bool validCanvas =
        std::isfinite(layout.canvasWidth) && std::isfinite(layout.canvasHeight) &&
        layout.canvasWidth > 0.0 && layout.canvasHeight > 0.0;
    const double canvasAspect = validCanvas
        ? (layout.canvasWidth / layout.canvasHeight)
        : kDefaultCanvasAspect;

    const double aspectRatioRaw = layout.pip.aspectRatio;
    const double aspectRatio = (std::isfinite(aspectRatioRaw) && aspectRatioRaw > 0.0)
        ? aspectRatioRaw
        : kDefaultAspectRatio;

    double pipWidth = SanitizeFinite(layout.pip.normalizedWidth, kDefaultNormalizedWidth);
    pipWidth = Clamp(pipWidth, kMinPipWidth, kMaxPipWidth);

    // pipHeight is normalized to canvas height; canvasAspect converts the
    // width-normalized pipWidth into the same vertical units.
    double pipHeight = pipWidth * canvasAspect / aspectRatio;
    pipHeight = ClampUnit(pipHeight);

    const double marginFraction = SanitizeFinite(layout.pip.marginFraction, kDefaultMarginFraction);
    const double horizontalMargin = marginFraction;
    // Vertical margin must be expressed in canvas-height-normalized units to
    // preserve the same physical (pixel) margin as the horizontal one.
    const double verticalMargin = marginFraction * canvasAspect;

    double centerX;
    double centerY;
    switch (layout.pip.anchor) {
        case MultiCamPiPAnchor::kTopLeft:
            centerX = horizontalMargin + pipWidth / 2.0;
            centerY = verticalMargin + pipHeight / 2.0;
            break;
        case MultiCamPiPAnchor::kTopRight:
            centerX = 1.0 - horizontalMargin - pipWidth / 2.0;
            centerY = verticalMargin + pipHeight / 2.0;
            break;
        case MultiCamPiPAnchor::kBottomLeft:
            centerX = horizontalMargin + pipWidth / 2.0;
            centerY = 1.0 - verticalMargin - pipHeight / 2.0;
            break;
        case MultiCamPiPAnchor::kBottomRight:
            centerX = 1.0 - horizontalMargin - pipWidth / 2.0;
            centerY = 1.0 - verticalMargin - pipHeight / 2.0;
            break;
        case MultiCamPiPAnchor::kFreeFloating:
        default:
            centerX = ClampUnit(SanitizeFinite(layout.pip.centerX, kDefaultCenter));
            centerY = ClampUnit(SanitizeFinite(layout.pip.centerY, kDefaultCenter));
            break;
    }

    const double x = ClampUnit(centerX - pipWidth / 2.0);
    const double y = ClampUnit(centerY - pipHeight / 2.0);

    const double opacity = ClampUnit(SanitizeFinite(layout.pip.opacity, kDefaultOpacity));

    // Corner radius is expressed as a fraction of canvas width; pipHeight is
    // converted back into width-normalized units (dividing out canvasAspect)
    // before taking the min, matching the units pipWidth is already in.
    const double cornerRadiusMax =
        std::max(0.0, std::min(pipWidth, pipHeight / canvasAspect) / 2.0);
    const double cornerRadiusRaw =
        SanitizeFinite(layout.pip.cornerRadiusFractionOfCanvasWidth, 0.0);
    const double cornerRadius = Clamp(cornerRadiusRaw, 0.0, cornerRadiusMax);

    MultiCamLayoutResult result;
    result.primaryViewport   = NormalizedRect{0.0, 0.0, 1.0, 1.0};
    result.secondaryViewport = NormalizedRect{x, y, pipWidth, pipHeight};
    result.primaryCrop       = NormalizedRect{0.0, 0.0, 1.0, 1.0};
    result.secondaryCrop     = NormalizedRect{0.0, 0.0, 1.0, 1.0};
    result.secondaryOpacity  = opacity;
    result.secondaryCornerRadiusFractionOfCanvasWidth = cornerRadius;
    return result;
}

MultiCamLayoutResult ComputeSplitScreenLayout(const MultiCamLayout& layout) {
    double splitRatio = SanitizeFinite(layout.split.splitRatio, kDefaultSplitRatio);
    splitRatio = Clamp(splitRatio, kMinSplitRatio, kMaxSplitRatio);

    MultiCamLayoutResult result;
    if (layout.split.direction == MultiCamSplitDirection::kTopBottom) {
        result.primaryViewport   = NormalizedRect{0.0, 0.0, 1.0, splitRatio};
        result.secondaryViewport = NormalizedRect{0.0, splitRatio, 1.0, 1.0 - splitRatio};
    } else {
        result.primaryViewport   = NormalizedRect{0.0, 0.0, splitRatio, 1.0};
        result.secondaryViewport = NormalizedRect{splitRatio, 0.0, 1.0 - splitRatio, 1.0};
    }
    result.primaryCrop      = NormalizedRect{0.0, 0.0, 1.0, 1.0};
    result.secondaryCrop    = NormalizedRect{0.0, 0.0, 1.0, 1.0};
    result.secondaryOpacity = 1.0;
    result.secondaryCornerRadiusFractionOfCanvasWidth = 0.0;
    return result;
}

} // namespace

MultiCamLayoutResult ComputeMultiCamLayout(const MultiCamLayout& layout) {
    if (layout.mode == MultiCamLayoutMode::kSplitScreen) {
        return ComputeSplitScreenLayout(layout);
    }
    return ComputePictureInPictureLayout(layout);
}

MultiCamCompositorNode::MultiCamCompositorNode(std::string id) : id_(std::move(id)) {
    inputPorts_.push_back({"primary_video_in", vanguard::graph::PortDataType::kVideoFrame});
    inputPorts_.push_back({"secondary_video_in", vanguard::graph::PortDataType::kVideoFrame});
    outputPorts_.push_back({"composited_video_out", vanguard::graph::PortDataType::kVideoFrame});
}

const std::string& MultiCamCompositorNode::id() const {
    return id_;
}

vanguard::graph::NodeKind MultiCamCompositorNode::kind() const {
    return vanguard::graph::NodeKind::kProcessing;
}

vanguard::graph::NodeType MultiCamCompositorNode::type() const {
    return vanguard::graph::NodeType::kMultiCamCompositor;
}

const std::vector<vanguard::graph::PortDescriptor>& MultiCamCompositorNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& MultiCamCompositorNode::outputPorts() const {
    return outputPorts_;
}

MultiCamLayoutResult MultiCamCompositorNode::computeLayout(const MultiCamLayout& layout) {
    return ComputeMultiCamLayout(layout);
}

} // namespace compositors
} // namespace vanguard
