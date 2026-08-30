#pragma once
#include "vanguard/graph/node.h"
#include <string>
#include <vector>

namespace vanguard {
namespace compositors {

// Normalized-space layout mode for the two-input multi-camera compositor.
enum class MultiCamLayoutMode {
    kPictureInPicture,
    kSplitScreen
};

// Split-screen tiling axis.
enum class MultiCamSplitDirection {
    kTopBottom,
    kLeftRight
};

// Corner-snap anchor for picture-in-picture placement. kFreeFloating uses the
// caller-supplied center directly instead of a margin-derived corner offset.
enum class MultiCamPiPAnchor {
    kFreeFloating,
    kTopLeft,
    kTopRight,
    kBottomLeft,
    kBottomRight
};

// A rectangle in normalized coordinates: top-left origin, Y-down. `x`/`width`
// are fractions of canvas width; `y`/`height` are fractions of canvas height
// (the two axes are normalized independently, which is why layout math below
// must explicitly convert between them via the canvas aspect ratio).
struct NormalizedRect {
    double x;
    double y;
    double width;
    double height;
};

struct MultiCamPiPGeometry {
    MultiCamPiPAnchor anchor;
    double            centerX;
    double            centerY;
    double            normalizedWidth;
    double            aspectRatio;
    double            marginFraction;
    double            cornerRadiusFractionOfCanvasWidth;
    double            opacity;
};

struct MultiCamSplitGeometry {
    MultiCamSplitDirection direction;
    double                 splitRatio;
};

struct MultiCamLayout {
    MultiCamLayoutMode     mode;
    double                 canvasWidth;
    double                 canvasHeight;
    MultiCamPiPGeometry    pip;
    MultiCamSplitGeometry  split;
};

// Resolved, render-ready geometry for both inputs of the compositor. The
// primary viewport is always the full canvas ({0,0,1,1}); crops default to
// identity ({0,0,1,1}) in this foundation slice (no cropping is computed
// yet). All fields are guaranteed finite.
struct MultiCamLayoutResult {
    NormalizedRect primaryViewport;
    NormalizedRect secondaryViewport;
    NormalizedRect primaryCrop;
    NormalizedRect secondaryCrop;
    double         secondaryOpacity;
    double         secondaryCornerRadiusFractionOfCanvasWidth;
};

// Pure layout math, free of any node/graph/render state, so future renderers
// or tests can call it directly.
//
// Fail-safe clamping (native side): PiP width is clamped to [0.05, 0.95],
// split ratio to [0.2, 0.8], opacity to [0,1], and every output rect field is
// clamped finite into [0,1]. This native clamp is a defensive fail-safe only;
// Dart-side product policy may enforce a narrower range on top of it.
MultiCamLayoutResult ComputeMultiCamLayout(const MultiCamLayout& layout);

// Logical DAG processing node representing a two-input multi-camera
// compositor. Carries no pixel/texture state; it only exposes DAG topology
// (ports/kind/type) and the pure layout math above via a thin wrapper method.
class MultiCamCompositorNode : public vanguard::graph::Node {
public:
    explicit MultiCamCompositorNode(std::string id);

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                          kind()        const override;
    vanguard::graph::NodeType                          type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    static MultiCamLayoutResult computeLayout(const MultiCamLayout& layout);

private:
    std::string                                   id_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace compositors
} // namespace vanguard
