#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace transforms {

// 2D affine transform matrix in the CSS/SVG `matrix(a, b, c, d, tx, ty)`
// convention:
//   x' = a*x + c*y + tx
//   y' = b*x + d*y + ty
struct SpatialAffineMatrix {
    double a{1.0};
    double b{0.0};
    double c{0.0};
    double d{1.0};
    double tx{0.0};
    double ty{0.0};
};

// Normalized crop rectangle in unit [0,1] coordinate space.
struct SpatialCropRect {
    double x{0.0};
    double y{0.0};
    double width{1.0};
    double height{1.0};
};

// A single point in the same 2D space the matrix/crop operate over.
struct SpatialPoint {
    double x{0.0};
    double y{0.0};
};

// Per-instance transform configuration for a SpatialTransformNode.
struct SpatialTransformDescriptor {
    uint64_t            timelineStartPtsUs{0};
    uint64_t            durationUs{UINT64_MAX};
    SpatialAffineMatrix matrix{};
    SpatialCropRect     crop{};
};

// P5-SPATIAL-TRANSFORM-NODE-A: platform-neutral logical DAG processing node
// applying a 2D affine transform (crop, scale, rotate, translate) - see
// "UMF architecture/01_True_DAG_Parity_Spec_V4.3.md" §12 and
// "UMF architecture/02_Node_Taxonomy_And_Graph.md" §2.2. This node owns only
// primitive matrix/crop/timeline metadata - no renderer, shader, texture,
// decoder, Android lifecycle, or GPU object, and creates no OS-level
// surface.
class SpatialTransformNode : public vanguard::graph::Node {
public:
    explicit SpatialTransformNode(
        std::string id,
        SpatialTransformDescriptor descriptor = SpatialTransformDescriptor{});

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    const SpatialTransformDescriptor& descriptor() const;
    const SpatialAffineMatrix&        matrix()     const;
    const SpatialCropRect&            crop()       const;
    uint64_t                          timelineStartPtsUs() const;
    uint64_t                          durationUs()         const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t                          timelineEndPtsUs()   const;

    // True when matrix() is the identity transform within `epsilon`.
    bool isIdentityTransform(double epsilon = 1e-9) const;

    // Applies matrix() to `point` (x' = a*x + c*y + tx; y' = b*x + d*y + ty).
    SpatialPoint applyToPoint(const SpatialPoint& point) const;

private:
    std::string                id_;
    SpatialTransformDescriptor descriptor_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace transforms
} // namespace vanguard
