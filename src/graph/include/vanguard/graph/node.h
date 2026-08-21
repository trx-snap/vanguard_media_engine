#pragma once
#include "vanguard/core/status.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace graph {

// Broad role of a node in the DAG.
enum class NodeKind {
    kSource,
    kProcessing,
    kSink
};

// Fine-grained node type used for capability dispatch.
enum class NodeType {
    kHardwareBufferSource,
    kExternalSurfaceSource,
    kCameraFrameSource,
    kDecodedMediaFrameSource,
    kImageTextureSource,
    kAudioSource,
    kStreamSource,
    kSpatialTransform,
    kFilter,
    kMultiCamCompositor,
    kVGTimelineCompositor,
    kGraphicOverlayCompositor,
    kAudioMixBus,
    kPreviewSurfaceSink,
    kOfflineMediaMuxerSink,
    kPassthroughRemuxSink,
    kImageOptimizerSink,
    kCustom
};

// Data type carried by a port.
enum class PortDataType {
    kVideoFrame,
    kAudioPacket,
    kTextureBuffer,
    kMetadata
};

// Descriptor for a single input or output port on a node.
struct PortDescriptor {
    std::string  id;
    PortDataType dataType;
};

// Abstract base for all DAG nodes.
class Node {
public:
    virtual ~Node() = default;

    virtual const std::string&                 id()          const = 0;
    virtual NodeKind                           kind()        const = 0;
    virtual NodeType                           type()        const = 0;
    virtual const std::vector<PortDescriptor>& inputPorts()  const = 0;
    virtual const std::vector<PortDescriptor>& outputPorts() const = 0;

    // Timeline evaluation methods.
    virtual bool     isActiveAt(uint64_t timelinePtsUs) const { return true; }
    virtual uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const { return timelinePtsUs; }
    virtual float    blendWeightAt(uint64_t timelinePtsUs) const { return 1.0f; }
};

} // namespace graph
} // namespace vanguard
