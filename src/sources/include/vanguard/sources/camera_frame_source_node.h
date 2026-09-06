#pragma once
#include "vanguard/graph/node.h"
#include <cstdint>
#include <string>
#include <vector>

namespace vanguard {
namespace sources {

// P3-CAMERA-FRAME-SOURCE-NODE-A: platform-neutral logical DAG source node
// for live camera frames delivered by Kotlin Camera2 capture, mirroring
// DecodedMediaFrameSourceNode's and StreamSourceNode's role for camera
// ingest. This node owns no Camera2 session, HardwareBuffer, frame buffer,
// texture, or other OS resource, and includes no Android/NDK/Camera2
// headers - Kotlin remains the sole owner of the camera open/capture
// lifecycle. This node only represents the node's identity, ports, and
// timeline-window semantics within the DAG, mirroring
// DecodedMediaFrameSourceNode's timeline behavior (active window
// [start, start+duration), saturating end; map before start to 0; map
// within window to elapsed; map at/after end to duration).
class CameraFrameSourceNode : public vanguard::graph::Node {
public:
    CameraFrameSourceNode(std::string id,
                           std::string cameraId,
                           uint64_t timelineStartPtsUs,
                           uint64_t durationUs,
                           int32_t width,
                           int32_t height,
                           int32_t sensorOrientationDegrees,
                           bool mirrorHorizontal,
                           bool live);

    // Delegating overload defaulting sensorOrientationDegrees=0,
    // mirrorHorizontal=false, live=true.
    CameraFrameSourceNode(std::string id,
                           std::string cameraId,
                           uint64_t timelineStartPtsUs,
                           uint64_t durationUs,
                           int32_t width,
                           int32_t height);

    const std::string&                                  id()          const override;
    vanguard::graph::NodeKind                           kind()        const override;
    vanguard::graph::NodeType                           type()        const override;
    const std::vector<vanguard::graph::PortDescriptor>& inputPorts()  const override;
    const std::vector<vanguard::graph::PortDescriptor>& outputPorts() const override;

    bool     isActiveAt(uint64_t timelinePtsUs) const override;
    uint64_t mapTimelineToLocalPts(uint64_t timelinePtsUs) const override;
    float    blendWeightAt(uint64_t timelinePtsUs) const override;

    const std::string& cameraId()                 const;
    uint64_t            timelineStartPtsUs()       const;
    uint64_t            durationUs()               const;
    // Saturates to UINT64_MAX instead of overflowing when
    // timelineStartPtsUs() + durationUs() would exceed it.
    uint64_t            timelineEndPtsUs()         const;
    int32_t              width()                    const;
    int32_t              height()                   const;
    int32_t              sensorOrientationDegrees() const;
    bool                 mirrorHorizontal()         const;
    bool                 live()                     const;

private:
    std::string id_;
    std::string cameraId_;
    uint64_t    timelineStartPtsUs_;
    uint64_t    durationUs_;
    int32_t     width_;
    int32_t     height_;
    int32_t     sensorOrientationDegrees_;
    bool        mirrorHorizontal_;
    bool        live_;

    std::vector<vanguard::graph::PortDescriptor> inputPorts_;
    std::vector<vanguard::graph::PortDescriptor> outputPorts_;
};

} // namespace sources
} // namespace vanguard
