#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace compositors {

// Kind of graphic overlay primitive carried by a GraphicOverlayDescriptor.
// This is metadata only - no PNG decode, rasterizer, or renderer lives
// here.
enum class GraphicOverlayKind {
    kPng,
    kText,
    kSticker,
    kEmoji
};

// Normalized canvas-space rectangle for an overlay's on-screen placement:
// top-left origin, unit [0,1] on both axes.
struct GraphicOverlayBounds {
    double x{0.0};
    double y{0.0};
    double width{1.0};
    double height{1.0};
};

// Per-overlay primitive metadata: identity, kind, timeline window, canvas
// bounds, opacity, and stacking order. Validated by
// GraphicOverlayCompositorNode's constructor.
struct GraphicOverlayDescriptor {
    std::string           overlayId;
    GraphicOverlayKind     kind{GraphicOverlayKind::kPng};
    uint64_t               timelineStartPtsUs{0};
    uint64_t               durationUs{UINT64_MAX};
    GraphicOverlayBounds   bounds{};
    double                 opacity{1.0};
    int                    zIndex{0};
};

// Per-instance configuration for a GraphicOverlayCompositorNode.
struct GraphicOverlayCompositorDescriptor {
    uint64_t                              timelineStartPtsUs{0};
    uint64_t                              durationUs{UINT64_MAX};
    uint32_t                              overlayInputCount{1};
    std::vector<GraphicOverlayDescriptor> overlays{};
};

// P5-GRAPHIC-OVERLAY-COMPOSITOR-NODE-A: platform-neutral logical DAG
// processing node compositing UI graphic (PNG), text, sticker, and emoji
// overlays over a base video stream - see "UMF architecture/
// 01_True_DAG_Parity_Spec_V4.3.md" §12 Processing Nodes. This node owns
// only primitive overlay/timeline metadata and pure topology - no
// renderer, PNG decoder, text rasterizer, shader, GL/GLES/Vulkan texture/
// sampler, GPU lifecycle, Android lifecycle, file IO, MediaCodec, thread,
// or product/app/editor/ConnectsApp wiring.
class GraphicOverlayCompositorNode : public vanguard::graph::Node {
public:
    explicit GraphicOverlayCompositorNode(
        std::string id,
        GraphicOverlayCompositorDescriptor descriptor = GraphicOverlayCompositorDescriptor{});

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    const GraphicOverlayCompositorDescriptor& descriptor() const;
    uint32_t                                   overlayInputCount() const;
    const std::vector<GraphicOverlayDescriptor>& overlays() const;
    uint64_t                                   timelineStartPtsUs() const;
    uint64_t                                   durationUs()         const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t                                   timelineEndPtsUs()   const;

    // True when at least one overlay descriptor is configured.
    bool hasOverlays() const;

    // Returns the overlays whose own half-open timeline interval
    // [timelineStartPtsUs, timelineStartPtsUs + durationUs) contains
    // `timelinePtsUs` (saturated end, same semantics as the node's own
    // timeline window), sorted by zIndex ascending then overlayId
    // ascending.
    std::vector<GraphicOverlayDescriptor> activeOverlaysAt(uint64_t timelinePtsUs) const;

private:
    std::string                                  id_;
    GraphicOverlayCompositorDescriptor           descriptor_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace compositors
} // namespace vanguard
