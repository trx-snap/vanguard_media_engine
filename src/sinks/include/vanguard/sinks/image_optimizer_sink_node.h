#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace sinks {

// Output container format requested for the eventual downscaled/optimized
// image asset. This is metadata only - no JPEG/PNG/HEIC encoder lives here.
enum class ImageOptimizerOutputFormat {
    kJpeg,
    kPng,
    kHeic
};

// Per-instance configuration for an ImageOptimizerSinkNode. Validated by
// the node's constructor.
struct ImageOptimizerSinkDescriptor {
    uint64_t                    timelineStartPtsUs{0};
    uint64_t                    durationUs{1};
    int32_t                     targetWidth{1};
    int32_t                     targetHeight{1};
    int32_t                     qualityPercent{90};
    ImageOptimizerOutputFormat  outputFormat{ImageOptimizerOutputFormat::kJpeg};
    bool                        generateThumbnail{true};
    bool                        preserveExifOrientation{true};
};

// P5-IMAGE-OPTIMIZER-SINK-NODE-A: platform-neutral logical DAG sink node
// representing the eventual downscaled-thumbnail/optimized-JPEG (or PNG/
// HEIC) output (see "UMF architecture/01_True_DAG_Parity_Spec_V4.3.md" §12
// Sink Nodes), mirroring OfflineMediaMuxerSinkNode's and
// PreviewSurfaceSinkNode's role for their respective sink targets.
//
// This node is a pure graph-topology/timeline participant: it owns no
// decoded pixels, Bitmap/ImageDecoder lifecycle, JPEG/PNG/HEIC encoder
// lifecycle, output file/path/file descriptor, GPU texture/sampler/
// lifecycle, Android lifecycle, MediaCodec, thread, or other OS resource,
// and includes no Android/NDK/EGL/GLES/Vulkan header. AndroidImageOptimizer
// and other platform adapters remain the sole owners of the actual decode/
// downscale/encode/file-IO lifecycle; this node only lets the native graph
// reason about the sink's identity, required ports, target/quality/format
// metadata, and timeline-window semantics (active window
// [start, start+duration), saturating end; map before start to 0; map
// within window to elapsed; map at/after end to duration), mirroring
// OfflineMediaMuxerSinkNode's timeline behavior.
class ImageOptimizerSinkNode : public vanguard::graph::Node {
public:
    explicit ImageOptimizerSinkNode(
        std::string id,
        ImageOptimizerSinkDescriptor descriptor = ImageOptimizerSinkDescriptor{});

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    const ImageOptimizerSinkDescriptor& descriptor() const;
    int32_t                             targetWidth()             const;
    int32_t                             targetHeight()            const;
    int32_t                             qualityPercent()          const;
    ImageOptimizerOutputFormat          outputFormat()            const;
    bool                                generateThumbnail()       const;
    bool                                preserveExifOrientation() const;
    uint64_t                            timelineStartPtsUs()      const;
    uint64_t                            durationUs()              const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t                            timelineEndPtsUs()        const;

private:
    std::string                                  id_;
    ImageOptimizerSinkDescriptor                 descriptor_;
    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sinks
} // namespace vanguard
