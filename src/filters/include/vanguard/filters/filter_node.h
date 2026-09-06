#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace filters {

// RGBA color matrix in the Android/Flutter `ColorFilter.matrix` 4x5 layout:
// 4 rows of [R,G,B,A] weights plus a per-row additive offset (row-major, 20
// values total). Default is the identity matrix (no offset):
//   R' = m[0]*R  + m[1]*G  + m[2]*B  + m[3]*A  + m[4]
//   G' = m[5]*R  + m[6]*G  + m[7]*B  + m[8]*A  + m[9]
//   B' = m[10]*R + m[11]*G + m[12]*B + m[13]*A + m[14]
//   A' = m[15]*R + m[16]*G + m[17]*B + m[18]*A + m[19]
struct FilterColorMatrix {
    double m[20] = {
        1.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0, 0.0,
    };
};

// A single RGBA color sample consumed/produced by applyColorMatrix().
struct FilterRgba {
    double r{0.0};
    double g{0.0};
    double b{0.0};
    double a{0.0};
};

// Beauty V2 primitive parameter metadata. Each field is expected to lie in
// [0, 1]; validated by FilterNode's constructor.
struct FilterBeautyV2Parameters {
    double intensity{0.0};
    double smoothing{0.0};
    double whitening{0.0};
    double skinTone{0.0};
};

// Per-instance filter configuration for a FilterNode.
struct FilterDescriptor {
    uint64_t                 timelineStartPtsUs{0};
    uint64_t                 durationUs{UINT64_MAX};
    bool                     colorMatrixEnabled{false};
    FilterColorMatrix        colorMatrix{};
    bool                     beautyV2Enabled{false};
    FilterBeautyV2Parameters beauty{};
};

// P5-FILTER-NODE-A: platform-neutral logical DAG processing node applying
// Beauty V2 and color-matrix filter metadata - see "UMF architecture/
// 01_True_DAG_Parity_Spec_V4.3.md" §12 Processing Nodes. This node owns only
// primitive color-matrix/Beauty-V2 parameter metadata and pure CPU sample
// math - no renderer, shader, GLES/Vulkan texture, decoder, Android
// lifecycle, file IO, thread, MediaCodec, or product/app/editor wiring.
class FilterNode : public vanguard::graph::Node {
public:
    explicit FilterNode(std::string id, FilterDescriptor descriptor = FilterDescriptor{});

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    const FilterDescriptor&         descriptor()  const;
    const FilterColorMatrix&        colorMatrix() const;
    const FilterBeautyV2Parameters& beauty()      const;
    uint64_t                        timelineStartPtsUs() const;
    uint64_t                        durationUs()         const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t                        timelineEndPtsUs()   const;

    // True when colorMatrixEnabled is true.
    bool hasColorMatrix() const;
    // True when beautyV2Enabled is true.
    bool hasBeautyV2() const;

    // True when neither enabled effect would visibly change a frame: the
    // color matrix is disabled or equals the identity matrix within
    // `epsilon`, and Beauty V2 is disabled or every parameter is within
    // `epsilon` of 0.
    bool isPassThrough(double epsilon = 1e-9) const;

    // Applies colorMatrix() to `input` when colorMatrixEnabled is true;
    // otherwise returns `input` unchanged.
    FilterRgba applyColorMatrix(const FilterRgba& input) const;

private:
    std::string      id_;
    FilterDescriptor descriptor_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace filters
} // namespace vanguard
