#include "vanguard/compositors/vg_timeline_compositor_node.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace vanguard {
namespace compositors {

namespace {

constexpr uint64_t kMaxPtsUs = std::numeric_limits<uint64_t>::max();

double SanitizeSpeedRatio(double speedRatio) {
    if (!std::isfinite(speedRatio) || speedRatio <= 0.0) {
        return 1.0;
    }
    return speedRatio;
}

double ClampUnit(double value) {
    if (!std::isfinite(value)) {
        return 0.0;
    }
    return std::min(1.0, std::max(0.0, value));
}

// Converts a non-negative double microsecond count to uint64, saturating at
// UINT64_MAX and treating non-finite/negative values as 0.
uint64_t SaturatingDoubleToPtsUs(double value) {
    if (!std::isfinite(value) || value <= 0.0) {
        return 0;
    }
    // 2^64 as a double; any value at or above it cannot be represented.
    constexpr double kTwoPow64 = 18446744073709551616.0;
    if (value >= kTwoPow64) {
        return kMaxPtsUs;
    }
    return static_cast<uint64_t>(value);
}

TimelineNormalizedRect IdentityRect() {
    return TimelineNormalizedRect{0.0, 0.0, 1.0, 1.0};
}

const TimelineClipDescriptor* FindClipById(const std::vector<TimelineClipDescriptor>& clips,
                                           const std::string& clipId) {
    if (clipId.empty()) {
        return nullptr;
    }
    for (const auto& clip : clips) {
        if (clip.clipId == clipId) {
            return &clip;
        }
    }
    return nullptr;
}

// Hard-cut primary selection: later-placed active clip wins; ties keep vector
// order (first wins).
const TimelineClipDescriptor* SelectHardCutPrimary(const std::vector<TimelineClipDescriptor>& clips,
                                                   uint64_t timelinePtsUs) {
    const TimelineClipDescriptor* best = nullptr;
    for (const auto& clip : clips) {
        if (!IsClipActiveAt(clip, timelinePtsUs)) {
            continue;
        }
        if (best == nullptr || clip.timelineStartPtsUs > best->timelineStartPtsUs) {
            best = &clip;
        }
    }
    return best;
}

} // namespace

// ── Pure helper math ────────────────────────────────────────────────────────

uint64_t SaturatingAddPtsUs(uint64_t a, uint64_t b) {
    if (a > kMaxPtsUs - b) {
        return kMaxPtsUs;
    }
    return a + b;
}

uint64_t ClipEndPtsUs(const TimelineClipDescriptor& clip) {
    return SaturatingAddPtsUs(clip.timelineStartPtsUs, clip.durationUs);
}

bool IsClipActiveAt(const TimelineClipDescriptor& clip, uint64_t timelinePtsUs) {
    if (clip.durationUs == 0) {
        return false;
    }
    return timelinePtsUs >= clip.timelineStartPtsUs && timelinePtsUs < ClipEndPtsUs(clip);
}

uint64_t MapClipTimelineToLocalPts(const TimelineClipDescriptor& clip, uint64_t timelinePtsUs) {
    const uint64_t delta = timelinePtsUs > clip.timelineStartPtsUs
        ? (timelinePtsUs - clip.timelineStartPtsUs)
        : 0;
    const double speed = SanitizeSpeedRatio(clip.speedRatio);

    uint64_t scaled;
    if (speed == 1.0) {
        // Exact integer path avoids double precision loss for large deltas.
        scaled = delta;
    } else {
        scaled = SaturatingDoubleToPtsUs(std::floor(static_cast<double>(delta) * speed));
    }
    return SaturatingAddPtsUs(clip.sourceTrimInPtsUs, scaled);
}

bool IsTransitionActiveAt(const TimelineTransitionDescriptor& transition, uint64_t timelinePtsUs) {
    if (transition.durationUs == 0) {
        return false;
    }
    const uint64_t end = SaturatingAddPtsUs(transition.timelineStartPtsUs, transition.durationUs);
    return timelinePtsUs >= transition.timelineStartPtsUs && timelinePtsUs < end;
}

double TransitionProgressAt(const TimelineTransitionDescriptor& transition, uint64_t timelinePtsUs) {
    if (!IsTransitionActiveAt(transition, timelinePtsUs)) {
        return 0.0;
    }
    // durationUs != 0 is guaranteed by IsTransitionActiveAt above.
    const uint64_t elapsed = timelinePtsUs - transition.timelineStartPtsUs;
    const double progress =
        static_cast<double>(elapsed) / static_cast<double>(transition.durationUs);
    return ClampUnit(progress);
}

TimelineTransitionProgress ComputeTransitionGeometry(TransitionType type, double progress) {
    TimelineTransitionProgress result;
    result.fromViewport = IdentityRect();
    result.toViewport   = IdentityRect();
    result.fromCrop     = IdentityRect();
    result.toCrop       = IdentityRect();

    if (type == TransitionType::kNone) {
        result.isTransitionActive = false;
        result.type               = TransitionType::kNone;
        result.progress           = 0.0;
        result.blendWeightFrom    = 1.0;
        result.blendWeightTo      = 0.0;
        return result;
    }

    const double p = ClampUnit(progress);
    result.isTransitionActive = true;
    result.type               = type;
    result.progress           = p;

    switch (type) {
        case TransitionType::kCrossfade:
            result.blendWeightFrom = 1.0 - p;
            result.blendWeightTo   = p;
            break;

        // Slides: full-size viewports translated across the canvas. Viewport
        // x/y intentionally leave [0,1] to describe off-canvas motion.
        case TransitionType::kSlideLeft:
            result.blendWeightFrom = 1.0;
            result.blendWeightTo   = 1.0;
            result.fromViewport.x  = -p;
            result.toViewport.x    = 1.0 - p;
            break;
        case TransitionType::kSlideRight:
            result.blendWeightFrom = 1.0;
            result.blendWeightTo   = 1.0;
            result.fromViewport.x  = p;
            result.toViewport.x    = p - 1.0;
            break;
        case TransitionType::kSlideUp:
            result.blendWeightFrom = 1.0;
            result.blendWeightTo   = 1.0;
            result.fromViewport.y  = -p;
            result.toViewport.y    = 1.0 - p;
            break;
        case TransitionType::kSlideDown:
            result.blendWeightFrom = 1.0;
            result.blendWeightTo   = 1.0;
            result.fromViewport.y  = p;
            result.toViewport.y    = p - 1.0;
            break;

        // Wipes: identity viewports, complementary crops that always tile
        // the canvas exactly (from + to == full extent along the wipe axis).
        case TransitionType::kWipeLeft:
            result.blendWeightFrom = 1.0;
            result.blendWeightTo   = 1.0;
            result.fromCrop.width  = 1.0 - p;
            result.toCrop.x        = 1.0 - p;
            result.toCrop.width    = p;
            break;
        case TransitionType::kWipeRight:
            result.blendWeightFrom = 1.0;
            result.blendWeightTo   = 1.0;
            result.fromCrop.x      = p;
            result.fromCrop.width  = 1.0 - p;
            result.toCrop.x        = 0.0;
            result.toCrop.width    = p;
            break;
        case TransitionType::kWipeUp:
            result.blendWeightFrom = 1.0;
            result.blendWeightTo   = 1.0;
            result.fromCrop.height = 1.0 - p;
            result.toCrop.y        = 1.0 - p;
            result.toCrop.height   = p;
            break;
        case TransitionType::kWipeDown:
            result.blendWeightFrom = 1.0;
            result.blendWeightTo   = 1.0;
            result.fromCrop.y      = p;
            result.fromCrop.height = 1.0 - p;
            result.toCrop.y        = 0.0;
            result.toCrop.height   = p;
            break;

        case TransitionType::kNone:
        default:
            // Unreachable for kNone (handled above); unknown enum values are
            // treated as an inactive transition for fail-safety.
            result.isTransitionActive = false;
            result.type               = TransitionType::kNone;
            result.progress           = 0.0;
            result.blendWeightFrom    = 1.0;
            result.blendWeightTo      = 0.0;
            break;
    }
    return result;
}

TimelineCompositionState EvaluateTimelineComposition(
    uint64_t                                          timelinePtsUs,
    const std::vector<TimelineClipDescriptor>&        clips,
    const std::vector<TimelineTransitionDescriptor>&  transitions) {

    TimelineCompositionState state;
    state.transition = ComputeTransitionGeometry(TransitionType::kNone, 0.0);

    // 1. Transition window lookup (first match in vector order).
    for (const auto& transition : transitions) {
        if (transition.type == TransitionType::kNone) {
            continue;
        }
        if (!IsTransitionActiveAt(transition, timelinePtsUs)) {
            continue;
        }
        if (transition.fromClipId == transition.toClipId) {
            continue;
        }
        const TimelineClipDescriptor* fromClip = FindClipById(clips, transition.fromClipId);
        const TimelineClipDescriptor* toClip   = FindClipById(clips, transition.toClipId);
        if (fromClip == nullptr || toClip == nullptr) {
            continue; // Fail-safe: unresolved endpoint, ignore this transition.
        }

        state.hasActiveClip       = true;
        state.primaryClipId       = fromClip->clipId;
        state.primaryLocalPtsUs   = MapClipTimelineToLocalPts(*fromClip, timelinePtsUs);
        state.secondaryClipId     = toClip->clipId;
        state.secondaryLocalPtsUs = MapClipTimelineToLocalPts(*toClip, timelinePtsUs);
        state.transition          = ComputeTransitionGeometry(
            transition.type, TransitionProgressAt(transition, timelinePtsUs));
        return state;
    }

    // 2. Hard-cut evaluation.
    const TimelineClipDescriptor* primary = SelectHardCutPrimary(clips, timelinePtsUs);
    if (primary != nullptr) {
        state.hasActiveClip     = true;
        state.primaryClipId     = primary->clipId;
        state.primaryLocalPtsUs = MapClipTimelineToLocalPts(*primary, timelinePtsUs);
        return state;
    }

    // 3. Nothing active: identity result.
    return state;
}

// ── Node ────────────────────────────────────────────────────────────────────

VGTimelineCompositorNode::VGTimelineCompositorNode(std::string id) : id_(std::move(id)) {
    inputPorts_.push_back({"clip_0_video_in", vanguard::graph::PortDataType::kVideoFrame});
    inputPorts_.push_back({"clip_1_video_in", vanguard::graph::PortDataType::kVideoFrame});
    outputPorts_.push_back({"composited_video_out", vanguard::graph::PortDataType::kVideoFrame});
}

const std::string& VGTimelineCompositorNode::id() const {
    return id_;
}

vanguard::graph::NodeKind VGTimelineCompositorNode::kind() const {
    return vanguard::graph::NodeKind::kProcessing;
}

vanguard::graph::NodeType VGTimelineCompositorNode::type() const {
    return vanguard::graph::NodeType::kVGTimelineCompositor;
}

const std::vector<vanguard::graph::PortDescriptor>& VGTimelineCompositorNode::inputPorts() const {
    return inputPorts_;
}

const std::vector<vanguard::graph::PortDescriptor>& VGTimelineCompositorNode::outputPorts() const {
    return outputPorts_;
}

bool VGTimelineCompositorNode::isActiveAt(uint64_t timelinePtsUs) const {
    return evaluate(timelinePtsUs).hasActiveClip;
}

uint64_t VGTimelineCompositorNode::mapTimelineToLocalPts(uint64_t timelinePtsUs) const {
    const TimelineCompositionState state = evaluate(timelinePtsUs);
    return state.hasActiveClip ? state.primaryLocalPtsUs : timelinePtsUs;
}

float VGTimelineCompositorNode::blendWeightAt(uint64_t timelinePtsUs) const {
    const TimelineCompositionState state = evaluate(timelinePtsUs);
    if (!state.hasActiveClip) {
        return 0.0f;
    }
    if (state.transition.isTransitionActive) {
        return static_cast<float>(state.transition.blendWeightFrom);
    }
    return 1.0f;
}

void VGTimelineCompositorNode::setClips(std::vector<TimelineClipDescriptor> clips) {
    clips_ = std::move(clips);
}

void VGTimelineCompositorNode::setTransitions(std::vector<TimelineTransitionDescriptor> transitions) {
    transitions_ = std::move(transitions);
}

const std::vector<TimelineClipDescriptor>& VGTimelineCompositorNode::clips() const {
    return clips_;
}

const std::vector<TimelineTransitionDescriptor>& VGTimelineCompositorNode::transitions() const {
    return transitions_;
}

TimelineCompositionState VGTimelineCompositorNode::evaluate(uint64_t timelinePtsUs) const {
    return EvaluateTimelineComposition(timelinePtsUs, clips_, transitions_);
}

} // namespace compositors
} // namespace vanguard
