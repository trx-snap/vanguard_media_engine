#include "vanguard/sources/camera_frame_source_node.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace vanguard {
namespace sources {

CameraFrameSourceNode::CameraFrameSourceNode(std::string id,
                                              std::string cameraId,
                                              uint64_t timelineStartPtsUs,
                                              uint64_t durationUs,
                                              int32_t width,
                                              int32_t height,
                                              int32_t sensorOrientationDegrees,
                                              bool mirrorHorizontal,
                                              bool live)
    : id_(std::move(id)),
      cameraId_(std::move(cameraId)),
      timelineStartPtsUs_(timelineStartPtsUs),
      durationUs_(durationUs),
      width_(width),
      height_(height),
      sensorOrientationDegrees_(sensorOrientationDegrees),
      mirrorHorizontal_(mirrorHorizontal),
      live_(live) {
    if (id_.empty()) {
        throw std::invalid_argument("empty_id");
    }
    if (cameraId_.empty()) {
        throw std::invalid_argument("empty_camera_id");
    }
    if (durationUs_ == 0) {
        throw std::invalid_argument("invalid_duration_us");
    }
    if (width_ <= 0) {
        throw std::invalid_argument("invalid_width");
    }
    if (height_ <= 0) {
        throw std::invalid_argument("invalid_height");
    }
    if (sensorOrientationDegrees_ != 0 && sensorOrientationDegrees_ != 90 &&
        sensorOrientationDegrees_ != 180 && sensorOrientationDegrees_ != 270) {
        throw std::invalid_argument("invalid_sensor_orientation_degrees");
    }

    outputPorts_.push_back({"kVideoFrame", vanguard::graph::PortDataType::kVideoFrame});
}

CameraFrameSourceNode::CameraFrameSourceNode(std::string id,
                                              std::string cameraId,
                                              uint64_t timelineStartPtsUs,
                                              uint64_t durationUs,
                                              int32_t width,
                                              int32_t height)
    : CameraFrameSourceNode(std::move(id),
                             std::move(cameraId),
                             timelineStartPtsUs,
                             durationUs,
                             width,
                             height,
                             /*sensorOrientationDegrees=*/0,
                             /*mirrorHorizontal=*/false,
                             /*live=*/true) {}

const std::string& CameraFrameSourceNode::id() const {
    return id_;
}

vanguard::graph::NodeKind CameraFrameSourceNode::kind() const {
    return vanguard::graph::NodeKind::kSource;
}

vanguard::graph::NodeType CameraFrameSourceNode::type() const {
    return vanguard::graph::NodeType::kCameraFrameSource;
}

const std::vector<vanguard::graph::PortDescriptor>& CameraFrameSourceNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& CameraFrameSourceNode::outputPorts() const {
    return outputPorts_;
}

const std::string& CameraFrameSourceNode::cameraId() const {
    return cameraId_;
}

uint64_t CameraFrameSourceNode::timelineStartPtsUs() const {
    return timelineStartPtsUs_;
}

uint64_t CameraFrameSourceNode::durationUs() const {
    return durationUs_;
}

uint64_t CameraFrameSourceNode::timelineEndPtsUs() const {
    return (std::numeric_limits<uint64_t>::max() - timelineStartPtsUs_ < durationUs_)
        ? std::numeric_limits<uint64_t>::max()
        : timelineStartPtsUs_ + durationUs_;
}

int32_t CameraFrameSourceNode::width() const {
    return width_;
}

int32_t CameraFrameSourceNode::height() const {
    return height_;
}

int32_t CameraFrameSourceNode::sensorOrientationDegrees() const {
    return sensorOrientationDegrees_;
}

bool CameraFrameSourceNode::mirrorHorizontal() const {
    return mirrorHorizontal_;
}

bool CameraFrameSourceNode::live() const {
    return live_;
}

bool CameraFrameSourceNode::isActiveAt(uint64_t timelinePtsUs) const {
    const uint64_t endPtsUs = timelineEndPtsUs();
    return timelinePtsUs >= timelineStartPtsUs_ && timelinePtsUs < endPtsUs;
}

uint64_t CameraFrameSourceNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    if (timelinePtsUs < timelineStartPtsUs_) {
        return 0;
    }

    if (timelinePtsUs >= timelineEndPtsUs()) {
        return durationUs_;
    }

    return timelinePtsUs - timelineStartPtsUs_;
}

float CameraFrameSourceNode::blendWeightAt(uint64_t timelinePtsUs) const {
    return isActiveAt(timelinePtsUs) ? 1.0f : 0.0f;
}

} // namespace sources
} // namespace vanguard
